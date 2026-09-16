// Package protocol is the Go side of the RemoteControl wire contract.
//
// PROTOCOL.md in this directory is normative; these types must mirror it exactly.
// Nothing here may import anything outside the standard library.
package protocol

import (
	"encoding/json"
	"errors"
	"fmt"
)

// Version is the only protocol version this build speaks. PROTOCOL.md "v2
// changes" lists what the bump to 2 changed: connect_req is gated by
// entitlement, the access code is proved peer to peer by the relayed pake
// exchange, and the server stores nothing about any code.
const Version = 2

// Tunables the server advertises in hello_ok. Duplicated in PROTOCOL.md §2.4.
const (
	HeartbeatSec       = 15  // client -> server heartbeat interval
	OfflineAfterSec    = 40  // silence after which a device is considered offline
	SessionTokenTTLSec = 600 // session token lifetime (10 min)
	PendingTimeoutSec  = 30  // host must attach to a pending session within this
	MaxFrameBytes      = 256 * 1024
	AuthTimeoutSec     = 20 // unauthenticated socket is closed after this
	NonceTTLSec        = 20
	MaxWatches         = 8
	TurnCredTTLSec     = 12 * 60 * 60
)

// ---------------------------------------------------------------------------
// Envelope
// ---------------------------------------------------------------------------

// Envelope wraps every message on every surface.
type Envelope struct {
	V       int             `json:"v"`
	Type    string          `json:"type"`
	ID      string          `json:"id,omitempty"`
	Re      string          `json:"re,omitempty"`
	TS      int64           `json:"ts,omitempty"`
	Payload json.RawMessage `json:"payload"`
}

// Message types. Keep in sync with PROTOCOL.md §2.16.
const (
	TypeChallenge     = "challenge"
	TypeRegister      = "register"
	TypeRegisterOK    = "register_ok"
	TypeHello         = "hello"
	TypeHelloOK       = "hello_ok"
	TypeHeartbeat     = "heartbeat"
	TypeHeartbeatOK   = "heartbeat_ok"
	TypeWatch         = "watch"
	TypeWatchOK       = "watch_ok"
	TypeUnwatch       = "unwatch"
	TypeUnwatchOK     = "unwatch_ok"
	TypePresence      = "presence"
	TypeConnectReq    = "connect_req"
	TypeConnectOK     = "connect_ok"
	TypeSessionStart  = "session_start"
	TypeResume        = "resume"
	TypeResumeOK      = "resume_ok"
	TypeRenew         = "renew"
	TypeRenewOK       = "renew_ok"
	TypePeerState     = "peer_state"
	TypeSDP           = "sdp"
	TypeICE           = "ice"
	TypeBye           = "bye"
	TypeRefreshCode   = "refresh_code"
	TypeRefreshCodeOK = "refresh_code_ok"
	TypePake          = "pake"
	TypeError         = "error"
)

// MaxPakePayloadBytes caps the base64 text of a single Pake.Payload.
const MaxPakePayloadBytes = 4096

// Roles.
const (
	RoleHost       = "host"
	RoleController = "controller"
)

// Error codes. Keep in sync with PROTOCOL.md §7.
const (
	ErrBadRequest         = "bad_request"
	ErrUnsupportedVersion = "unsupported_version"
	ErrUnsupported        = "unsupported"
	ErrUnauthenticated    = "unauthenticated"
	ErrBadSignature       = "bad_signature"
	ErrUnknownDevice      = "unknown_device"
	ErrBadCode            = "bad_code"
	ErrOffline            = "offline"
	ErrBusy               = "busy"
	ErrRateLimited        = "rate_limited"
	ErrSelfConnect        = "self_connect"
	ErrNoSession          = "no_session"
	ErrBadToken           = "bad_token"
	ErrPeerOffline        = "peer_offline"
	ErrDisplaced          = "displaced"
	ErrForbidden          = "forbidden"
	ErrEntitlement        = "entitlement"
	ErrInternal           = "internal"
)

// Reasons carried by Error.Reason, which is set only when Code is ErrEntitlement.
// PROTOCOL.md §7. The server decides these; clients only render them.
const (
	EntitlementUnlinked     = "unlinked"
	EntitlementTrialExpired = "trial_expired"
	EntitlementNoBalance    = "no_balance"
	EntitlementConcurrency  = "concurrency"
	EntitlementSuspended    = "suspended"
)

// Bye reasons. PROTOCOL.md §2.14.
const (
	ByeUserEnded     = "user_ended"
	ByeHostEnded     = "host_ended"
	ByeTimeout       = "timeout"
	ByeFailed        = "failed"
	ByeCodeRefreshed = "code_refreshed"
	ByeReplaced      = "replaced"
	ByeShutdown      = "shutdown"
	ByeError         = "error"
	// ByePeerAuthFailed: the peer's signed SDP fingerprints did not verify
	// against the device key this side expects (PROTOCOL.md §2.12).
	ByePeerAuthFailed = "peer_auth_failed"
	// ByeAuthFailed: the host refused the controller's access code, or refused
	// to look at it because that controller is locked out (PROTOCOL.md §2.17).
	// Distinct from ByePeerAuthFailed, which is about device keys, not codes.
	ByeAuthFailed = "auth_failed"
)

// Session states. PROTOCOL.md §4.2.
const (
	SessionPending  = "pending"
	SessionOpen     = "open"
	SessionHalfOpen = "half_open"
	SessionOrphaned = "orphaned"
	SessionClosed   = "closed"
)

// ---------------------------------------------------------------------------
// Signaling payloads
// ---------------------------------------------------------------------------

// Challenge is pushed by the server on connect and after register_ok.
type Challenge struct {
	Nonce      string `json:"nonce"`      // base64, 32 random bytes
	ServerTime int64  `json:"serverTime"` // unix ms
}

// CodeVerifier is the Argon2id verifier for an access code. The plaintext code
// never appears in this struct and must never be stored server-side.
type CodeVerifier struct {
	Alg    string `json:"alg"`    // "argon2id"
	Salt   string `json:"salt"`   // base64, >= 16 bytes
	Hash   string `json:"hash"`   // base64
	Time   uint32 `json:"time"`   // iterations, 1..10
	MemKiB uint32 `json:"memKiB"` // 8192..262144
	Par    uint8  `json:"par"`    // 1..4
	Len    uint32 `json:"len"`    // 16..64
}

// AlgArgon2id is the only accepted CodeVerifier.Alg value.
const AlgArgon2id = "argon2id"

// Validate checks structural sanity of a verifier (not the hash itself).
func (c CodeVerifier) Validate() error {
	if c.Alg != AlgArgon2id {
		return fmt.Errorf("code.alg must be %q", AlgArgon2id)
	}
	if c.Salt == "" || c.Hash == "" {
		return errors.New("code.salt and code.hash are required")
	}
	if c.Time < 1 || c.Time > 10 {
		return errors.New("code.time out of range 1..10")
	}
	if c.MemKiB < 8192 || c.MemKiB > 262144 {
		return errors.New("code.memKiB out of range 8192..262144")
	}
	if c.Par < 1 || c.Par > 4 {
		return errors.New("code.par out of range 1..4")
	}
	if c.Len < 16 || c.Len > 64 {
		return errors.New("code.len out of range 16..64")
	}
	return nil
}

// Register creates a device and mints a deviceId. Idempotent per pubkey.
type Register struct {
	Pubkey string       `json:"pubkey"` // base64 DER SPKI, P-256
	Sig    string       `json:"sig"`    // base64 DER ECDSA-SHA256 over the nonce bytes
	Label  string       `json:"label,omitempty"`
	Code   CodeVerifier `json:"code"`
}

type RegisterOK struct {
	DeviceID string `json:"deviceId"`
	Existing bool   `json:"existing"`
}

type Hello struct {
	DeviceID string `json:"deviceId"`
	Pubkey   string `json:"pubkey"`
	Sig      string `json:"sig"`
	Role     string `json:"role"` // host | controller
}

type ICEServer struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username,omitempty"`
	Credential string   `json:"credential,omitempty"`
	ExpiresAt  int64    `json:"expiresAt,omitempty"` // unix ms
}

type HelloOK struct {
	DeviceID           string      `json:"deviceId"`
	ServerTime         int64       `json:"serverTime"`
	ICEServers         []ICEServer `json:"iceServers"`
	HeartbeatSec       int         `json:"heartbeatSec"`
	OfflineAfterSec    int         `json:"offlineAfterSec"`
	SessionTokenTTLSec int         `json:"sessionTokenTtlSec"`
	ActiveSessionID    string      `json:"activeSessionId,omitempty"`
}

type Heartbeat struct{}

type HeartbeatOK struct {
	ServerTime int64 `json:"serverTime"`
}

type Watch struct {
	DeviceID string `json:"deviceId"`
}

type WatchOK struct {
	DeviceID string `json:"deviceId"`
}

type Unwatch struct {
	DeviceID string `json:"deviceId"`
}

type UnwatchOK struct {
	DeviceID string `json:"deviceId"`
}

type Presence struct {
	DeviceID string `json:"deviceId"`
	Online   bool   `json:"online"`
	Since    int64  `json:"since"` // unix ms, 0 if never seen
}

// ConnectReq asks the server to open a session against a host. Authorisation is
// the host's entitlement; the access code is proved peer to peer by the Pake
// exchange, so AccessCode survives only to be rejected when a v1 client sends it.
type ConnectReq struct {
	DeviceID   string `json:"deviceId"`
	AccessCode string `json:"accessCode,omitempty"`
}

type ConnectOK struct {
	SessionID          string `json:"sessionId"`
	SessionToken       string `json:"sessionToken"`
	ExpiresAt          int64  `json:"expiresAt"` // unix ms
	TTLSec             int    `json:"ttlSec"`
	HostDeviceID       string `json:"hostDeviceId"`
	ControllerDeviceID string `json:"controllerDeviceId"`
	// HostPubkey is the host's registered pubkey, base64 DER SPKI: the key the
	// controller requires on the host's signed SDP (PROTOCOL.md §2.12). The
	// server has it from `register`; it is public material, not a secret.
	HostPubkey string `json:"hostPubkey,omitempty"`
}

// SessionStart is pushed to the host when a controller connects. It carries
// everything ConnectOK does plus the controller's registered pubkey, which the
// server has held since that device registered. The host needs it before the
// Pake exchange starts: it is what its guess counter and its trusted-controller
// list are keyed on (PROTOCOL.md §2.9).
type SessionStart struct {
	ConnectOK
	ControllerPubkey string `json:"controllerPubkey,omitempty"`
}

type Resume struct {
	SessionID    string `json:"sessionId"`
	SessionToken string `json:"sessionToken"`
}

type ResumeOK struct {
	SessionID    string `json:"sessionId"`
	SessionToken string `json:"sessionToken"` // rotated; old token is dead
	ExpiresAt    int64  `json:"expiresAt"`
	TTLSec       int    `json:"ttlSec"`
	PeerAttached bool   `json:"peerAttached"`
	Role         string `json:"role"`
}

type Renew struct {
	SessionID    string `json:"sessionId"`
	SessionToken string `json:"sessionToken"`
}

type RenewOK struct {
	SessionID    string `json:"sessionId"`
	SessionToken string `json:"sessionToken"`
	ExpiresAt    int64  `json:"expiresAt"`
	TTLSec       int    `json:"ttlSec"`
}

type PeerState struct {
	SessionID string `json:"sessionId"`
	Attached  bool   `json:"attached"`
}

// SDP is relayed verbatim. The server never parses or stores Sdp, and it
// neither validates nor could produce Sig: that is the point of signing the
// fingerprints (PROTOCOL.md §2.12).
type SDP struct {
	SessionID string `json:"sessionId"`
	SDPType   string `json:"sdpType"` // offer | answer | pranswer | rollback
	SDP       string `json:"sdp"`
	Restart   bool   `json:"restart,omitempty"`
	// FP is every a=fingerprint value in SDP, de-duplicated, sorted, joined
	// with "\n".
	FP string `json:"fp,omitempty"`
	// Pubkey is the sender's device key, base64 DER SPKI.
	Pubkey string `json:"pubkey,omitempty"`
	// Sig is base64 DER ECDSA-SHA256 over
	// "skipperdesk/sdp/v1|" SessionID "|" SDPType "|" FP.
	Sig string `json:"sig,omitempty"`
}

// ICE is relayed verbatim.
type ICE struct {
	SessionID     string `json:"sessionId"`
	Candidate     string `json:"candidate"` // "" = end of candidates
	SDPMid        string `json:"sdpMid,omitempty"`
	SDPMLineIndex int    `json:"sdpMLineIndex,omitempty"`
}

type Bye struct {
	SessionID string `json:"sessionId"`
	Reason    string `json:"reason"`
}

// RefreshCode replaces the calling device's access-code verifier and kills all
// of its sessions and tokens.
type RefreshCode CodeVerifier

type RefreshCodeOK struct {
	DeviceID  string `json:"deviceId"`
	UpdatedAt int64  `json:"updatedAt"`
}

// Pake relays one opaque SPAKE2 message between the two peers. Payload is
// base64 of the opaque PAKE message. The server validates SessionID and
// attachment, then routes it verbatim: it never parses, stores or logs Payload.
type Pake struct {
	SessionID string `json:"sessionId"`
	Step      int    `json:"step"`
	Payload   string `json:"payload"`
}

type Error struct {
	Code          string `json:"code"`
	Message       string `json:"message"`
	RetryAfterSec int    `json:"retryAfterSec,omitempty"`
	Reason        string `json:"reason,omitempty"`
}

func (e Error) Error() string { return e.Code + ": " + e.Message }

// ---------------------------------------------------------------------------
// ctrl data channel (reliable, ordered)
// ---------------------------------------------------------------------------

const (
	CtrlMouseDown     = "mouse_down"
	CtrlMouseUp       = "mouse_up"
	CtrlMouseDrag     = "mouse_drag"
	CtrlClick         = "click"
	CtrlKeyDown       = "key_down"
	CtrlKeyUp         = "key_up"
	CtrlScroll        = "scroll"
	CtrlClipboardText = "clipboard_text"
	CtrlGesture       = "gesture"
	CtrlInputReset    = "input_reset"
	CtrlDisplayInfo   = "display_info"
	CtrlQuality       = "quality"
	CtrlPing          = "ping"
	CtrlPong          = "pong"
	CtrlSessionClose  = "session_close"

	// hi data channel (unreliable, unordered)
	HiMouseMove = "mouse_move"
)

// Mouse buttons.
const (
	ButtonLeft   = 0
	ButtonRight  = 1
	ButtonMiddle = 2
)

// Modifier bitmask for KeyDown/KeyUp.
const (
	ModShift    = 1 << 0
	ModControl  = 1 << 1
	ModOption   = 1 << 2
	ModCommand  = 1 << 3
	ModCapsLock = 1 << 4
	ModFn       = 1 << 5
)

// Scroll phases.
const (
	PhaseBegin    = "begin"
	PhaseChanged  = "changed"
	PhaseEnd      = "end"
	PhaseMomentum = "momentum"
)

// Gesture names.
const (
	GestureMissionControl   = "mission_control"
	GestureAppExpose        = "app_expose"
	GestureShowDesktop      = "show_desktop"
	GestureLaunchpad        = "launchpad"
	GestureSpotlight        = "spotlight"
	GestureAppSwitcher      = "app_switcher"
	GestureScreenshotRegion = "screenshot_region"
	GestureForceQuit        = "force_quit"
	GestureLockScreen       = "lock_screen"
)

// Quality modes.
const (
	QualityAuto   = "auto"
	QualitySharp  = "sharp"
	QualitySmooth = "smooth"
)

// MouseEvent covers mouse_down, mouse_up and mouse_drag.
// X and Y are normalised 0..1 doubles; receivers must clamp.
type MouseEvent struct {
	Button int     `json:"button"`
	X      float64 `json:"x"`
	Y      float64 `json:"y"`
}

type Click struct {
	Button int     `json:"button"`
	X      float64 `json:"x"`
	Y      float64 `json:"y"`
	Count  int     `json:"count"`
}

type KeyEvent struct {
	Keycode int    `json:"keycode"` // macOS kVK_* virtual keycode
	Mods    int    `json:"mods"`    // Mod* bitmask
	Chars   string `json:"chars,omitempty"`
}

type Scroll struct {
	DX    float64 `json:"dx"` // pixel units at host resolution
	DY    float64 `json:"dy"`
	Phase string  `json:"phase"`
}

// ClipboardText content must never be logged.
type ClipboardText struct {
	Text     string `json:"text"`
	OriginID string `json:"originId"` // deviceId that produced it
	Hash     string `json:"hash"`     // base64 SHA-256 of Text; echo-loop guard
}

type Gesture struct {
	Name string `json:"name"`
}

type InputReset struct{}

type DisplayInfo struct {
	W     int     `json:"w"`
	H     int     `json:"h"`
	Scale float64 `json:"scale"`
	// OS is the host operating system: OSMacOS or OSWindows. Additive under
	// PROTOCOL.md §0; an absent value means macOS, which is what every build
	// that predates this field was.
	OS string `json:"os,omitempty"`
}

// Host operating systems, for DisplayInfo.OS.
const (
	OSMacOS   = "macos"
	OSWindows = "windows"
)

type Quality struct {
	Mode string `json:"mode"`
}

type Ping struct {
	T int64 `json:"t"` // sender unix ms
}

type Pong struct {
	T int64 `json:"t"` // echoed verbatim from Ping
}

type SessionClose struct {
	Reason string `json:"reason"`
}

// MouseMove is the only message allowed on the unreliable "hi" channel.
// Receivers must drop any packet whose Seq is <= the highest already seen.
type MouseMove struct {
	X   float64 `json:"x"`
	Y   float64 `json:"y"`
	Seq int64   `json:"seq"`
}

// ---------------------------------------------------------------------------
// Encoding helpers
// ---------------------------------------------------------------------------

// Encode builds an envelope with the given type/payload. re may be "".
func Encode(msgType, id, re string, nowMs int64, payload any) ([]byte, error) {
	var raw json.RawMessage
	if payload == nil {
		raw = json.RawMessage(`{}`)
	} else {
		b, err := json.Marshal(payload)
		if err != nil {
			return nil, err
		}
		raw = b
	}
	return json.Marshal(Envelope{V: Version, Type: msgType, ID: id, Re: re, TS: nowMs, Payload: raw})
}

// Decode unmarshals a frame into an Envelope, checking the version.
func Decode(b []byte) (Envelope, error) {
	var e Envelope
	if err := json.Unmarshal(b, &e); err != nil {
		return e, err
	}
	if e.V != Version {
		return e, fmt.Errorf("unsupported protocol version %d", e.V)
	}
	if e.Type == "" {
		return e, errors.New("missing type")
	}
	return e, nil
}

// Unmarshal decodes an envelope payload into v. A nil/absent payload is treated
// as {} so that types with no required fields decode cleanly.
func Unmarshal(e Envelope, v any) error {
	if len(e.Payload) == 0 {
		return json.Unmarshal([]byte(`{}`), v)
	}
	return json.Unmarshal(e.Payload, v)
}

// ValidDeviceID reports whether s is exactly 9 ASCII digits.
func ValidDeviceID(s string) bool {
	if len(s) != 9 {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}
