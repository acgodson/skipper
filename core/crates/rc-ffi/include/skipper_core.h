/*
 * skipper_core.h — the C ABI of the shared session state machine (PROTOCOL.md §4).
 *
 * Hand-written on purpose: this file IS the contract, so it is reviewed rather
 * than generated. It must stay in step with core/crates/rc-ffi/src/lib.rs.
 *
 * Lifetime
 *   skipper_session_new  returns an opaque handle, or NULL if allocation failed.
 *   skipper_session_free releases it. The handle is NOT thread-safe: it carries
 *   no lock and holds no global state, so the caller owns the serialisation.
 *
 * Results
 *   Every call below returns a NUL-terminated UTF-8 JSON string that the caller
 *   must release with skipper_string_free. A NULL return means the result could
 *   not even be allocated. The JSON has exactly one shape:
 *
 *     {
 *       "ok": true,
 *       "actions": [ { "action": "<name>", ...fields } ],
 *       "state": {
 *         "role":                     "host" | "controller",
 *         "phase":                    "idle" | "connecting" | "live"
 *                                     | "reconnecting" | "closed",
 *         "closedReason":             string | null,
 *         "hasSession":               bool,
 *         "signalingUp":              bool,
 *         "resumeInFlight":           bool,
 *         "isOfferer":                bool,
 *         "iceState":                 "new" | "checking" | "connected"
 *                                     | "completed" | "disconnected"
 *                                     | "failed" | "closed",
 *         "sessionId":                string | null,
 *         "sessionToken":             string | null,
 *         "peerDeviceId":             string | null,
 *         "rememberedAccessCode":     string | null,
 *         "serverAdvertisedSessionId": string | null
 *       }
 *     }
 *
 *   or, for a rejected call (null handle, non-UTF-8 argument, unknown ICE state,
 *   a panic caught at the boundary):
 *
 *     { "ok": false, "error": "<message>" }
 *
 *   Action objects use the same names and fields as the shared vectors in
 *   protocol/vectors/session-scenarios.json:
 *
 *     {"action":"sendConnectReq","deviceId":S,"accessCode":S}
 *     {"action":"sendResume","sessionId":S,"sessionToken":S}
 *     {"action":"scheduleResume","afterSec":N}
 *     {"action":"sendRenew","sessionId":S,"sessionToken":S}
 *     {"action":"sendInputReset"}
 *     {"action":"startPeerConnection","offerer":B}
 *     {"action":"restartICE"}
 *     {"action":"reissueWatches"}
 *     {"action":"teardownPeerConnection"}
 *     {"action":"clearStoredSession"}
 *     {"action":"promptForAccessCode","reason":S}
 *     {"action":"sendBye","sessionId":S,"reason":S}
 *
 * Conventions
 *   Times are Unix milliseconds. String arguments are NUL-terminated UTF-8;
 *   those documented as nullable accept NULL, the rest reject it. No function
 *   here unwinds: a panic is caught and returned as an "ok": false result.
 */

#ifndef SKIPPER_CORE_H
#define SKIPPER_CORE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SKIPPER_ROLE_HOST 0
#define SKIPPER_ROLE_CONTROLLER 1

typedef struct SkipperSession SkipperSession;

SkipperSession *skipper_session_new(int32_t role,
                                    int64_t ice_restart_delay_ms,
                                    int64_t ice_failure_grace_ms,
                                    int64_t renew_interval_ms);

void skipper_session_free(SkipperSession *session);

void skipper_string_free(char *string);

/* Read-only snapshot; emits no actions. */
char *skipper_session_state(SkipperSession *session);

/* The user pressed Connect. */
char *skipper_session_connect_requested(SkipperSession *session,
                                        const char *device_id,
                                        const char *access_code,
                                        bool remember);

/* `connect_ok` (controller) or `session_start` (host). */
char *skipper_session_granted(SkipperSession *session,
                              const char *session_id,
                              const char *session_token,
                              const char *host_device_id,
                              const char *controller_device_id,
                              int64_t now_ms);

/* `error` in reply to `connect_req`. */
char *skipper_session_connect_failed(SkipperSession *session, const char *code);

/* The signaling socket dropped. */
char *skipper_session_signaling_lost(SkipperSession *session);

/* `hello_ok`. active_session_id is nullable. */
char *skipper_session_signaling_authenticated(SkipperSession *session,
                                              const char *active_session_id);

char *skipper_session_resume_succeeded(SkipperSession *session,
                                       const char *session_id,
                                       const char *session_token,
                                       int64_t now_ms);

char *skipper_session_resume_failed(SkipperSession *session,
                                    const char *code,
                                    int32_t retry_after_sec);

char *skipper_session_renew_succeeded(SkipperSession *session,
                                      const char *session_id,
                                      const char *session_token,
                                      int64_t now_ms);

char *skipper_session_renew_failed(SkipperSession *session, const char *code);

/* ice_state is one of the "iceState" strings listed above. */
char *skipper_session_ice_state_changed(SkipperSession *session,
                                        const char *ice_state,
                                        int64_t now_ms);

/* Drives the ICE-restart delay, the failure grace window and renew. */
char *skipper_session_tick(SkipperSession *session, int64_t now_ms);

/* A `bye` from the peer or the server, and a `refresh_code` that displaced the
 * session, both arrive here with the wire reason. */
char *skipper_session_close_locally(SkipperSession *session, const char *reason);

/* The local user pressed End Session. */
char *skipper_session_user_ended(SkipperSession *session, const char *reason);

/* The code the controller may silently reuse. NULL forgets it. */
char *skipper_session_set_remembered_access_code(SkipperSession *session,
                                                 const char *access_code);

/*
 * Access code and SPAKE2 exchange (PROTOCOL.md §2.17).
 *
 * The exchange handle carries the access code and the derived keys, so it is
 * freed as soon as the session key has been read; skipper_pake_free wipes both.
 * Results follow the conventions above — JSON released with
 * skipper_string_free, { "ok": false, "error": ... } for a rejected call — but
 * carry their own fields instead of "actions"/"state":
 *
 *   skipper_pake_step            { "ok":true,
 *                                  "outgoing": { "step":N, "payload":S } | null,
 *                                  "complete": B,
 *                                  "peerPubkey": S }   ("" until the peer's
 *                                                       first frame arrives)
 *   skipper_pake_session_key     { "ok":true, "sessionKey": S }   (base64, 32 bytes)
 *   skipper_pake_guess_policy_*  { "ok":true, "allowed":B, "retryAfterMs":N,
 *                                  "counter": { "failures":N,
 *                                               "lastFailureMs":N,
 *                                               "lockedUntilMs":N } }
 *   skipper_access_code_generate { "ok":true, "accessCode": S }
 *
 * The guess-policy calls are pure: the caller owns the counter, passes it back
 * as the JSON object it received (NULL or "" means a fresh one), and persists
 * whatever comes out, keyed by controller public key and session.
 */

typedef struct SkipperPake SkipperPake;

/* NULL when an argument is not usable: null, not UTF-8, an access code that is
 * empty once normalised, an empty device_id / session_id, or an own_pubkey that
 * is not base64 of a DER SPKI key.
 *
 * own_pubkey is THIS device's `pubkey`. It travels in this side's first frame
 * and is bound into the SPAKE2 transcript, so when the exchange completes each
 * side knows which device key must sign the peer's `sdp` fingerprints. */
SkipperPake *skipper_pake_new(int32_t role,
                              const char *access_code,
                              const char *device_id,
                              const char *session_id,
                              const char *own_pubkey);

void skipper_pake_free(SkipperPake *pake);

/* One turn of the exchange. The controller starts with step 0 and a NULL
 * payload; every other call passes the step and base64 payload that arrived in
 * the peer's `pake` frame. A wrong code surfaces here as an "ok": false result
 * whose error names the failed confirmation, and the handle refuses to
 * continue. */
char *skipper_pake_step(SkipperPake *pake, int32_t step, const char *payload_base64);

/* Only once "complete" was true. */
char *skipper_pake_session_key(SkipperPake *pake);

int32_t skipper_pake_max_payload_base64(void);

/* May this controller start another exchange? */
char *skipper_pake_guess_policy_check(const char *counter_json, int64_t now_ms);

/* The host rejected a confirmation, or the exchange completed. */
char *skipper_pake_guess_policy_record_failure(const char *counter_json, int64_t now_ms);
char *skipper_pake_guess_policy_record_success(const char *counter_json);

/* Twelve Crockford base32 symbols, 60 bits, from the OS CSPRNG. */
char *skipper_access_code_generate(void);

/*
 * Signed SDP fingerprints (PROTOCOL.md §2.12).
 *
 * A compromised signaling server relays `sdp`, so it could swap the DTLS
 * fingerprint for one of its own and terminate DTLS on both sides. Every `sdp`
 * therefore carries `fp`, `pubkey` and `sig`, and a receiver checks all three
 * before setRemoteDescription.
 *
 * Signing is NOT here: a Secure Enclave key can only be used by the platform.
 * The core builds the bytes and verifies what comes back. Results follow the
 * conventions above:
 *
 *   skipper_sdp_fingerprints     { "ok":true, "fp": S }
 *   skipper_sdp_signing_message  { "ok":true, "fp": S, "message": S }
 *                                  message is base64 of the bytes to sign with
 *                                  the device key (ECDSA-P256/SHA-256, DER).
 *   skipper_sdp_verify           { "ok":true, "verified": true }
 *                                  or { "ok":false, "error": ... } naming the
 *                                  check that failed.
 */

/* Every a=fingerprint value in the SDP, de-duplicated, sorted, joined with
 * "\n" — the wire `fp` field. */
char *skipper_sdp_fingerprints(const char *sdp);

/* `fp` plus the bytes to sign:
 * "skipperdesk/sdp/v1|" session_id "|" sdp_type "|" fp. */
char *skipper_sdp_signing_message(const char *session_id,
                                  const char *sdp_type,
                                  const char *sdp);

/* Checks, in order: `fp` is the fingerprint set actually in `sdp`, `pubkey` is
 * the expected peer (when expected_pubkey is given), and `sig` verifies. A NULL
 * or empty expected_pubkey means this side has not learned the peer's key yet,
 * and only the other two checks are made. */
char *skipper_sdp_verify(const char *session_id,
                         const char *sdp_type,
                         const char *sdp,
                         const char *fp,
                         const char *pubkey,
                         const char *sig,
                         const char *expected_pubkey);

#ifdef __cplusplus
}
#endif

#endif /* SKIPPER_CORE_H */
