use super::*;

const SPS: &[u8] = &[0x67, 0x42, 0xE0, 0x32, 0xAB];
const PPS: &[u8] = &[0x68, 0xCE, 0x3C, 0x80];
const IDR: &[u8] = &[0x65, 0x88, 0x84, 0x00, 0x21];
const SLICE: &[u8] = &[0x41, 0x9A, 0x02];
const AUD: &[u8] = &[0x09, 0xF0];

fn annex_b(units: &[&[u8]]) -> Vec<u8> {
    units
        .iter()
        .flat_map(|unit| START_CODE.iter().chain(unit.iter()).copied())
        .collect()
}

#[test]
fn units_are_split_on_three_and_four_byte_start_codes() {
    let mut data = vec![0, 0, 0, 1];
    data.extend_from_slice(SPS);
    data.extend_from_slice(&[0, 0, 1]);
    data.extend_from_slice(PPS);
    data.extend_from_slice(&[0, 0, 0, 1]);
    data.extend_from_slice(IDR);

    let units = nal_units(&data);
    let kinds: Vec<_> = units.iter().map(NalUnit::kind).collect();
    assert_eq!(kinds, [Some(NAL_SPS), Some(NAL_PPS), Some(NAL_IDR)]);
    assert_eq!(units[0].payload, SPS);
    assert_eq!(units[1].payload, PPS);
    assert_eq!(units[2].payload, IDR);
    assert_eq!(units[1].offset, 4 + SPS.len());
    assert_eq!(units[2].offset, 4 + SPS.len() + 3 + PPS.len());
}

#[test]
fn only_a_leading_start_code_counts_as_annex_b() {
    assert!(is_annex_b(&annex_b(&[IDR])));
    assert!(is_annex_b(&[0, 0, 1, 0x65]));
    let length_prefixed = [0, 0, 0, 5, 0x65, 0x88, 0x84, 0x00, 0x21];
    assert!(!is_annex_b(&length_prefixed));
    assert!(ParameterSets::default()
        .complete(length_prefixed.to_vec())
        .is_err());
}

#[test]
fn an_idr_that_carries_its_parameter_sets_is_left_alone() {
    let mut sets = ParameterSets::default();
    let au = annex_b(&[SPS, PPS, IDR]);
    assert_eq!(sets.complete(au.clone()).unwrap(), au);
}

#[test]
fn a_later_bare_idr_gets_the_cached_sps_and_pps_in_front() {
    let mut sets = ParameterSets::default();
    sets.complete(annex_b(&[SPS, PPS, IDR])).unwrap();
    assert_eq!(sets.complete(annex_b(&[SLICE])).unwrap(), annex_b(&[SLICE]));
    assert_eq!(
        sets.complete(annex_b(&[IDR])).unwrap(),
        annex_b(&[SPS, PPS, IDR])
    );
}

#[test]
fn a_half_complete_idr_gets_both_sets_so_the_sps_still_comes_first() {
    let mut sets = ParameterSets::default();
    sets.complete(annex_b(&[SPS, PPS, IDR])).unwrap();
    assert_eq!(
        sets.complete(annex_b(&[PPS, IDR])).unwrap(),
        annex_b(&[SPS, PPS, PPS, IDR])
    );
}

#[test]
fn the_sequence_header_seeds_the_cache_before_any_output() {
    let mut sets = ParameterSets::default();
    sets.observe(&annex_b(&[SPS, PPS]));
    assert_eq!(
        sets.complete(annex_b(&[IDR])).unwrap(),
        annex_b(&[SPS, PPS, IDR])
    );
}

#[test]
fn parameter_sets_go_after_an_access_unit_delimiter() {
    let mut sets = ParameterSets::default();
    sets.observe(&annex_b(&[SPS, PPS]));
    assert_eq!(
        sets.complete(annex_b(&[AUD, IDR])).unwrap(),
        annex_b(&[AUD, SPS, PPS, IDR])
    );
}

#[test]
fn the_newest_parameter_sets_win() {
    let newer_sps: &[u8] = &[0x67, 0x42, 0xE0, 0x1F];
    let mut sets = ParameterSets::default();
    sets.observe(&annex_b(&[SPS, PPS]));
    sets.complete(annex_b(&[newer_sps, PPS, IDR])).unwrap();
    assert_eq!(
        sets.complete(annex_b(&[IDR])).unwrap(),
        annex_b(&[newer_sps, PPS, IDR])
    );
}

#[test]
fn a_bare_idr_with_nothing_cached_is_an_error_and_empty_output_passes() {
    let mut sets = ParameterSets::default();
    assert!(sets.complete(annex_b(&[IDR])).is_err());
    assert_eq!(sets.complete(Vec::new()).unwrap(), Vec::<u8>::new());
}
