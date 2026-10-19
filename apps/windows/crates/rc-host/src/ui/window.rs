//! The status window, laid out like the Mac's host screen: a hero card with
//! "This PC", the status pill and the two codes; an Access card with the
//! Unattended access toggle and the account row; and the activity log.
//!
//! The layout is recomputed from the state on every change, so text that
//! wraps differently, a row that appears, or a new DPI all land in one place.

use windows::core::w;
use windows::Win32::Foundation::{HINSTANCE, HWND, RECT};
use windows::Win32::Graphics::Gdi::{BeginPaint, EndPaint, GetDC, ReleaseDC, PAINTSTRUCT};
use windows::Win32::UI::Input::KeyboardAndMouse::EnableWindow;
use windows::Win32::UI::WindowsAndMessaging::{
    GetClientRect, ShowWindow, ES_AUTOHSCROLL, ES_AUTOVSCROLL, ES_MULTILINE, ES_READONLY, SW_HIDE, SW_SHOW,
    WINDOW_STYLE, WS_CAPTION, WS_CLIPCHILDREN, WS_MINIMIZEBOX, WS_OVERLAPPED, WS_SYSMENU, WS_TABSTOP, WS_VSCROLL,
};

use super::paint::{buffered, rect, Canvas, LINE, WRAP};
use super::theme::space::{L, M, RADIUS_LARGE, RADIUS_SMALL, S, XL, XS, XXS};
use super::{
    child, owner_drawn_button, place, repaint, set_font, set_text, State, ID_COPY_CODE, ID_COPY_ID, ID_OPEN_LOG, ID_SIGN,
    ID_UNATTENDED,
};
use crate::settings::{unattended_detail, UNATTENDED_OFF_NOTE};
use crate::status::AccountView;

pub const WIDTH: i32 = 560;
pub const HEIGHT: i32 = 680;
pub const STYLE: WINDOW_STYLE =
    WINDOW_STYLE(WS_OVERLAPPED.0 | WS_CAPTION.0 | WS_SYSMENU.0 | WS_MINIMIZEBOX.0 | WS_CLIPCHILDREN.0);

const TITLE: &str = "This PC";
const CAPTION: &str = "Give these two to the Mac that will control this one.";
const SIGNED_OUT_NOTE: &str = "Sign in to host this PC and manage your plan.";
const MIN_LOG_HEIGHT: i32 = 48;

pub struct Controls {
    pub copy_id: HWND,
    pub copy_code: HWND,
    pub toggle: HWND,
    pub sign: HWND,
    pub url: HWND,
    pub open_log: HWND,
    pub log: HWND,
}

impl Controls {
    pub unsafe fn create(main: HWND, instance: HINSTANCE) -> Self {
        Self {
            copy_id: owner_drawn_button(main, instance, "Copy", ID_COPY_ID),
            copy_code: owner_drawn_button(main, instance, "Copy", ID_COPY_CODE),
            toggle: owner_drawn_button(main, instance, "Unattended access", ID_UNATTENDED),
            sign: owner_drawn_button(main, instance, "Sign in to SkipperDesk", ID_SIGN),
            url: child(main, instance, w!("EDIT"), "", WS_TABSTOP.0 | (ES_READONLY | ES_AUTOHSCROLL) as u32, 0),
            open_log: owner_drawn_button(main, instance, "Open Log", ID_OPEN_LOG),
            log: child(
                main,
                instance,
                w!("EDIT"),
                "",
                WS_VSCROLL.0 | (ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL) as u32,
                0,
            ),
        }
    }

    fn all(&self) -> [HWND; 7] {
        [self.copy_id, self.copy_code, self.toggle, self.sign, self.url, self.open_log, self.log]
    }
}

/// Where everything the window paints itself goes, in physical pixels.
#[derive(Default)]
pub struct Layout {
    hero: RECT,
    title: RECT,
    caption: RECT,
    pill_left: i32,
    pill_top: i32,
    id_label: RECT,
    id_value: RECT,
    divider: RECT,
    code_label: RECT,
    code_value: RECT,
    note: RECT,
    off_note: Option<RECT>,
    access: RECT,
    access_label: RECT,
    toggle_title: RECT,
    toggle_detail: RECT,
    row_divider: RECT,
    avatar: Option<RECT>,
    account_title: RECT,
    account_detail: RECT,
    activity: RECT,
    activity_label: RECT,
    log_box: RECT,
}

/// Where each child control goes, computed alongside the layout.
struct Placements {
    copy_id: RECT,
    copy_code: RECT,
    toggle: RECT,
    sign: RECT,
    url: Option<RECT>,
    open_log: RECT,
    log: RECT,
}

impl State {
    fn account_texts(&self) -> (String, String) {
        match &self.account {
            AccountView::SignedIn { email } if email.is_empty() => ("Signed in".into(), "Signed in to SkipperDesk".into()),
            AccountView::SignedIn { email } => (email.clone(), "Signed in to SkipperDesk".into()),
            AccountView::SigningIn { .. } => ("Continue in your browser…".into(), String::new()),
            AccountView::SignedOut | AccountView::Unknown => (String::new(), SIGNED_OUT_NOTE.into()),
        }
    }

    fn compute(&self, canvas: &Canvas, client_height: i32) -> (Layout, Placements) {
        let px = |logical: i32| canvas.px(logical);
        let f = &self.fonts;
        let mut layout = Layout::default();

        let card_left = px(XL);
        let card_width = px(WIDTH) - px(XL) * 2;
        let inner_left = card_left + px(XL);
        let inner_width = card_width - px(XL) * 2;
        let button_height = px(30);
        let copy_width = px(84);

        let mut y = px(XL) + px(XL);
        let (pill_label, _) = self.status.pill();
        let pill_width = canvas.pill_width(pill_label, f.caption_semibold);
        layout.pill_left = inner_left + inner_width - pill_width;
        layout.pill_top = y;
        let (_, title_height) = canvas.measure(0, TITLE, f.title, LINE);
        layout.title = rect(inner_left, y, inner_width - pill_width - px(M), title_height);
        y += title_height + px(XXS);
        let (_, caption_height) = canvas.measure(inner_width - pill_width - px(M), CAPTION, f.caption, WRAP);
        layout.caption = rect(inner_left, y, inner_width - pill_width - px(M), caption_height);
        y += caption_height + px(L);

        let (_, label_height) = canvas.measure(0, "Device ID", f.caption, LINE);
        let (_, value_height) = canvas.measure(0, "0", f.code_hero, LINE);
        let value_width = inner_width - copy_width - px(M);
        layout.id_label = rect(inner_left, y, value_width, label_height);
        y += label_height + px(XS);
        layout.id_value = rect(inner_left, y, value_width, value_height);
        let copy_id = rect(inner_left + inner_width - copy_width, y + (value_height - button_height) / 2, copy_width, button_height);
        y += value_height + px(M);
        layout.divider = rect(inner_left, y, inner_width, px(1).max(1));
        y += px(1) + px(M);
        layout.code_label = rect(inner_left, y, value_width, label_height);
        y += label_height + px(XS);
        layout.code_value = rect(inner_left, y, value_width, value_height);
        let copy_code = rect(inner_left + inner_width - copy_width, y + (value_height - button_height) / 2, copy_width, button_height);
        y += value_height + px(M);

        let (_, note_height) = canvas.measure(inner_width, &self.hero_note(), f.caption, WRAP);
        layout.note = rect(inner_left, y, inner_width, note_height);
        y += note_height;
        if !self.unattended {
            y += px(S);
            let (_, height) = canvas.measure(inner_width, UNATTENDED_OFF_NOTE, f.caption, WRAP);
            layout.off_note = Some(rect(inner_left, y, inner_width, height));
            y += height;
        }
        y += px(XL);
        layout.hero = RECT { left: card_left, top: px(XL), right: card_left + card_width, bottom: y };

        let row_left = card_left + px(L);
        let row_width = card_width - px(L) * 2;
        let access_top = y + px(L);
        y = access_top + px(L);
        let (_, section_height) = canvas.measure(0, "ACCESS", f.section, LINE);
        layout.access_label = rect(row_left, y, row_width, section_height);
        y += section_height + px(S);
        let toggle_width = px(52);
        let text_width = row_width - toggle_width - px(M);
        let (_, toggle_title_height) = canvas.measure(0, "Unattended access", f.body_emphasis, LINE);
        let detail = unattended_detail(self.unattended);
        let (_, detail_height) = canvas.measure(text_width, detail, f.caption, WRAP);
        layout.toggle_title = rect(row_left, y, text_width, toggle_title_height);
        layout.toggle_detail = rect(row_left, y + toggle_title_height + px(XXS), text_width, detail_height);
        let row_height = toggle_title_height + px(XXS) + detail_height;
        let toggle = rect(row_left + row_width - toggle_width, y + (row_height - px(30)) / 2, toggle_width, px(30));
        y += row_height + px(M);
        layout.row_divider = rect(row_left, y, row_width, px(1).max(1));
        y += px(1) + px(M);

        let (account_title, account_detail) = self.account_texts();
        let (sign_width, _) = canvas.measure(0, self.sign_label(), f.body_emphasis, LINE);
        let sign_width = sign_width + px(M) * 2;
        let mut url = None;
        let sign;
        match &self.account {
            AccountView::SignedOut | AccountView::Unknown => {
                sign = rect(row_left, y, sign_width, button_height);
                let detail_left = row_left + sign_width + px(M);
                let detail_width = row_width - sign_width - px(M);
                let (_, height) = canvas.measure(detail_width, &account_detail, f.caption, WRAP);
                layout.account_detail = rect(detail_left, y + (button_height - height).max(0) / 2, detail_width, height);
                layout.avatar = None;
                y += button_height.max(height);
            }
            AccountView::SigningIn { .. } => {
                let text_width = row_width - sign_width - px(M);
                let (_, title_height) = canvas.measure(0, &account_title, f.body_emphasis, LINE);
                let (_, url_height) = canvas.measure(0, "x", f.code_caption, LINE);
                layout.account_title = rect(row_left, y, text_width, title_height);
                url = Some(rect(row_left, y + title_height + px(XXS), text_width, url_height));
                let height = (title_height + px(XXS) + url_height).max(button_height);
                sign = rect(row_left + row_width - sign_width, y + (height - button_height) / 2, sign_width, button_height);
                layout.avatar = None;
                y += height;
            }
            AccountView::SignedIn { .. } => {
                let avatar = px(36);
                let text_left = row_left + avatar + px(M);
                let text_width = row_width - avatar - px(M) - sign_width - px(M);
                let (_, title_height) = canvas.measure(0, &account_title, f.body_emphasis, LINE);
                let (_, detail_height) = canvas.measure(0, &account_detail, f.caption, LINE);
                let height = (title_height + px(XXS) + detail_height).max(avatar);
                let text_top = y + (height - title_height - px(XXS) - detail_height) / 2;
                layout.avatar = Some(rect(row_left, y + (height - avatar) / 2, avatar, avatar));
                layout.account_title = rect(text_left, text_top, text_width, title_height);
                layout.account_detail = rect(text_left, text_top + title_height + px(XXS), text_width, detail_height);
                sign = rect(row_left + row_width - sign_width, y + (height - button_height) / 2, sign_width, button_height);
                y += height;
            }
        }
        y += px(L);
        layout.access = RECT { left: card_left, top: access_top, right: card_left + card_width, bottom: y };

        let activity_top = y + px(L);
        y = activity_top + px(L);
        layout.activity_label = rect(row_left, y, row_width, section_height);
        let (log_width, _) = canvas.measure(0, "Open Log", f.body_emphasis, LINE);
        let open_log_width = log_width + px(M) * 2;
        let open_log = rect(row_left + row_width - open_log_width, y + (section_height - px(26)) / 2, open_log_width, px(26));
        y += section_height + px(S);
        let bottom = (client_height - px(XL)).max(y + px(MIN_LOG_HEIGHT) + px(L));
        layout.log_box = rect(row_left, y, row_width, bottom - px(L) - y);
        layout.activity = RECT { left: card_left, top: activity_top, right: card_left + card_width, bottom };
        let inset = px(S);
        let log = RECT {
            left: layout.log_box.left + inset,
            top: layout.log_box.top + inset,
            right: layout.log_box.right - inset / 2,
            bottom: layout.log_box.bottom - inset,
        };

        (layout, Placements { copy_id, copy_code, toggle, sign, url, open_log, log })
    }

    fn hero_note(&self) -> String {
        match self.quitting {
            true => "Stopping…".into(),
            false => self.status.note(),
        }
    }

    /// Lays the window out again for the current state and DPI, moves the
    /// controls, and repaints.
    pub(super) unsafe fn relayout(&mut self) {
        let mut client = RECT::default();
        let _ = GetClientRect(self.main, &mut client);
        let dc = GetDC(self.main);
        let canvas = Canvas { dc, palette: self.palette, scale: self.scale };
        let (layout, placements) = self.compute(&canvas, client.bottom - client.top);
        ReleaseDC(self.main, dc);
        self.layout = layout;

        let c = &self.controls;
        place(c.copy_id, placements.copy_id);
        place(c.copy_code, placements.copy_code);
        place(c.toggle, placements.toggle);
        place(c.sign, placements.sign);
        place(c.open_log, placements.open_log);
        place(c.log, placements.log);
        match (&self.account, placements.url) {
            (AccountView::SigningIn { url }, Some(area)) => {
                set_text(c.url, url);
                place(c.url, area);
                let _ = ShowWindow(c.url, SW_SHOW);
            }
            _ => {
                let _ = ShowWindow(c.url, SW_HIDE);
            }
        }
        set_font(c.url, self.fonts.code_caption);
        set_font(c.log, self.fonts.code_caption);
        let copy_label = |id| match self.copied == Some(id) {
            true => "Copied",
            false => "Copy",
        };
        set_text(c.copy_id, copy_label(ID_COPY_ID));
        set_text(c.copy_code, copy_label(ID_COPY_CODE));
        set_text(c.sign, self.sign_label());
        let _ = EnableWindow(c.sign, !self.quitting);
        let _ = EnableWindow(c.copy_code, !self.status.in_session());
        repaint(self.main);
        for control in c.all() {
            repaint(control);
        }
    }

    pub(super) unsafe fn paint_main(&self) {
        let mut paint = PAINTSTRUCT::default();
        let dc = BeginPaint(self.main, &mut paint);
        let mut client = RECT::default();
        let _ = GetClientRect(self.main, &mut client);
        buffered(dc, client, self.palette, self.scale, |canvas| self.draw_main(canvas, client));
        let _ = EndPaint(self.main, &paint);
    }

    fn draw_main(&self, canvas: &Canvas, client: RECT) {
        let p = &self.palette;
        let f = &self.fonts;
        let l = &self.layout;
        canvas.fill(client, p.canvas);

        canvas.round(l.hero, RADIUS_LARGE, p.surface, Some(p.hero_stroke()));
        canvas.text(l.title, TITLE, f.title, p.text_primary, LINE);
        canvas.text(l.caption, CAPTION, f.caption, p.text_secondary, WRAP);
        let (label, tone) = self.status.pill();
        canvas.pill(l.pill_left, l.pill_top, label, tone, f.caption_semibold);
        canvas.text(l.id_label, "Device ID", f.caption, p.text_secondary, LINE);
        canvas.text(l.id_value, &self.device_id, f.code_hero, p.text_primary, LINE);
        canvas.fill(l.divider, p.border);
        canvas.text(l.code_label, "Access Code", f.caption, p.text_secondary, LINE);
        canvas.text(l.code_value, &self.access_code, f.code_hero, p.text_primary, LINE);
        canvas.text(l.note, &self.hero_note(), f.caption, p.text_secondary, WRAP);
        if let Some(area) = l.off_note {
            canvas.text(area, UNATTENDED_OFF_NOTE, f.caption, p.text_secondary, WRAP);
        }

        canvas.round(l.access, RADIUS_LARGE, p.surface, Some(p.border));
        canvas.section_label(l.access_label, "Access", f.section);
        canvas.text(l.toggle_title, "Unattended access", f.body_emphasis, p.text_primary, LINE);
        canvas.text(l.toggle_detail, unattended_detail(self.unattended), f.caption, p.text_secondary, WRAP);
        canvas.fill(l.row_divider, p.border);
        let (title, detail) = self.account_texts();
        if let Some(avatar) = l.avatar {
            canvas.ellipse(avatar, p.accent);
            let initial = title
                .chars()
                .find(|c| c.is_alphanumeric())
                .map(|c| c.to_uppercase().to_string())
                .unwrap_or_else(|| "?".into());
            canvas.text(avatar, &initial, f.body_emphasis, p.on_accent, super::paint::CENTERED);
        }
        canvas.text(l.account_title, &title, f.body_emphasis, p.text_primary, LINE);
        canvas.text(l.account_detail, &detail, f.caption, p.text_secondary, WRAP);

        canvas.round(l.activity, RADIUS_LARGE, p.surface, Some(p.border));
        canvas.section_label(l.activity_label, "Activity", f.section);
        canvas.round(l.log_box, RADIUS_SMALL, p.surface_muted, None);
    }
}
