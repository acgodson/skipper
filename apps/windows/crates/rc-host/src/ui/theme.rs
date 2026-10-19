//! DESIGN.md's tokens for GDI: the colour roles in both themes, the type scale
//! as fonts at the window's DPI, and the spacing scale in physical pixels.

use windows::core::{w, HSTRING};
use windows::Win32::Foundation::{BOOL, COLORREF, ERROR_SUCCESS, HWND};
use windows::Win32::Graphics::Dwm::{DwmSetWindowAttribute, DWMWA_USE_IMMERSIVE_DARK_MODE};
use windows::Win32::Graphics::Gdi::{
    CreateFontW, DeleteObject, GetDC, GetTextFaceW, ReleaseDC, SelectObject, CLEARTYPE_QUALITY, HFONT,
};
use windows::Win32::System::Registry::{RegGetValueW, HKEY_CURRENT_USER, RRF_RT_REG_DWORD};

use crate::status::Tone;

const fn rgb(hex: u32) -> COLORREF {
    COLORREF(((hex & 0xFF) << 16) | (hex & 0xFF00) | ((hex >> 16) & 0xFF))
}

/// `a` moved toward `b` by `amount` (0 keeps `a`, 1 is `b`).
pub fn blend(a: COLORREF, b: COLORREF, amount: f32) -> COLORREF {
    let channel = |shift: u32| {
        let from = ((a.0 >> shift) & 0xFF) as f32;
        let to = ((b.0 >> shift) & 0xFF) as f32;
        ((from + (to - from) * amount).round() as u32) << shift
    };
    COLORREF(channel(0) | channel(8) | channel(16))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Palette {
    pub dark: bool,
    pub canvas: COLORREF,
    pub surface: COLORREF,
    pub surface_muted: COLORREF,
    pub border: COLORREF,
    pub border_strong: COLORREF,
    pub text_primary: COLORREF,
    pub text_secondary: COLORREF,
    pub text_tertiary: COLORREF,
    pub accent: COLORREF,
    pub accent_pressed: COLORREF,
    pub accent_soft: COLORREF,
    pub on_accent: COLORREF,
    pub positive: COLORREF,
    pub positive_soft: COLORREF,
    pub attention: COLORREF,
    pub attention_soft: COLORREF,
    pub critical: COLORREF,
    pub critical_soft: COLORREF,
    pub neutral_soft: COLORREF,
}

impl Palette {
    pub const LIGHT: Self = Self {
        dark: false,
        canvas: rgb(0xF3F5F6),
        surface: rgb(0xFFFFFF),
        surface_muted: rgb(0xEAEEF0),
        border: rgb(0xDBE1E4),
        border_strong: rgb(0xBFC8CD),
        text_primary: rgb(0x131719),
        text_secondary: rgb(0x57626A),
        text_tertiary: rgb(0x838D95),
        accent: rgb(0x0E6F7A),
        accent_pressed: rgb(0x0A555E),
        accent_soft: rgb(0xDDEFF1),
        on_accent: rgb(0xFFFFFF),
        positive: rgb(0x1C8A52),
        positive_soft: rgb(0xDFF1E7),
        attention: rgb(0xA76500),
        attention_soft: rgb(0xFAECD8),
        critical: rgb(0xB02A22),
        critical_soft: rgb(0xFAE3E1),
        neutral_soft: rgb(0xE6EAEC),
    };

    pub const DARK: Self = Self {
        dark: true,
        canvas: rgb(0x16191B),
        surface: rgb(0x212528),
        surface_muted: rgb(0x282D31),
        border: rgb(0x33393E),
        border_strong: rgb(0x474F55),
        text_primary: rgb(0xF1F4F5),
        text_secondary: rgb(0xA4AEB5),
        text_tertiary: rgb(0x79838B),
        accent: rgb(0x45B4C0),
        accent_pressed: rgb(0x67C7D1),
        accent_soft: rgb(0x123238),
        on_accent: rgb(0x06191C),
        positive: rgb(0x53C78C),
        positive_soft: rgb(0x13301F),
        attention: rgb(0xE2A951),
        attention_soft: rgb(0x352612),
        critical: rgb(0xF08078),
        critical_soft: rgb(0x3A1917),
        neutral_soft: rgb(0x2B3034),
    };

    /// The apps theme the user chose in Settings › Personalization › Colors.
    /// Light when it cannot be read, which is also the Windows default.
    pub fn system() -> Self {
        let mut value = 1u32;
        let mut size = std::mem::size_of::<u32>() as u32;
        let read = unsafe {
            RegGetValueW(
                HKEY_CURRENT_USER,
                w!("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
                w!("AppsUseLightTheme"),
                RRF_RT_REG_DWORD,
                None,
                Some(&mut value as *mut u32 as *mut _),
                Some(&mut size),
            )
        };
        match read == ERROR_SUCCESS && value == 0 {
            true => Self::DARK,
            false => Self::LIGHT,
        }
    }

    /// A tone's (foreground, soft background) pair.
    pub fn tone(&self, tone: Tone) -> (COLORREF, COLORREF) {
        match tone {
            Tone::Neutral => (self.text_secondary, self.neutral_soft),
            Tone::Accent => (self.accent, self.accent_soft),
            Tone::Positive => (self.positive, self.positive_soft),
            Tone::Attention => (self.attention, self.attention_soft),
            Tone::Critical => (self.critical, self.critical_soft),
        }
    }

    /// The hero's and the consent card's stroke: accent at 35 % over the card.
    pub fn hero_stroke(&self) -> COLORREF {
        blend(self.surface, self.accent, 0.35)
    }

    /// The title bar follows the theme too, where Windows supports it.
    pub fn apply_title_bar(&self, window: HWND) {
        let dark = BOOL::from(self.dark);
        unsafe {
            let _ = DwmSetWindowAttribute(
                window,
                DWMWA_USE_IMMERSIVE_DARK_MODE,
                &dark as *const BOOL as *const _,
                std::mem::size_of::<BOOL>() as u32,
            );
        }
    }
}

/// Logical (96-DPI) pixels to this window's pixels. DESIGN.md's points are
/// taken as logical pixels, which is how the Mac's points read on screen.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Scale(pub u32);

impl Scale {
    pub fn px(self, logical: i32) -> i32 {
        (logical * self.0 as i32 + 48) / 96
    }
}

pub mod space {
    pub const XXS: i32 = 2;
    pub const XS: i32 = 4;
    pub const S: i32 = 8;
    pub const M: i32 = 12;
    pub const L: i32 = 16;
    pub const XL: i32 = 24;
    pub const RADIUS_SMALL: i32 = 6;
    pub const RADIUS_LARGE: i32 = 14;
}

/// The type scale at one DPI. Recreated when the window moves to a display
/// with a different scale.
pub struct Fonts {
    pub title: HFONT,
    pub body: HFONT,
    pub body_emphasis: HFONT,
    pub caption: HFONT,
    pub caption_semibold: HFONT,
    pub section: HFONT,
    pub code_hero: HFONT,
    pub code: HFONT,
    pub code_caption: HFONT,
}

const REGULAR: i32 = 400;
const MEDIUM: i32 = 500;
const SEMIBOLD: i32 = 600;

impl Fonts {
    pub fn new(scale: Scale) -> Self {
        let display = available(&["Segoe UI Variable Display", "Segoe UI"]);
        let text = available(&["Segoe UI Variable Text", "Segoe UI"]);
        let mono = available(&["Cascadia Mono", "Consolas"]);
        let font = |face: &str, size: i32, weight: i32| make(face, scale.px(size), weight);
        Self {
            title: font(&display, 20, SEMIBOLD),
            body: font(&text, 13, REGULAR),
            body_emphasis: font(&text, 13, MEDIUM),
            caption: font(&text, 11, REGULAR),
            caption_semibold: font(&text, 11, SEMIBOLD),
            section: font(&text, 11, SEMIBOLD),
            code_hero: font(&mono, 26, MEDIUM),
            code: font(&mono, 13, REGULAR),
            code_caption: font(&mono, 11, REGULAR),
        }
    }
}

impl Drop for Fonts {
    fn drop(&mut self) {
        for font in [
            self.title,
            self.body,
            self.body_emphasis,
            self.caption,
            self.caption_semibold,
            self.section,
            self.code_hero,
            self.code,
            self.code_caption,
        ] {
            unsafe {
                let _ = DeleteObject(font);
            }
        }
    }
}

fn make(face: &str, pixels: i32, weight: i32) -> HFONT {
    unsafe {
        CreateFontW(
            -pixels,
            0,
            0,
            0,
            weight,
            0,
            0,
            0,
            0,
            0,
            0,
            CLEARTYPE_QUALITY.0 as u32,
            0,
            &HSTRING::from(face),
        )
    }
}

/// The first face GDI really has. Asking for a missing face silently gives
/// another one, so the face a font actually selected is read back.
fn available(faces: &[&str]) -> String {
    let fallback = faces.last().copied().unwrap_or("Segoe UI");
    for face in faces {
        let font = make(face, 12, REGULAR);
        let mut name = [0u16; 64];
        let chosen = unsafe {
            let dc = GetDC(None);
            let previous = SelectObject(dc, font);
            GetTextFaceW(dc, Some(&mut name));
            SelectObject(dc, previous);
            ReleaseDC(None, dc);
            let _ = DeleteObject(font);
            let length = name.iter().position(|&unit| unit == 0).unwrap_or(name.len());
            String::from_utf16_lossy(&name[..length])
        };
        if chosen.eq_ignore_ascii_case(face) {
            return face.to_string();
        }
    }
    fallback.to_string()
}
