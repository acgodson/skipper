//! DXGI Desktop Duplication capture — the real Windows screen source.
//!
//! Compiled only on Windows. It cannot be runtime-tested from the build Mac, so
//! it is written to lean on the type checker and to fail *safe*: an error that
//! means "no change this frame" idles, one that means "the desktop moved out
//! from under us" rebuilds the duplication object, and one that means "this is
//! not our desktop" is reported as unavailable so the host suspends input
//! rather than leaving a stale picture with live clicks behind it.
//!
//! Why Desktop Duplication over Windows.Graphics.Capture (WINDOWS-HOST.md §4):
//! it exposes native dirty rects, so an unchanged screen returns `WAIT_TIMEOUT`
//! and we idle — the same efficiency the Mac's ScreenCaptureKit path relies on —
//! and it draws no yellow capture border.
//!
//! Known limitation, by design: on the secure desktop (a UAC prompt, the lock
//! screen) duplication yields nothing. Getting *past* the secure desktop needs
//! the session-0 service model, which is deferred; what is not deferred is
//! saying so, because the alternative is a controller showing the desktop as it
//! was before the prompt appeared while clicks go somewhere the user cannot see.

use std::time::{Duration, Instant};

use windows::core::Interface;
use windows::Win32::Foundation::{E_ACCESSDENIED, HANDLE};
use windows::Win32::Graphics::Direct3D::D3D_DRIVER_TYPE_UNKNOWN;
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::*;
use windows::Win32::Graphics::Dxgi::*;
use windows::Win32::Graphics::Gdi::{GetMonitorInfoW, HMONITOR, MONITORINFO};
use windows::Win32::System::StationsAndDesktops::{
    CloseDesktop, GetUserObjectInformationW, OpenInputDesktop, DESKTOP_CONTROL_FLAGS,
    DESKTOP_READOBJECTS, UOI_NAME,
};
use windows::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI};
use windows::Win32::UI::WindowsAndMessaging::{
    GetSystemMetrics, MONITORINFOF_PRIMARY, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN,
    SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN,
};

use rc_input::{DisplayGeometry, Rect};

use crate::media::{CaptureBackend, CaptureStatus, FrameSource, RawFrame};

/// Opens a capture source on the primary display, once per session.
pub struct DxgiBackend;

impl DxgiBackend {
    pub fn primary_display() -> Self {
        Self
    }
}

impl CaptureBackend for DxgiBackend {
    type Source = DxgiCaptureSource;

    fn open(&mut self) -> Result<Self::Source, String> {
        DxgiCaptureSource::primary()
    }

    fn describe(&self) -> &'static str {
        "DXGI Desktop Duplication, primary display"
    }
}

/// How often the display geometry is re-read. A resolution change announces
/// itself through `ACCESS_LOST`, but a **DPI** change does not, so polling is
/// the only way to notice that the scale the controller was told is now wrong.
const GEOMETRY_POLL: Duration = Duration::from_millis(500);

pub struct DxgiCaptureSource {
    device: ID3D11Device,
    context: ID3D11DeviceContext,
    adapter: IDXGIAdapter1,
    output_index: u32,
    /// The captured monitor's handle, as an integer: `HMONITOR` wraps a raw
    /// pointer and is therefore not `Send`, and this source lives on the
    /// pump's blocking thread. It is a handle, never dereferenced.
    monitor: isize,
    duplication: Option<IDXGIOutputDuplication>,
    /// Reused CPU-readable staging texture; re-created when the size changes.
    staging: Option<(ID3D11Texture2D, u32, u32)>,
    geometry: Option<DisplayGeometry>,
    status: CaptureStatus,
    geometry_read_at: Instant,
}

impl DxgiCaptureSource {
    /// Open the **primary** display, wherever it is.
    ///
    /// The first adapter's first output is not the primary display: output 0 of
    /// adapter 0 is whatever DXGI enumerates first, which on a laptop with an
    /// external screen, or on a machine with two GPUs, is routinely the wrong
    /// one. The primary monitor is the one `GetMonitorInfoW` flags
    /// `MONITORINFOF_PRIMARY`, and it is the one at the virtual desktop's
    /// origin, so that is what is searched for.
    ///
    /// The device must be created on the adapter that owns the chosen output:
    /// `IDXGIOutput1::DuplicateOutput` fails otherwise.
    pub fn primary() -> Result<Self, String> {
        unsafe {
            let factory: IDXGIFactory1 =
                CreateDXGIFactory1().map_err(|e| format!("CreateDXGIFactory1: {e}"))?;

            let mut first_attached: Option<(IDXGIAdapter1, u32, HMONITOR)> = None;
            let mut adapter_index = 0u32;
            while let Ok(adapter) = factory.EnumAdapters1(adapter_index) {
                let mut output_index = 0u32;
                while let Ok(output) = adapter.EnumOutputs(output_index) {
                    if let Ok(desc) = output.GetDesc() {
                        if desc.AttachedToDesktop.as_bool() {
                            if is_primary(desc.Monitor) {
                                return Self::with_output(
                                    adapter.clone(),
                                    output_index,
                                    desc.Monitor,
                                );
                            }
                            if first_attached.is_none() {
                                first_attached =
                                    Some((adapter.clone(), output_index, desc.Monitor));
                            }
                        }
                    }
                    output_index += 1;
                }
                adapter_index += 1;
            }

            // No monitor claimed to be primary. Rather than refuse to capture,
            // take any attached one — but this is a fallback, not the plan.
            match first_attached {
                Some((adapter, output_index, monitor)) => {
                    eprintln!(
                        "rc-host: no display reported itself as primary; capturing output \
                         {output_index}"
                    );
                    Self::with_output(adapter, output_index, monitor)
                }
                None => Err("no display is attached to the desktop".into()),
            }
        }
    }

    fn with_output(
        adapter: IDXGIAdapter1,
        output_index: u32,
        monitor: HMONITOR,
    ) -> Result<Self, String> {
        unsafe {
            let mut device: Option<ID3D11Device> = None;
            let mut context: Option<ID3D11DeviceContext> = None;
            D3D11CreateDevice(
                &adapter,
                // `D3D11CreateDevice` requires `D3D_DRIVER_TYPE_UNKNOWN`
                // whenever `pAdapter` is non-null — passing an adapter *and*
                // `D3D_DRIVER_TYPE_HARDWARE` is an invalid combination and the
                // call is documented to fail with E_INVALIDARG. The adapter
                // already determines that this is the hardware device.
                D3D_DRIVER_TYPE_UNKNOWN,
                None,
                D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                None,
                D3D11_SDK_VERSION,
                Some(&mut device),
                None,
                Some(&mut context),
            )
            .map_err(|e| format!("D3D11CreateDevice: {e}"))?;

            let device = device.ok_or("D3D11CreateDevice returned no device")?;
            let context = context.ok_or("D3D11CreateDevice returned no context")?;

            let mut source = Self {
                device,
                context,
                adapter,
                output_index,
                monitor: monitor.0 as isize,
                duplication: None,
                staging: None,
                geometry: None,
                status: CaptureStatus::Live,
                geometry_read_at: Instant::now() - GEOMETRY_POLL,
            };
            source.refresh_geometry();
            source.reinit_duplication()?;
            Ok(source)
        }
    }

    /// Re-read the captured monitor's rectangle, its DPI, and the virtual
    /// desktop around it. Everything a click is aimed with and everything
    /// `display_info` reports comes from here.
    fn monitor(&self) -> HMONITOR {
        HMONITOR(self.monitor as *mut core::ffi::c_void)
    }

    fn refresh_geometry(&mut self) {
        self.geometry_read_at = Instant::now();
        let Some(monitor) = read_monitor_rect(self.monitor()) else {
            self.geometry = None;
            return;
        };
        let virtual_desktop = read_virtual_desktop();
        let scale = read_scale(self.monitor());
        let geometry = DisplayGeometry { monitor, virtual_desktop, scale };
        // A geometry that does not hang together was read mid-change; keep the
        // last good one rather than aiming clicks with it.
        if geometry.is_usable() {
            self.geometry = Some(geometry);
        }
    }

    /// (Re)create the duplication object — first time, and after ACCESS_LOST.
    fn reinit_duplication(&mut self) -> Result<(), String> {
        unsafe {
            let output: IDXGIOutput = self
                .adapter
                .EnumOutputs(self.output_index)
                .map_err(|e| format!("EnumOutputs({}): {e}", self.output_index))?;
            let output1: IDXGIOutput1 = output.cast().map_err(|e| format!("IDXGIOutput1: {e}"))?;
            match output1.DuplicateOutput(&self.device) {
                Ok(dup) => {
                    self.duplication = Some(dup);
                    self.staging = None;
                    self.status = CaptureStatus::Live;
                    Ok(())
                }
                // Duplicating the secure desktop is refused, not broken.
                Err(e) if e.code() == E_ACCESSDENIED => {
                    self.status = CaptureStatus::DesktopUnavailable;
                    Ok(())
                }
                Err(e) => Err(format!("DuplicateOutput: {e}")),
            }
        }
    }

    /// Ensure a CPU-readable staging texture of the given size exists.
    fn ensure_staging(&mut self, w: u32, h: u32) -> Result<ID3D11Texture2D, String> {
        if let Some((tex, sw, sh)) = &self.staging {
            if *sw == w && *sh == h {
                return Ok(tex.clone());
            }
        }
        unsafe {
            let desc = D3D11_TEXTURE2D_DESC {
                Width: w,
                Height: h,
                MipLevels: 1,
                ArraySize: 1,
                Format: DXGI_FORMAT_B8G8R8A8_UNORM,
                SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                Usage: D3D11_USAGE_STAGING,
                BindFlags: 0,
                CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
                MiscFlags: 0,
            };
            let mut tex: Option<ID3D11Texture2D> = None;
            self.device
                .CreateTexture2D(&desc, None, Some(&mut tex))
                .map_err(|e| format!("CreateTexture2D(staging): {e}"))?;
            let tex = tex.ok_or("CreateTexture2D returned nothing")?;
            self.staging = Some((tex.clone(), w, h));
            Ok(tex)
        }
    }

    /// Acquire one frame. `Ok(None)` = nothing new this frame; `Err` = a hard
    /// failure the caller surfaces.
    fn acquire(&mut self) -> Result<Option<RawFrame>, String> {
        let dup = match &self.duplication {
            Some(d) => d.clone(),
            None => {
                self.reinit_duplication()?;
                match &self.duplication {
                    Some(d) => d.clone(),
                    // Refused (secure desktop); status already says so.
                    None => return Ok(None),
                }
            }
        };

        unsafe {
            let mut info = DXGI_OUTDUPL_FRAME_INFO::default();
            let mut resource: Option<IDXGIResource> = None;
            // 15 ms: long enough to coalesce, short enough to keep the pump at
            // ~30 fps when the screen is busy, and short enough that a stop is
            // noticed promptly.
            match dup.AcquireNextFrame(15, &mut info, &mut resource) {
                Ok(()) => {}
                Err(e) if e.code() == DXGI_ERROR_WAIT_TIMEOUT => return Ok(None),
                Err(e) if e.code() == DXGI_ERROR_ACCESS_LOST => {
                    // Resolution change, or a desktop switch (UAC/lock). Rebuild
                    // and let the next tick try again; re-read the geometry
                    // because a resolution change is one of the causes.
                    self.duplication = None;
                    self.refresh_geometry();
                    return Ok(None);
                }
                Err(e) => return Err(format!("AcquireNextFrame: {e}")),
            }

            // Ensure the frame is released even on an early return below.
            let _guard = FrameGuard { dup: &dup };

            // A zero `LastPresentTime` means the desktop image did not change
            // and this wake-up was a cursor move. Encoding the whole screen for
            // a moved pointer is pure waste: the controller draws the cursor
            // itself (PROTOCOL.md §5 `cursor_shape`).
            if info.LastPresentTime == 0 {
                return Ok(None);
            }

            let resource = match resource {
                Some(r) => r,
                None => return Ok(None),
            };
            let frame_tex: ID3D11Texture2D =
                resource.cast().map_err(|e| format!("frame as texture: {e}"))?;

            let mut td = D3D11_TEXTURE2D_DESC::default();
            frame_tex.GetDesc(&mut td);
            let (w, h) = (td.Width, td.Height);
            let staging = self.ensure_staging(w, h)?;
            self.context.CopyResource(&staging, &frame_tex);

            let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
            self.context
                .Map(&staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped))
                .map_err(|e| format!("Map(staging): {e}"))?;

            // BGRA rows (row_pitch may exceed w*4) -> tightly packed RGB.
            let src = mapped.pData as *const u8;
            let pitch = mapped.RowPitch as usize;
            let (w, h) = (w as usize, h as usize);
            let mut rgb = vec![0u8; w * h * 3];
            for y in 0..h {
                let row = src.add(y * pitch);
                let dst_row = y * w * 3;
                for x in 0..w {
                    let px = row.add(x * 4);
                    // BGRA -> RGB
                    rgb[dst_row + x * 3] = *px.add(2);
                    rgb[dst_row + x * 3 + 1] = *px.add(1);
                    rgb[dst_row + x * 3 + 2] = *px;
                }
            }
            self.context.Unmap(&staging, 0);

            Ok(Some(RawFrame { width: w, height: h, rgb }))
        }
    }
}

/// Releases the duplicated frame when the acquire scope ends, on every path.
struct FrameGuard<'a> {
    dup: &'a IDXGIOutputDuplication,
}

impl Drop for FrameGuard<'_> {
    fn drop(&mut self) {
        unsafe {
            let _ = self.dup.ReleaseFrame();
        }
    }
}

impl FrameSource for DxgiCaptureSource {
    fn next_frame(&mut self) -> Option<RawFrame> {
        if self.geometry_read_at.elapsed() >= GEOMETRY_POLL {
            self.refresh_geometry();
        }

        // Checked before capturing, not after: on the secure desktop there is
        // no frame to tell us from, and the point is to stop input before the
        // next click lands somewhere invisible.
        if is_secure_desktop() {
            self.status = CaptureStatus::DesktopUnavailable;
            self.duplication = None;
            return None;
        }

        match self.acquire() {
            Ok(frame) => {
                if frame.is_some() {
                    self.status = CaptureStatus::Live;
                }
                frame
            }
            Err(msg) => {
                // A hard error is reported, not fatal: the pump idles, the host
                // suspends input, and the next tick rebuilds. A wobble is not a
                // dead session, but it is also not a live screen.
                self.duplication = None;
                self.status = CaptureStatus::Unavailable(msg);
                None
            }
        }
    }

    fn geometry(&self) -> Option<DisplayGeometry> {
        self.geometry
    }

    fn status(&self) -> CaptureStatus {
        if self.geometry.is_none() {
            return CaptureStatus::Unavailable("display geometry unknown".into());
        }
        self.status.clone()
    }
}

fn is_primary(monitor: HMONITOR) -> bool {
    let mut info = MONITORINFO {
        cbSize: std::mem::size_of::<MONITORINFO>() as u32,
        ..Default::default()
    };
    let read = unsafe { GetMonitorInfoW(monitor, &mut info) }.as_bool();
    read && (info.dwFlags & MONITORINFOF_PRIMARY) != 0
}

fn read_monitor_rect(monitor: HMONITOR) -> Option<Rect> {
    let mut info = MONITORINFO {
        cbSize: std::mem::size_of::<MONITORINFO>() as u32,
        ..Default::default()
    };
    if !unsafe { GetMonitorInfoW(monitor, &mut info).as_bool() } {
        return None;
    }
    // rcMonitor, not rcWork: the captured image is the whole display, taskbar
    // included, so a click's coordinate space has to be the whole display too.
    Some(Rect::new(
        info.rcMonitor.left,
        info.rcMonitor.top,
        info.rcMonitor.right,
        info.rcMonitor.bottom,
    ))
}

/// The bounding rectangle of every attached monitor — the space
/// `MOUSEEVENTF_VIRTUALDESK` addresses. Its origin is negative whenever a
/// monitor sits left of or above the primary one.
fn read_virtual_desktop() -> Rect {
    unsafe {
        let x = GetSystemMetrics(SM_XVIRTUALSCREEN);
        let y = GetSystemMetrics(SM_YVIRTUALSCREEN);
        let w = GetSystemMetrics(SM_CXVIRTUALSCREEN);
        let h = GetSystemMetrics(SM_CYVIRTUALSCREEN);
        Rect::new(x, y, x + w, y + h)
    }
}

/// The monitor's effective scale. The process is per-monitor-DPI-aware (set in
/// `main`), so the captured pixels are physical and this is reported to the
/// controller rather than applied to them.
fn read_scale(monitor: HMONITOR) -> f64 {
    let mut dpi_x = 96u32;
    let mut dpi_y = 96u32;
    if unsafe { GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &mut dpi_x, &mut dpi_y) }.is_err() {
        return 1.0;
    }
    (dpi_x as f64 / 96.0).max(0.1)
}

/// Whether the desktop currently receiving input is a secure one — the lock
/// screen, or the desktop a UAC prompt switches to.
///
/// `OpenInputDesktop` on the Winlogon desktop is refused to a process that is
/// not running as SYSTEM, and the input desktop's name is `Winlogon` while that
/// desktop is in front. Either answer means the same thing here: what the user
/// is looking at is not what this process can capture or click on.
fn is_secure_desktop() -> bool {
    unsafe {
        let Ok(desktop) = OpenInputDesktop(DESKTOP_CONTROL_FLAGS(0), false, DESKTOP_READOBJECTS) else {
            return true;
        };
        let mut name = [0u16; 64];
        let mut needed = 0u32;
        let read = GetUserObjectInformationW(
            HANDLE(desktop.0),
            UOI_NAME,
            Some(name.as_mut_ptr().cast()),
            std::mem::size_of_val(&name) as u32,
            Some(&mut needed),
        );
        let _ = CloseDesktop(desktop);
        if read.is_err() {
            return false;
        }
        let len = name.iter().position(|c| *c == 0).unwrap_or(name.len());
        String::from_utf16_lossy(&name[..len]).eq_ignore_ascii_case("winlogon")
    }
}
