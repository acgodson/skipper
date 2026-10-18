use super::*;

const BLACK: [u8; 3] = [0, 0, 0];
const WHITE: [u8; 3] = [255, 255, 255];
const RED: [u8; 3] = [255, 0, 0];
const GREEN: [u8; 3] = [0, 255, 0];
const BLUE: [u8; 3] = [0, 0, 255];

fn frame(width: usize, height: usize, pixel: impl Fn(usize, usize) -> [u8; 3]) -> RawFrame {
    let mut rgb = Vec::with_capacity(width * height * 3);
    for y in 0..height {
        for x in 0..width {
            rgb.extend_from_slice(&pixel(x, y));
        }
    }
    RawFrame { width, height, rgb }
}

fn convert(frame: &RawFrame) -> Nv12Frame {
    let mut nv12 = Nv12Frame::default();
    nv12.fill_from_rgb(frame);
    nv12
}

#[test]
fn flat_colours_land_on_the_bt601_limited_range_values() {
    for (colour, y, cb, cr) in [
        (BLACK, 16, 128, 128),
        (WHITE, 235, 128, 128),
        (RED, 82, 90, 240),
    ] {
        let nv12 = convert(&frame(2, 2, |_, _| colour));
        assert_eq!(nv12.luma(), [y; 4], "luma of {colour:?}");
        assert_eq!(nv12.chroma(), [cb, cr], "chroma of {colour:?}");
    }
}

#[test]
fn luma_is_per_pixel_and_chroma_averages_the_two_by_two_block() {
    let nv12 = convert(&frame(2, 2, |x, y| [RED, GREEN, BLUE, WHITE][y * 2 + x]));
    assert_eq!(nv12.luma(), [82, 144, 41, 235]);
    assert_eq!(nv12.chroma(), [128, 128]);
}

#[test]
fn even_sizes_give_a_half_size_interleaved_chroma_plane() {
    let nv12 = convert(&frame(4, 2, |x, _| if x < 2 { BLACK } else { RED }));
    assert_eq!(nv12.data.len(), 4 * 2 + 4);
    assert_eq!(nv12.luma(), [16, 16, 82, 82, 16, 16, 82, 82]);
    assert_eq!(nv12.chroma(), [128, 128, 90, 240]);
}

#[test]
fn odd_sizes_round_chroma_up_and_average_only_real_pixels() {
    let nv12 = convert(&frame(3, 3, |x, _| if x < 2 { BLACK } else { RED }));
    assert_eq!(
        (
            nv12.chroma_width(),
            nv12.chroma_height(),
            nv12.chroma_stride()
        ),
        (2, 2, 4)
    );
    assert_eq!(nv12.data.len(), 9 + 8);
    assert_eq!(nv12.luma(), [16, 16, 82, 16, 16, 82, 16, 16, 82]);
    assert_eq!(nv12.chroma(), [128, 128, 90, 240, 128, 128, 90, 240]);

    let single = convert(&frame(1, 1, |_, _| WHITE));
    assert_eq!(single.data, [235, 128, 128]);
}

#[test]
fn a_reused_buffer_follows_the_new_frame_size() {
    let mut nv12 = Nv12Frame::default();
    nv12.fill_from_rgb(&frame(4, 4, |_, _| WHITE));
    nv12.fill_from_rgb(&frame(2, 2, |_, _| BLACK));
    assert_eq!(nv12.data, [16, 16, 16, 16, 128, 128]);
}
