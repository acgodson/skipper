// Command gen emits the cross-implementation wire vectors.
// Regenerate with: go run ./vectors -out vectors/vectors.json -signing-out vectors/signing-vectors.json
package main

import (
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"os"

	p "rcprotocol"
)

type Case struct {
	Name    string          `json:"name"`
	Surface string          `json:"surface"` // signaling | ctrl | hi
	Type    string          `json:"type"`
	Frame   json.RawMessage `json:"frame"`
	Note    string          `json:"note,omitempty"`
}

type File struct {
	Version int    `json:"version"`
	Cases   []Case `json:"cases"`
}

var cases []Case

func add(name, surface, msgType, note string, id, re string, ts int64, payload any) {
	b, err := p.Encode(msgType, id, re, ts, payload)
	if err != nil {
		panic(err)
	}
	cases = append(cases, Case{name, surface, msgType, json.RawMessage(b), note})
}

func main() {
	out := flag.String("out", "vectors/vectors.json", "output path")
	signingOut := flag.String("signing-out", "vectors/signing-vectors.json", "signing-message vectors output path")
	flag.Parse()

	const ts = int64(1755600000000)

	const hostPubkey = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEuBGGi2DgfaFZytt5/esidQP3Qd3pzdIUC2MN8/OzOl+mubtCml0DONiJGrtUrhqnO7XcFGUDx/gNpT3TdtsLuA=="
	const controllerPubkey = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEb/A7lJJBzh2t1DUZ5pYOCoW0GmmgXDKBA6orzhWUyhY8T3U6Vb8B3FP2wLDH7ueLQMb/fSWpbiKCuYnO9xwUSg=="
	const signedFP = "sha-256 7B:8C:1D:4F:2A:90:33:AE:BB:01:5C:6D:77:E8:99:0A:1B:2C:3D:4E:5F:60:71:82:93:A4:B5:C6:D7:E8:F9:0A"
	const signedOffer = "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=fingerprint:" + signedFP + "\r\na=setup:actpass\r\n"

	recCode := p.CodeVerifier{
		Alg: p.AlgArgon2id, Salt: "c2FsdHNhbHRzYWx0c2FsdA==",
		Hash: "aGFzaGhhc2hoYXNoaGFzaGhhc2hoYXNoaGFzaGhhc2g=",
		Time: 3, MemKiB: 65536, Par: 1, Len: 32,
	}

	add("challenge", "signaling", p.TypeChallenge, "", "", "", ts,
		p.Challenge{Nonce: "bm9uY2Vub25jZW5vbmNlbm9uY2Vub25jZW5vbg==", ServerTime: ts})

	add("register_full", "signaling", p.TypeRegister, "", "c-1", "", ts,
		p.Register{Pubkey: "cHVia2V5", Sig: "c2ln", Label: "Studio PC", Code: recCode})

	add("register_no_label", "signaling", p.TypeRegister,
		"label is omitempty: it must be absent, not an empty string", "c-2", "", ts,
		p.Register{Pubkey: "cHVia2V5", Sig: "c2ln", Code: recCode})

	add("register_ok_existing", "signaling", p.TypeRegisterOK, "", "", "c-1", ts,
		p.RegisterOK{DeviceID: "481930275", Existing: true})

	add("register_ok_leading_zero", "signaling", p.TypeRegisterOK,
		"deviceId keeps leading zeros; it is a string, never a number", "", "c-1", ts,
		p.RegisterOK{DeviceID: "000000042", Existing: false})

	add("hello_host", "signaling", p.TypeHello, "", "c-3", "", ts,
		p.Hello{DeviceID: "481930275", Pubkey: "cHVia2V5", Sig: "c2ln", Role: p.RoleHost})

	add("hello_ok_with_active_session", "signaling", p.TypeHelloOK,
		"activeSessionId present: the server has a session this client holds no token for", "", "c-3", ts,
		p.HelloOK{
			DeviceID: "481930275", ServerTime: ts,
			ICEServers: []p.ICEServer{
				{URLs: []string{"stun:54.246.73.81:3478"}},
				{URLs: []string{"turn:54.246.73.81:3478?transport=udp"},
					Username: "1755600000:rc", Credential: "Y3JlZA==", ExpiresAt: ts + 43200000},
			},
			HeartbeatSec: 15, OfflineAfterSec: 40, SessionTokenTTLSec: 600,
			ActiveSessionID: "8c7f1a2b3c4d5e6f708192a3b4c5d6e7",
		})

	add("hello_ok_no_active_session", "signaling", p.TypeHelloOK,
		"activeSessionId omitempty; iceServers may be empty", "", "c-3", ts,
		p.HelloOK{DeviceID: "481930275", ServerTime: ts, HeartbeatSec: 15,
			OfflineAfterSec: 40, SessionTokenTTLSec: 600})

	add("heartbeat", "signaling", p.TypeHeartbeat,
		"no fields: payload must be {} and never null", "c-4", "", ts, p.Heartbeat{})

	add("heartbeat_ok", "signaling", p.TypeHeartbeatOK, "", "", "c-4", ts,
		p.HeartbeatOK{ServerTime: ts})

	add("watch", "signaling", p.TypeWatch, "", "c-5", "", ts, p.Watch{DeviceID: "739000587"})
	add("watch_ok", "signaling", p.TypeWatchOK, "", "", "c-5", ts, p.WatchOK{DeviceID: "739000587"})
	add("unwatch", "signaling", p.TypeUnwatch, "", "c-6", "", ts, p.Unwatch{DeviceID: "739000587"})
	add("unwatch_ok", "signaling", p.TypeUnwatchOK, "", "", "c-6", ts, p.UnwatchOK{DeviceID: "739000587"})

	add("presence_online", "signaling", p.TypePresence, "", "", "", ts,
		p.Presence{DeviceID: "739000587", Online: true, Since: ts - 90000})
	add("presence_never_seen", "signaling", p.TypePresence,
		"since is 0 when never seen, and 0 is NOT omitempty on this type", "", "", ts,
		p.Presence{DeviceID: "739000587", Online: false, Since: 0})

	add("connect_req", "signaling", p.TypeConnectReq,
		"v1: carries the plaintext access code; never log this frame", "c-7", "", ts,
		p.ConnectReq{DeviceID: "739000587", AccessCode: "K7M2QX9P"})

	add("connect_req_v2_no_access_code", "signaling", p.TypeConnectReq,
		"v2: only deviceId; accessCode is omitempty and must be absent, not empty", "c-7", "", ts,
		p.ConnectReq{DeviceID: "739000587"})

	add("connect_ok", "signaling", p.TypeConnectOK,
		"hostPubkey is what the controller requires on the host's signed sdp", "", "c-7", ts,
		p.ConnectOK{
			SessionID: "8c7f1a2b3c4d5e6f708192a3b4c5d6e7", SessionToken: "dG9rZW4=",
			ExpiresAt: ts + 600000, TTLSec: 600,
			HostDeviceID: "739000587", ControllerDeviceID: "481930275",
			HostPubkey: hostPubkey,
		})

	add("connect_ok_no_host_pubkey", "signaling", p.TypeConnectOK,
		"hostPubkey is omitempty: absent, never an empty string", "", "c-7", ts,
		p.ConnectOK{
			SessionID: "8c7f1a2b3c4d5e6f708192a3b4c5d6e7", SessionToken: "dG9rZW4=",
			ExpiresAt: ts + 600000, TTLSec: 600,
			HostDeviceID: "739000587", ControllerDeviceID: "481930275",
		})

	add("session_start", "signaling", p.TypeSessionStart,
		"connect_ok plus controllerPubkey, which the host keys its guess policy on", "", "", ts,
		p.SessionStart{
			ConnectOK: p.ConnectOK{
				SessionID: "8c7f1a2b3c4d5e6f708192a3b4c5d6e7", SessionToken: "dG9rZW4y",
				ExpiresAt: ts + 600000, TTLSec: 600,
				HostDeviceID: "739000587", ControllerDeviceID: "481930275",
				HostPubkey: hostPubkey,
			},
			ControllerPubkey: controllerPubkey,
		})

	add("session_start_no_controller_pubkey", "signaling", p.TypeSessionStart,
		"controllerPubkey is omitempty: absent, never an empty string", "", "", ts,
		p.SessionStart{
			ConnectOK: p.ConnectOK{
				SessionID: "8c7f1a2b3c4d5e6f708192a3b4c5d6e7", SessionToken: "dG9rZW4y",
				ExpiresAt: ts + 600000, TTLSec: 600,
				HostDeviceID: "739000587", ControllerDeviceID: "481930275",
			},
		})

	add("resume", "signaling", p.TypeResume, "", "c-8", "", ts,
		p.Resume{SessionID: "8c7f1a2b3c4d5e6f708192a3b4c5d6e7", SessionToken: "dG9rZW4="})
	add("resume_ok", "signaling", p.TypeResumeOK, "token is rotated; the old one is dead", "", "c-8", ts,
		p.ResumeOK{SessionID: "8c7f1a2b3c4d5e6f708192a3b4c5d6e7", SessionToken: "bmV3dG9rZW4=",
			ExpiresAt: ts + 600000, TTLSec: 600, PeerAttached: true, Role: p.RoleController})

	add("renew", "signaling", p.TypeRenew, "", "c-9", "", ts,
		p.Renew{SessionID: "8c7f1a2b3c4d5e6f708192a3b4c5d6e7", SessionToken: "bmV3dG9rZW4="})
	add("renew_ok", "signaling", p.TypeRenewOK, "", "", "c-9", ts,
		p.RenewOK{SessionID: "8c7f1a2b3c4d5e6f708192a3b4c5d6e7", SessionToken: "bmV3ZXI=",
			ExpiresAt: ts + 600000, TTLSec: 600})

	add("peer_state_attached", "signaling", p.TypePeerState, "", "", "", ts,
		p.PeerState{SessionID: "8c7f1a2b3c4d5e6f708192a3b4c5d6e7", Attached: true})
	add("peer_state_detached", "signaling", p.TypePeerState,
		"attached:false must be present, not omitted", "", "", ts,
		p.PeerState{SessionID: "8c7f1a2b3c4d5e6f708192a3b4c5d6e7", Attached: false})

	add("sdp_offer", "signaling", p.TypeSDP,
		"fp, pubkey, sig and (v3) mac bind the DTLS fingerprints to the device key and the PAKE; the server relays them unchecked",
		"", "", ts,
		p.SDP{SessionID: "8c7f1a2b3c4d5e6f708192a3b4c5d6e7", SDPType: "offer",
			SDP: signedOffer, FP: signedFP, Pubkey: controllerPubkey, Sig: "c2lnbmF0dXJl",
			MAC: "bWFjbWFjbWFjbWFjbWFjbWFjbWFjbWFjbWFjbWFjbWE="})
	add("sdp_restart", "signaling", p.TypeSDP, "restart is omitempty when false", "", "", ts,
		p.SDP{SessionID: "8c7f1a2b3c4d5e6f708192a3b4c5d6e7", SDPType: "offer",
			SDP: "v=0\r\n", Restart: true})
	add("sdp_two_fingerprints", "signaling", p.TypeSDP,
		"several fingerprints are sorted and joined with a newline", "", "", ts,
		p.SDP{SessionID: "8c7f1a2b3c4d5e6f708192a3b4c5d6e7", SDPType: "answer",
			SDP: "v=0\r\n", FP: "sha-256 AA:01\nsha-256 BB:02",
			Pubkey: hostPubkey, Sig: "c2lnbmF0dXJl", MAC: "bWFj"})

	add("ice_candidate", "signaling", p.TypeICE, "", "", "", ts,
		p.ICE{SessionID: "8c7f1a2b3c4d5e6f708192a3b4c5d6e7",
			Candidate: "candidate:1 1 udp 2130706431 192.0.2.1 54321 typ host",
			SDPMid:    "0", SDPMLineIndex: 0})
	add("ice_end_of_candidates", "signaling", p.TypeICE,
		"empty candidate means end-of-candidates", "", "", ts,
		p.ICE{SessionID: "8c7f1a2b3c4d5e6f708192a3b4c5d6e7", Candidate: ""})

	add("bye", "signaling", p.TypeBye, "", "", "", ts,
		p.Bye{SessionID: "8c7f1a2b3c4d5e6f708192a3b4c5d6e7", Reason: p.ByeUserEnded})
	add("bye_peer_auth_failed", "signaling", p.TypeBye,
		"the peer's signed SDP fingerprints did not verify", "", "", ts,
		p.Bye{SessionID: "8c7f1a2b3c4d5e6f708192a3b4c5d6e7", Reason: p.ByePeerAuthFailed})
	add("bye_auth_failed", "signaling", p.TypeBye,
		"the host refused the access code, or refused to try one from a locked-out controller",
		"", "", ts,
		p.Bye{SessionID: "8c7f1a2b3c4d5e6f708192a3b4c5d6e7", Reason: p.ByeAuthFailed})

	add("pake_step1", "signaling", p.TypePake,
		"v2: opaque to the server, relayed verbatim like sdp and ice", "", "", ts,
		p.Pake{SessionID: "8c7f1a2b3c4d5e6f708192a3b4c5d6e7", Step: 1, Payload: "cGFrZXN0ZXAx"})
	add("pake_step2", "signaling", p.TypePake, "", "", "", ts,
		p.Pake{SessionID: "8c7f1a2b3c4d5e6f708192a3b4c5d6e7", Step: 2, Payload: "cGFrZXN0ZXAy"})
	add("pake_step3", "signaling", p.TypePake, "the controller's confirmation ends the exchange",
		"", "", ts,
		p.Pake{SessionID: "8c7f1a2b3c4d5e6f708192a3b4c5d6e7", Step: 3, Payload: "cGFrZXN0ZXAz"})

	add("refresh_code", "signaling", p.TypeRefreshCode, "", "c-10", "", ts, p.RefreshCode(recCode))
	add("refresh_code_ok", "signaling", p.TypeRefreshCodeOK, "", "", "c-10", ts,
		p.RefreshCodeOK{DeviceID: "739000587", UpdatedAt: ts})

	add("error_bad_code", "signaling", p.TypeError, "", "", "c-7", ts,
		p.Error{Code: p.ErrBadCode, Message: "access code rejected"})
	add("error_rate_limited", "signaling", p.TypeError, "retryAfterSec present only here", "", "c-7", ts,
		p.Error{Code: p.ErrRateLimited, Message: "too many attempts", RetryAfterSec: 30})
	add("error_busy", "signaling", p.TypeError, "", "", "c-7", ts,
		p.Error{Code: p.ErrBusy, Message: "device already has a remote session"})
	add("error_entitlement", "signaling", p.TypeError,
		"v2: reason is present only on the entitlement code", "", "c-7", ts,
		p.Error{Code: p.ErrEntitlement, Message: "trial has ended",
			Reason: p.EntitlementTrialExpired})

	add("mouse_down_left", "ctrl", p.CtrlMouseDown, "", "", "", ts,
		p.MouseEvent{Button: p.ButtonLeft, X: 0.5, Y: 0.5})
	add("mouse_up_right", "ctrl", p.CtrlMouseUp, "", "", "", ts,
		p.MouseEvent{Button: p.ButtonRight, X: 0, Y: 0})
	add("mouse_drag_middle", "ctrl", p.CtrlMouseDrag,
		"reliable on purpose: a dropped drag point visibly breaks window dragging", "", "", ts,
		p.MouseEvent{Button: p.ButtonMiddle, X: 1, Y: 1})
	add("click_double", "ctrl", p.CtrlClick, "", "", "", ts,
		p.Click{Button: p.ButtonLeft, X: 0.25, Y: 0.75, Count: 2})

	add("key_down_cmd_c", "ctrl", p.CtrlKeyDown,
		"kVK_ANSI_C with Command; the chars field is absent for a shortcut", "", "", ts,
		p.KeyEvent{Keycode: 8, Mods: p.ModCommand})
	add("key_down_with_chars", "ctrl", p.CtrlKeyDown,
		"chars present: a host may inject the text and ignore the macOS keycode", "", "", ts,
		p.KeyEvent{Keycode: 0, Mods: 0, Chars: "a"})
	add("key_down_unicode_chars", "ctrl", p.CtrlKeyDown,
		"chars is arbitrary UTF-8, not ASCII", "", "", ts,
		p.KeyEvent{Keycode: 0, Mods: p.ModShift, Chars: "é中\U0001f600"})
	add("key_down_all_mods", "ctrl", p.CtrlKeyDown, "every defined modifier bit set", "", "", ts,
		p.KeyEvent{Keycode: 49, Mods: p.ModShift | p.ModControl | p.ModOption |
			p.ModCommand | p.ModCapsLock | p.ModFn})
	add("key_up", "ctrl", p.CtrlKeyUp, "", "", "", ts, p.KeyEvent{Keycode: 8, Mods: 0})

	add("scroll_natural_down", "ctrl", p.CtrlScroll,
		"positive dy = content moves up (macOS natural); Windows wheel is inverted", "", "", ts,
		p.Scroll{DX: 0, DY: 12.5, Phase: p.PhaseChanged})
	add("scroll_negative_fractional", "ctrl", p.CtrlScroll,
		"sub-pixel deltas must not be truncated to zero by a notch-based host", "", "", ts,
		p.Scroll{DX: -0.5, DY: -0.25, Phase: p.PhaseMomentum})
	add("scroll_begin", "ctrl", p.CtrlScroll, "", "", "", ts,
		p.Scroll{DX: 0, DY: 0, Phase: p.PhaseBegin})

	add("clipboard_text", "ctrl", p.CtrlClipboardText, "contents are never logged", "", "", ts,
		p.ClipboardText{Text: "hello 世界", OriginID: "481930275",
			Hash: "MHhoYXNo"})

	for _, g := range []string{
		p.GestureMissionControl, p.GestureAppExpose, p.GestureShowDesktop,
		p.GestureLaunchpad, p.GestureSpotlight, p.GestureAppSwitcher,
		p.GestureScreenshotRegion, p.GestureForceQuit, p.GestureLockScreen,
	} {
		add("gesture_"+g, "ctrl", p.CtrlGesture, "", "", "", ts, p.Gesture{Name: g})
	}

	add("input_reset", "ctrl", p.CtrlInputReset,
		"no fields; must be idempotent on the receiver", "", "", ts, p.InputReset{})

	add("display_info_retina", "ctrl", p.CtrlDisplayInfo, "", "", "", ts,
		p.DisplayInfo{W: 1920, H: 1200, Scale: 2})
	add("display_info_scale_one", "ctrl", p.CtrlDisplayInfo,
		"a non-Retina host; scale 1 is present, not omitted", "", "", ts,
		p.DisplayInfo{W: 2560, H: 1440, Scale: 1})
	add("display_info_windows", "ctrl", p.CtrlDisplayInfo,
		"os field present; a controller that predates it must ignore it, not fail", "", "", ts,
		p.DisplayInfo{W: 2560, H: 1440, Scale: 1, OS: p.OSWindows})
	add("display_info_os_absent_means_macos", "ctrl", p.CtrlDisplayInfo,
		"os is omitempty; absent is the macOS default", "", "", ts,
		p.DisplayInfo{W: 1920, H: 1200, Scale: 2, OS: ""})

	add("quality_auto", "ctrl", p.CtrlQuality, "", "", "", ts, p.Quality{Mode: p.QualityAuto})
	add("quality_sharp", "ctrl", p.CtrlQuality, "", "", "", ts, p.Quality{Mode: p.QualitySharp})
	add("quality_smooth", "ctrl", p.CtrlQuality, "", "", "", ts, p.Quality{Mode: p.QualitySmooth})

	add("ping", "ctrl", p.CtrlPing, "", "", "", ts, p.Ping{T: ts})
	add("pong", "ctrl", p.CtrlPong, "echoes ping.t verbatim", "", "", ts, p.Pong{T: ts})
	add("session_close", "ctrl", p.CtrlSessionClose, "", "", "", ts,
		p.SessionClose{Reason: p.ByeHostEnded})

	for _, shape := range p.CursorShapes {
		add("cursor_shape_"+shape, "ctrl", p.CtrlCursorShape, "host -> controller, sent on change only", "", "", ts,
			p.CursorShape{Shape: shape})
	}

	add("mouse_move", "hi", p.HiMouseMove,
		"receiver must drop any packet whose seq is <= the highest already seen", "", "", ts,
		p.MouseMove{X: 0.123456789, Y: 0.987654321, Seq: 1})
	add("mouse_move_large_seq", "hi", p.HiMouseMove,
		"seq is int64 and must not be narrowed to 32 bits", "", "", ts,
		p.MouseMove{X: 0.5, Y: 0.5, Seq: 9007199254740993})

	write(*out, File{Version: p.Version, Cases: cases})
	fmt.Fprintf(os.Stderr, "wrote %d cases to %s\n", len(cases), *out)
	signing := signingCases()
	write(*signingOut, SigningFile{Version: p.Version, Note: signingNote, Cases: signing})
	fmt.Fprintf(os.Stderr, "wrote %d cases to %s\n", len(signing), *signingOut)
}

func write(path string, v any) {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		panic(err)
	}
	b = append(b, '\n')
	if err := os.WriteFile(path, b, 0o644); err != nil {
		panic(err)
	}
}

type SigningCase struct {
	Name       string `json:"name"`
	Purpose    string `json:"purpose"`
	PayloadHex string `json:"payloadHex"`
	MessageHex string `json:"messageHex,omitempty"`
	Valid      bool   `json:"valid"`
	Note       string `json:"note,omitempty"`
}

type SigningFile struct {
	Version int           `json:"version"`
	Note    string        `json:"note"`
	Cases   []SigningCase `json:"cases"`
}

const signingNote = "Device-key signing messages, PROTOCOL.md 3.1: \"skipperdesk/\" purpose \"/v1|\" followed by the payload. valid=false means every implementation must refuse to build the message."

func signingCases() []SigningCase {
	nonce := make([]byte, p.NonceLen)
	for i := range nonce {
		nonce[i] = byte(i)
	}
	sdp := []byte("8c7f1a2b3c4d5e6f708192a3b4c5d6e7|offer|sha-256 7B:8C")
	one := func(name string, purpose p.SigningPurpose, payload []byte, note string) SigningCase {
		c := SigningCase{Name: name, Purpose: string(purpose), PayloadHex: hex.EncodeToString(payload), Note: note}
		if message, err := p.SigningMessage(purpose, payload); err == nil {
			c.Valid, c.MessageHex = true, hex.EncodeToString(message)
		}
		return c
	}
	return []SigningCase{
		one("hello", p.PurposeHello, nonce, "the challenge nonce's raw bytes"),
		one("register", p.PurposeRegister, nonce, ""),
		one("api_challenge", p.PurposeAPIChallenge, nonce, "API.md device challenge"),
		one("sdp", p.PurposeSDP, sdp, "payload is sessionId|sdpType|fp; the message is what sdp.sig signs and sdp.mac MACs"),
		one("hello_short_nonce", p.PurposeHello, nonce[:31], "refused: a nonce is exactly 32 bytes"),
		one("register_long_nonce", p.PurposeRegister, append(append([]byte{}, nonce...), 0), "refused"),
		one("hello_sdp_shaped_nonce", p.PurposeHello, append([]byte("skipperdesk/sdp/v1|"), sdp...),
			"refused: a server cannot pass an sdp message off as a nonce"),
		one("sdp_empty", p.PurposeSDP, nil, "refused"),
	}
}
