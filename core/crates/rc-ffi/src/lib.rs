//! The C ABI over [`rc_session`] and [`rc_identity`], described by
//! `include/skipper_core.h`. The header is the contract; this file implements
//! it and nothing else.

#![allow(clippy::missing_safety_doc)]

use std::ffi::{c_char, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};

use rc_session::{
    IceLinkState, ResumeOk, Role, SessionAction, SessionGrant, SessionPhase, SessionStateMachine,
};
use serde_json::{json, Value};

mod consent;
mod pake;
mod sdp;
mod signing;
mod text;

pub use pake::SkipperPake;
pub(crate) use text::{optional_text, payload_bytes, required_text};

pub struct SkipperSession {
    machine: SessionStateMachine,
}

pub(crate) const ROLE_HOST: i32 = 0;

type CallResult = Result<Vec<SessionAction>, String>;

fn action_json(action: &SessionAction) -> Value {
    match action {
        SessionAction::SendConnectReq {
            device_id,
            access_code,
        } => {
            json!({ "action": "sendConnectReq", "deviceId": device_id, "accessCode": access_code })
        }
        SessionAction::SendResume {
            session_id,
            session_token,
        } => {
            json!({ "action": "sendResume", "sessionId": session_id, "sessionToken": session_token })
        }
        SessionAction::ScheduleResume { after_sec } => {
            json!({ "action": "scheduleResume", "afterSec": after_sec })
        }
        SessionAction::SendRenew {
            session_id,
            session_token,
        } => {
            json!({ "action": "sendRenew", "sessionId": session_id, "sessionToken": session_token })
        }
        SessionAction::SendInputReset => json!({ "action": "sendInputReset" }),
        SessionAction::StartPeerConnection { offerer } => {
            json!({ "action": "startPeerConnection", "offerer": offerer })
        }
        SessionAction::RestartIce { relay_only } => {
            json!({ "action": "restartICE", "relayOnly": relay_only })
        }
        SessionAction::ReissueWatches => json!({ "action": "reissueWatches" }),
        SessionAction::TeardownPeerConnection => json!({ "action": "teardownPeerConnection" }),
        SessionAction::ClearStoredSession => json!({ "action": "clearStoredSession" }),
        SessionAction::PromptForAccessCode { reason } => {
            json!({ "action": "promptForAccessCode", "reason": reason })
        }
        SessionAction::SendBye { session_id, reason } => {
            json!({ "action": "sendBye", "sessionId": session_id, "reason": reason })
        }
        SessionAction::PromptForConsent { expires_at_ms } => {
            json!({ "action": "promptForConsent", "expiresAtMs": expires_at_ms })
        }
        SessionAction::DismissConsentPrompt { outcome } => {
            json!({ "action": "dismissConsentPrompt", "outcome": outcome.name() })
        }
    }
}

fn ice_state_name(state: IceLinkState) -> &'static str {
    match state {
        IceLinkState::New => "new",
        IceLinkState::Checking => "checking",
        IceLinkState::Connected => "connected",
        IceLinkState::Completed => "completed",
        IceLinkState::Disconnected => "disconnected",
        IceLinkState::Failed => "failed",
        IceLinkState::Closed => "closed",
    }
}

fn ice_state_from_name(name: &str) -> Result<IceLinkState, String> {
    match name {
        "new" => Ok(IceLinkState::New),
        "checking" => Ok(IceLinkState::Checking),
        "connected" => Ok(IceLinkState::Connected),
        "completed" => Ok(IceLinkState::Completed),
        "disconnected" => Ok(IceLinkState::Disconnected),
        "failed" => Ok(IceLinkState::Failed),
        "closed" => Ok(IceLinkState::Closed),
        other => Err(format!("unknown ice state {other:?}")),
    }
}

fn state_json(machine: &SessionStateMachine) -> Value {
    let (phase, closed_reason) = match machine.phase() {
        SessionPhase::Idle => ("idle", None),
        SessionPhase::Connecting => ("connecting", None),
        SessionPhase::AwaitingConsent => ("awaitingConsent", None),
        SessionPhase::Live => ("live", None),
        SessionPhase::Reconnecting => ("reconnecting", None),
        SessionPhase::Closed { reason } => ("closed", Some(reason.clone())),
    };
    json!({
        "role": match machine.role() { Role::Host => "host", Role::Controller => "controller" },
        "phase": phase,
        "closedReason": closed_reason,
        "hasSession": machine.has_session(),
        "signalingUp": machine.signaling_up(),
        "resumeInFlight": machine.resume_in_flight(),
        "relayOnly": machine.relay_only(),
        "isOfferer": machine.is_offerer(),
        "iceState": ice_state_name(machine.ice_state()),
        "sessionId": machine.session_id(),
        "sessionToken": machine.session_token(),
        "peerDeviceId": machine.peer_device_id(),
        "rememberedAccessCode": machine.remembered_access_code,
        "serverAdvertisedSessionId": machine.server_advertised_session_id,
        "consentRequired": machine.consent_required,
        "consentExpiresAtMs": machine.consent_expires_at_ms(),
    })
}

pub(crate) struct FfiError {
    message: String,
    kind: Option<&'static str>,
}

impl FfiError {
    pub(crate) fn with_kind(message: impl Into<String>, kind: &'static str) -> Self {
        Self {
            message: message.into(),
            kind: Some(kind),
        }
    }
}

impl From<String> for FfiError {
    fn from(message: String) -> Self {
        Self {
            message,
            kind: None,
        }
    }
}

impl From<&str> for FfiError {
    fn from(message: &str) -> Self {
        message.to_string().into()
    }
}

pub(crate) fn respond<F>(panic_message: &str, body: F) -> *mut c_char
where
    F: FnOnce() -> Result<Value, FfiError>,
{
    let outcome = catch_unwind(AssertUnwindSafe(|| match body() {
        Ok(mut value) => {
            if let Some(object) = value.as_object_mut() {
                object.insert("ok".to_string(), json!(true));
            }
            value.to_string()
        }
        Err(error) => error_string(&error),
    }));
    into_c_string(outcome.unwrap_or_else(|_| error_string(&panic_message.into())))
}

pub(crate) fn into_c_string(value: String) -> *mut c_char {
    match CString::new(value) {
        Ok(owned) => owned.into_raw(),
        Err(_) => match CString::new(r#"{"ok":false,"error":"result contained a NUL byte"}"#) {
            Ok(fallback) => fallback.into_raw(),
            Err(_) => std::ptr::null_mut(),
        },
    }
}

pub(crate) fn error_string(error: &FfiError) -> String {
    match error.kind {
        Some(kind) => json!({ "ok": false, "error": error.message, "kind": kind }),
        None => json!({ "ok": false, "error": error.message }),
    }
    .to_string()
}

fn dispatch<F>(session: *mut SkipperSession, body: F) -> *mut c_char
where
    F: FnOnce(&mut SessionStateMachine) -> CallResult,
{
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        let Some(session) = (unsafe { session.as_mut() }) else {
            return error_string(&"session handle is null".into());
        };
        match body(&mut session.machine) {
            Ok(actions) => json!({
                "ok": true,
                "actions": actions.iter().map(action_json).collect::<Vec<_>>(),
                "state": state_json(&session.machine),
            })
            .to_string(),
            Err(message) => error_string(&message.into()),
        }
    }));
    into_c_string(outcome.unwrap_or_else(|_| error_string(&"the state machine panicked".into())))
}

#[no_mangle]
pub extern "C" fn skipper_session_new(
    role: i32,
    ice_restart_delay_ms: i64,
    ice_failure_grace_ms: i64,
    renew_interval_ms: i64,
) -> *mut SkipperSession {
    let built = catch_unwind(|| {
        let mut machine = SessionStateMachine::new(if role == ROLE_HOST {
            Role::Host
        } else {
            Role::Controller
        });
        machine.ice_restart_delay_ms = ice_restart_delay_ms;
        machine.ice_failure_grace_ms = ice_failure_grace_ms;
        machine.renew_interval_ms = renew_interval_ms;
        Box::into_raw(Box::new(SkipperSession { machine }))
    });
    built.unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn skipper_session_free(session: *mut SkipperSession) {
    if session.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| drop(unsafe { Box::from_raw(session) })));
}

#[no_mangle]
pub unsafe extern "C" fn skipper_string_free(string: *mut c_char) {
    if string.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        drop(unsafe { CString::from_raw(string) })
    }));
}

#[no_mangle]
pub unsafe extern "C" fn skipper_session_state(session: *mut SkipperSession) -> *mut c_char {
    dispatch(session, |_| Ok(vec![]))
}

#[no_mangle]
pub unsafe extern "C" fn skipper_session_connect_requested(
    session: *mut SkipperSession,
    device_id: *const u8,
    device_id_len: usize,
    access_code: *const u8,
    access_code_len: usize,
    remember: bool,
) -> *mut c_char {
    dispatch(session, |machine| {
        let device_id = unsafe { required_text(device_id, device_id_len, "device_id") }?;
        let access_code = unsafe { required_text(access_code, access_code_len, "access_code") }?;
        Ok(machine.connect_requested(device_id, access_code, remember))
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_session_granted(
    session: *mut SkipperSession,
    session_id: *const u8,
    session_id_len: usize,
    session_token: *const u8,
    session_token_len: usize,
    host_device_id: *const u8,
    host_device_id_len: usize,
    controller_device_id: *const u8,
    controller_device_id_len: usize,
    now_ms: i64,
) -> *mut c_char {
    dispatch(session, |machine| {
        let grant = SessionGrant {
            session_id: unsafe { required_text(session_id, session_id_len, "session_id") }?
                .to_string(),
            session_token: unsafe {
                required_text(session_token, session_token_len, "session_token")
            }?
            .to_string(),
            host_device_id: unsafe {
                required_text(host_device_id, host_device_id_len, "host_device_id")
            }?
            .to_string(),
            controller_device_id: unsafe {
                required_text(
                    controller_device_id,
                    controller_device_id_len,
                    "controller_device_id",
                )
            }?
            .to_string(),
        };
        Ok(machine.session_granted(&grant, now_ms))
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_session_connect_failed(
    session: *mut SkipperSession,
    code: *const u8,
    code_len: usize,
) -> *mut c_char {
    dispatch(session, |machine| {
        Ok(machine.connect_failed(unsafe { required_text(code, code_len, "code") }?))
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_session_signaling_lost(
    session: *mut SkipperSession,
) -> *mut c_char {
    dispatch(session, |machine| Ok(machine.signaling_lost()))
}

#[no_mangle]
pub unsafe extern "C" fn skipper_session_signaling_authenticated(
    session: *mut SkipperSession,
    active_session_id: *const u8,
    active_session_id_len: usize,
) -> *mut c_char {
    dispatch(session, |machine| {
        let active = unsafe {
            optional_text(
                active_session_id,
                active_session_id_len,
                "active_session_id",
            )
        }?;
        Ok(machine.signaling_authenticated(active))
    })
}

unsafe fn resume_ok(
    session_id: *const u8,
    session_id_len: usize,
    session_token: *const u8,
    session_token_len: usize,
) -> Result<ResumeOk, String> {
    Ok(ResumeOk {
        session_id: unsafe { required_text(session_id, session_id_len, "session_id") }?.to_string(),
        session_token: unsafe { required_text(session_token, session_token_len, "session_token") }?
            .to_string(),
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_session_resume_succeeded(
    session: *mut SkipperSession,
    session_id: *const u8,
    session_id_len: usize,
    session_token: *const u8,
    session_token_len: usize,
    now_ms: i64,
) -> *mut c_char {
    dispatch(session, |machine| {
        let ok =
            unsafe { resume_ok(session_id, session_id_len, session_token, session_token_len) }?;
        Ok(machine.resume_succeeded(&ok, now_ms))
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_session_resume_failed(
    session: *mut SkipperSession,
    code: *const u8,
    code_len: usize,
    retry_after_sec: i32,
) -> *mut c_char {
    dispatch(session, |machine| {
        let code = unsafe { required_text(code, code_len, "code") }?;
        Ok(machine.resume_failed(code, retry_after_sec))
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_session_renew_succeeded(
    session: *mut SkipperSession,
    session_id: *const u8,
    session_id_len: usize,
    session_token: *const u8,
    session_token_len: usize,
    now_ms: i64,
) -> *mut c_char {
    dispatch(session, |machine| {
        let ok =
            unsafe { resume_ok(session_id, session_id_len, session_token, session_token_len) }?;
        machine.renew_succeeded(&ok, now_ms);
        Ok(vec![])
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_session_renew_failed(
    session: *mut SkipperSession,
    code: *const u8,
    code_len: usize,
) -> *mut c_char {
    dispatch(session, |machine| {
        Ok(machine.renew_failed(unsafe { required_text(code, code_len, "code") }?))
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_session_ice_state_changed(
    session: *mut SkipperSession,
    ice_state: *const u8,
    ice_state_len: usize,
    now_ms: i64,
) -> *mut c_char {
    dispatch(session, |machine| {
        let name = unsafe { required_text(ice_state, ice_state_len, "ice_state") }?;
        Ok(machine.ice_state_changed(ice_state_from_name(name)?, now_ms))
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_session_tick(
    session: *mut SkipperSession,
    now_ms: i64,
) -> *mut c_char {
    dispatch(session, |machine| Ok(machine.tick(now_ms)))
}

#[no_mangle]
pub unsafe extern "C" fn skipper_session_close_locally(
    session: *mut SkipperSession,
    reason: *const u8,
    reason_len: usize,
) -> *mut c_char {
    dispatch(session, |machine| {
        Ok(machine.close_locally(unsafe { required_text(reason, reason_len, "reason") }?))
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_session_user_ended(
    session: *mut SkipperSession,
    reason: *const u8,
    reason_len: usize,
) -> *mut c_char {
    dispatch(session, |machine| {
        Ok(machine.user_ended(unsafe { required_text(reason, reason_len, "reason") }?))
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_session_set_relay_only(
    session: *mut SkipperSession,
    relay_only: bool,
) -> *mut c_char {
    dispatch(session, |machine| {
        machine.set_relay_only(relay_only);
        Ok(vec![])
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_session_set_remembered_access_code(
    session: *mut SkipperSession,
    access_code: *const u8,
    access_code_len: usize,
) -> *mut c_char {
    dispatch(session, |machine| {
        machine.remembered_access_code =
            unsafe { optional_text(access_code, access_code_len, "access_code") }?
                .map(str::to_string);
        Ok(vec![])
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_session_pake_succeeded(
    session: *mut SkipperSession,
    now_ms: i64,
) -> *mut c_char {
    dispatch(session, |machine| Ok(machine.pake_succeeded(now_ms)))
}

#[no_mangle]
pub unsafe extern "C" fn skipper_session_consent_answered(
    session: *mut SkipperSession,
    allow: bool,
    now_ms: i64,
) -> *mut c_char {
    dispatch(session, |machine| {
        Ok(machine.consent_answered(allow, now_ms))
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_session_set_consent_required(
    session: *mut SkipperSession,
    consent_required: bool,
) -> *mut c_char {
    dispatch(session, |machine| {
        machine.consent_required = consent_required;
        Ok(vec![])
    })
}
