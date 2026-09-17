//! The C ABI over [`rc_session`] and [`rc_identity`], described by
//! `include/skipper_core.h`. The header is the contract; this file implements
//! it and nothing else.

#![allow(clippy::missing_safety_doc)]

use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};

use rc_session::{
    IceLinkState, ResumeOk, Role, SessionAction, SessionGrant, SessionPhase, SessionStateMachine,
};
use serde_json::{json, Value};

mod pake;
mod sdp;

pub use pake::SkipperPake;

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
    })
}

pub(crate) fn respond<F>(panic_message: &str, body: F) -> *mut c_char
where
    F: FnOnce() -> Result<Value, String>,
{
    let outcome = catch_unwind(AssertUnwindSafe(|| match body() {
        Ok(mut value) => {
            if let Some(object) = value.as_object_mut() {
                object.insert("ok".to_string(), json!(true));
            }
            value.to_string()
        }
        Err(message) => error_string(&message),
    }));
    into_c_string(outcome.unwrap_or_else(|_| error_string(panic_message)))
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

pub(crate) fn error_string(message: &str) -> String {
    json!({ "ok": false, "error": message }).to_string()
}

// SAFETY: `pointer` is either null or an outliving NUL-terminated C string.
pub(crate) unsafe fn optional_str<'a>(pointer: *const c_char) -> Result<Option<&'a str>, String> {
    if pointer.is_null() {
        return Ok(None);
    }
    unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .map(Some)
        .map_err(|_| "argument is not valid UTF-8".to_string())
}

pub(crate) unsafe fn required_str<'a>(
    pointer: *const c_char,
    name: &str,
) -> Result<&'a str, String> {
    unsafe { optional_str(pointer) }?.ok_or_else(|| format!("argument {name} must not be null"))
}

fn dispatch<F>(session: *mut SkipperSession, body: F) -> *mut c_char
where
    F: FnOnce(&mut SessionStateMachine) -> CallResult,
{
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        let Some(session) = (unsafe { session.as_mut() }) else {
            return error_string("session handle is null");
        };
        match body(&mut session.machine) {
            Ok(actions) => json!({
                "ok": true,
                "actions": actions.iter().map(action_json).collect::<Vec<_>>(),
                "state": state_json(&session.machine),
            })
            .to_string(),
            Err(message) => error_string(&message),
        }
    }));
    into_c_string(outcome.unwrap_or_else(|_| error_string("the state machine panicked")))
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
    device_id: *const c_char,
    access_code: *const c_char,
    remember: bool,
) -> *mut c_char {
    dispatch(session, |machine| {
        let device_id = unsafe { required_str(device_id, "device_id") }?;
        let access_code = unsafe { required_str(access_code, "access_code") }?;
        Ok(machine.connect_requested(device_id, access_code, remember))
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_session_granted(
    session: *mut SkipperSession,
    session_id: *const c_char,
    session_token: *const c_char,
    host_device_id: *const c_char,
    controller_device_id: *const c_char,
    now_ms: i64,
) -> *mut c_char {
    dispatch(session, |machine| {
        let grant = SessionGrant {
            session_id: unsafe { required_str(session_id, "session_id") }?.to_string(),
            session_token: unsafe { required_str(session_token, "session_token") }?.to_string(),
            host_device_id: unsafe { required_str(host_device_id, "host_device_id") }?.to_string(),
            controller_device_id: unsafe {
                required_str(controller_device_id, "controller_device_id")
            }?
            .to_string(),
        };
        Ok(machine.session_granted(&grant, now_ms))
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_session_connect_failed(
    session: *mut SkipperSession,
    code: *const c_char,
) -> *mut c_char {
    dispatch(session, |machine| {
        Ok(machine.connect_failed(unsafe { required_str(code, "code") }?))
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
    active_session_id: *const c_char,
) -> *mut c_char {
    dispatch(session, |machine| {
        let active = unsafe { optional_str(active_session_id) }?;
        Ok(machine.signaling_authenticated(active))
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_session_resume_succeeded(
    session: *mut SkipperSession,
    session_id: *const c_char,
    session_token: *const c_char,
    now_ms: i64,
) -> *mut c_char {
    dispatch(session, |machine| {
        let ok = ResumeOk {
            session_id: unsafe { required_str(session_id, "session_id") }?.to_string(),
            session_token: unsafe { required_str(session_token, "session_token") }?.to_string(),
        };
        Ok(machine.resume_succeeded(&ok, now_ms))
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_session_resume_failed(
    session: *mut SkipperSession,
    code: *const c_char,
    retry_after_sec: i32,
) -> *mut c_char {
    dispatch(session, |machine| {
        let code = unsafe { required_str(code, "code") }?;
        Ok(machine.resume_failed(code, retry_after_sec))
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_session_renew_succeeded(
    session: *mut SkipperSession,
    session_id: *const c_char,
    session_token: *const c_char,
    now_ms: i64,
) -> *mut c_char {
    dispatch(session, |machine| {
        let ok = ResumeOk {
            session_id: unsafe { required_str(session_id, "session_id") }?.to_string(),
            session_token: unsafe { required_str(session_token, "session_token") }?.to_string(),
        };
        machine.renew_succeeded(&ok, now_ms);
        Ok(vec![])
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_session_renew_failed(
    session: *mut SkipperSession,
    code: *const c_char,
) -> *mut c_char {
    dispatch(session, |machine| {
        Ok(machine.renew_failed(unsafe { required_str(code, "code") }?))
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_session_ice_state_changed(
    session: *mut SkipperSession,
    ice_state: *const c_char,
    now_ms: i64,
) -> *mut c_char {
    dispatch(session, |machine| {
        let state = ice_state_from_name(unsafe { required_str(ice_state, "ice_state") }?)?;
        Ok(machine.ice_state_changed(state, now_ms))
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
    reason: *const c_char,
) -> *mut c_char {
    dispatch(session, |machine| {
        Ok(machine.close_locally(unsafe { required_str(reason, "reason") }?))
    })
}

#[no_mangle]
pub unsafe extern "C" fn skipper_session_user_ended(
    session: *mut SkipperSession,
    reason: *const c_char,
) -> *mut c_char {
    dispatch(session, |machine| {
        Ok(machine.user_ended(unsafe { required_str(reason, "reason") }?))
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
    access_code: *const c_char,
) -> *mut c_char {
    dispatch(session, |machine| {
        machine.remembered_access_code = unsafe { optional_str(access_code) }?.map(str::to_string);
        Ok(vec![])
    })
}
