//! macOS pixel scroll -> Windows wheel deltas.
//!
//! Two conventions differ and both are silent failures if missed:
//!
//! * **Sign.** PROTOCOL.md §5: positive `dy` means content moves up. A positive
//!   Windows wheel delta rotates the wheel *forward*, which moves content down.
//!   The mapping is therefore a negation, not a scale.
//! * **Granularity.** macOS sends pixel-precise deltas; Windows is quantised to
//!   `WHEEL_DELTA` (120) per notch. Truncating each event independently makes
//!   slow trackpad scrolling do nothing at all, because every delta rounds to
//!   zero. The remainder has to be carried across events.

/// One wheel notch, as Windows defines it.
pub const WHEEL_DELTA: f64 = 120.0;

/// Pixels of macOS scroll that equal one notch.
///
/// 120 makes the mapping 1:1 with `WHEEL_DELTA`, so a 120-pixel swipe is exactly
/// one notch. Lower values scroll faster.
pub const DEFAULT_PIXELS_PER_NOTCH: f64 = 120.0;

/// Accumulates fractional wheel deltas so that no scrolling is lost to rounding.
///
/// One instance per axis per session. `input_reset` should [`Self::reset`] it:
/// a leftover fraction from before a reconnect would otherwise leak into the
/// first scroll after it.
#[derive(Debug, Clone)]
pub struct ScrollAccumulator {
    pixels_per_notch: f64,
    remainder: f64,
}

impl Default for ScrollAccumulator {
    fn default() -> Self {
        Self::new(DEFAULT_PIXELS_PER_NOTCH)
    }
}

impl ScrollAccumulator {
    pub fn new(pixels_per_notch: f64) -> Self {
        assert!(
            pixels_per_notch > 0.0,
            "pixels_per_notch must be positive, got {pixels_per_notch}"
        );
        Self {
            pixels_per_notch,
            remainder: 0.0,
        }
    }

    /// Feed one axis of a `scroll` message; returns the wheel delta to send, or
    /// `None` when the movement so far is under one unit and has been banked.
    ///
    /// The returned value is in Windows wheel units and already sign-corrected.
    pub fn push(&mut self, delta_pixels: f64) -> Option<i32> {
        if !delta_pixels.is_finite() {
            return None; // a NaN from a malformed peer must not poison the bank
        }
        // Negate here, once: this is the macOS-natural -> Windows-wheel flip.
        let units = -delta_pixels * (WHEEL_DELTA / self.pixels_per_notch);
        self.remainder += units;

        let whole = self.remainder.trunc();
        if whole == 0.0 {
            return None;
        }
        self.remainder -= whole;
        Some(whole as i32)
    }

    /// Drop any banked fraction. Call on `input_reset` and at session end.
    pub fn reset(&mut self) {
        self.remainder = 0.0;
    }

    /// The unsent fraction, for tests and diagnostics.
    pub fn banked(&self) -> f64 {
        self.remainder
    }
}
