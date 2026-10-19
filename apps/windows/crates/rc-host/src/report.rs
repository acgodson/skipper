//! Where the host's words go.
//!
//! Two kinds of words: a **milestone** (`report!`) is something the owner may
//! want to know happened — registered, a connection request, link up, session
//! ended — and **console text** (`say!`) is the narrative a terminal user reads.
//! The diagnostic build prints them exactly as it always has, milestones to
//! stderr after `rc-host:` and console text to stdout, because the interop
//! tests and the latency harness read them there.
//!
//! The Windows host has no console. Both kinds go to a timestamped log under
//! the data directory, and milestones also reach the window, as do the typed
//! [`HostEvent`]s. Nothing here can block on the window: the sink is a send
//! that never waits.

use std::fs::File;
use std::io::Write;
use std::path::PathBuf;
use std::sync::OnceLock;

use crate::status::HostEvent;

#[macro_export]
macro_rules! report {
    ($($arg:tt)*) => {
        $crate::report::milestone(&format!($($arg)*))
    };
}

#[macro_export]
macro_rules! say {
    () => {
        $crate::report::console("")
    };
    ($($arg:tt)*) => {
        $crate::report::console(&format!($($arg)*))
    };
}

type Sink = Box<dyn Fn(HostEvent) + Send + Sync>;

static SINK: OnceLock<Sink> = OnceLock::new();

/// Installs the one receiver of [`HostEvent`]s. Set once, by the window.
pub fn set_sink(sink: Sink) {
    let _ = SINK.set(sink);
}

pub fn event(event: HostEvent) {
    if let Some(sink) = SINK.get() {
        sink(event);
    }
}

pub fn milestone(text: &str) {
    #[cfg(not(windows))]
    eprintln!("rc-host: {text}");
    #[cfg(windows)]
    {
        append_to_log(text);
        event(HostEvent::Line(text.to_string()));
    }
}

pub fn console(text: &str) {
    #[cfg(not(windows))]
    println!("{text}");
    #[cfg(windows)]
    if !text.trim().is_empty() {
        append_to_log(text.trim());
    }
}

#[cfg(windows)]
fn append_to_log(text: &str) {
    use std::sync::Mutex;

    static LOG: OnceLock<Mutex<Option<LogFile>>> = OnceLock::new();
    let log = LOG.get_or_init(|| Mutex::new(LogFile::open(crate::paths::log_file(), LOG_LIMIT).ok()));
    if let Ok(mut log) = log.lock() {
        if let Some(log) = log.as_mut() {
            log.append(&format!("{} {text}", local_timestamp()));
        }
    }
}

#[cfg(windows)]
fn local_timestamp() -> String {
    let t = unsafe { windows::Win32::System::SystemInformation::GetLocalTime() };
    format!("{:04}-{:02}-{:02} {}", t.wYear, t.wMonth, t.wDay, clock())
}

/// The local time of day, for the window's activity list.
#[cfg(windows)]
pub fn clock() -> String {
    let t = unsafe { windows::Win32::System::SystemInformation::GetLocalTime() };
    format!("{:02}:{:02}:{:02}", t.wHour, t.wMinute, t.wSecond)
}

/// About two megabytes of log, plus one rotated copy of the same size.
pub const LOG_LIMIT: u64 = 2 * 1024 * 1024;

/// An append-only log that rotates itself to `<name>.1` once, replacing any
/// older copy, when the next line would take it past its limit.
pub struct LogFile {
    path: PathBuf,
    file: Option<File>,
    size: u64,
    limit: u64,
}

impl LogFile {
    pub fn open(path: PathBuf, limit: u64) -> std::io::Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let file = Self::append_to(&path)?;
        let size = file.metadata().map(|m| m.len()).unwrap_or(0);
        Ok(Self { path, file: Some(file), size, limit })
    }

    pub fn rotated_path(&self) -> PathBuf {
        let mut name = self.path.clone().into_os_string();
        name.push(".1");
        PathBuf::from(name)
    }

    pub fn append(&mut self, line: &str) {
        let bytes = line.len() as u64 + 2;
        if self.size > 0 && self.size + bytes > self.limit {
            self.rotate();
        }
        if let Some(file) = self.file.as_mut() {
            if write!(file, "{line}\r\n").is_ok() {
                self.size += bytes;
            }
        }
    }

    /// The handle is closed first: a file still open here cannot be renamed
    /// on every Windows configuration.
    fn rotate(&mut self) {
        self.file = None;
        let rotated = self.rotated_path();
        let _ = std::fs::remove_file(&rotated);
        let _ = std::fs::rename(&self.path, &rotated);
        self.file = Self::append_to(&self.path).ok();
        self.size = self
            .file
            .as_ref()
            .and_then(|f| f.metadata().ok())
            .map_or(0, |m| m.len());
    }

    fn append_to(path: &std::path::Path) -> std::io::Result<File> {
        std::fs::OpenOptions::new().create(true).append(true).open(path)
    }
}

#[cfg(test)]
mod tests;
