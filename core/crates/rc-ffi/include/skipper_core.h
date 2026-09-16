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
 *     "signalingUp":B, "resumeInFlight":B, "isOfferer":B, "iceState":S,
 *     "sessionId":S|null, "sessionToken":S|null, "peerDeviceId":S|null,
 *     "rememberedAccessCode":S|null, "serverAdvertisedSessionId":S|null } }
 * or, rejected: { "ok": false, "error": "<message>" }. Actions match
 * protocol/vectors/session-scenarios.json; "phase" and "iceState" match the
 * SessionPhase/IceLinkState variant names, lowercased.
 *
 * Times are Unix milliseconds; strings are NUL-terminated UTF-8; nullable
 * params accept NULL. No function here unwinds a panic across the boundary.
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

char *skipper_session_state(SkipperSession *session);

char *skipper_session_connect_requested(SkipperSession *session,
                                        const char *device_id,
                                        const char *access_code,
                                        bool remember);

char *skipper_session_granted(SkipperSession *session,
                              const char *session_id,
                              const char *session_token,
                              const char *host_device_id,
                              const char *controller_device_id,
                              int64_t now_ms);

char *skipper_session_connect_failed(SkipperSession *session, const char *code);

char *skipper_session_signaling_lost(SkipperSession *session);

/* active_session_id is nullable. */
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

/* ice_state is one of the "iceState" strings above. */
char *skipper_session_ice_state_changed(SkipperSession *session,
                                        const char *ice_state,
                                        int64_t now_ms);

char *skipper_session_tick(SkipperSession *session, int64_t now_ms);

char *skipper_session_close_locally(SkipperSession *session, const char *reason);

char *skipper_session_user_ended(SkipperSession *session, const char *reason);

/* NULL forgets the remembered access code. */
char *skipper_session_set_remembered_access_code(SkipperSession *session,
                                                 const char *access_code);

/*
 * SPAKE2 access-code exchange (PROTOCOL.md §2.17). skipper_pake_free wipes the
 * access code and derived keys. Own JSON fields (still "ok"/"error" wrapped):
 *   step:  "outgoing":{"step":N,"payload":S}|null, "complete":B, "peerPubkey":S
 *   session_key: "sessionKey":S (base64, 32 bytes)
 *   guess_policy_*: "allowed":B, "retryAfterMs":N,
 *     "counter":{"failures":N,"lastFailureMs":N,"lockedUntilMs":N}
 *   access_code_generate: "accessCode":S
 * guess_policy_* are pure: pass back the counter JSON received (NULL/"" for a
 * fresh one) and persist whatever comes out.
 */

typedef struct SkipperPake SkipperPake;

/* NULL on a bad argument: null/non-UTF-8, empty fields, or a bad own_pubkey. */
SkipperPake *skipper_pake_new(int32_t role,
                              const char *access_code,
                              const char *device_id,
                              const char *session_id,
                              const char *own_pubkey);

void skipper_pake_free(SkipperPake *pake);

/* Controller starts with step 0 and a NULL payload; later calls pass the step
 * and base64 payload from the peer's `pake` frame. */
char *skipper_pake_step(SkipperPake *pake, int32_t step, const char *payload_base64);

/* Valid only once "complete" was true. */
char *skipper_pake_session_key(SkipperPake *pake);

int32_t skipper_pake_max_payload_base64(void);

char *skipper_pake_guess_policy_check(const char *counter_json, int64_t now_ms);

char *skipper_pake_guess_policy_record_failure(const char *counter_json, int64_t now_ms);
char *skipper_pake_guess_policy_record_success(const char *counter_json);

char *skipper_access_code_generate(void);

/*
 * Signed SDP fingerprints (PROTOCOL.md §2.12): every `sdp` carries `fp`,
 * `pubkey` and `sig`, checked before setRemoteDescription. Signing happens on
 * the platform side (may be a Secure Enclave key); the core builds the bytes
 * to sign and verifies what comes back.
 *   signing_message: "fp":S, "message":S (base64 ECDSA-P256/SHA-256 DER bytes)
 *   verify:          "verified":true, or "error" naming the failed check
 */

/* De-duplicated, sorted a=fingerprint values joined with "\n". */
char *skipper_sdp_fingerprints(const char *sdp);

char *skipper_sdp_signing_message(const char *session_id,
                                  const char *sdp_type,
                                  const char *sdp);

/* expected_pubkey NULL/empty means the peer's key is not yet known. */
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
