/*
 * skipper_core.h — C ABI of the shared session state machine (PROTOCOL.md §4).
 * Must stay in step with core/crates/rc-ffi/src/lib.rs.
 *
 * skipper_session_new returns an opaque handle, or NULL on allocation failure;
 * skipper_session_free releases it. Not thread-safe: caller owns serialisation.
 *
 * Every call returns a NUL-terminated UTF-8 JSON string the caller must free
 * with skipper_string_free (NULL = allocation failed):
 *   { "ok": true, "actions": [{"action":"<name>",...fields}], "state": {
 *     "role":S, "phase":S, "closedReason":S|null, "hasSession":B,
 *     "signalingUp":B, "resumeInFlight":B, "relayOnly":B, "isOfferer":B,
 *     "iceState":S,
 *     "sessionId":S|null, "sessionToken":S|null, "peerDeviceId":S|null,
 *     "rememberedAccessCode":S|null, "serverAdvertisedSessionId":S|null,
 *     "consentRequired":B, "consentExpiresAtMs":N|null } }
 * or, rejected: { "ok": false, "error": "<message>", "kind"?: "<kind>" }.
 * Actions match protocol/vectors/session-scenarios.json; "phase" and
 * "iceState" match the SessionPhase/IceLinkState variant names, lowercased.
 *
 * Every text argument is a (pointer, length) pair of UTF-8 bytes; nothing is
 * read up to a terminator. The core refuses invalid UTF-8 and any NUL byte in
 * a value. A nullable text argument is NULL with length 0; any other pointer,
 * including one with length 0, is a present (possibly empty) value.
 * Times are Unix milliseconds. No function here unwinds a panic across the
 * boundary.
 */

#ifndef SKIPPER_CORE_H
#define SKIPPER_CORE_H

#include <stdbool.h>
#include <stddef.h>
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

char *skipper_session_state(SkipperSession *session);

char *skipper_session_connect_requested(SkipperSession *session,
                                        const uint8_t *device_id, size_t device_id_len,
                                        const uint8_t *access_code, size_t access_code_len,
                                        bool remember);

char *skipper_session_granted(SkipperSession *session,
                              const uint8_t *session_id, size_t session_id_len,
                              const uint8_t *session_token, size_t session_token_len,
                              const uint8_t *host_device_id, size_t host_device_id_len,
                              const uint8_t *controller_device_id,
                              size_t controller_device_id_len,
                              int64_t now_ms);

char *skipper_session_connect_failed(SkipperSession *session,
                                     const uint8_t *code, size_t code_len);

char *skipper_session_signaling_lost(SkipperSession *session);

/* active_session_id is nullable. */
char *skipper_session_signaling_authenticated(SkipperSession *session,
                                              const uint8_t *active_session_id,
                                              size_t active_session_id_len);

char *skipper_session_resume_succeeded(SkipperSession *session,
                                       const uint8_t *session_id, size_t session_id_len,
                                       const uint8_t *session_token, size_t session_token_len,
                                       int64_t now_ms);

char *skipper_session_resume_failed(SkipperSession *session,
                                    const uint8_t *code, size_t code_len,
                                    int32_t retry_after_sec);

char *skipper_session_renew_succeeded(SkipperSession *session,
                                      const uint8_t *session_id, size_t session_id_len,
                                      const uint8_t *session_token, size_t session_token_len,
                                      int64_t now_ms);

char *skipper_session_renew_failed(SkipperSession *session,
                                   const uint8_t *code, size_t code_len);

/* ice_state is one of the "iceState" strings above. */
char *skipper_session_ice_state_changed(SkipperSession *session,
                                        const uint8_t *ice_state, size_t ice_state_len,
                                        int64_t now_ms);

char *skipper_session_tick(SkipperSession *session, int64_t now_ms);

char *skipper_session_close_locally(SkipperSession *session,
                                    const uint8_t *reason, size_t reason_len);

char *skipper_session_user_ended(SkipperSession *session,
                                 const uint8_t *reason, size_t reason_len);

/*
 * A session that already runs on TURN relay only. The state machine never
 * asks for a relay-only ICE restart while this is true.
 */
char *skipper_session_set_relay_only(SkipperSession *session, bool relay_only);

/* NULL forgets the remembered access code. */
char *skipper_session_set_remembered_access_code(SkipperSession *session,
                                                 const uint8_t *access_code,
                                                 size_t access_code_len);

/*
 * Host consent (PROTOCOL.md §2.17 Consent). The peer connection starts only
 * after pake_succeeded. A host with consent_required enters "awaitingConsent"
 * instead and emits promptForConsent{"expiresAtMs":N}; consent_answered or the
 * 30 s tick timeout leaves it with dismissConsentPrompt{"outcome":S}, S one of
 * "allowed", "declined", "timedOut", "cancelled". Declined and timed out end
 * the session with bye{declined}. Either side whose peer connection has not
 * come up 45 s after it started ends the session with bye{timeout}.
 */
char *skipper_session_pake_succeeded(SkipperSession *session, int64_t now_ms);

char *skipper_session_consent_answered(SkipperSession *session, bool allow, int64_t now_ms);

char *skipper_session_set_consent_required(SkipperSession *session, bool consent_required);

/*
 * The host's per-controller consent ledger. Pure, like guess_*: pass back the
 * ledger JSON received (NULL/"" for a fresh one) and persist what comes out.
 *   "prompt":B, "retryAfterMs":N, "ledger":{"declineTimesMs":[N]}
 * "prompt" is false while the controller has two declines inside 10 minutes:
 * the host then declines without asking.
 */
char *skipper_consent_admit(const uint8_t *ledger_json, size_t ledger_json_len, int64_t now_ms);

char *skipper_consent_declined(const uint8_t *ledger_json, size_t ledger_json_len,
                               int64_t now_ms);

char *skipper_consent_allowed(const uint8_t *ledger_json, size_t ledger_json_len,
                              int64_t now_ms);

/*
 * Domain-separated device-key signatures (PROTOCOL.md §3.1). A device key
 * signs only bytes this core built: "skipperdesk/<purpose>/v1|" ‖ payload.
 *   signing_message: "message":S (base64 of the exact bytes to sign)
 * The nonce purposes require a payload of exactly 32 bytes. The sdp purpose is
 * refused here: its message comes only from skipper_sdp_signing_message.
 */

#define SKIPPER_SIGN_HELLO 0
#define SKIPPER_SIGN_REGISTER 1
#define SKIPPER_SIGN_SDP 2
#define SKIPPER_SIGN_API_CHALLENGE 3

char *skipper_signing_message(int32_t purpose, const uint8_t *payload, size_t payload_len);

/*
 * SPAKE2 access-code exchange (PROTOCOL.md §2.17). skipper_pake_free wipes the
 * access code and derived keys; the session key never leaves the core. Own
 * JSON fields (still "ok"/"error" wrapped):
 *   step:  "outgoing":{"step":N,"payload":S}|null, "complete":B, "peerPubkey":S
 *          a failed confirmation (wrong code) is rejected with
 *          "kind":"authentication"; any other rejection carries no kind
 *   guess_*: "allowed":B, "retryAfterMs":N,
 *     "ledger":{"controller":COUNTER,"host":COUNTER}
 *     COUNTER = {"failures":N,"lastFailureMs":N,"lockedUntilMs":N,
 *                "failureTimesMs"?:[N]}
 *   access_code_generate: "accessCode":S
 * guess_* are pure: pass back the ledger JSON received (NULL/"" for a fresh
 * one) and persist whatever comes out. "allowed" is always the admission
 * decision for the ledger that comes out.
 */

typedef struct SkipperPake SkipperPake;

/* NULL on a bad argument: null/non-UTF-8/NUL, empty fields, or a bad own_pubkey. */
SkipperPake *skipper_pake_new(int32_t role,
                              const uint8_t *access_code, size_t access_code_len,
                              const uint8_t *device_id, size_t device_id_len,
                              const uint8_t *session_id, size_t session_id_len,
                              const uint8_t *own_pubkey, size_t own_pubkey_len);

void skipper_pake_free(SkipperPake *pake);

/* Controller starts with step 0 and a NULL payload; later calls pass the step
 * and base64 payload from the peer's `pake` frame. */
char *skipper_pake_step(SkipperPake *pake, int32_t step,
                        const uint8_t *payload_base64, size_t payload_base64_len);

int32_t skipper_pake_max_payload_base64(void);

/* May the host run step 1 at all? Both the per-controller and the host-wide
 * budget must allow it. */
char *skipper_pake_guess_admit(const uint8_t *ledger_json, size_t ledger_json_len,
                               int64_t now_ms);

/* Call before step 2 leaves the host: records the failure in both counters. */
char *skipper_pake_guess_reply_sent(const uint8_t *ledger_json, size_t ledger_json_len,
                                    int64_t now_ms);

/* Call once step 3 verified: withdraws the failure reply_sent recorded. */
char *skipper_pake_guess_confirmed(const uint8_t *ledger_json, size_t ledger_json_len,
                                   int64_t now_ms);

char *skipper_access_code_generate(void);

/*
 * Signed, MACed SDP fingerprints (PROTOCOL.md §2.12): every `sdp` carries
 * `fp`, `pubkey`, `sig` and `mac`, checked before setRemoteDescription.
 * Signing happens on the platform side (may be a Secure Enclave key); the core
 * builds the bytes to sign, MACs them with the key of the completed exchange
 * `pake`, and verifies what comes back. Both calls fail until `pake` is
 * complete.
 *   signing_message: "fp":S, "message":S (base64 bytes to sign), "mac":S
 *   verify:          "verified":true, or "error" naming the failed check
 */

/* De-duplicated, sorted a=fingerprint values joined with "\n". Refuses an SDP
 * that contains a NUL or a CR not followed by LF. */
char *skipper_sdp_fingerprints(const uint8_t *sdp, size_t sdp_len);

char *skipper_sdp_signing_message(SkipperPake *pake,
                                  const uint8_t *session_id, size_t session_id_len,
                                  const uint8_t *sdp_type, size_t sdp_type_len,
                                  const uint8_t *sdp, size_t sdp_len);

/* expected_pubkey NULL/empty means the peer's key is not yet known. */
char *skipper_sdp_verify(SkipperPake *pake,
                         const uint8_t *session_id, size_t session_id_len,
                         const uint8_t *sdp_type, size_t sdp_type_len,
                         const uint8_t *sdp, size_t sdp_len,
                         const uint8_t *fp, size_t fp_len,
                         const uint8_t *pubkey, size_t pubkey_len,
                         const uint8_t *sig, size_t sig_len,
                         const uint8_t *mac, size_t mac_len,
                         const uint8_t *expected_pubkey, size_t expected_pubkey_len);

#ifdef __cplusplus
}
#endif

#endif /* SKIPPER_CORE_H */
