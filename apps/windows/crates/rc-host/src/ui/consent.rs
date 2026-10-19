//! The consent window: DESIGN.md's consent prompt in its window style, as its
//! own always-on-top window so it is seen whatever else is open. Allow stays
//! disabled for the prompt's first moments, Esc and the close box decline, and
//! Return does nothing, so a stray keypress never lets anyone in.

use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::{BeginPaint, EndPaint, GetDC, ReleaseDC, PAINTSTRUCT};
use windows::Win32::System::Diagnostics::Debug::MessageBeep;
use windows::Win32::UI::Controls::DRAWITEMSTRUCT;
use windows::Win32::UI::Input::KeyboardAndMouse::{EnableWindow, SetFocus};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DestroyWindow, FlashWindowEx, GetClientRect, GetSystemMetrics, KillTimer, SetForegroundWindow,
    SetTimer, ShowWindow, FLASHWINFO, FLASHW_ALL, FLASHW_TIMERNOFG, MB_ICONQUESTION, SM_CXSCREEN, SM_CYSCREEN, SW_SHOW,
    WINDOW_STYLE, WM_CLOSE, WM_COMMAND, WM_DRAWITEM, WM_ERASEBKGND, WM_PAINT, WM_TIMER,
    WS_CAPTION, WS_CLIPCHILDREN, WS_EX_TOPMOST, WS_POPUP, WS_SYSMENU,
};

use super::paint::{buffered, rect, Canvas, LINE, WRAP};
use super::theme::space::{L, M, RADIUS_LARGE, S, XL, XS};
use super::{
    low_word, outer_size, owner_drawn_button, place, repaint, Handled, State, CONSENT_CLASS, ID_ALLOW,
    ID_ALLOW_ALWAYS, ID_CANCEL, ID_DECLINE, TIMER_COUNTDOWN, TIMER_GUARD, TITLE,
};
use crate::consent::ConsentAnswer;
use crate::status::{ConsentRequest, Tone};

const WIDTH: i32 = 460;
const SECONDS: u32 = 30;
const GUARD_MS: u32 = 1600;
const HEADING: &str = "Allow this computer to be controlled?";
const REPLACED: &str = "A different request replaced the previous one.";
const SENTENCE: &str = "It entered this PC's access code. If you do not answer, the connection is declined.";
const NOTE: &str = "\u{201C}Allow and Don't Ask Again\u{201D} turns on unattended access: from then on anyone with this PC's access code connects without asking.";

const STYLE: WINDOW_STYLE = WINDOW_STYLE(WS_POPUP.0 | WS_CAPTION.0 | WS_SYSMENU.0 | WS_CLIPCHILDREN.0);

pub struct ConsentWindow {
    pub window: HWND,
    allow: HWND,
    allow_always: HWND,
    request: ConsentRequest,
    seconds_left: u32,
    layout: Layout,
}

#[derive(Default)]
struct Layout {
    card: RECT,
    heading: RECT,
    replaced: Option<RECT>,
    sentence: RECT,
    device: RECT,
    fingerprint: RECT,
    pill_left: i32,
    pill_top: i32,
    note: RECT,
    allow: RECT,
    allow_always: RECT,
    decline: RECT,
    height: i32,
}

fn countdown(seconds: u32) -> String {
    match seconds {
        0 => "Declining…".into(),
        s => format!("Declines in {s} s"),
    }
}

impl State {
    fn consent_layout(&self, canvas: &Canvas, request: &ConsentRequest) -> Layout {
        let px = |logical: i32| canvas.px(logical);
        let f = &self.fonts;
        let mut layout = Layout::default();
        let card_left = px(L);
        let card_width = px(WIDTH) - px(L) * 2;
        let left = card_left + px(XL);
        let width = card_width - px(XL) * 2;

        let mut y = px(L) + px(XL);
        let (_, height) = canvas.measure(width, HEADING, f.title, WRAP);
        layout.heading = rect(left, y, width, height);
        y += height + px(S);
        if request.replaces_previous {
            let (_, height) = canvas.measure(width, REPLACED, f.caption_semibold, WRAP);
            layout.replaced = Some(rect(left, y, width, height));
            y += height + px(XS);
        }
        let (_, height) = canvas.measure(width, SENTENCE, f.caption, WRAP);
        layout.sentence = rect(left, y, width, height);
        y += height + px(M);
        let (_, line) = canvas.measure(0, "0", f.code, LINE);
        layout.device = rect(left, y, width, line);
        y += line + px(XS);
        let (_, height) = canvas.measure(width, &self.fingerprint_line(request), f.code, WRAP);
        layout.fingerprint = rect(left, y, width, height);
        y += height + px(L);
        layout.pill_left = left;
        layout.pill_top = y;
        y += px(26) + px(L);

        let button = |label: &str| canvas.measure(0, label, f.body_emphasis, LINE).0 + px(M) * 2;
        let button_height = px(32);
        let allow_width = button("Allow");
        let always_width = button("Allow and Don't Ask Again");
        let decline_width = button("Decline");
        let right = left + width;
        layout.allow = rect(right - allow_width, y, allow_width, button_height);
        layout.allow_always = rect(layout.allow.left - px(S) - always_width, y, always_width, button_height);
        layout.decline = rect(layout.allow_always.left - px(S) - decline_width, y, decline_width, button_height);
        y += button_height + px(M);
        let (_, height) = canvas.measure(width, NOTE, f.caption, WRAP);
        layout.note = rect(left, y, width, height);
        y += height + px(XL);
        layout.card = RECT { left: card_left, top: px(L), right: card_left + card_width, bottom: y };
        layout.height = y + px(L);
        layout
    }

    fn fingerprint_line(&self, request: &ConsentRequest) -> String {
        format!("Fingerprint {}", request.fingerprint)
    }

    /// Opens the prompt, replacing any that is still up, and makes sure it is
    /// noticed: it comes to the front, flashes in the taskbar and beeps.
    pub(super) unsafe fn open_consent(&mut self, request: ConsentRequest) {
        self.close_consent();
        let dc = GetDC(None);
        let canvas = Canvas { dc, palette: self.palette, scale: self.scale };
        let layout = self.consent_layout(&canvas, &request);
        ReleaseDC(None, dc);

        let extended = WS_EX_TOPMOST;
        let (width, height) = outer_size(self.scale, self.scale.px(WIDTH), layout.height, STYLE, extended);
        let x = (GetSystemMetrics(SM_CXSCREEN) - width) / 2;
        let y = (GetSystemMetrics(SM_CYSCREEN) - height) / 3;
        let Ok(window) = CreateWindowExW(
            extended,
            CONSENT_CLASS,
            TITLE,
            STYLE,
            x,
            y,
            width,
            height,
            None,
            None,
            self.instance,
            None,
        ) else {
            return;
        };
        self.palette.apply_title_bar(window);
        let decline = owner_drawn_button(window, self.instance, "Decline", ID_DECLINE);
        let allow_always = owner_drawn_button(window, self.instance, "Allow and Don't Ask Again", ID_ALLOW_ALWAYS);
        let allow = owner_drawn_button(window, self.instance, "Allow", ID_ALLOW);
        place(decline, layout.decline);
        place(allow_always, layout.allow_always);
        place(allow, layout.allow);
        let _ = EnableWindow(allow, false);
        let _ = EnableWindow(allow_always, false);
        SetTimer(window, TIMER_GUARD, GUARD_MS, None);
        SetTimer(window, TIMER_COUNTDOWN, 1000, None);
        self.consent = Some(ConsentWindow { window, allow, allow_always, request, seconds_left: SECONDS, layout });

        let _ = ShowWindow(window, SW_SHOW);
        let _ = SetForegroundWindow(window);
        let _ = SetFocus(decline);
        let flash = FLASHWINFO {
            cbSize: std::mem::size_of::<FLASHWINFO>() as u32,
            hwnd: window,
            dwFlags: FLASHW_ALL | FLASHW_TIMERNOFG,
            uCount: 0,
            dwTimeout: 0,
        };
        let _ = FlashWindowEx(&flash);
        let _ = MessageBeep(MB_ICONQUESTION);
    }

    pub(super) unsafe fn close_consent(&mut self) {
        if let Some(consent) = self.consent.take() {
            let _ = DestroyWindow(consent.window);
        }
    }

    unsafe fn paint_consent(&self, consent: &ConsentWindow) {
        let mut paint = PAINTSTRUCT::default();
        let dc = BeginPaint(consent.window, &mut paint);
        let mut client = RECT::default();
        let _ = GetClientRect(consent.window, &mut client);
        buffered(dc, client, self.palette, self.scale, |canvas| {
            let p = &self.palette;
            let f = &self.fonts;
            let l = &consent.layout;
            canvas.fill(client, p.canvas);
            canvas.round(l.card, RADIUS_LARGE, p.surface, Some(p.hero_stroke()));
            canvas.text(l.heading, HEADING, f.title, p.text_primary, WRAP);
            if let Some(area) = l.replaced {
                canvas.text(area, REPLACED, f.caption_semibold, p.attention, WRAP);
            }
            canvas.text(l.sentence, SENTENCE, f.caption, p.text_secondary, WRAP);
            let device = format!("Device ID {}", consent.request.device_id);
            canvas.text(l.device, &device, f.code, p.text_primary, LINE);
            canvas.text(l.fingerprint, &self.fingerprint_line(&consent.request), f.code, p.text_primary, WRAP);
            canvas.pill(l.pill_left, l.pill_top, &countdown(consent.seconds_left), Tone::Attention, f.caption_semibold);
            canvas.text(l.note, NOTE, f.caption, p.text_tertiary, WRAP);
        });
        let _ = EndPaint(consent.window, &paint);
    }

    pub(super) unsafe fn on_consent(&mut self, window: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) -> Handled {
        if self.consent.as_ref().is_none_or(|c| c.window != window) {
            return Handled::Default;
        }
        match message {
            WM_COMMAND => match low_word(wparam.0) {
                ID_ALLOW => self.answer(ConsentAnswer::Allow),
                ID_ALLOW_ALWAYS => self.answer(ConsentAnswer::AllowAndTurnOnUnattended),
                ID_DECLINE | ID_CANCEL => self.answer(ConsentAnswer::Decline),
                _ => return Handled::Default,
            },
            WM_TIMER => {
                let Some(consent) = self.consent.as_mut() else { return Handled::Default };
                match wparam.0 {
                    TIMER_GUARD => {
                        let _ = KillTimer(window, TIMER_GUARD);
                        let _ = EnableWindow(consent.allow, true);
                        let _ = EnableWindow(consent.allow_always, true);
                    }
                    TIMER_COUNTDOWN => {
                        consent.seconds_left = consent.seconds_left.saturating_sub(1);
                        repaint(window);
                    }
                    _ => return Handled::Default,
                }
            }
            WM_PAINT => {
                if let Some(consent) = &self.consent {
                    self.paint_consent(consent);
                }
            }
            WM_ERASEBKGND => return Handled::Done(LRESULT(1)),
            WM_DRAWITEM => {
                self.draw_item(&*(lparam.0 as *const DRAWITEMSTRUCT));
                return Handled::Done(LRESULT(1));
            }
            WM_CLOSE => self.answer(ConsentAnswer::Decline),
            _ => return Handled::Default,
        }
        Handled::Done(LRESULT(0))
    }
}
