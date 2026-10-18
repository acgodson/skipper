//! Packed RGB24 to NV12, the layout hardware H.264 encoders take in.
//!
//! The conversion lives apart from any encoder on purpose: a later capture path
//! that hands the encoder a GPU texture already in NV12 skips it entirely, and
//! nothing in the encoder has to change for that.
//!
//! The matrix is BT.601 limited range, the one openh264's own RGB input uses,
//! so switching between the hardware and software paths does not shift the
//! picture's colours.

use crate::media::RawFrame;

/// One frame in NV12: a full-resolution luma plane, then one plane of
/// interleaved Cb/Cr samples at half resolution in both directions.
///
/// An odd dimension rounds the chroma plane up, so its last column or row
/// averages the pixels that exist rather than reading past the edge.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Nv12Frame {
    pub width: usize,
    pub height: usize,
    pub data: Vec<u8>,
}

impl Nv12Frame {
    pub fn chroma_width(&self) -> usize {
        self.width.div_ceil(2)
    }

    pub fn chroma_height(&self) -> usize {
        self.height.div_ceil(2)
    }

    /// Bytes per chroma row: one Cb and one Cr per chroma sample.
    pub fn chroma_stride(&self) -> usize {
        self.chroma_width() * 2
    }

    pub fn luma(&self) -> &[u8] {
        &self.data[..self.width * self.height]
    }

    pub fn chroma(&self) -> &[u8] {
        &self.data[self.width * self.height..]
    }

    /// Convert `frame` into this buffer, reusing its allocation across frames.
    pub fn fill_from_rgb(&mut self, frame: &RawFrame) {
        self.width = frame.width;
        self.height = frame.height;
        let luma_len = frame.width * frame.height;
        let chroma_stride = self.chroma_stride();
        self.data
            .resize(luma_len + chroma_stride * self.chroma_height(), 0);
        let (luma, chroma) = self.data.split_at_mut(luma_len);

        for (y, px) in luma.iter_mut().zip(frame.rgb.chunks_exact(3)) {
            *y = luma_of(i32::from(px[0]), i32::from(px[1]), i32::from(px[2]));
        }

        let row_bytes = frame.width * 3;
        for (cy, out) in chroma.chunks_exact_mut(chroma_stride).enumerate() {
            let rows = cy * 2..(cy * 2 + 2).min(frame.height);
            for (cx, pair) in out.chunks_exact_mut(2).enumerate() {
                let columns = cx * 2..(cx * 2 + 2).min(frame.width);
                let mut sum = [0i32; 3];
                let mut count = 0i32;
                for y in rows.clone() {
                    for x in columns.clone() {
                        let px = &frame.rgb[y * row_bytes + x * 3..][..3];
                        sum[0] += i32::from(px[0]);
                        sum[1] += i32::from(px[1]);
                        sum[2] += i32::from(px[2]);
                        count += 1;
                    }
                }
                let [r, g, b] = sum.map(|s| (s + count / 2) / count);
                pair[0] = chroma_blue_of(r, g, b);
                pair[1] = chroma_red_of(r, g, b);
            }
        }
    }
}

fn clamp_byte(value: i32) -> u8 {
    value.clamp(0, 255) as u8
}

fn luma_of(r: i32, g: i32, b: i32) -> u8 {
    clamp_byte(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16)
}

fn chroma_blue_of(r: i32, g: i32, b: i32) -> u8 {
    clamp_byte(((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128)
}

fn chroma_red_of(r: i32, g: i32, b: i32) -> u8 {
    clamp_byte(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128)
}

#[cfg(test)]
mod tests;
