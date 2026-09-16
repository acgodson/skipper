//! Frame production and encoding.
//!
//! `FrameSource` is the seam between the platform capture (DXGI Desktop
//! Duplication on Windows, a synthetic pattern elsewhere) and the encoder.
//! The encoder here is openh264 — the software baseline that works on every
//! platform this binary compiles for. The Media Foundation hardware path
//! (WINDOWS-HOST.md §4) slots in behind the same seam later; software H.264 at
//! high resolution is exactly the CPU trap the Mac side fell into once, so the
//! synthetic source keeps itself small on purpose.

use bytes::Bytes;
use openh264::encoder::{Encoder, EncoderConfig};
use openh264::formats::{RgbSliceU8, YUVBuffer};
use openh264::OpenH264API;

/// One BGRA frame plus its geometry.
pub struct RawFrame {
    pub width: usize,
    pub height: usize,
    /// Tightly packed RGB (3 bytes/px) — what the encoder eats.
    pub rgb: Vec<u8>,
}

pub trait FrameSource: Send {
    /// Produce the next frame, or `None` when the screen is unchanged and the
    /// pump may idle (the dirty-rect signal on Windows).
    fn next_frame(&mut self) -> Option<RawFrame>;
    fn dimensions(&self) -> (u32, u32);
}

/// A moving diagonal gradient: cheap, obviously alive on screen, and it
/// exercises the whole encode path because every frame differs.
pub struct SyntheticSource {
    width: usize,
    height: usize,
    tick: u32,
}

impl SyntheticSource {
    pub fn new(width: usize, height: usize) -> Self {
        Self { width, height, tick: 0 }
    }
}

impl FrameSource for SyntheticSource {
    fn next_frame(&mut self) -> Option<RawFrame> {
        self.tick = self.tick.wrapping_add(3);
        let t = self.tick as usize;
        let mut rgb = vec![0u8; self.width * self.height * 3];
        for y in 0..self.height {
            let row = y * self.width * 3;
            for x in 0..self.width {
                let i = row + x * 3;
                rgb[i] = ((x + t) & 0xFF) as u8;
                rgb[i + 1] = ((y + t / 2) & 0xFF) as u8;
                rgb[i + 2] = (((x + y) / 2 + t) & 0xFF) as u8;
            }
        }
        Some(RawFrame { width: self.width, height: self.height, rgb })
    }

    fn dimensions(&self) -> (u32, u32) {
        (self.width as u32, self.height as u32)
    }
}

pub struct H264Encoder {
    encoder: Encoder,
}

impl H264Encoder {
    pub fn new(bitrate_bps: u32, fps: f32) -> Result<Self, String> {
        let config = EncoderConfig::new()
            .set_bitrate_bps(bitrate_bps)
            .max_frame_rate(fps);
        let encoder = Encoder::with_api_config(OpenH264API::from_source(), config)
            .map_err(|e| e.to_string())?;
        Ok(Self { encoder })
    }

    /// Annex-B access unit for one frame; empty when the encoder skips.
    pub fn encode(&mut self, frame: &RawFrame) -> Result<Bytes, String> {
        let yuv = YUVBuffer::from_rgb_source(RgbSliceU8::new(&frame.rgb, (frame.width, frame.height)));
        let bitstream = self.encoder.encode(&yuv).map_err(|e| e.to_string())?;
        Ok(Bytes::from(bitstream.to_vec()))
    }
}
