//! The Windows host's face: a tray icon, the status window and the consent
//! window, all on one thread running a plain Win32 message loop, drawn with
//! GDI in DESIGN.md's tokens.
//!
//! The host never waits on this thread. Its events reach [`report::set_sink`],
//! which queues them on a channel and posts a message to wake the loop; the
//! window answers through the host's own channels with sends that cannot
//! block. A window being dragged, or a modal box left open, therefore cannot
//! stall a session — which is what a console in selection mode did.
//!
//! Window procedures borrow the thread's state only briefly. Anything that runs
//! a nested message loop (a menu, a message box, the shell) is returned as a
//! [`Deferred`] and performed after the borrow is released, so a message that
//! arrives during it finds the state free.

mod consent;
mod paint;
mod theme;
mod window;

use std::cell::{Cell, RefCell};
use std::collections::VecDeque;
use std::sync::atomic::{AtomicIsize, Ordering};
use std::sync::mpsc::{Receiver, Sender};
use std::sync::Arc;
use std::time::Duration;

use tokio::sync::{mpsc, watch};
use windows::core::{w, HSTRING, PCWSTR};
use windows::Win32::Foundation::{
    GetLastError, GlobalFree, COLORREF, ERROR_ALREADY_EXISTS, HANDLE, HINSTANCE, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM,
};
use windows::Win32::Graphics::Gdi::{CreateSolidBrush, DeleteObject, InvalidateRect, SetBkColor, SetTextColor, HBRUSH, HDC};
use windows::Win32::System::DataExchange::{CloseClipboard, EmptyClipboard, OpenClipboard, SetClipboardData};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};
use windows::Win32::System::Threading::CreateMutexW;
use windows::Win32::UI::Controls::{SetWindowTheme, DRAWITEMSTRUCT};
use windows::Win32::UI::HiDpi::{AdjustWindowRectExForDpi, GetDpiForSystem};
use windows::Win32::UI::Shell::{
    Shell_NotifyIconW, NIF_ICON, NIF_INFO, NIF_MESSAGE, NIF_TIP, NIIF_INFO, NIM_ADD, NIM_DELETE, NIM_MODIFY,
    NOTIFYICONDATAW, NOTIFY_ICON_MESSAGE,
};
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::consent::ConsentAnswer;
use crate::report;
use crate::secrets::SecretStore;
use crate::status::{headline, AccountRequest, AccountView, HostEvent, HostStatus};
use paint::ButtonKind;
use theme::{Fonts, Palette, Scale};

const MAIN_CLASS: PCWSTR = w!("SkipperDeskHostWindow");
const CONSENT_CLASS: PCWSTR = w!("SkipperDeskConsentWindow");
const TITLE: PCWSTR = w!("SkipperDesk");

const WM_APP_EVENTS: u32 = WM_APP + 1;
const WM_APP_TRAY: u32 = WM_APP + 2;
const WM_APP_SHOW: u32 = WM_APP + 3;
const WM_APP_SETTINGS: u32 = WM_APP + 4;
const WM_APP_CLOSE: u32 = WM_APP + 5;

const ID_COPY_ID: u16 = 101;
const ID_COPY_CODE: u16 = 102;
const ID_UNATTENDED: u16 = 103;
const ID_SIGN: u16 = 104;
const ID_OPEN_LOG: u16 = 105;
const ID_QUIT: u16 = 106;
const ID_SHOW: u16 = 107;
const ID_ALLOW: u16 = 201;
const ID_ALLOW_ALWAYS: u16 = 202;
const ID_DECLINE: u16 = 203;
const ID_CANCEL: u16 = 2;

const TIMER_COUNTDOWN: usize = 1;
const TIMER_GUARD: usize = 2;
const TIMER_COPIED: usize = 3;
const TIMER_QUIT: usize = 4;

const CF_UNICODETEXT: u32 = 13;
const COPIED_MS: u32 = 1500;
const LOG_LINES_KEPT: usize = 250;
const LOG_LINES_AFTER_TRIM: usize = 150;
const QUIT_DEADLINE_MS: u32 = 10_000;
const END_SESSION_WAIT: Duration = Duration::from_secs(5);

/// The ends of the host's channels this window holds.
pub struct UiChannels {
    pub shutdown: watch::Sender<bool>,
    pub answers: mpsc::Sender<ConsentAnswer>,
    pub settings_changed: mpsc::Sender<()>,
    pub account: mpsc::UnboundedSender<AccountRequest>,
    pub secrets: SecretStore,
}

/// The running window thread.
pub struct Ui {
    thread: std::thread::JoinHandle<()>,
    window: Arc<AtomicIsize>,
    stopped: Sender<()>,
}

impl Ui {
    /// Starts the window thread and installs it as the report sink. Returns
    /// once the window exists, or with the reason it could not be made.
    pub fn start(channels: UiChannels) -> Result<Self, String> {
        let (events_tx, events_rx) = std::sync::mpsc::channel::<HostEvent>();
        let (stopped_tx, stopped_rx) = std::sync::mpsc::channel::<()>();
        let (ready_tx, ready_rx) = std::sync::mpsc::channel::<Result<(), String>>();
        let window = Arc::new(AtomicIsize::new(0));

        let sink_window = window.clone();
        report::set_sink(Box::new(move |event| {
            if events_tx.send(event).is_ok() {
                post(sink_window.load(Ordering::Acquire), WM_APP_EVENTS);
            }
        }));

        let thread_window = window.clone();
        let thread = std::thread::Builder::new()
            .name("window".into())
            .spawn(move || {
                match unsafe { create_state(channels, events_rx, stopped_rx) } {
                    Ok(main) => {
                        thread_window.store(main.0 as isize, Ordering::Release);
                        let _ = ready_tx.send(Ok(()));
                        post(main.0 as isize, WM_APP_EVENTS);
                        unsafe { message_loop() };
                    }
                    Err(e) => {
                        let _ = ready_tx.send(Err(e));
                    }
                }
                STATE.with(|cell| cell.borrow_mut().take());
            })
            .map_err(|e| e.to_string())?;
        match ready_rx.recv() {
            Ok(Ok(())) => Ok(Self { thread, window, stopped: stopped_tx }),
            Ok(Err(e)) => Err(e),
            Err(_) => Err("the window thread ended before its window was made".into()),
        }
    }

    /// The host has stopped: close the window and the tray icon and wait for
    /// the thread, so the icon never outlives the process.
    pub fn finish(self) {
        let _ = self.stopped.send(());
        post(self.window.load(Ordering::Acquire), WM_APP_CLOSE);
        let _ = self.thread.join();
    }
}

fn post(window: isize, message: u32) {
    if window != 0 {
        unsafe {
            let _ = PostMessageW(HWND(window as _), message, WPARAM(0), LPARAM(0));
        }
    }
}

/// `true` when this is the only host running for this user. The mutex is held
/// for the life of the process.
pub fn claim_single_instance() -> bool {
    unsafe {
        let Ok(_held) = CreateMutexW(None, true, w!("Local\\SkipperDeskHost")) else {
            return true;
        };
        GetLastError() != ERROR_ALREADY_EXISTS
    }
}

/// Brings the already-running host's window forward. The running copy may
/// only take the foreground because this one, which the user just started,
/// lets it.
pub fn show_running_instance() {
    signal_running_instance(WM_APP_SHOW);
}

/// Tells the running host that `--unattended` changed the stored setting.
pub fn settings_changed_in_running_instance() {
    signal_running_instance(WM_APP_SETTINGS);
}

fn signal_running_instance(message: u32) {
    unsafe {
        let Ok(window) = FindWindowW(MAIN_CLASS, PCWSTR::null()) else { return };
        if window.0.is_null() {
            return;
        }
        let mut process = 0u32;
        GetWindowThreadProcessId(window, Some(&mut process));
        let _ = AllowSetForegroundWindow(process);
        let _ = PostMessageW(window, message, WPARAM(0), LPARAM(0));
    }
}

/// A message for a run with no window of its own: a command-line flag, a
/// failed start, the sign-in hand-off.
pub fn message_box(text: &str, error: bool) {
    let style = match error {
        true => MB_OK | MB_ICONERROR | MB_SETFOREGROUND,
        false => MB_OK | MB_ICONINFORMATION | MB_SETFOREGROUND,
    };
    unsafe {
        MessageBoxW(None, &HSTRING::from(text), TITLE, style);
    }
}

thread_local! {
    static STATE: RefCell<Option<State>> = const { RefCell::new(None) };
    static EDIT_COLOURS: Cell<Option<EditColours>> = const { Cell::new(None) };
}

/// The read-only edits' colours: the log on `surfaceMuted` in
/// `textSecondary`, the sign-in address on `surface` in `textTertiary`.
#[derive(Clone, Copy)]
struct EditColours {
    log: HWND,
    log_text: COLORREF,
    log_back: COLORREF,
    log_brush: HBRUSH,
    url_text: COLORREF,
    url_back: COLORREF,
    url_brush: HBRUSH,
}

impl EditColours {
    unsafe fn apply(&self, dc: HDC, control: HWND) -> LRESULT {
        let (text, back, brush) = match control == self.log {
            true => (self.log_text, self.log_back, self.log_brush),
            false => (self.url_text, self.url_back, self.url_brush),
        };
        SetTextColor(dc, text);
        SetBkColor(dc, back);
        LRESULT(brush.0 as isize)
    }
}

/// The two brushes child edit controls are painted with, kept for as long as
/// the theme they were made for.
struct Brushes {
    surface: HBRUSH,
    muted: HBRUSH,
}

impl Brushes {
    fn new(palette: &Palette) -> Self {
        unsafe {
            Self {
                surface: CreateSolidBrush(palette.surface),
                muted: CreateSolidBrush(palette.surface_muted),
            }
        }
    }
}

impl Drop for Brushes {
    fn drop(&mut self) {
        unsafe {
            let _ = DeleteObject(self.surface);
            let _ = DeleteObject(self.muted);
        }
    }
}

struct State {
    channels: UiChannels,
    events: Receiver<HostEvent>,
    stopped: Option<Receiver<()>>,
    instance: HINSTANCE,
    scale: Scale,
    fonts: Fonts,
    palette: Palette,
    brushes: Brushes,
    small_icon: HICON,
    main: HWND,
    controls: window::Controls,
    layout: window::Layout,
    consent: Option<consent::ConsentWindow>,
    status: HostStatus,
    account: AccountView,
    device_id: String,
    access_code: String,
    unattended: bool,
    log: VecDeque<String>,
    copied: Option<u16>,
    told_about_tray: bool,
    quitting: bool,
    taskbar_created: u32,
}

/// Work that runs a nested message loop, done once the state is released.
enum Deferred {
    Menu(HMENU),
    ConfirmSignOut,
    Error(String),
    Open(String),
    AwaitStop(Receiver<()>),
    Destroy(HWND),
}

enum Handled {
    Default,
    Done(LRESULT),
    Then(Deferred),
}

unsafe fn create_state(channels: UiChannels, events: Receiver<HostEvent>, stopped: Receiver<()>) -> Result<HWND, String> {
    let instance: HINSTANCE = GetModuleHandleW(None).map_err(|e| e.to_string())?.into();
    let scale = Scale(GetDpiForSystem().max(96));
    let palette = Palette::system();
    let large_icon = app_icon(instance, GetSystemMetrics(SM_CXICON));
    let small_icon = app_icon(instance, GetSystemMetrics(SM_CXSMICON));
    register_class(instance, MAIN_CLASS, Some(main_procedure), large_icon, small_icon)?;
    register_class(instance, CONSENT_CLASS, Some(consent_procedure), large_icon, small_icon)?;

    let (width, height) = outer_size(scale, scale.px(window::WIDTH), scale.px(window::HEIGHT), window::STYLE, WINDOW_EX_STYLE(0));
    let main = CreateWindowExW(
        WINDOW_EX_STYLE(0),
        MAIN_CLASS,
        TITLE,
        window::STYLE,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        width,
        height,
        None,
        None,
        instance,
        None,
    )
    .map_err(|e| format!("the window could not be made ({e})"))?;
    palette.apply_title_bar(main);

    let fonts = Fonts::new(scale);
    let controls = window::Controls::create(main, instance);
    let mut state = State {
        channels,
        events,
        stopped: Some(stopped),
        instance,
        scale,
        fonts,
        palette,
        brushes: Brushes::new(&palette),
        small_icon,
        main,
        controls,
        layout: window::Layout::default(),
        consent: None,
        status: HostStatus::Starting,
        account: AccountView::Unknown,
        device_id: String::new(),
        access_code: String::new(),
        unattended: false,
        log: VecDeque::new(),
        copied: None,
        told_about_tray: false,
        quitting: false,
        taskbar_created: RegisterWindowMessageW(w!("TaskbarCreated")),
    };
    state.publish_edit_colours();
    state.apply_theme_to_children();
    state.tray(NIM_ADD);
    state.refresh();
    STATE.with(|cell| *cell.borrow_mut() = Some(state));
    let _ = ShowWindow(main, SW_SHOW);
    let _ = SetForegroundWindow(main);
    Ok(main)
}

unsafe fn register_class(instance: HINSTANCE, class: PCWSTR, procedure: WNDPROC, icon: HICON, small: HICON) -> Result<(), String> {
    let registration = WNDCLASSEXW {
        cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
        lpfnWndProc: procedure,
        hInstance: instance,
        hIcon: icon,
        hIconSm: small,
        hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
        lpszClassName: class,
        ..Default::default()
    };
    match RegisterClassExW(&registration) {
        0 => Err("the window class could not be registered".into()),
        _ => Ok(()),
    }
}

unsafe fn message_loop() {
    let mut message = MSG::default();
    while GetMessageW(&mut message, None, 0, 0).0 > 0 {
        if is_dialog_message(&message) {
            continue;
        }
        let _ = TranslateMessage(&message);
        DispatchMessageW(&message);
    }
}

/// Tab, Space and Esc in either window, the way a dialog handles them.
unsafe fn is_dialog_message(message: &MSG) -> bool {
    let windows = STATE.with(|cell| {
        cell.try_borrow()
            .ok()
            .and_then(|state| state.as_ref().map(|s| (s.main, s.consent.as_ref().map(|c| c.window))))
    });
    let Some((main, consent)) = windows else { return false };
    [Some(main), consent]
        .into_iter()
        .flatten()
        .any(|window| IsDialogMessageW(window, message).as_bool())
}

unsafe fn app_icon(instance: HINSTANCE, size: i32) -> HICON {
    match LoadImageW(instance, PCWSTR(1 as _), IMAGE_ICON, size, size, LR_DEFAULTCOLOR) {
        Ok(handle) => HICON(handle.0),
        Err(_) => LoadIconW(None, IDI_APPLICATION).unwrap_or_default(),
    }
}

unsafe fn outer_size(scale: Scale, width: i32, height: i32, style: WINDOW_STYLE, extended: WINDOW_EX_STYLE) -> (i32, i32) {
    let mut area = RECT { left: 0, top: 0, right: width, bottom: height };
    let _ = AdjustWindowRectExForDpi(&mut area, style, false, extended, scale.0);
    (area.right - area.left, area.bottom - area.top)
}

/// A child control. Buttons are owner-drawn so they take the theme; the two
/// edit controls are read-only and coloured through `WM_CTLCOLORSTATIC`.
unsafe fn child(parent: HWND, instance: HINSTANCE, class: PCWSTR, text: &str, style: u32, id: u16) -> HWND {
    CreateWindowExW(
        WINDOW_EX_STYLE(0),
        class,
        &HSTRING::from(text),
        WS_CHILD | WS_VISIBLE | WINDOW_STYLE(style),
        0,
        0,
        0,
        0,
        parent,
        HMENU(id as usize as _),
        instance,
        None,
    )
    .unwrap_or_default()
}

unsafe fn owner_drawn_button(parent: HWND, instance: HINSTANCE, text: &str, id: u16) -> HWND {
    child(parent, instance, w!("BUTTON"), text, WS_TABSTOP.0 | BS_OWNERDRAW as u32, id)
}

unsafe fn set_text(window: HWND, text: &str) {
    let _ = SetWindowTextW(window, &HSTRING::from(text));
}

unsafe fn set_font(window: HWND, font: windows::Win32::Graphics::Gdi::HFONT) {
    SendMessageW(window, WM_SETFONT, WPARAM(font.0 as usize), LPARAM(1));
}

unsafe fn place(window: HWND, area: RECT) {
    let _ = MoveWindow(window, area.left, area.top, area.right - area.left, area.bottom - area.top, false);
}

unsafe fn repaint(window: HWND) {
    let _ = InvalidateRect(window, None, false);
}

fn wide_into(target: &mut [u16], text: &str) {
    let room = target.len().saturating_sub(1);
    let mut written = 0;
    for (slot, unit) in target.iter_mut().zip(text.encode_utf16().take(room)) {
        *slot = unit;
        written += 1;
    }
    target[written] = 0;
}

fn low_word(value: usize) -> u16 {
    (value & 0xFFFF) as u16
}

impl State {
    fn headline(&self) -> String {
        match self.quitting {
            true => HostStatus::Stopping.line(),
            false => headline(&self.status, &self.account),
        }
    }

    unsafe fn tray(&self, action: NOTIFY_ICON_MESSAGE) {
        let mut data = self.tray_data();
        data.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
        let _ = Shell_NotifyIconW(action, &data);
    }

    fn tray_data(&self) -> NOTIFYICONDATAW {
        let mut data = NOTIFYICONDATAW {
            cbSize: std::mem::size_of::<NOTIFYICONDATAW>() as u32,
            hWnd: self.main,
            uID: 1,
            uCallbackMessage: WM_APP_TRAY,
            hIcon: self.small_icon,
            ..Default::default()
        };
        wide_into(&mut data.szTip, &format!("SkipperDesk — {}", self.headline()));
        data
    }

    unsafe fn balloon(&self, title: &str, text: &str) {
        let mut data = self.tray_data();
        data.uFlags = NIF_INFO;
        data.dwInfoFlags = NIIF_INFO;
        wide_into(&mut data.szInfoTitle, title);
        wide_into(&mut data.szInfo, text);
        let _ = Shell_NotifyIconW(NIM_MODIFY, &data);
    }

    /// Everything shown is a function of the state, so every change ends here.
    unsafe fn refresh(&mut self) {
        self.relayout();
        self.tray(NIM_MODIFY);
    }

    /// Re-reads the system theme; on a change, everything is repainted in it.
    unsafe fn follow_theme(&mut self) {
        let palette = Palette::system();
        if palette == self.palette {
            return;
        }
        self.palette = palette;
        self.brushes = Brushes::new(&palette);
        self.publish_edit_colours();
        palette.apply_title_bar(self.main);
        self.apply_theme_to_children();
        if let Some(consent) = &self.consent {
            palette.apply_title_bar(consent.window);
            repaint(consent.window);
        }
        self.refresh();
    }

    /// The log's scroll bar is the one piece of system chrome inside the
    /// window; it follows the theme through the shell's dark Explorer style.
    unsafe fn apply_theme_to_children(&self) {
        let theme = match self.palette.dark {
            true => w!("DarkMode_Explorer"),
            false => w!("Explorer"),
        };
        let _ = SetWindowTheme(self.controls.log, theme, PCWSTR::null());
    }

    unsafe fn rescale(&mut self, dpi: u32, suggested: Option<&RECT>) {
        self.scale = Scale(dpi.max(96));
        self.fonts = Fonts::new(self.scale);
        if let Some(area) = suggested {
            let _ = SetWindowPos(
                self.main,
                None,
                area.left,
                area.top,
                area.right - area.left,
                area.bottom - area.top,
                SWP_NOZORDER | SWP_NOACTIVATE,
            );
        }
        self.refresh();
    }

    unsafe fn apply(&mut self, event: HostEvent) {
        match event {
            HostEvent::Line(text) => self.append_log(&text),
            HostEvent::Identity { device_id, access_code } => {
                self.device_id = device_id;
                self.access_code = access_code;
            }
            HostEvent::Status(status) => self.status = status,
            HostEvent::Account(account) => self.account = account,
            HostEvent::Unattended(on) => self.unattended = on,
            HostEvent::ConsentOpened(request) => self.open_consent(request),
            HostEvent::ConsentClosed => self.close_consent(),
        }
    }

    unsafe fn drain_events(&mut self) {
        while let Ok(event) = self.events.try_recv() {
            self.apply(event);
        }
        self.refresh();
    }

    unsafe fn append_log(&mut self, text: &str) {
        let line = format!("{}  {text}", report::clock());
        self.log.push_back(line.clone());
        let edit = self.controls.log;
        if self.log.len() > LOG_LINES_KEPT {
            let excess = self.log.len() - LOG_LINES_AFTER_TRIM;
            self.log.drain(..excess);
            let all: Vec<&str> = self.log.iter().map(String::as_str).collect();
            set_text(edit, &all.join("\r\n"));
        } else {
            let length = GetWindowTextLengthW(edit).max(0) as usize;
            let separated = match length {
                0 => line,
                _ => format!("\r\n{line}"),
            };
            let wide = HSTRING::from(separated);
            SendMessageW(edit, windows::Win32::UI::Controls::EM_SETSEL, WPARAM(length), LPARAM(length as isize));
            SendMessageW(edit, windows::Win32::UI::Controls::EM_REPLACESEL, WPARAM(0), LPARAM(wide.as_ptr() as isize));
        }
        let end = GetWindowTextLengthW(edit).max(0) as usize;
        SendMessageW(edit, windows::Win32::UI::Controls::EM_SETSEL, WPARAM(end), LPARAM(end as isize));
        SendMessageW(edit, windows::Win32::UI::Controls::EM_SCROLLCARET, WPARAM(0), LPARAM(0));
    }

    unsafe fn show(&self) {
        let command = match IsIconic(self.main).as_bool() {
            true => SW_RESTORE,
            false => SW_SHOW,
        };
        let _ = ShowWindow(self.main, command);
        let _ = SetForegroundWindow(self.main);
    }

    unsafe fn hide(&mut self) {
        let _ = ShowWindow(self.main, SW_HIDE);
        if !self.told_about_tray {
            self.told_about_tray = true;
            self.balloon(
                "SkipperDesk is still running",
                "This PC stays reachable. Open it again from this icon, or choose Quit there to stop.",
            );
        }
    }

    /// Asks the host to stop. The window stays until the host says it has, so
    /// the keys a controller held are released first; if it has not within the
    /// deadline, the process ends anyway rather than ignore the user.
    unsafe fn quit(&mut self) {
        if self.quitting {
            return;
        }
        self.quitting = true;
        self.channels.shutdown.send_replace(true);
        self.close_consent();
        SetTimer(self.main, TIMER_QUIT, QUIT_DEADLINE_MS, None);
        self.refresh();
    }

    unsafe fn copy(&mut self, id: u16) {
        if id == ID_COPY_CODE && self.status.in_session() {
            return;
        }
        let text = match id {
            ID_COPY_ID => self.device_id.clone(),
            _ => self.access_code.clone(),
        };
        if copy_to_clipboard(self.main, &text).is_ok() {
            self.copied = Some(id);
            SetTimer(self.main, TIMER_COPIED, COPIED_MS, None);
            self.refresh();
        }
    }

    unsafe fn toggle_unattended(&mut self) -> Option<Deferred> {
        let wanted = !self.unattended;
        if let Err(e) = crate::settings::save_unattended(&self.channels.secrets, wanted) {
            return Some(Deferred::Error(format!("Unattended access could not be changed: {e}")));
        }
        self.unattended = wanted;
        let _ = self.channels.settings_changed.try_send(());
        self.refresh();
        None
    }

    fn sign(&mut self) -> Option<Deferred> {
        match &self.account {
            AccountView::SignedIn { .. } => Some(Deferred::ConfirmSignOut),
            AccountView::SigningIn { url } => Some(Deferred::Open(url.clone())),
            _ => {
                let _ = self.channels.account.send(AccountRequest::SignIn);
                None
            }
        }
    }

    fn sign_label(&self) -> &'static str {
        match self.account {
            AccountView::SignedIn { .. } => "Sign Out…",
            AccountView::SigningIn { .. } => "Open Browser Again",
            _ => "Sign in to SkipperDesk",
        }
    }

    unsafe fn tray_menu(&self) -> Option<HMENU> {
        let menu = CreatePopupMenu().ok()?;
        let item = |flags: MENU_ITEM_FLAGS, id: u16, text: &str| {
            let _ = AppendMenuW(menu, MF_STRING | flags, id as usize, &HSTRING::from(text));
        };
        let enabled = MENU_ITEM_FLAGS(0);
        item(MF_GRAYED, 0, &self.headline());
        let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null());
        item(enabled, ID_SHOW, "Show window");
        let signing = match self.quitting {
            true => MF_GRAYED,
            false => enabled,
        };
        let sign = match self.account {
            AccountView::SignedIn { .. } => "Sign out",
            AccountView::SigningIn { .. } => "Open browser again",
            _ => "Sign in",
        };
        item(signing, ID_SIGN, sign);
        let checked = match self.unattended {
            true => MF_CHECKED,
            false => enabled,
        };
        item(checked, ID_UNATTENDED, "Unattended access");
        item(enabled, ID_COPY_ID, "Copy device ID");
        let copy_code = match self.status.in_session() {
            true => MF_GRAYED,
            false => enabled,
        };
        item(copy_code, ID_COPY_CODE, "Copy access code");
        item(enabled, ID_OPEN_LOG, "Open log");
        let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null());
        item(enabled, ID_QUIT, "Quit");
        Some(menu)
    }

    unsafe fn command(&mut self, id: u16) -> Option<Deferred> {
        match id {
            ID_SHOW => self.show(),
            ID_COPY_ID | ID_COPY_CODE => self.copy(id),
            ID_UNATTENDED => return self.toggle_unattended(),
            ID_SIGN if !self.quitting => return self.sign(),
            ID_OPEN_LOG => return Some(Deferred::Open(crate::paths::log_file().display().to_string())),
            ID_QUIT => self.quit(),
            _ => {}
        }
        None
    }

    /// Which way an owner-drawn button of the main window is painted.
    fn button_kind(&self, id: u16) -> ButtonKind {
        match id {
            ID_COPY_ID | ID_COPY_CODE if self.copied == Some(id) => ButtonKind::Done,
            ID_SIGN => match self.account {
                AccountView::SignedIn { .. } | AccountView::SigningIn { .. } => ButtonKind::Secondary,
                _ => ButtonKind::Primary,
            },
            ID_OPEN_LOG => ButtonKind::Quiet,
            _ => ButtonKind::Secondary,
        }
    }

    unsafe fn draw_item(&self, item: &DRAWITEMSTRUCT) {
        let id = item.CtlID as u16;
        let behind = self.palette.surface;
        match id {
            ID_UNATTENDED => paint::draw_toggle(item, self.palette, self.scale, self.unattended, behind),
            ID_ALLOW => paint::draw_button(item, self.palette, self.scale, self.fonts.body_emphasis, ButtonKind::Primary, behind),
            ID_ALLOW_ALWAYS => {
                paint::draw_button(item, self.palette, self.scale, self.fonts.body_emphasis, ButtonKind::Secondary, behind)
            }
            ID_DECLINE => paint::draw_button(item, self.palette, self.scale, self.fonts.body_emphasis, ButtonKind::Plain, behind),
            _ => paint::draw_button(item, self.palette, self.scale, self.fonts.body_emphasis, self.button_kind(id), behind),
        }
    }

    /// Publishes the edits' colours where the window procedure can read them
    /// without the state: an edit paints new text the moment it is appended,
    /// which is while the state is borrowed.
    fn publish_edit_colours(&self) {
        let colours = EditColours {
            log: self.controls.log,
            log_text: self.palette.text_secondary,
            log_back: self.palette.surface_muted,
            log_brush: self.brushes.muted,
            url_text: self.palette.text_tertiary,
            url_back: self.palette.surface,
            url_brush: self.brushes.surface,
        };
        EDIT_COLOURS.with(|cell| cell.set(Some(colours)));
    }

    unsafe fn on_main(&mut self, message: u32, wparam: WPARAM, lparam: LPARAM) -> Handled {
        match message {
            WM_APP_EVENTS => self.drain_events(),
            WM_APP_SHOW => self.show(),
            WM_APP_SETTINGS => {
                let _ = self.channels.settings_changed.try_send(());
            }
            WM_APP_TRAY => match lparam.0 as u32 {
                WM_LBUTTONUP | WM_LBUTTONDBLCLK => self.show(),
                WM_RBUTTONUP | WM_CONTEXTMENU => {
                    if let Some(menu) = self.tray_menu() {
                        return Handled::Then(Deferred::Menu(menu));
                    }
                }
                _ => {}
            },
            WM_APP_CLOSE => {
                self.close_consent();
                let data = self.tray_data();
                let _ = Shell_NotifyIconW(NIM_DELETE, &data);
                return Handled::Then(Deferred::Destroy(self.main));
            }
            WM_PAINT => self.paint_main(),
            WM_ERASEBKGND => return Handled::Done(LRESULT(1)),
            WM_DRAWITEM => {
                self.draw_item(&*(lparam.0 as *const DRAWITEMSTRUCT));
                return Handled::Done(LRESULT(1));
            }
            WM_SETTINGCHANGE => self.follow_theme(),
            WM_DPICHANGED => {
                let suggested = (lparam.0 as *const RECT).as_ref();
                self.rescale(u32::from(low_word(wparam.0)), suggested);
            }
            WM_COMMAND => {
                if let Some(deferred) = self.command(low_word(wparam.0)) {
                    return Handled::Then(deferred);
                }
            }
            WM_TIMER => match wparam.0 {
                TIMER_COPIED => {
                    let _ = KillTimer(self.main, TIMER_COPIED);
                    self.copied = None;
                    self.refresh();
                }
                TIMER_QUIT => std::process::exit(0),
                _ => {}
            },
            WM_CLOSE => self.hide(),
            WM_QUERYENDSESSION => return Handled::Done(LRESULT(1)),
            WM_ENDSESSION if wparam.0 != 0 => {
                self.quit();
                if let Some(stopped) = self.stopped.take() {
                    return Handled::Then(Deferred::AwaitStop(stopped));
                }
            }
            message if message == self.taskbar_created && message != 0 => self.tray(NIM_ADD),
            _ => return Handled::Default,
        }
        Handled::Done(LRESULT(0))
    }

    fn answer(&self, answer: ConsentAnswer) {
        let _ = self.channels.answers.try_send(answer);
    }
}

/// Runs a procedure against the state when it is free. A message that arrives
/// while it is borrowed (one sent during a call that is already using it) gets
/// the default handling, except the event wake-up, which is posted again.
unsafe fn with_state(window: HWND, message: u32, handle: impl FnOnce(&mut State) -> Handled) -> Handled {
    let outcome = STATE.with(|cell| match cell.try_borrow_mut() {
        Ok(mut guard) => guard.as_mut().map(handle),
        Err(_) => None,
    });
    match outcome {
        Some(handled) => handled,
        None if message == WM_APP_EVENTS => {
            post(window.0 as isize, WM_APP_EVENTS);
            Handled::Done(LRESULT(0))
        }
        None => Handled::Default,
    }
}

unsafe fn finish_message(window: HWND, message: u32, wparam: WPARAM, lparam: LPARAM, handled: Handled) -> LRESULT {
    match handled {
        Handled::Default => DefWindowProcW(window, message, wparam, lparam),
        Handled::Done(result) => result,
        Handled::Then(deferred) => {
            perform(window, deferred);
            LRESULT(0)
        }
    }
}

unsafe fn perform(window: HWND, deferred: Deferred) {
    match deferred {
        Deferred::Menu(menu) => {
            let mut point = POINT::default();
            let _ = GetCursorPos(&mut point);
            let _ = SetForegroundWindow(window);
            let _ = TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN, point.x, point.y, 0, window, None);
            let _ = PostMessageW(window, WM_NULL, WPARAM(0), LPARAM(0));
            let _ = DestroyMenu(menu);
        }
        Deferred::ConfirmSignOut => {
            let answer = MessageBoxW(
                window,
                w!("Sign out of SkipperDesk?\n\nThis PC stops accepting remote sessions until you sign in again. Its Device ID and access code stay the same."),
                TITLE,
                MB_YESNO | MB_ICONQUESTION,
            );
            if answer == IDYES {
                STATE.with(|cell| {
                    if let Ok(state) = cell.try_borrow() {
                        if let Some(state) = state.as_ref() {
                            let _ = state.channels.account.send(AccountRequest::SignOut);
                        }
                    }
                });
            }
        }
        Deferred::Error(text) => {
            MessageBoxW(window, &HSTRING::from(text), TITLE, MB_OK | MB_ICONERROR);
        }
        Deferred::Open(target) => {
            if let Err(e) = crate::urlhandler::open_externally(&target) {
                MessageBoxW(window, &HSTRING::from(e), TITLE, MB_OK | MB_ICONERROR);
            }
        }
        Deferred::AwaitStop(stopped) => {
            let _ = stopped.recv_timeout(END_SESSION_WAIT);
        }
        Deferred::Destroy(main) => {
            let _ = DestroyWindow(main);
            PostQuitMessage(0);
        }
    }
}

unsafe extern "system" fn main_procedure(window: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if matches!(message, WM_CTLCOLORSTATIC | WM_CTLCOLOREDIT) {
        if let Some(colours) = EDIT_COLOURS.with(Cell::get) {
            return colours.apply(HDC(wparam.0 as _), HWND(lparam.0 as _));
        }
    }
    let handled = with_state(window, message, |state| state.on_main(message, wparam, lparam));
    finish_message(window, message, wparam, lparam, handled)
}

unsafe extern "system" fn consent_procedure(window: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    let handled = with_state(window, message, |state| state.on_consent(window, message, wparam, lparam));
    finish_message(window, message, wparam, lparam, handled)
}

unsafe fn copy_to_clipboard(owner: HWND, text: &str) -> Result<(), String> {
    let wide: Vec<u16> = text.encode_utf16().chain(std::iter::once(0)).collect();
    OpenClipboard(owner).map_err(|e| e.to_string())?;
    let placed = (|| -> windows::core::Result<()> {
        EmptyClipboard()?;
        let memory = GlobalAlloc(GMEM_MOVEABLE, wide.len() * 2)?;
        let target = GlobalLock(memory) as *mut u16;
        if target.is_null() {
            let _ = GlobalFree(memory);
            return Err(windows::core::Error::from_win32());
        }
        std::ptr::copy_nonoverlapping(wide.as_ptr(), target, wide.len());
        let _ = GlobalUnlock(memory);
        if let Err(e) = SetClipboardData(CF_UNICODETEXT, HANDLE(memory.0)) {
            let _ = GlobalFree(memory);
            return Err(e);
        }
        Ok(())
    })();
    let _ = CloseClipboard();
    placed.map_err(|e| e.to_string())
}
