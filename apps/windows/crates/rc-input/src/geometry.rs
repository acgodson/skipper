//! Where the captured display sits inside the Windows virtual desktop.
//!
//! `SendInput` with `MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK` takes
//! `0..=65535` across the **whole virtual desktop** — the bounding rectangle of
//! every attached monitor — not across the monitor being captured. Those two
//! only coincide on a machine with exactly one display, and the virtual desktop
//! may have a non-zero or negative origin, because the primary monitor is always
//! at `(0,0)` and a monitor placed to its left or above it therefore has
//! negative coordinates.
//!
//! The protocol's coordinates are normalised to the *captured* display
//! (PROTOCOL.md §5), so a one-monitor product still has to do this translation
//! to behave on a PC that happens to have a second screen plugged in.

use rc_proto::ctrl::{clamp_unit, DisplayInfo, host_os};

/// A Windows `RECT`, in virtual-desktop pixels. `right`/`bottom` are exclusive.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Rect {
    pub left: i32,
    pub top: i32,
    pub right: i32,
    pub bottom: i32,
}

impl Rect {
    pub const fn new(left: i32, top: i32, right: i32, bottom: i32) -> Self {
        Self { left, top, right, bottom }
    }

    pub const fn sized(width: i32, height: i32) -> Self {
        Self { left: 0, top: 0, right: width, bottom: height }
    }

    pub fn width(&self) -> i32 {
        self.right.saturating_sub(self.left).max(0)
    }

    pub fn height(&self) -> i32 {
        self.bottom.saturating_sub(self.top).max(0)
    }

    pub fn is_empty(&self) -> bool {
        self.width() == 0 || self.height() == 0
    }
}

/// The absolute coordinate space `MOUSEEVENTF_VIRTUALDESK` spans, inclusive.
pub const ABSOLUTE_MAX: i32 = 65535;

/// The captured monitor, the virtual desktop it lives in, and its scale.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DisplayGeometry {
    /// The monitor being captured, in virtual-desktop pixels.
    pub monitor: Rect,
    /// The bounding rectangle of every attached monitor.
    pub virtual_desktop: Rect,
    /// Backing scale: DPI / 96. 1.0 on an unscaled display.
    pub scale: f64,
}

impl DisplayGeometry {
    /// The single-display case: the captured monitor *is* the virtual desktop.
    pub fn single(width: i32, height: i32, scale: f64) -> Self {
        Self {
            monitor: Rect::sized(width, height),
            virtual_desktop: Rect::sized(width, height),
            scale,
        }
    }

    pub fn width(&self) -> i32 {
        self.monitor.width()
    }

    pub fn height(&self) -> i32 {
        self.monitor.height()
    }

    /// A monitor that is not inside the virtual desktop, or either rectangle
    /// being empty, means the geometry was read mid-change and must not be used
    /// to aim a click.
    pub fn is_usable(&self) -> bool {
        !self.monitor.is_empty()
            && !self.virtual_desktop.is_empty()
            && self.monitor.left >= self.virtual_desktop.left
            && self.monitor.top >= self.virtual_desktop.top
            && self.monitor.right <= self.virtual_desktop.right
            && self.monitor.bottom <= self.virtual_desktop.bottom
    }

    /// Normalised `[0,1]` on the captured monitor -> `SendInput`'s absolute
    /// virtual-desktop space.
    ///
    /// Both ends are reachable: `0.0` lands on the monitor's first pixel column
    /// and `1.0` on its last, which is what makes a click on the right-hand edge
    /// of the remote window hit the right-hand edge of the screen.
    pub fn to_absolute(&self, x: f64, y: f64) -> (i32, i32) {
        (
            project(clamp_unit(x), self.monitor.left, self.monitor.width(), self.virtual_desktop.left, self.virtual_desktop.width()),
            project(clamp_unit(y), self.monitor.top, self.monitor.height(), self.virtual_desktop.top, self.virtual_desktop.height()),
        )
    }

    /// The `display_info` the controller sizes its window from (PROTOCOL.md §5).
    pub fn display_info(&self) -> DisplayInfo {
        DisplayInfo {
            w: self.width(),
            h: self.height(),
            scale: self.scale,
            os: host_os::WINDOWS.to_string(),
        }
    }
}

/// One axis of [`DisplayGeometry::to_absolute`].
///
/// `span - 1` rather than `span` on both sides: the units are pixel *indices*,
/// so a 1920-wide monitor addresses columns 0..=1919 and the last column has to
/// reach `ABSOLUTE_MAX` instead of stopping a pixel short.
fn project(unit: f64, monitor_origin: i32, monitor_span: i32, desktop_origin: i32, desktop_span: i32) -> i32 {
    let last_pixel = (monitor_span - 1).max(0) as f64;
    let pixel = monitor_origin as f64 + unit * last_pixel;
    let desktop_last = (desktop_span - 1).max(1) as f64;
    let absolute = (pixel - desktop_origin as f64) * ABSOLUTE_MAX as f64 / desktop_last;
    (absolute.round() as i64).clamp(0, ABSOLUTE_MAX as i64) as i32
}
