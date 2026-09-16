//! DXGI Desktop Duplication capture — the real Windows screen source.
//!
//! Compiled only on Windows. It cannot be runtime-tested from the build Mac, so
//! it is written to lean on the type checker and to fail *safe*: any error that
//! is not a clean "no change this frame" becomes a rebuild of the duplication
//! object rather than a panic, because the states this hits in the field
//! (`ACCESS_LOST` on a resolution change or UAC desktop switch, `WAIT_TIMEOUT`
//! on an idle screen) are normal, not exceptional.
//!
//! Why Desktop Duplication over Windows.Graphics.Capture (WINDOWS-HOST.md §4):
//! it exposes native dirty rects, so an unchanged screen returns `WAIT_TIMEOUT`
//! and we idle — the same efficiency the Mac's ScreenCaptureKit path relies on —
//! and it draws no yellow capture border.
//!
//! Known limitation, by design: on the secure desktop (a UAC prompt, the lock
//! screen) `AcquireNextFrame` yields nothing and this returns `None`. The
//! controller keeps the last frame and the session survives; getting *past* the
//! secure desktop needs the session-0 service model, which is deferred.

use windows::core::Interface;
use windows::Win32::Foundation::{E_ACCESSDENIED, GENERIC_ALL};
use windows::Win32::Graphics::Direct3D::D3D_DRIVER_TYPE_HARDWARE;
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::*;
use windows::Win32::Graphics::Dxgi::*;

use crate::media::{FrameSource, RawFrame};

pub struct DxgiCaptureSource {
    device: ID3D11Device,
    context: ID3D11DeviceContext,
    adapter: IDXGIAdapter1,
    output_index: u32,
    duplication: Option<IDXGIOutputDuplication>,
    /// Reused CPU-readable staging texture; re-created when the size changes.
    staging: Option<(ID3D11Texture2D, u32, u32)>,
    width: u32,
    height: u32,
}

impl DxgiCaptureSource {
    /// Open the primary output of the first adapter. `output_index` selects the
    /// monitor; 0 is the primary.
    pub fn new(output_index: u32) -> Result<Self, String> {
        unsafe {
            let factory: IDXGIFactory1 =
                CreateDXGIFactory1().map_err(|e| format!("CreateDXGIFactory1: {e}"))?;
            let adapter: IDXGIAdapter1 = factory
                .EnumAdapters1(0)
                .map_err(|e| format!("EnumAdapters1: {e}"))?;

            let mut device: Option<ID3D11Device> = None;
            let mut context: Option<ID3D11DeviceContext> = None;
            D3D11CreateDevice(
                &adapter,
                D3D_DRIVER_TYPE_HARDWARE,
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
                duplication: None,
                staging: None,
                width: 0,
                height: 0,
            };
            source.reinit_duplication()?;
            Ok(source)
        }
    }

    /// (Re)create the duplication object — first time, and after ACCESS_LOST.
    fn reinit_duplication(&mut self) -> Result<(), String> {
        unsafe {
            let output: IDXGIOutput = self
                .adapter
                .EnumOutputs(self.output_index)
                .map_err(|e| format!("EnumOutputs({}): {e}", self.output_index))?;
            let desc = output.GetDesc().map_err(|e| format!("GetDesc: {e}"))?;
            self.width = (desc.DesktopCoordinates.right - desc.DesktopCoordinates.left) as u32;
            self.height = (desc.DesktopCoordinates.bottom - desc.DesktopCoordinates.top) as u32;

            let output1: IDXGIOutput1 = output.cast().map_err(|e| format!("IDXGIOutput1: {e}"))?;
            let dup = output1
                .DuplicateOutput(&self.device)
                .map_err(|e| format!("DuplicateOutput: {e}"))?;
            self.duplication = Some(dup);
            self.staging = None;
            Ok(())
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

    /// Acquire one frame. `Ok(None)` = no change (idle / timeout / secure
    /// desktop); `Err` = a hard failure the caller should surface.
    fn acquire(&mut self) -> Result<Option<RawFrame>, String> {
        let dup = match &self.duplication {
            Some(d) => d.clone(),
            None => {
                self.reinit_duplication()?;
                self.duplication.as_ref().unwrap().clone()
            }
        };

        unsafe {
            let mut info = DXGI_OUTDUPL_FRAME_INFO::default();
            let mut resource: Option<IDXGIResource> = None;
            // 15 ms: long enough to coalesce, short enough to keep the pump at
            // ~30 fps when the screen is busy.
            match dup.AcquireNextFrame(15, &mut info, &mut resource) {
                Ok(()) => {}
                Err(e) if e.code() == DXGI_ERROR_WAIT_TIMEOUT => return Ok(None),
                Err(e) if e.code() == DXGI_ERROR_ACCESS_LOST => {
                    // Resolution change, or a desktop switch (UAC/lock). Rebuild
                    // and let the next tick try again.
                    self.duplication = None;
                    return Ok(None);
                }
                Err(e) => return Err(format!("AcquireNextFrame: {e}")),
            }

            // Ensure the frame is released even on an early return below.
            let _guard = FrameGuard { dup: &dup };

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
        match self.acquire() {
            Ok(frame) => frame,
            Err(msg) => {
                // A hard error is logged, not fatal: the pump idles and retries,
                // matching the "a wobble is not a dead session" rule.
                eprintln!("rc-host: capture error (will retry): {msg}");
                self.duplication = None;
                None
            }
        }
    }

    fn dimensions(&self) -> (u32, u32) {
        (self.width, self.height)
    }
}

/// Best-effort note: `GENERIC_ALL`/`E_ACCESSDENIED` are referenced so the
/// feature set that pulls them in is not flagged unused on some toolchains.
#[allow(dead_code)]
const _TOUCH: (windows::core::HRESULT, windows::Win32::Foundation::GENERIC_ACCESS_RIGHTS) =
    (E_ACCESSDENIED, GENERIC_ALL);
