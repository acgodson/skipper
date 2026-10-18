//! The quality ladder, number for number the Mac's `QualityProfile.swift`, and
//! the account ceiling the host gate reads. `protocol/vectors/quality-vectors.json`
//! pins both implementations to the same values.

use std::sync::{Arc, Mutex};

use rc_proto::ctrl::QualityMode;

use crate::api::Entitlement;

pub const ACTIVE_FRAMERATE: u32 = 30;
pub const BURST_BITRATE_BPS: u32 = 8_000_000;
pub const FLOOR_BITRATE_BPS: u32 = 400_000;

/// The widest frame each mode encodes. The derivation of every number below is
/// on the Mac side (`QualityProfile.swift`, `docs/BETA.md` §2.3).
pub fn maximum_width(mode: QualityMode) -> u32 {
    match mode {
        QualityMode::Sharp => 2560,
        QualityMode::Auto => 1920,
        QualityMode::Smooth => 1280,
    }
}

pub fn maximum_bitrate_bps(mode: QualityMode) -> u32 {
    match mode {
        QualityMode::Sharp => BURST_BITRATE_BPS,
        QualityMode::Auto => 2_000_000,
        QualityMode::Smooth => 1_000_000,
    }
}

pub fn minimum_bitrate_bps(mode: QualityMode) -> u32 {
    FLOOR_BITRATE_BPS.min(maximum_bitrate_bps(mode) / 4)
}

fn even(value: f64) -> u32 {
    ((value / 2.0).round() as u32 * 2).max(2)
}

/// The Mac's `cappedSize`: at most the mode's width, aspect kept, both edges
/// rounded to even.
pub fn capped_size(width: u32, height: u32, mode: QualityMode) -> (u32, u32) {
    if width == 0 || height == 0 {
        return (0, 0);
    }
    let cap = maximum_width(mode);
    if width <= cap {
        return (even(f64::from(width)), even(f64::from(height)));
    }
    let scale = f64::from(width) / f64::from(cap);
    (even(f64::from(cap)), even(f64::from(height) / scale))
}

/// What this host encodes a `width`×`height` capture at. Inside the cap the
/// frame is cropped to even rather than resampled to the Mac's rounded-up size:
/// a 1365→1366 resample would soften every pixel to gain one, so the encode
/// size differs from `capped_size` by at most one pixel and only on odd edges.
pub fn encode_size(width: u32, height: u32, mode: QualityMode) -> (u32, u32) {
    if width <= maximum_width(mode) {
        return (width & !1, height & !1);
    }
    capped_size(width, height, mode)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct QualityProfile {
    pub mode: QualityMode,
    pub max_bitrate_bps: u32,
    pub min_bitrate_bps: u32,
    pub max_framerate: u32,
}

impl QualityProfile {
    pub fn for_mode(mode: QualityMode) -> Self {
        Self {
            mode,
            max_bitrate_bps: maximum_bitrate_bps(mode),
            min_bitrate_bps: minimum_bitrate_bps(mode),
            max_framerate: ACTIVE_FRAMERATE,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct StatedCeiling {
    mode: QualityMode,
    fetched_ms: i64,
    refresh_after_sec: i32,
}

/// The account's `limits.maxQuality` as last fetched, shared between whoever
/// refreshes the entitlement and the host that gates on it. Freshness is the
/// Mac's `CachedEntitlement.isStale`: an answer is stale once it is
/// `refreshAfterSec` old.
#[derive(Debug, Clone, Default)]
pub struct QualityCeiling(Arc<Mutex<Option<StatedCeiling>>>);

impl QualityCeiling {
    pub fn record(&self, entitlement: Option<&Entitlement>, fetched_ms: i64) {
        let stated = entitlement.map(|value| StatedCeiling {
            mode: value.max_quality(),
            fetched_ms,
            refresh_after_sec: value.refresh_after_sec,
        });
        *self.0.lock().unwrap_or_else(|e| e.into_inner()) = stated;
    }

    /// The gate's inputs at `now_ms`: the stated ceiling, and whether it is fresh.
    pub fn stated(&self, now_ms: i64) -> (Option<QualityMode>, bool) {
        let stated = *self.0.lock().unwrap_or_else(|e| e.into_inner());
        match stated {
            Some(c) => {
                let fresh =
                    now_ms.saturating_sub(c.fetched_ms) < i64::from(c.refresh_after_sec) * 1000;
                (Some(c.mode), fresh)
            }
            None => (None, false),
        }
    }

    pub fn permitted(&self, requested: QualityMode, now_ms: i64) -> QualityMode {
        let (stated, fresh) = self.stated(now_ms);
        QualityMode::permitted(requested, stated, fresh)
    }
}
