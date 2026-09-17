// Package protocol is the Go side of the RemoteControl wire contract.
// It mirrors PROTOCOL.md exactly.
package protocol

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"unicode"
	"unicode/utf8"
)

// Version is the only protocol version this build speaks.
const Version = 5

const (
	HeartbeatSec       = 15
	OfflineAfterSec    = 40
	SessionTokenTTLSec = 600
	PendingTimeoutSec  = 30
	MaxFrameBytes      = 256 * 1024
	AuthTimeoutSec     = 20
	NonceTTLSec        = 20
	MaxWatches         = 8
	TurnCredTTLSec     = 10 * 60
)

// Signaling rate limits (PROTOCOL.md §3.3); exceeding one answers error{rate_limited, retryAfterSec}.
const (
	ConnectPerControllerPerMin  = 6
	ConnectPerControllerPerHour = 60
	ConnectPerHostPerMin        = 30
	ConnectPerHostPerHour       = 300
	ConnectPerPairPerMin        = 6
	ConnectPerPairPerHour       = 60
	ConnectPerIPPerMin          = 30
	RegistersPerSocket          = 1
	RegistersPerIPPerHour       = 20
)

// Envelope wraps every message on every surface.
type Envelope struct {
	V       int             `json:"v"`
	Type    string          `json:"type"`
	ID      string          `json:"id,omitempty"`
	Re      string          `json:"re,omitempty"`
	TS      int64           `json:"ts,omitempty"`
	Payload json.RawMessage `json:"payload"`
}

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
	TypeICEServers    = "ice_servers"
	TypeError         = "error"
)

const (
	RoleHost       = "host"
	RoleController = "controller"
)

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
	ErrUnavailable        = "unavailable"
)

const (
	EntitlementUnlinked     = "unlinked"
	EntitlementTrialExpired = "trial_expired"
	EntitlementNoBalance    = "no_balance"
	EntitlementConcurrency  = "concurrency"
	EntitlementSuspended    = "suspended"
)

const (
	ByeUserEnded      = "user_ended"
	ByeHostEnded      = "host_ended"
	ByeTimeout        = "timeout"
	ByeFailed         = "failed"
	ByeCodeRefreshed  = "code_refreshed"
	ByeReplaced       = "replaced"
	ByeShutdown       = "shutdown"
	ByeError          = "error"
	ByePeerAuthFailed = "peer_auth_failed"
	ByeAuthFailed     = "auth_failed"
	ByeDeclined       = "declined"
	ByeDisplaced      = "displaced"
)

// ByeReasons is the closed §2.14 set; the server refuses any other bye reason and never relays it.
var ByeReasons = []string{
	ByeUserEnded, ByeHostEnded, ByeTimeout, ByeFailed, ByeCodeRefreshed, ByeReplaced,
	ByeShutdown, ByeError, ByePeerAuthFailed, ByeAuthFailed, ByeDeclined, ByeDisplaced,
}

func ValidByeReason(reason string) bool {
	for _, known := range ByeReasons {
		if reason == known {
			return true
		}
	}
	return false
}

const (
	SessionPending  = "pending"
	SessionOpen     = "open"
	SessionHalfOpen = "half_open"
	SessionOrphaned = "orphaned"
	SessionClosed   = "closed"
)

// Challenge is pushed by the server on connect and after register_ok.
type Challenge struct {
	Nonce      string `json:"nonce"`      // base64, 32 random bytes
	ServerTime int64  `json:"serverTime"` // unix ms
}

// CodeVerifier is the Argon2id verifier for an access code; the plaintext code must never be stored server-side.
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
// PreferredDeviceID is honoured only together with an IDCert the registry issued for that id and this pubkey.
type Register struct {
	Pubkey            string       `json:"pubkey"` // canonical std base64 of a DER SPKI P-256 key
	Sig               string       `json:"sig"`    // base64 DER ECDSA-SHA256 over SigningMessage(PurposeRegister, nonce)
	Label             string       `json:"label,omitempty"`
	PreferredDeviceID string       `json:"preferredDeviceId,omitempty"`
	IDCert            string       `json:"idCert,omitempty"`
	Code              CodeVerifier `json:"code"`
}

// RegisterOK.IDCert is the registry's signature over DeviceIDCertMessage; clients store it and never interpret it.
type RegisterOK struct {
	DeviceID string `json:"deviceId"`
	Existing bool   `json:"existing"`
	IDCert   string `json:"idCert"`
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

// HelloOK.ICEServers never carries credentials; TURN arrives per metered session in ice_servers and renew_ok.
type HelloOK struct {
	DeviceID           string      `json:"deviceId"`
	ServerTime         int64       `json:"serverTime"`
	ICEServers         []ICEServer `json:"iceServers"`
	HeartbeatSec       int         `json:"heartbeatSec"`
	OfflineAfterSec    int         `json:"offlineAfterSec"`
	SessionTokenTTLSec int         `json:"sessionTokenTtlSec"`
	ActiveSessionID    string      `json:"activeSessionId,omitempty"`
	IDCert             string      `json:"idCert,omitempty"`
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
	// HostPubkey is the host's registered pubkey, base64 DER SPKI; it is public material, not a secret.
	HostPubkey string `json:"hostPubkey,omitempty"`
	// ICEServers is STUN only; TURN for the session arrives in ice_servers once it is metered.
	ICEServers []ICEServer `json:"iceServers,omitempty"`
}

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

// RenewOK.ICEServers is present only for a metered session and then carries fresh TURN credentials.
type RenewOK struct {
	SessionID    string      `json:"sessionId"`
	SessionToken string      `json:"sessionToken"`
	ExpiresAt    int64       `json:"expiresAt"`
	TTLSec       int         `json:"ttlSec"`
	ICEServers   []ICEServer `json:"iceServers,omitempty"`
}

// ICEServers is pushed to both peers when a session becomes metered: the complete list, TURN included.
type ICEServers struct {
	SessionID  string      `json:"sessionId"`
	ICEServers []ICEServer `json:"iceServers"`
}

type PeerState struct {
	SessionID string `json:"sessionId"`
	Attached  bool   `json:"attached"`
}

type Bye struct {
	SessionID string `json:"sessionId"`
	Reason    string `json:"reason"`
}

// RefreshCode replaces the calling device's access-code verifier and kills all of its sessions and tokens.
type RefreshCode CodeVerifier

type RefreshCodeOK struct {
	DeviceID  string `json:"deviceId"`
	UpdatedAt int64  `json:"updatedAt"`
}

type Error struct {
	Code          string `json:"code"`
	Message       string `json:"message"`
	RetryAfterSec int    `json:"retryAfterSec,omitempty"`
	Reason        string `json:"reason,omitempty"`
}

func (e Error) Error() string { return e.Code + ": " + e.Message }

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
	CtrlCursorShape   = "cursor_shape"

	HiMouseMove = "mouse_move"
)

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

const (
	PhaseBegin    = "begin"
	PhaseChanged  = "changed"
	PhaseEnd      = "end"
	PhaseMomentum = "momentum"
)

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

const (
	CursorArrow          = "arrow"
	CursorIBeam          = "ibeam"
	CursorCrosshair      = "crosshair"
	CursorPointingHand   = "pointing_hand"
	CursorOpenHand       = "open_hand"
	CursorClosedHand     = "closed_hand"
	CursorResizeLR       = "resize_lr"
	CursorResizeUD       = "resize_ud"
	CursorResizeDiagNESW = "resize_diag_nesw"
	CursorResizeDiagNWSE = "resize_diag_nwse"
	CursorNotAllowed     = "not_allowed"
	CursorBusy           = "busy"
)

// CursorShapes lists every defined cursor_shape value; receivers draw anything else as CursorArrow.
var CursorShapes = []string{
	CursorArrow, CursorIBeam, CursorCrosshair, CursorPointingHand, CursorOpenHand,
	CursorClosedHand, CursorResizeLR, CursorResizeUD, CursorResizeDiagNESW,
	CursorResizeDiagNWSE, CursorNotAllowed, CursorBusy,
}

const (
	QualityAuto   = "auto"
	QualitySharp  = "sharp"
	QualitySmooth = "smooth"
)

// MouseEvent: X and Y are normalised 0..1 doubles; receivers must clamp.
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
	OriginID string `json:"originId"`
	Hash     string `json:"hash"` // base64 SHA-256 of Text; echo-loop guard
}

type Gesture struct {
	Name string `json:"name"`
}

type InputReset struct{}

type DisplayInfo struct {
	W     int     `json:"w"`
	H     int     `json:"h"`
	Scale float64 `json:"scale"`
	// OS is OSMacOS or OSWindows; an absent value means macOS.
	OS string `json:"os,omitempty"`
}

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

type CursorShape struct {
	Shape string `json:"shape"`
}

type SessionClose struct {
	Reason string `json:"reason"`
}

// MouseMove: receivers must drop any packet whose Seq is <= the highest already seen.
type MouseMove struct {
	X   float64 `json:"x"`
	Y   float64 `json:"y"`
	Seq int64   `json:"seq"`
}

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

func Unmarshal(e Envelope, v any) error {
	if len(e.Payload) == 0 {
		return json.Unmarshal([]byte(`{}`), v)
	}
	return json.Unmarshal(e.Payload, v)
}

// ValidSessionID reports whether s is exactly 32 lowercase hex characters.
func ValidSessionID(s string) bool {
	if len(s) != 32 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

// TrimLabel drops control characters and invalid UTF-8 and cuts s to MaxLabelLen bytes on a rune boundary.
func TrimLabel(s string) string {
	s = strings.TrimSpace(strings.ToValidUTF8(s, ""))
	var b strings.Builder
	for _, r := range s {
		if unicode.IsControl(r) {
			continue
		}
		if b.Len()+utf8.RuneLen(r) > MaxLabelLen {
			break
		}
		b.WriteRune(r)
	}
	return strings.TrimSpace(b.String())
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
