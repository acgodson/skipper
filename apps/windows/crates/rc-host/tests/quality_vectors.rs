//! The quality ladder and host gate against `protocol/vectors/quality-vectors.json`,
//! the same file the Mac's `QualityProfile.swift` is tested against.

use rc_host::quality::{
    capped_size, maximum_bitrate_bps, maximum_width, minimum_bitrate_bps, ACTIVE_FRAMERATE,
};
use rc_proto::ctrl::QualityMode;
use serde_json::Value;

const VECTORS: &str = include_str!("../../../../../protocol/vectors/quality-vectors.json");

fn mode(value: &Value) -> QualityMode {
    let wire = value.as_str().expect("a mode is a string");
    let parsed = QualityMode::from_wire(wire);
    assert_eq!(parsed.as_wire(), wire, "vector modes are canonical");
    parsed
}

fn number(value: &Value) -> u32 {
    value.as_u64().expect("a number") as u32
}

#[test]
fn the_ladder_matches_the_shared_vectors() {
    let vectors: Value = serde_json::from_str(VECTORS).unwrap();
    let ladder: Vec<QualityMode> = vectors["ladder"].as_array().unwrap().iter().map(mode).collect();
    assert_eq!(ladder, QualityMode::LADDER);
    assert_eq!(number(&vectors["framerate"]), ACTIVE_FRAMERATE);
    for row in vectors["modes"].as_array().unwrap() {
        let m = mode(&row["mode"]);
        assert_eq!(maximum_width(m), number(&row["maxWidth"]), "{row}");
        assert_eq!(maximum_bitrate_bps(m), number(&row["maxBitrateBps"]), "{row}");
        assert_eq!(minimum_bitrate_bps(m), number(&row["minBitrateBps"]), "{row}");
    }
}

#[test]
fn wire_values_parse_as_the_mac_parses_them() {
    let vectors: Value = serde_json::from_str(VECTORS).unwrap();
    for row in vectors["wire"].as_array().unwrap() {
        assert_eq!(QualityMode::from_wire(row["wire"].as_str().unwrap()), mode(&row["mode"]), "{row}");
    }
}

#[test]
fn encode_sizes_match_the_shared_vectors() {
    let vectors: Value = serde_json::from_str(VECTORS).unwrap();
    for row in vectors["profiles"].as_array().unwrap() {
        let (display, encode) = (&row["display"], &row["encode"]);
        let size = capped_size(number(&display[0]), number(&display[1]), mode(&row["mode"]));
        assert_eq!(size, (number(&encode[0]), number(&encode[1])), "{row}");
    }
}

#[test]
fn the_host_gate_matches_the_shared_vectors() {
    let vectors: Value = serde_json::from_str(VECTORS).unwrap();
    for row in vectors["permitted"].as_array().unwrap() {
        let stated = (!row["stated"].is_null()).then(|| mode(&row["stated"]));
        let applied =
            QualityMode::permitted(mode(&row["requested"]), stated, row["fresh"].as_bool().unwrap());
        assert_eq!(applied, mode(&row["applied"]), "{row}");
    }
}

#[test]
fn the_cases_the_gate_exists_for() {
    use QualityMode::*;
    assert_eq!(QualityMode::permitted(Sharp, Some(Auto), true), Auto, "a trial asking for sharp");
    assert_eq!(QualityMode::permitted(Sharp, None, true), Auto, "no entitlement");
    assert_eq!(QualityMode::permitted(Sharp, Some(Sharp), false), Auto, "a stale entitlement");
    assert_eq!(QualityMode::permitted(Smooth, Some(Sharp), true), Smooth, "a lower request stands");
}
