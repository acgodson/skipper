//! Constants mirrored from `protocol/protocol.go` and PROTOCOL.md.
//!
//! PROTOCOL.md is normative. If this file and that document disagree, the
//! document wins and this file is a bug.

/// The only protocol version this build speaks. PROTOCOL.md §0.1.
pub const VERSION: i32 = 2;

/// Frames larger than this are a protocol error (WebSocket close 1009).
pub const MAX_FRAME_BYTES: usize = 256 * 1024;

/// Tunables the server advertises in `hello_ok`. PROTOCOL.md §2.4. These are the
/// values used until the server states otherwise; they are not authoritative.
pub mod tunable {
    pub const HEARTBEAT_SEC: i32 = 15;
    pub const OFFLINE_AFTER_SEC: i32 = 40;
    pub const SESSION_TOKEN_TTL_SEC: i32 = 600;
    pub const PENDING_TIMEOUT_SEC: i32 = 30;
    pub const AUTH_TIMEOUT_SEC: i32 = 20;
    pub const NONCE_TTL_SEC: i32 = 20;
    pub const MAX_WATCHES: usize = 8;
    pub const TURN_CRED_TTL_SEC: i32 = 12 * 60 * 60;
}

/// Signaling message types. PROTOCOL.md §2.16.
pub mod msg {
    pub const CHALLENGE: &str = "challenge";
    pub const REGISTER: &str = "register";
    pub const REGISTER_OK: &str = "register_ok";
    pub const HELLO: &str = "hello";
    pub const HELLO_OK: &str = "hello_ok";
    pub const HEARTBEAT: &str = "heartbeat";
    pub const HEARTBEAT_OK: &str = "heartbeat_ok";
    pub const WATCH: &str = "watch";
    pub const WATCH_OK: &str = "watch_ok";
    pub const UNWATCH: &str = "unwatch";
    pub const UNWATCH_OK: &str = "unwatch_ok";
    pub const PRESENCE: &str = "presence";
    pub const CONNECT_REQ: &str = "connect_req";
    pub const CONNECT_OK: &str = "connect_ok";
    pub const SESSION_START: &str = "session_start";
    pub const RESUME: &str = "resume";
    pub const RESUME_OK: &str = "resume_ok";
    pub const RENEW: &str = "renew";
    pub const RENEW_OK: &str = "renew_ok";
    pub const PEER_STATE: &str = "peer_state";
    pub const SDP: &str = "sdp";
    pub const ICE: &str = "ice";
    pub const BYE: &str = "bye";
    pub const REFRESH_CODE: &str = "refresh_code";
    pub const REFRESH_CODE_OK: &str = "refresh_code_ok";
    pub const PAKE: &str = "pake";
    pub const ERROR: &str = "error";
}

/// `ctrl` data-channel types. PROTOCOL.md §5.
pub mod ctrl {
    pub const MOUSE_DOWN: &str = "mouse_down";
    pub const MOUSE_UP: &str = "mouse_up";
    pub const MOUSE_DRAG: &str = "mouse_drag";
    pub const CLICK: &str = "click";
    pub const KEY_DOWN: &str = "key_down";
    pub const KEY_UP: &str = "key_up";
    pub const SCROLL: &str = "scroll";
    pub const CLIPBOARD_TEXT: &str = "clipboard_text";
    pub const GESTURE: &str = "gesture";
    pub const INPUT_RESET: &str = "input_reset";
    pub const DISPLAY_INFO: &str = "display_info";
    pub const QUALITY: &str = "quality";
    pub const PING: &str = "ping";
    pub const PONG: &str = "pong";
    pub const SESSION_CLOSE: &str = "session_close";
}

/// The only type permitted on the unreliable `hi` channel. PROTOCOL.md §6.
pub mod hi {
    pub const MOUSE_MOVE: &str = "mouse_move";
}

/// Device roles. PROTOCOL.md §2.4.
pub mod role {
    pub const HOST: &str = "host";
    pub const CONTROLLER: &str = "controller";
}

/// Error codes. PROTOCOL.md §7. Clients branch on these, never on `message`.
pub mod err {
    pub const BAD_REQUEST: &str = "bad_request";
    pub const UNSUPPORTED_VERSION: &str = "unsupported_version";
    pub const UNSUPPORTED: &str = "unsupported";
    pub const UNAUTHENTICATED: &str = "unauthenticated";
    pub const BAD_SIGNATURE: &str = "bad_signature";
    pub const UNKNOWN_DEVICE: &str = "unknown_device";
    pub const BAD_CODE: &str = "bad_code";
    pub const OFFLINE: &str = "offline";
    pub const BUSY: &str = "busy";
    pub const RATE_LIMITED: &str = "rate_limited";
    pub const SELF_CONNECT: &str = "self_connect";
    pub const NO_SESSION: &str = "no_session";
    pub const BAD_TOKEN: &str = "bad_token";
    pub const PEER_OFFLINE: &str = "peer_offline";
    pub const DISPLACED: &str = "displaced";
    pub const FORBIDDEN: &str = "forbidden";
    pub const ENTITLEMENT: &str = "entitlement";
    pub const INTERNAL: &str = "internal";
}

/// Reasons carried by `ErrorPayload::reason` when the code is
/// [`err::ENTITLEMENT`]. PROTOCOL.md §7; the same set as API.md §4.3.
pub mod entitlement {
    pub const UNLINKED: &str = "unlinked";
    pub const TRIAL_EXPIRED: &str = "trial_expired";
    pub const NO_BALANCE: &str = "no_balance";
    pub const CONCURRENCY: &str = "concurrency";
    pub const SUSPENDED: &str = "suspended";
}

/// `bye` reasons. PROTOCOL.md §2.14.
pub mod bye {
    pub const USER_ENDED: &str = "user_ended";
    pub const HOST_ENDED: &str = "host_ended";
    pub const TIMEOUT: &str = "timeout";
    pub const FAILED: &str = "failed";
    pub const CODE_REFRESHED: &str = "code_refreshed";
    pub const REPLACED: &str = "replaced";
    pub const SHUTDOWN: &str = "shutdown";
    pub const ERROR: &str = "error";
}

/// Server-side session states. PROTOCOL.md §4.2.
pub mod session_state {
    pub const PENDING: &str = "pending";
    pub const OPEN: &str = "open";
    pub const HALF_OPEN: &str = "half_open";
    pub const ORPHANED: &str = "orphaned";
    pub const CLOSED: &str = "closed";
}

/// The base64 text of a single `Pake::payload` may not exceed this.
pub const MAX_PAKE_PAYLOAD_BYTES: usize = 4096;

/// The only accepted `CodeVerifier::alg`.
pub const ALG_ARGON2ID: &str = "argon2id";
