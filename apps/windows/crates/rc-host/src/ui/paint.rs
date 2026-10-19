//! GDI drawing in DESIGN.md's shapes: cards, pills, buttons and the toggle.

use windows::Win32::Foundation::{COLORREF, HWND, RECT};
use windows::Win32::Graphics::Gdi::{
    BitBlt, CreateCompatibleBitmap, CreateCompatibleDC, CreatePen, CreateSolidBrush, DeleteDC, DeleteObject,
    DrawTextW, Ellipse, FillRect, RoundRect, SelectObject, SetBkMode, SetTextCharacterExtra, SetTextColor,
    DRAW_TEXT_FORMAT, DT_CALCRECT, DT_CENTER, DT_END_ELLIPSIS, DT_NOPREFIX, DT_SINGLELINE, DT_VCENTER, DT_WORDBREAK,
    HDC, HFONT, PS_SOLID, SRCCOPY, TRANSPARENT,
};
use windows::Win32::UI::Controls::{DRAWITEMSTRUCT, ODS_DISABLED, ODS_FOCUS, ODS_SELECTED};
use windows::Win32::UI::WindowsAndMessaging::GetWindowTextW;

use super::theme::{blend, space, Palette, Scale};
use crate::status::Tone;

pub const WRAP: DRAW_TEXT_FORMAT = DRAW_TEXT_FORMAT(DT_WORDBREAK.0 | DT_NOPREFIX.0);
pub const LINE: DRAW_TEXT_FORMAT = DRAW_TEXT_FORMAT(DT_SINGLELINE.0 | DT_NOPREFIX.0 | DT_VCENTER.0 | DT_END_ELLIPSIS.0);
pub const CENTERED: DRAW_TEXT_FORMAT = DRAW_TEXT_FORMAT(LINE.0 | DT_CENTER.0);

pub fn rect(x: i32, y: i32, width: i32, height: i32) -> RECT {
    RECT { left: x, top: y, right: x + width, bottom: y + height }
}

pub struct Canvas {
    pub dc: HDC,
    pub palette: Palette,
    pub scale: Scale,
}

impl Canvas {
    pub fn px(&self, logical: i32) -> i32 {
        self.scale.px(logical)
    }

    pub fn fill(&self, area: RECT, color: COLORREF) {
        unsafe {
            let brush = CreateSolidBrush(color);
            FillRect(self.dc, &area, brush);
            let _ = DeleteObject(brush);
        }
    }

    /// A rounded rectangle with a one-pixel stroke; `stroke` defaults to the fill.
    pub fn round(&self, area: RECT, radius: i32, fill: COLORREF, stroke: Option<COLORREF>) {
        let corner = self.px(radius) * 2;
        unsafe {
            let brush = CreateSolidBrush(fill);
            let pen = CreatePen(PS_SOLID, self.px(1).max(1), stroke.unwrap_or(fill));
            let old_brush = SelectObject(self.dc, brush);
            let old_pen = SelectObject(self.dc, pen);
            let _ = RoundRect(self.dc, area.left, area.top, area.right, area.bottom, corner, corner);
            SelectObject(self.dc, old_brush);
            SelectObject(self.dc, old_pen);
            let _ = DeleteObject(brush);
            let _ = DeleteObject(pen);
        }
    }

    pub fn ellipse(&self, area: RECT, fill: COLORREF) {
        unsafe {
            let brush = CreateSolidBrush(fill);
            let pen = CreatePen(PS_SOLID, 1, fill);
            let old_brush = SelectObject(self.dc, brush);
            let old_pen = SelectObject(self.dc, pen);
            let _ = Ellipse(self.dc, area.left, area.top, area.right, area.bottom);
            SelectObject(self.dc, old_brush);
            SelectObject(self.dc, old_pen);
            let _ = DeleteObject(brush);
            let _ = DeleteObject(pen);
        }
    }

    pub fn text(&self, area: RECT, text: &str, font: HFONT, color: COLORREF, format: DRAW_TEXT_FORMAT) {
        let mut wide: Vec<u16> = text.encode_utf16().collect();
        let mut area = area;
        unsafe {
            let previous = SelectObject(self.dc, font);
            SetBkMode(self.dc, TRANSPARENT);
            SetTextColor(self.dc, color);
            DrawTextW(self.dc, &mut wide, &mut area, format);
            SelectObject(self.dc, previous);
        }
    }

    /// DESIGN.md's `sectionLabel`: uppercase, semibold, slightly tracked.
    pub fn section_label(&self, area: RECT, text: &str, font: HFONT) {
        unsafe {
            SetTextCharacterExtra(self.dc, self.px(1));
        }
        self.text(area, &text.to_uppercase(), font, self.palette.text_tertiary, LINE);
        unsafe {
            SetTextCharacterExtra(self.dc, 0);
        }
    }

    /// The size `text` takes in `font`, wrapped to `width` unless `format` is single-line.
    pub fn measure(&self, width: i32, text: &str, font: HFONT, format: DRAW_TEXT_FORMAT) -> (i32, i32) {
        let mut wide: Vec<u16> = text.encode_utf16().collect();
        let mut area = rect(0, 0, width, 0);
        unsafe {
            let previous = SelectObject(self.dc, font);
            DrawTextW(self.dc, &mut wide, &mut area, DRAW_TEXT_FORMAT(format.0 | DT_CALCRECT.0));
            SelectObject(self.dc, previous);
        }
        (area.right - area.left, area.bottom - area.top)
    }

    pub fn pill_width(&self, label: &str, font: HFONT) -> i32 {
        let (text_width, _) = self.measure(0, label, font, LINE);
        self.px(space::M) * 2 + self.px(7) + self.px(space::S) + text_width
    }

    /// The status pill at `left`, `top`: a capsule in the tone's soft colour,
    /// a 7 px dot and the label in the tone.
    pub fn pill(&self, left: i32, top: i32, label: &str, tone: Tone, font: HFONT) {
        let (foreground, background) = self.palette.tone(tone);
        let (text_width, _) = self.measure(0, label, font, LINE);
        let height = self.px(26);
        let dot = self.px(7);
        let padding = self.px(space::M);
        let area = rect(left, top, self.pill_width(label, font), height);
        self.round(area, 13, background, None);
        let dot_top = top + (height - dot) / 2;
        self.ellipse(rect(area.left + padding, dot_top, dot, dot), foreground);
        let text_left = area.left + padding + dot + self.px(space::S);
        self.text(rect(text_left, top, text_width + padding, height), label, font, foreground, LINE);
    }
}

/// Paints a window off screen and copies it in one go, so nothing flickers.
pub fn buffered(target: HDC, area: RECT, palette: Palette, scale: Scale, paint: impl FnOnce(&Canvas)) {
    let width = area.right - area.left;
    let height = area.bottom - area.top;
    unsafe {
        let memory = CreateCompatibleDC(target);
        let bitmap = CreateCompatibleBitmap(target, width, height);
        let previous = SelectObject(memory, bitmap);
        paint(&Canvas { dc: memory, palette, scale });
        let _ = BitBlt(target, 0, 0, width, height, memory, 0, 0, SRCCOPY);
        SelectObject(memory, previous);
        let _ = DeleteObject(bitmap);
        let _ = DeleteDC(memory);
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ButtonKind {
    Primary,
    Secondary,
    Quiet,
    Plain,
    Done,
}

/// An owner-drawn button. `behind` is the colour the button sits on, which
/// fills the corners its radius leaves.
pub fn draw_button(item: &DRAWITEMSTRUCT, palette: Palette, scale: Scale, font: HFONT, kind: ButtonKind, behind: COLORREF) {
    let canvas = Canvas { dc: item.hDC, palette, scale };
    let area = item.rcItem;
    let pressed = item.itemState.0 & ODS_SELECTED.0 != 0;
    let disabled = item.itemState.0 & ODS_DISABLED.0 != 0;
    let focused = item.itemState.0 & ODS_FOCUS.0 != 0;
    let (fill, stroke, text) = match kind {
        ButtonKind::Primary => {
            let fill = match pressed {
                true => palette.accent_pressed,
                false => palette.accent,
            };
            (Some(fill), None, palette.on_accent)
        }
        ButtonKind::Secondary | ButtonKind::Done => {
            let fill = match pressed {
                true => palette.border,
                false => palette.surface_muted,
            };
            let text = match kind {
                ButtonKind::Done => palette.positive,
                _ => palette.text_primary,
            };
            (Some(fill), Some(palette.border), text)
        }
        ButtonKind::Quiet => (pressed.then_some(palette.surface_muted), None, palette.accent),
        ButtonKind::Plain => (pressed.then_some(palette.surface_muted), Some(palette.border), palette.text_primary),
    };
    let fade = |color: COLORREF| match disabled {
        true => blend(color, behind, 0.55),
        false => color,
    };
    canvas.fill(area, behind);
    let stroke = match focused {
        true => Some(palette.accent),
        false => stroke.map(fade),
    };
    if let Some(fill) = fill {
        canvas.round(area, space::RADIUS_SMALL, fade(fill), stroke);
    } else if let Some(stroke) = stroke {
        canvas.round(area, space::RADIUS_SMALL, behind, Some(stroke));
    }
    canvas.text(area, &window_text(item.hwndItem), font, fade(text), CENTERED);
}

/// The toggle: a track in `accent` when on and `borderStrong` when off, with
/// a light knob at the end it points to.
pub fn draw_toggle(item: &DRAWITEMSTRUCT, palette: Palette, scale: Scale, on: bool, behind: COLORREF) {
    let canvas = Canvas { dc: item.hDC, palette, scale };
    let area = item.rcItem;
    canvas.fill(area, behind);
    let width = canvas.px(40);
    let height = canvas.px(22);
    let left = area.right - width - canvas.px(2);
    let top = area.top + (area.bottom - area.top - height) / 2;
    let track = match on {
        true => palette.accent,
        false => palette.border_strong,
    };
    if item.itemState.0 & ODS_FOCUS.0 != 0 {
        let ring = canvas.px(2);
        let outline = rect(left - ring, top - ring, width + ring * 2, height + ring * 2);
        canvas.round(outline, 13, behind, Some(palette.accent));
    }
    canvas.round(rect(left, top, width, height), 11, track, None);
    let inset = canvas.px(2);
    let knob = height - inset * 2;
    let knob_left = match on {
        true => left + width - inset - knob,
        false => left + inset,
    };
    let knob_color = match palette.dark {
        true => COLORREF(0x00E6E6E6),
        false => COLORREF(0x00FFFFFF),
    };
    canvas.ellipse(rect(knob_left, top + inset, knob, knob), knob_color);
}

fn window_text(window: HWND) -> String {
    let mut buffer = [0u16; 128];
    let length = unsafe { GetWindowTextW(window, &mut buffer) }.max(0) as usize;
    String::from_utf16_lossy(&buffer[..length])
}
