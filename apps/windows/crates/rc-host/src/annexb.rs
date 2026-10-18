//! Annex-B access units, and the parameter sets every IDR must carry.
//!
//! The controller's decoder recovers from loss only at an IDR, and only if that
//! IDR brings its SPS and PPS along. Some hardware encoders emit them once, at
//! the start of the stream, or only in the media type's sequence header; this
//! keeps the latest of each and puts them back in front of any IDR that arrives
//! without them.

const START_CODE: [u8; 4] = [0, 0, 0, 1];

pub const NAL_IDR: u8 = 5;
pub const NAL_SPS: u8 = 7;
pub const NAL_PPS: u8 = 8;
pub const NAL_AUD: u8 = 9;

/// One NAL unit inside an Annex-B buffer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NalUnit<'a> {
    /// Where its start code begins.
    pub offset: usize,
    /// The unit itself, header byte first, without the start code.
    pub payload: &'a [u8],
}

impl NalUnit<'_> {
    pub fn kind(&self) -> Option<u8> {
        self.payload.first().map(|header| header & 0x1F)
    }
}

/// Whether `data` opens with a three- or four-byte start code, which is what
/// separates Annex-B from the length-prefixed form.
pub fn is_annex_b(data: &[u8]) -> bool {
    data.starts_with(&START_CODE) || data.starts_with(&START_CODE[1..])
}

/// Every NAL unit in `data`, in order. A zero byte right before `00 00 01` is
/// read as the first byte of a four-byte start code.
pub fn nal_units(data: &[u8]) -> Vec<NalUnit<'_>> {
    let mut codes = Vec::new();
    let mut i = 0;
    while i + 3 <= data.len() {
        if data[i..i + 3] == START_CODE[1..] {
            let offset = if i > 0 && data[i - 1] == 0 { i - 1 } else { i };
            codes.push((offset, i + 3));
            i += 3;
        } else {
            i += 1;
        }
    }
    codes
        .iter()
        .enumerate()
        .map(|(k, &(offset, payload_start))| {
            let end = codes
                .get(k + 1)
                .map_or(data.len(), |next| next.0)
                .max(payload_start);
            NalUnit {
                offset,
                payload: &data[payload_start..end],
            }
        })
        .collect()
}

/// The newest SPS and PPS the encoder has produced.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct ParameterSets {
    sps: Option<Vec<u8>>,
    pps: Option<Vec<u8>>,
}

impl ParameterSets {
    /// Remember any SPS or PPS in `data`: an access unit, or the media type's
    /// `MF_MT_MPEG_SEQUENCE_HEADER`, which is the same Annex-B form.
    pub fn observe(&mut self, data: &[u8]) {
        for unit in nal_units(data) {
            match unit.kind() {
                Some(NAL_SPS) => self.sps = Some(unit.payload.to_vec()),
                Some(NAL_PPS) => self.pps = Some(unit.payload.to_vec()),
                _ => {}
            }
        }
    }

    /// The access unit as it must go out: unchanged unless it is an IDR missing
    /// its SPS or PPS, in which case the newest of both are inserted in front of
    /// it (after an access unit delimiter, if it opens with one). Both, not just
    /// the missing one, so the SPS always precedes the PPS that refers to it.
    ///
    /// Output that is not Annex-B is an error rather than something to repair:
    /// the packetiser would split it wrongly and the controller would show
    /// nothing, so the caller is better off on another encoder.
    pub fn complete(&mut self, access_unit: Vec<u8>) -> Result<Vec<u8>, String> {
        if access_unit.is_empty() {
            return Ok(access_unit);
        }
        if !is_annex_b(&access_unit) {
            return Err("the encoder's output is not Annex-B (no start code)".into());
        }
        self.observe(&access_unit);
        let units = nal_units(&access_unit);
        let has = |kind| units.iter().any(|unit| unit.kind() == Some(kind));
        if !has(NAL_IDR) || (has(NAL_SPS) && has(NAL_PPS)) {
            return Ok(access_unit);
        }
        let (Some(sps), Some(pps)) = (&self.sps, &self.pps) else {
            return Err(
                "an IDR arrived without parameter sets and the encoder has produced none".into(),
            );
        };
        let at = match units.first() {
            Some(first) if first.kind() == Some(NAL_AUD) => {
                units.get(1).map_or(access_unit.len(), |next| next.offset)
            }
            _ => 0,
        };
        let mut out =
            Vec::with_capacity(access_unit.len() + 2 * START_CODE.len() + sps.len() + pps.len());
        out.extend_from_slice(&access_unit[..at]);
        for set in [sps, pps] {
            out.extend_from_slice(&START_CODE);
            out.extend_from_slice(set);
        }
        out.extend_from_slice(&access_unit[at..]);
        Ok(out)
    }
}

#[cfg(test)]
mod tests;
