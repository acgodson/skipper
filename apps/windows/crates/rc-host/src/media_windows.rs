//! Media Foundation hardware H.264 encode: the GPU's fixed-function encoder
//! behind the same [`VideoEncoder`] seam as openh264.
//!
//! Compiled only on Windows and, like the capture backend, written against the
//! cross-compiler. Every step that can fail returns an error, and every error
//! means "use openh264": at build time through the factory, mid-session through
//! the pump's one fallback hop. A hardware path that misbehaves costs CPU, never
//! the session.
//!
//! * The encoder is the first hardware H.264 MFT that `MFTEnumEx` offers, in the
//!   system's own merit order. Its friendly name is in [`VideoEncoder::name`], so
//!   the `RC_MEDIA_STATS` line shows which GPU block is doing the work, along
//!   with any low-latency setting it refused.
//! * Hardware MFTs are asynchronous. The transform is unlocked
//!   (`MF_TRANSFORM_ASYNC_UNLOCK`) and driven by its own event queue: input only
//!   against a `METransformNeedInput`, `ProcessOutput` only against a
//!   `METransformHaveOutput`. The queue is polled, never blocked on, so a driver
//!   that stops answering becomes an error after a bounded wait rather than an
//!   encode thread that a stop can never reach.
//! * One frame in, everything the MFT has ready out, as one Annex-B buffer with
//!   SPS/PPS in front of every IDR ([`crate::annexb`]).
//! * A stream is opened at the size of the frame it is given and reopened when
//!   the load response changes that size, because an MFT's media types are
//!   fixed once it is streaming.
//!
//! Phase 1 feeds the MFT from system memory: the capture's RGB is converted to
//! NV12 on the CPU ([`crate::nv12`]) and copied into a memory buffer. The seam
//! for a zero-copy phase 2 is [`MediaFoundationEncoder::encode_sample`], which
//! takes any `IMFSample`: a sample wrapping the duplicated D3D11 texture
//! (`MFCreateDXGISurfaceBuffer`, after the MFT is handed the capture device
//! with `MFT_MESSAGE_SET_D3D_MANAGER` and a GPU colour conversion produces NV12)
//! goes in through the same door, and nothing past it changes.

use std::mem::ManuallyDrop;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use bytes::Bytes;
use windows::core::{Interface, GUID, PWSTR, VARIANT};
use windows::Win32::Foundation::E_INVALIDARG;
use windows::Win32::Media::MediaFoundation::*;
use windows::Win32::System::Com::{
    CoInitializeEx, CoTaskMemFree, CoUninitialize, COINIT_MULTITHREADED,
};

use crate::annexb::ParameterSets;
use crate::media::{RawFrame, VideoEncoder};
use crate::nv12::Nv12Frame;

/// How long the MFT may go without asking for input before it is called stalled.
const INPUT_WAIT: Duration = Duration::from_secs(1);

/// How long one frame waits for its output before the call returns empty and
/// the pump offers the frame again. An encoder that pipelines a frame deep
/// shows up here as one frame of latency, not as an error.
const OUTPUT_WAIT: Duration = Duration::from_millis(100);

const EVENT_POLL: Duration = Duration::from_millis(1);

/// Consecutive frames with no output before the encoder is called broken.
const EMPTY_LIMIT: u32 = 30;

/// IDRs come only when the pump asks, as on the openh264 path; the GOP is as
/// long as encoders commonly accept.
const GOP_FRAMES: u32 = 0xFFFF;

const TICKS_PER_SECOND: f64 = 10_000_000.0;

const NEED_INPUT: u32 = METransformNeedInput.0 as u32;
const HAVE_OUTPUT: u32 = METransformHaveOutput.0 as u32;
const ERROR_EVENT: u32 = MEError.0 as u32;

fn step(what: &'static str) -> impl Fn(windows::core::Error) -> String {
    move |e| format!("{what}: {e}")
}

/// Joins the calling thread to the multithreaded COM apartment for the rest of
/// its life. Media Foundation's objects are free-threaded, which is what lets
/// the encoder be built on the capture thread and used on the encode thread.
struct Apartment {
    joined: bool,
}

impl Drop for Apartment {
    fn drop(&mut self) {
        if self.joined {
            unsafe { CoUninitialize() };
        }
    }
}

thread_local! {
    static APARTMENT: Apartment = Apartment {
        joined: unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }.is_ok(),
    };
}

fn join_apartment() {
    APARTMENT.with(|_| {});
}

/// `MFStartup` once per process. The outcome is kept, so a machine without
/// Media Foundation fails over to openh264 at once on every later rebuild.
fn start_media_foundation() -> Result<(), String> {
    static STARTED: OnceLock<Result<(), String>> = OnceLock::new();
    join_apartment();
    STARTED
        .get_or_init(|| unsafe { MFStartup(MF_VERSION, MFSTARTUP_LITE) }.map_err(step("MFStartup")))
        .clone()
}

/// The best hardware H.264 encoder the system offers, and its friendly name.
fn first_hardware_encoder() -> Result<(IMFActivate, String), String> {
    let output = MFT_REGISTER_TYPE_INFO {
        guidMajorType: MFMediaType_Video,
        guidSubtype: MFVideoFormat_H264,
    };
    let mut list: *mut Option<IMFActivate> = std::ptr::null_mut();
    let mut count = 0u32;
    unsafe {
        MFTEnumEx(
            MFT_CATEGORY_VIDEO_ENCODER,
            MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
            None,
            Some(&output),
            &mut list,
            &mut count,
        )
    }
    .map_err(step("MFTEnumEx"))?;
    if list.is_null() {
        return Err("no hardware H.264 encoder is registered".into());
    }
    let found: Vec<IMFActivate> = unsafe { std::slice::from_raw_parts_mut(list, count as usize) }
        .iter_mut()
        .filter_map(Option::take)
        .collect();
    unsafe { CoTaskMemFree(Some(list as *const _)) };
    let activate = found
        .into_iter()
        .next()
        .ok_or("no hardware H.264 encoder is registered")?;
    let name = friendly_name(&activate);
    Ok((activate, name))
}

fn friendly_name(activate: &IMFActivate) -> String {
    let mut text = PWSTR::null();
    let mut length = 0u32;
    if unsafe { activate.GetAllocatedString(&MFT_FRIENDLY_NAME_Attribute, &mut text, &mut length) }
        .is_err()
    {
        return "unnamed".into();
    }
    let name = unsafe { text.to_string() }.unwrap_or_else(|_| "unnamed".into());
    unsafe { CoTaskMemFree(Some(text.0 as *const _)) };
    name
}

/// The H.264 encoder on the GPU, fed NV12 from system memory.
pub struct MediaFoundationEncoder {
    bitrate_bps: u32,
    fps: f32,
    name: String,
    stream: Option<Stream>,
    nv12: Nv12Frame,
}

/// Every COM object inside belongs to Media Foundation's free-threaded pipeline
/// and is only reached through `&mut self`, so handing the encoder from the
/// thread that built it to the encode thread is sound.
unsafe impl Send for MediaFoundationEncoder {}

impl MediaFoundationEncoder {
    /// Fails, so the caller can use openh264, when Media Foundation will not
    /// start or no hardware H.264 encoder is registered. The transform itself
    /// is opened on the first frame, at that frame's size.
    pub fn new(bitrate_bps: u32, fps: f32) -> Result<Self, String> {
        start_media_foundation()?;
        let (_, vendor) = first_hardware_encoder()?;
        Ok(Self {
            bitrate_bps,
            fps: fps.max(1.0),
            name: format!("mediafoundation:{vendor}"),
            stream: None,
            nv12: Nv12Frame::default(),
        })
    }

    /// Encode one `width`×`height` NV12 frame held in `sample`, wherever its
    /// buffer lives. The stream is reopened when the size changes, and when an
    /// IDR is asked of an MFT that cannot force one: a fresh stream opens with
    /// an IDR, which is slower than forcing one but keeps PLI recovery working.
    pub fn encode_sample(
        &mut self,
        sample: &IMFSample,
        width: usize,
        height: usize,
        keyframe: bool,
    ) -> Result<Bytes, String> {
        let stream = match self.stream.take() {
            Some(stream) if !stream.needs_reopen(width, height, keyframe) => {
                self.stream.insert(stream)
            }
            stale => {
                drop(stale);
                let stream = Stream::open(width, height, self.bitrate_bps, self.fps)?;
                self.name = stream.describe();
                self.stream.insert(stream)
            }
        };
        stream.encode(sample, keyframe).map(Bytes::from)
    }
}

impl VideoEncoder for MediaFoundationEncoder {
    fn encode(&mut self, frame: &RawFrame, keyframe: bool) -> Result<Bytes, String> {
        self.nv12.fill_from_rgb(frame);
        let sample = system_memory_sample(&self.nv12.data).map_err(step("wrap the frame"))?;
        self.encode_sample(&sample, frame.width, frame.height, keyframe)
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn is_hardware(&self) -> bool {
        true
    }
}

/// An activated MFT, shut down when dropped: at the end of a stream, and when
/// opening one fails halfway.
struct Mft {
    activate: IMFActivate,
    transform: IMFTransform,
    streaming: bool,
}

impl Drop for Mft {
    fn drop(&mut self) {
        unsafe {
            if self.streaming {
                let _ = self.transform.ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
                let _ = self
                    .transform
                    .ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
            }
            if let Ok(shutdown) = self.transform.cast::<IMFShutdown>() {
                let _ = shutdown.Shutdown();
            }
            let _ = self.activate.ShutdownObject();
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TransformEvent {
    NeedInput,
    HaveOutput,
    Other,
}

/// One MFT streaming at one frame size.
struct Stream {
    mft: Mft,
    events: IMFMediaEventGenerator,
    codec: Option<ICodecAPI>,
    vendor: String,
    unsupported: Vec<&'static str>,
    input_id: u32,
    output_id: u32,
    output_info: MFT_OUTPUT_STREAM_INFO,
    output_capacity: u32,
    size: (usize, usize),
    can_force_keyframe: bool,
    input_slots: u32,
    empty_runs: u32,
    delivered: bool,
    started: Instant,
    last_time: i64,
    duration: i64,
    parameter_sets: ParameterSets,
}

impl Stream {
    /// Output type first, then input, as the MFT contract requires; the codec
    /// settings go in before either, because some encoders read the rate
    /// control mode only when the output type is set.
    fn open(width: usize, height: usize, bitrate_bps: u32, fps: f32) -> Result<Self, String> {
        join_apartment();
        let (activate, vendor) = first_hardware_encoder()?;
        let transform: IMFTransform =
            unsafe { activate.ActivateObject() }.map_err(step("activate the hardware encoder"))?;
        let mut mft = Mft {
            activate,
            transform,
            streaming: false,
        };
        unlock_async(&mft.transform)?;
        let (input_id, output_id) = stream_ids(&mft.transform);

        let mut unsupported = Vec::new();
        let codec = mft.transform.cast::<ICodecAPI>().ok();
        match &codec {
            Some(codec) => configure_codec(codec, bitrate_bps, &mut unsupported),
            None => unsupported.push("ICodecAPI"),
        }
        set_output_type(
            &mft.transform,
            output_id,
            (width, height),
            bitrate_bps,
            fps,
            &mut unsupported,
        )?;
        set_input_type(&mft.transform, input_id, (width, height), fps)?;

        let mut parameter_sets = ParameterSets::default();
        observe_sequence_header(&mft.transform, output_id, &mut parameter_sets);
        let output_info = unsafe { mft.transform.GetOutputStreamInfo(output_id) }
            .map_err(step("read the output stream info"))?;
        let events = mft
            .transform
            .cast::<IMFMediaEventGenerator>()
            .map_err(step("reach the encoder's event queue"))?;

        unsafe {
            mft.transform
                .ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0)
        }
        .map_err(step("begin streaming"))?;
        mft.streaming = true;
        unsafe {
            mft.transform
                .ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0)
        }
        .map_err(step("start the stream"))?;

        let can_force_keyframe = codec
            .as_ref()
            .is_some_and(|c| unsafe { c.IsSupported(&CODECAPI_AVEncVideoForceKeyFrame) }.is_ok());
        if !can_force_keyframe {
            unsupported.push("forced keyframes");
        }
        let nv12_bytes = width * height + width.div_ceil(2) * 2 * height.div_ceil(2);
        Ok(Self {
            mft,
            events,
            codec,
            vendor,
            unsupported,
            input_id,
            output_id,
            output_capacity: output_info
                .cbSize
                .max(u32::try_from(nv12_bytes).unwrap_or(u32::MAX)),
            output_info,
            size: (width, height),
            can_force_keyframe,
            input_slots: 0,
            empty_runs: 0,
            delivered: false,
            started: Instant::now(),
            last_time: -1,
            duration: (TICKS_PER_SECOND / f64::from(fps)).round() as i64,
            parameter_sets,
        })
    }

    fn describe(&self) -> String {
        if self.unsupported.is_empty() {
            format!("mediafoundation:{}", self.vendor)
        } else {
            format!(
                "mediafoundation:{} (refused: {})",
                self.vendor,
                self.unsupported.join(", ")
            )
        }
    }

    /// A stream that has delivered nothing yet needs no reopening for an IDR:
    /// its first output is one. Without that, an MFT that holds a frame back
    /// would be reopened on every frame and never deliver.
    fn needs_reopen(&self, width: usize, height: usize, keyframe: bool) -> bool {
        self.size != (width, height) || (keyframe && !self.can_force_keyframe && self.delivered)
    }

    /// One frame in, every output that is ready out.
    ///
    /// Input waits for a `METransformNeedInput` (outputs that arrive meanwhile
    /// are kept). After it, the call waits up to [`OUTPUT_WAIT`] for the first
    /// `METransformHaveOutput` and then drains whatever else is already queued
    /// without waiting again.
    fn encode(&mut self, sample: &IMFSample, keyframe: bool) -> Result<Vec<u8>, String> {
        let mut out = Vec::new();
        let deadline = Instant::now() + INPUT_WAIT;
        while self.input_slots == 0 {
            let event = self
                .wait_event(deadline)?
                .ok_or("the hardware encoder stopped asking for input")?;
            self.handle(event, &mut out)?;
        }

        if keyframe && self.can_force_keyframe {
            self.force_keyframe()?;
        }
        self.stamp(sample)?;
        unsafe { self.mft.transform.ProcessInput(self.input_id, sample, 0) }
            .map_err(step("ProcessInput"))?;
        self.input_slots -= 1;

        let deadline = Instant::now() + OUTPUT_WAIT;
        let mut produced = false;
        loop {
            let event = if produced {
                self.poll_event()?
            } else {
                self.wait_event(deadline)?
            };
            let Some(event) = event else { break };
            produced |= event == TransformEvent::HaveOutput;
            self.handle(event, &mut out)?;
        }

        if out.is_empty() {
            self.empty_runs += 1;
            if self.empty_runs >= EMPTY_LIMIT {
                return Err(format!("no output for {EMPTY_LIMIT} frames in a row"));
            }
        } else {
            self.empty_runs = 0;
            self.delivered = true;
        }
        self.parameter_sets.complete(out)
    }

    fn handle(&mut self, event: TransformEvent, out: &mut Vec<u8>) -> Result<(), String> {
        match event {
            TransformEvent::NeedInput => self.input_slots += 1,
            TransformEvent::HaveOutput => self.collect_output(out)?,
            TransformEvent::Other => {}
        }
        Ok(())
    }

    fn poll_event(&self) -> Result<Option<TransformEvent>, String> {
        let event = match unsafe { self.events.GetEvent(MF_EVENT_FLAG_NO_WAIT) } {
            Ok(event) => event,
            Err(e) if e.code() == MF_E_NO_EVENTS_AVAILABLE => return Ok(None),
            Err(e) => return Err(format!("read the encoder's events: {e}")),
        };
        let kind = unsafe { event.GetType() }.map_err(step("read an event's type"))?;
        let status = unsafe { event.GetStatus() }.map_err(step("read an event's status"))?;
        if status.is_err() || kind == ERROR_EVENT {
            return Err(format!(
                "the encoder reported event {kind} with status {status:?}"
            ));
        }
        Ok(Some(match kind {
            NEED_INPUT => TransformEvent::NeedInput,
            HAVE_OUTPUT => TransformEvent::HaveOutput,
            _ => TransformEvent::Other,
        }))
    }

    fn wait_event(&self, deadline: Instant) -> Result<Option<TransformEvent>, String> {
        loop {
            if let Some(event) = self.poll_event()? {
                return Ok(Some(event));
            }
            if Instant::now() >= deadline {
                return Ok(None);
            }
            std::thread::sleep(EVENT_POLL);
        }
    }

    fn force_keyframe(&self) -> Result<(), String> {
        let Some(codec) = &self.codec else {
            return Ok(());
        };
        unsafe { codec.SetValue(&CODECAPI_AVEncVideoForceKeyFrame, &VARIANT::from(1u32)) }
            .map_err(step("force a keyframe"))
    }

    /// Sample times in 100 ns units from a monotonic clock, strictly
    /// increasing, so rate control sees the real cadence of an idling screen.
    fn stamp(&mut self, sample: &IMFSample) -> Result<(), String> {
        let elapsed = (self.started.elapsed().as_secs_f64() * TICKS_PER_SECOND) as i64;
        let time = elapsed.max(self.last_time + 1);
        self.last_time = time;
        unsafe {
            sample
                .SetSampleTime(time)
                .map_err(step("stamp the sample"))?;
            sample
                .SetSampleDuration(self.duration)
                .map_err(step("stamp the sample"))
        }
    }

    fn collect_output(&mut self, out: &mut Vec<u8>) -> Result<(), String> {
        let provides =
            (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES.0 | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES.0) as u32;
        let ours = if self.output_info.dwFlags & provides != 0 {
            None
        } else {
            Some(empty_sample(self.output_capacity).map_err(step("allocate an output sample"))?)
        };
        let mut buffers = [MFT_OUTPUT_DATA_BUFFER {
            dwStreamID: self.output_id,
            pSample: ManuallyDrop::new(ours),
            dwStatus: 0,
            pEvents: ManuallyDrop::new(None),
        }];
        let mut status = 0u32;
        let result = unsafe {
            self.mft
                .transform
                .ProcessOutput(0, &mut buffers, &mut status)
        };
        let [buffer] = buffers;
        let sample = ManuallyDrop::into_inner(buffer.pSample);
        drop(ManuallyDrop::into_inner(buffer.pEvents));
        match result {
            Ok(()) => sample.map_or(Ok(()), |sample| append_sample(&sample, out)),
            Err(e) if e.code() == MF_E_TRANSFORM_STREAM_CHANGE => self.renegotiate_output(),
            Err(e) if e.code() == MF_E_TRANSFORM_NEED_MORE_INPUT => Ok(()),
            Err(e) => Err(format!("ProcessOutput: {e}")),
        }
    }

    /// The MFT changed its output format mid-stream (some do once, after the
    /// first frame): take the type it now offers.
    fn renegotiate_output(&mut self) -> Result<(), String> {
        let transform = &self.mft.transform;
        let offered = unsafe { transform.GetOutputAvailableType(self.output_id, 0) }
            .map_err(step("read the changed output type"))?;
        unsafe { transform.SetOutputType(self.output_id, &offered, 0) }
            .map_err(step("accept the changed output type"))?;
        self.output_info = unsafe { transform.GetOutputStreamInfo(self.output_id) }
            .map_err(step("read the output stream info"))?;
        self.output_capacity = self.output_capacity.max(self.output_info.cbSize);
        observe_sequence_header(transform, self.output_id, &mut self.parameter_sets);
        Ok(())
    }
}

/// Hardware MFTs are asynchronous and refuse every call until unlocked. A
/// synchronous one would need the other driving model; none is expected under
/// `MFT_ENUM_FLAG_HARDWARE`, so it is an error and openh264 takes over.
fn unlock_async(transform: &IMFTransform) -> Result<(), String> {
    let attributes =
        unsafe { transform.GetAttributes() }.map_err(step("read the encoder's attributes"))?;
    if unsafe { attributes.GetUINT32(&MF_TRANSFORM_ASYNC) }.unwrap_or(0) == 0 {
        return Err("the hardware encoder is not asynchronous".into());
    }
    unsafe { attributes.SetUINT32(&MF_TRANSFORM_ASYNC_UNLOCK, 1) }
        .map_err(step("unlock the asynchronous encoder"))
}

/// `E_NOTIMPL` from `GetStreamIDs` means the streams are numbered from zero.
fn stream_ids(transform: &IMFTransform) -> (u32, u32) {
    let (mut input, mut output) = ([0u32], [0u32]);
    match unsafe { transform.GetStreamIDs(&mut input, &mut output) } {
        Ok(()) => (input[0], output[0]),
        Err(_) => (0, 0),
    }
}

/// Each setting an encoder refuses is recorded, not fatal: the stream still
/// works, and the refusal shows in the encoder's name.
fn configure_codec(codec: &ICodecAPI, bitrate_bps: u32, unsupported: &mut Vec<&'static str>) {
    let set = |api: &GUID, value: VARIANT| unsafe { codec.SetValue(api, &value) }.is_ok();
    let mode = |m: eAVEncCommonRateControlMode| VARIANT::from(m.0 as u32);

    if !set(&CODECAPI_AVLowLatencyMode, VARIANT::from(true)) {
        unsupported.push("low-latency mode");
    }
    if !set(
        &CODECAPI_AVEncCommonRateControlMode,
        mode(eAVEncCommonRateControlMode_CBR),
    ) {
        let peak = set(
            &CODECAPI_AVEncCommonRateControlMode,
            mode(eAVEncCommonRateControlMode_PeakConstrainedVBR),
        ) && set(&CODECAPI_AVEncCommonMaxBitRate, VARIANT::from(bitrate_bps));
        unsupported.push(if peak {
            "CBR (peak-constrained VBR instead)"
        } else {
            "CBR and VBR"
        });
    }
    for (api, value, label) in [
        (CODECAPI_AVEncCommonMeanBitRate, bitrate_bps, "mean bitrate"),
        (CODECAPI_AVEncMPVGOPSize, GOP_FRAMES, "GOP size"),
        (CODECAPI_AVEncMPVDefaultBPictureCount, 0, "no B-frames"),
    ] {
        if !set(&api, VARIANT::from(value)) {
            unsupported.push(label);
        }
    }
}

fn pack(high: u32, low: u32) -> u64 {
    (u64::from(high) << 32) | u64::from(low)
}

fn shape(
    media_type: &IMFMediaType,
    (width, height): (usize, usize),
    fps: f32,
) -> windows::core::Result<()> {
    unsafe {
        media_type.SetUINT64(&MF_MT_FRAME_SIZE, pack(width as u32, height as u32))?;
        media_type.SetUINT64(&MF_MT_FRAME_RATE, pack(fps.round() as u32, 1))?;
        media_type.SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, pack(1, 1))?;
        media_type.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)
    }
}

fn video_type(
    subtype: &GUID,
    size: (usize, usize),
    fps: f32,
) -> windows::core::Result<IMFMediaType> {
    let media_type = unsafe { MFCreateMediaType() }?;
    unsafe {
        media_type.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
        media_type.SetGUID(&MF_MT_SUBTYPE, subtype)?;
    }
    shape(&media_type, size, fps)?;
    Ok(media_type)
}

/// H.264 inside what the controller negotiates (`42e032`: Constrained
/// Baseline, level 5.0). Plain Baseline is the fallback for an MFT that does
/// not list Constrained Baseline: a hardware encoder uses none of the tools
/// that tell the two apart, so the stream is the same. The level is dropped
/// last, leaving the MFT to pick one for the size, which at the ladder's
/// largest size is still within 5.0.
fn set_output_type(
    transform: &IMFTransform,
    output_id: u32,
    size: (usize, usize),
    bitrate_bps: u32,
    fps: f32,
    unsupported: &mut Vec<&'static str>,
) -> Result<(), String> {
    let attempts = [
        (
            eAVEncH264VProfile_ConstrainedBase,
            Some(eAVEncH264VLevel5),
            None,
        ),
        (
            eAVEncH264VProfile_Base,
            Some(eAVEncH264VLevel5),
            Some("Constrained Baseline"),
        ),
        (eAVEncH264VProfile_ConstrainedBase, None, Some("level 5.0")),
        (
            eAVEncH264VProfile_Base,
            None,
            Some("Constrained Baseline and level 5.0"),
        ),
    ];
    let mut last = None;
    for (profile, level, refused) in attempts {
        let attempt = video_type(&MFVideoFormat_H264, size, fps).and_then(|media_type| unsafe {
            media_type.SetUINT32(&MF_MT_AVG_BITRATE, bitrate_bps)?;
            media_type.SetUINT32(&MF_MT_MPEG2_PROFILE, profile.0 as u32)?;
            if let Some(level) = level {
                media_type.SetUINT32(&MF_MT_MPEG2_LEVEL, level.0 as u32)?;
            }
            transform.SetOutputType(output_id, &media_type, 0)
        });
        match attempt {
            Ok(()) => {
                unsupported.extend(refused);
                return Ok(());
            }
            Err(e) => last = Some(e),
        }
    }
    Err(format!(
        "no Baseline H.264 output type was accepted: {}",
        last.map_or_else(String::new, |e| e.to_string())
    ))
}

/// The MFT's own NV12 type when it offers one, since some encoders accept
/// only types built from their own list, shaped to this stream.
fn set_input_type(
    transform: &IMFTransform,
    input_id: u32,
    size: (usize, usize),
    fps: f32,
) -> Result<(), String> {
    let offered = (0..64)
        .map_while(|i| unsafe { transform.GetInputAvailableType(input_id, i) }.ok())
        .find(|t| unsafe { t.GetGUID(&MF_MT_SUBTYPE) }.is_ok_and(|s| s == MFVideoFormat_NV12));
    let media_type = match offered {
        Some(media_type) => shape(&media_type, size, fps).map(|()| media_type),
        None => video_type(&MFVideoFormat_NV12, size, fps),
    };
    media_type
        .and_then(|media_type| unsafe {
            media_type.SetUINT32(&MF_MT_DEFAULT_STRIDE, size.0 as u32)?;
            transform.SetInputType(input_id, &media_type, 0)
        })
        .map_err(step("set the NV12 input type"))
}

/// Seed the parameter-set cache from `MF_MT_MPEG_SEQUENCE_HEADER`, for an MFT
/// that puts SPS/PPS there rather than in its first output.
fn observe_sequence_header(transform: &IMFTransform, output_id: u32, sets: &mut ParameterSets) {
    let Ok(current) = (unsafe { transform.GetOutputCurrentType(output_id) }) else {
        return;
    };
    let Ok(size) = (unsafe { current.GetBlobSize(&MF_MT_MPEG_SEQUENCE_HEADER) }) else {
        return;
    };
    let mut blob = vec![0u8; size as usize];
    if unsafe { current.GetBlob(&MF_MT_MPEG_SEQUENCE_HEADER, &mut blob, None) }.is_ok() {
        sets.observe(&blob);
    }
}

fn empty_sample(capacity: u32) -> windows::core::Result<IMFSample> {
    unsafe {
        let buffer = MFCreateMemoryBuffer(capacity)?;
        let sample = MFCreateSample()?;
        sample.AddBuffer(&buffer)?;
        Ok(sample)
    }
}

fn system_memory_sample(data: &[u8]) -> windows::core::Result<IMFSample> {
    let length = u32::try_from(data.len()).map_err(|_| windows::core::Error::from(E_INVALIDARG))?;
    unsafe {
        let buffer = MFCreateMemoryBuffer(length)?;
        let mut target = std::ptr::null_mut();
        buffer.Lock(&mut target, None, None)?;
        std::ptr::copy_nonoverlapping(data.as_ptr(), target, data.len());
        buffer.Unlock()?;
        buffer.SetCurrentLength(length)?;
        let sample = MFCreateSample()?;
        sample.AddBuffer(&buffer)?;
        Ok(sample)
    }
}

fn append_sample(sample: &IMFSample, out: &mut Vec<u8>) -> Result<(), String> {
    let buffer =
        unsafe { sample.ConvertToContiguousBuffer() }.map_err(step("read the encoded sample"))?;
    let mut data = std::ptr::null_mut();
    let mut length = 0u32;
    unsafe { buffer.Lock(&mut data, None, Some(&mut length)) }
        .map_err(step("lock the encoded sample"))?;
    if !data.is_null() {
        out.extend_from_slice(unsafe { std::slice::from_raw_parts(data, length as usize) });
    }
    unsafe { buffer.Unlock() }.map_err(step("unlock the encoded sample"))
}
