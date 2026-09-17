#!/usr/bin/env python3
"""Generates session-scenarios.json — the shared conformance suite for the
session state machine (PROTOCOL.md §4).

Two implementations execute every scenario in the output file:

  * Swift: app/Sources/RemoteControlTestSuite/StateMachineScenarioTests.swift
  * Rust:  win/crates/rc-session/tests/scenarios.rs

The scenarios are distilled from the original Swift unit tests, which are the
proven behaviour (they carry the field-tested fixes: the stale-session dead
end, busy-retry-once, flutter tolerance). If either machine drifts from the
file, that suite goes red; if the file drifts from the Swift machine, the Swift
suite goes red. That is what keeps "the Rust port behaves like the Mac app"
falsifiable.

Conventions:
  at            seconds since scenario start (mapped to each language's clock)
  expectActions the EXACT ordered action list the event must return
  expectPhase   idle | connecting | live | reconnecting | closed:<reason>
  expectRelayOnly whether the session has fallen back to a TURN-relay-only path
  expiresAt     (promptForConsent) seconds since scenario start, like `at`
  expectRejected  the core refused the event's input; absent means false
  expectPeerStarted whether the machine has ordered a peer connection
  expectPeerDeviceId the peer Device ID the UI may show (empty: "another Mac")
  promptForConsent  carries a random promptId the file cannot know; runners
                  compare expiresAt and replacesPrevious, and remember each
                  promptId in order
  consentAnswered prompt: "current" (the newest remembered promptId) or
                  "previous" (the one before it); promptId: a literal name;
                  neither: no name (the host's own decision)

The peer connection starts only once the access-code exchange (§2.17) has
verified (`pakeSucceeded`). A host with `consentRequired` asks its owner first
(§2.17 Consent): phase awaitingConsent, allow/decline/30 s timeout.
"""
import json, sys

SESS, TOK, TOK2 = "8c7f1a2b3c4d5e6f708192a3b4c5d6e7", "tok-1", "tok-2"
HOSTID, CTRLID, CODE = "739000587", "481930275", "K7M2QX9P"
STALE = "feedfacefeedfacefeedfacefeedface"
OTHER = "0123456789abcdef0123456789abcdef"

def grant(sess=SESS, tok=TOK, host=HOSTID, ctrl=CTRLID):
    return {"event": "sessionGranted", "sessionId": sess, "sessionToken": tok,
            "hostDeviceId": host, "controllerDeviceId": ctrl}

def auth(active=None):
    return {"event": "signalingAuthenticated", "activeSessionId": active}

def ice(state):
    return {"event": "iceStateChanged", "state": state}

def a_connect(dev=HOSTID, code=CODE):
    return {"action": "sendConnectReq", "deviceId": dev, "accessCode": code}

def a_resume(sess=SESS, tok=TOK):
    return {"action": "sendResume", "sessionId": sess, "sessionToken": tok}

def a_bye(sess, reason):
    return {"action": "sendBye", "sessionId": sess, "reason": reason}

A_RESET = {"action": "sendInputReset"}
A_WATCHES = {"action": "reissueWatches"}
A_RESTART = {"action": "restartICE", "relayOnly": False}
A_RESTART_RELAY = {"action": "restartICE", "relayOnly": True}
A_TEARDOWN = {"action": "teardownPeerConnection"}
A_CLEAR = {"action": "clearStoredSession"}
CLOSE_SET = [A_RESET, A_TEARDOWN, A_CLEAR]

def offer(v=True):
    return {"action": "startPeerConnection", "offerer": v}

PAKE_OK = {"event": "pakeSucceeded"}
REQUIRE_CONSENT = {"event": "setConsentRequired", "required": True}

def answer(allow, prompt="current"):
    e = {"event": "consentAnswered", "allow": allow}
    if prompt in ("current", "previous"):
        e["prompt"] = prompt
    elif prompt is not None:
        e["promptId"] = prompt
    return e

def a_prompt(expires_at, replaces=False):
    return {"action": "promptForConsent", "expiresAt": expires_at,
            "replacesPrevious": replaces}

def servers(sess=SESS):
    return {"event": "iceServersArrived", "sessionId": sess}

def a_dismiss(outcome):
    return {"action": "dismissConsentPrompt", "outcome": outcome}

def step(at, do, actions=None, phase=None, **extra):
    s = {"at": at, "do": do}
    if actions is not None:
        s["expectActions"] = actions
    if phase is not None:
        s["expectPhase"] = phase
    s.update(extra)
    return s

def granted(at, offerer, **extra):
    """session_start/connect_ok, then the verified exchange starts the peer."""
    return [
        step(at, grant(), [A_TEARDOWN], "connecting", **extra),
        step(at, PAKE_OK, [offer(offerer)], "connecting"),
    ]

def live_controller(remember=True):
    """Steps that bring a controller to live: auth, connect, grant, ICE up."""
    return [
        step(0, auth(), [], "idle"),
        step(0, {"event": "connectRequested", "deviceId": HOSTID,
                 "accessCode": CODE, "remember": remember},
             [a_connect()], "connecting"),
        *granted(0, True),
        step(0, ice("connected"), [A_RESET], "live"),
    ]

S = []
def scen(name, steps, role="controller", note=""):
    s = {"name": name, "role": role, "steps": steps}
    if note:
        s["note"] = note
    S.append(s)

# ---- happy path -----------------------------------------------------------

scen("controller_connects_and_goes_live", [
    step(0, auth(), [], "idle"),
    step(0, {"event": "connectRequested", "deviceId": HOSTID,
             "accessCode": CODE, "remember": False},
         [a_connect()], "connecting"),
    *granted(0, True, expectHasSession=True),
    step(0, ice("checking"), [], "connecting"),
    step(0, ice("connected"), [A_RESET], "live"),
])

scen("host_is_never_the_offerer", [
    step(0, auth(), [], "idle"),
    *granted(0, False),
], role="host")

scen("no_connect_req_while_a_session_is_believed_alive", [
    *live_controller(),
    step(1, {"event": "connectRequested", "deviceId": HOSTID,
             "accessCode": CODE, "remember": False}, [], "live"),
], note="§4.4: a client must never connect_req over its own live session")

# ---- the access-code exchange gates the peer (§2.17) ----------------------

scen("the_peer_connection_waits_for_the_access_code_exchange", [
    step(0, auth(), [], "idle"),
    step(0, {"event": "connectRequested", "deviceId": HOSTID,
             "accessCode": CODE, "remember": False}, [a_connect()], "connecting"),
    step(0, grant(), [A_TEARDOWN], "connecting", expectHasSession=True),
    step(5, {"event": "tick"}, [], "connecting"),
    step(6, PAKE_OK, [offer(True)], "connecting"),
    step(7, PAKE_OK, [], "connecting"),
], note="a second verified exchange for the same session never starts a second peer")

scen("a_host_without_consent_starts_the_peer_as_soon_as_the_code_is_proved", [
    step(0, auth(), [], "idle"),
    step(0, grant(), [A_TEARDOWN], "connecting"),
    step(1, PAKE_OK, [offer(False)], "connecting", expectConsentRequired=False),
    step(1, answer(True), [], "connecting"),
], role="host", note="unattended access on: the code alone is permission")

scen("a_controller_never_asks_for_consent", [
    step(0, REQUIRE_CONSENT, [], "idle"),
    step(0, auth(), [], "idle"),
    step(0, {"event": "connectRequested", "deviceId": HOSTID,
             "accessCode": CODE, "remember": False}, [a_connect()], "connecting"),
    step(0, grant(), [A_TEARDOWN], "connecting"),
    step(1, PAKE_OK, [offer(True)], "connecting"),
])

scen("an_exchange_that_never_verified_never_prompts", [
    step(0, REQUIRE_CONSENT, [], "idle"),
    step(0, auth(), [], "idle"),
    step(0, grant(), [A_TEARDOWN], "connecting"),
    step(40, {"event": "tick"}, [], "connecting"),
    step(41, answer(True), [], "connecting"),
], role="host", note="a prompt for an unauthenticated controller would be a nuisance and a phishing vector")

# ---- host consent (§2.17 Consent) -----------------------------------------

def consenting_host(pake_at=1):
    return [
        step(0, REQUIRE_CONSENT, [], "idle", expectConsentRequired=True),
        step(0, auth(), [], "idle"),
        step(0, grant(), [A_TEARDOWN], "connecting"),
        step(pake_at, PAKE_OK, [a_prompt(pake_at + 30)], "awaitingConsent",
             expectHasSession=True),
    ]

scen("consent_allowed_releases_the_held_peer_start", [
    *consenting_host(),
    step(11, {"event": "tick"}, [], "awaitingConsent"),
    step(25, {"event": "tick"}, [], "awaitingConsent"),
    step(26, answer(True), [a_dismiss("allowed"), offer(False)], "connecting"),
    step(27, ice("connected"), [A_RESET], "live"),
    step(60, {"event": "tick"}, [], "live"),
    step(61, answer(False), [], "live"),
], role="host", note="no step timer runs during the wait; the answer is taken once")

scen("consent_declined_ends_the_session_with_bye_declined", [
    *consenting_host(),
    step(5, answer(False),
         [a_dismiss("declined"), a_bye(SESS, "declined"), *CLOSE_SET],
         "closed:declined", expectHasSession=False),
    step(6, answer(True), [], "closed:declined"),
    step(40, {"event": "tick"}, [], "closed:declined"),
], role="host")

scen("an_unanswered_prompt_declines_after_exactly_30s", [
    *consenting_host(pake_at=2),
    step(31, {"event": "tick"}, [], "awaitingConsent"),
    step(32, {"event": "tick"},
         [a_dismiss("timedOut"), a_bye(SESS, "declined"), *CLOSE_SET],
         "closed:declined", expectHasSession=False),
    step(33, {"event": "tick"}, [], "closed:declined"),
], role="host", note="the default answer is decline")

scen("a_controller_that_gives_up_takes_the_prompt_with_it", [
    *consenting_host(),
    step(20, {"event": "closeLocally", "reason": "timeout"},
         [a_dismiss("cancelled"), *CLOSE_SET], "closed:timeout"),
    step(21, answer(True), [], "closed:timeout"),
    step(40, {"event": "tick"}, [], "closed:timeout"),
], role="host", note="the controller's own bye{timeout} or bye{user_ended} arrives as closeLocally")

scen("a_server_bye_during_the_wait_cancels_the_prompt", [
    *consenting_host(),
    step(3, {"event": "closeLocally", "reason": "code_refreshed"},
         [a_dismiss("cancelled"), *CLOSE_SET], "closed:code_refreshed"),
], role="host")

scen("ending_the_session_locally_during_the_wait_cancels_the_prompt", [
    *consenting_host(),
    step(3, {"event": "userEnded", "reason": "user_ended"},
         [a_bye(SESS, "user_ended"), a_dismiss("cancelled"), *CLOSE_SET],
         "closed:user_ended"),
], role="host")

scen("a_new_session_start_replaces_the_open_prompt", [
    *consenting_host(),
    step(4, grant(sess=STALE, tok=TOK2), [A_TEARDOWN, a_dismiss("cancelled")], "connecting"),
    step(5, PAKE_OK, [a_prompt(35, replaces=True)], "awaitingConsent"),
    step(34, {"event": "tick"}, [], "awaitingConsent"),
    step(35, {"event": "tick"},
         [a_dismiss("timedOut"), a_bye(STALE, "declined"), *CLOSE_SET], "closed:declined"),
], role="host", note="at most one prompt at a time, and its timer restarts")

scen("a_signaling_flap_during_the_wait_keeps_the_prompt", [
    *consenting_host(),
    step(5, {"event": "signalingLost"}, [], "awaitingConsent"),
    step(8, auth(SESS), [a_resume()], "awaitingConsent"),
    step(8, {"event": "resumeSucceeded", "sessionId": SESS, "sessionToken": TOK2},
         [A_WATCHES, A_RESET], "awaitingConsent"),
    step(10, answer(True), [a_dismiss("allowed"), offer(False)], "connecting"),
], role="host")

scen("a_session_lost_during_the_wait_cancels_the_prompt", [
    *consenting_host(),
    step(5, {"event": "signalingLost"}, []),
    step(8, auth(SESS), [a_resume()]),
    step(9, {"event": "resumeFailed", "code": "no_session", "retryAfterSec": 0},
         [a_dismiss("cancelled"), A_TEARDOWN, A_CLEAR,
          {"action": "promptForAccessCode", "reason": "no_session"}], "idle"),
    step(40, {"event": "tick"}, []),
], role="host")

scen("the_host_keeps_renewing_while_it_waits", [
    step(0, REQUIRE_CONSENT, [], "idle"),
    step(0, auth(), [], "idle"),
    step(0, grant(), [A_TEARDOWN], "connecting"),
    step(290, PAKE_OK, [a_prompt(320)], "awaitingConsent"),
    step(300, {"event": "tick"}, [{"action": "sendRenew", "sessionId": SESS,
                                   "sessionToken": TOK}], "awaitingConsent"),
], role="host")

scen("a_leftover_peer_never_turns_a_new_prompt_into_a_live_session", [
    step(0, REQUIRE_CONSENT, [], "idle"),
    step(0, auth(), [], "idle"),
    step(0, grant(), [A_TEARDOWN], "connecting"),
    step(1, PAKE_OK, [a_prompt(31)], "awaitingConsent"),
    step(3, answer(True), [a_dismiss("allowed"), offer(False)], "connecting"),
    step(4, ice("connected"), [A_RESET], "live", expectPeerStarted=True),
    step(10, grant(sess=OTHER, tok=TOK2), [A_TEARDOWN], "connecting",
         expectPeerStarted=False),
    step(11, PAKE_OK, [a_prompt(41)], "awaitingConsent"),
    step(12, ice("disconnected"), [], "awaitingConsent"),
    step(13, ice("connected"), [], "awaitingConsent", expectPeerStarted=False),
    step(14, ice("completed"), [], "awaitingConsent"),
    step(15, answer(False),
         [a_dismiss("declined"), a_bye(OTHER, "declined"), *CLOSE_SET],
         "closed:declined", expectPeerStarted=False, expectHasSession=False),
    step(16, ice("connected"), [], "closed:declined"),
    step(45, {"event": "tick"}, [], "closed:declined"),
], role="host", note="review M-A: a compromised server pushes session_start for B while A's "
                     "peer is up, then bounces A's ICE; B must never reach live, and Decline "
                     "must still end B")

scen("link_events_before_the_peer_starts_are_ignored", [
    step(0, auth(), [], "idle"),
    step(0, grant(), [A_TEARDOWN], "connecting"),
    step(0, ice("connected"), [], "connecting", expectPeerStarted=False),
    step(1, PAKE_OK, [offer(False)], "connecting"),
    step(2, ice("connected"), [A_RESET], "live"),
], role="host", note="only the peer connection the machine ordered can move the phase")

scen("allow_is_ignored_for_the_first_1_5_s_of_a_prompt", [
    *consenting_host(),
    step(1, answer(True), [], "awaitingConsent"),
    step(2.499, answer(True), [], "awaitingConsent"),
    step(2.5, answer(True), [a_dismiss("allowed"), offer(False)], "connecting"),
], role="host", note="a click aimed at something else cannot land on Allow")

scen("decline_is_accepted_at_once", [
    *consenting_host(),
    step(1, answer(False),
         [a_dismiss("declined"), a_bye(SESS, "declined"), *CLOSE_SET], "closed:declined"),
], role="host")

scen("an_answer_meant_for_another_prompt_changes_nothing", [
    *consenting_host(),
    step(5, answer(True, STALE), [], "awaitingConsent"),
    step(6, answer(False, STALE), [], "awaitingConsent"),
    step(7, answer(True), [a_dismiss("allowed"), offer(False)], "connecting"),
], role="host")

scen("a_prompt_is_named_locally_never_by_the_server_session_id", [
    *consenting_host(),
    step(5, answer(True, SESS), [], "awaitingConsent"),
    step(5, answer(False, SESS), [], "awaitingConsent"),
    step(6, answer(True, None), [], "awaitingConsent"),
    step(7, answer(True), [a_dismiss("allowed"), offer(False)], "connecting"),
], role="host", note="review C2: the server chooses session ids, so an answer carries the "
                     "prompt's local random name; Allow without a name is refused")

scen("the_hosts_own_decline_needs_no_name", [
    *consenting_host(),
    step(2, answer(False, None),
         [a_dismiss("declined"), a_bye(SESS, "declined"), *CLOSE_SET], "closed:declined"),
], role="host")

scen("an_allow_for_a_replaced_prompt_never_admits_the_new_controller", [
    *consenting_host(),
    step(4, grant(tok=TOK2, ctrl="739000588"), [A_TEARDOWN, a_dismiss("cancelled")], "connecting"),
    step(5, PAKE_OK, [a_prompt(35, replaces=True)], "awaitingConsent"),
    step(5.5, answer(True, "previous"), [], "awaitingConsent"),
    step(6, answer(True), [], "awaitingConsent"),
    step(6.6, {"event": "tick"}, [], "awaitingConsent", expectPeerStarted=False),
    step(7, answer(True, "previous"), [], "awaitingConsent"),
    step(7, answer(True), [a_dismiss("allowed"), offer(False)], "connecting"),
], role="host", note="review C2: a compromised server re-sends session_start with the same "
                     "session id for controller B; the owner's click on A's prompt, or an Allow "
                     "inside B's 1.5 s delay, is refused and never queued")

scen("a_prompt_after_a_finished_session_is_not_a_replacement", [
    *consenting_host(),
    step(3, answer(False),
         [a_dismiss("declined"), a_bye(SESS, "declined"), *CLOSE_SET], "closed:declined"),
    step(10, grant(sess=OTHER, tok=TOK2), [A_TEARDOWN], "connecting"),
    step(11, PAKE_OK, [a_prompt(41)], "awaitingConsent"),
], role="host")

# ---- server-supplied values are checked before use ------------------------

scen("a_grant_with_a_malformed_session_or_host_id_is_refused", [
    step(0, auth(), [], "idle"),
    step(0, grant(sess="S|offer"), [], "idle", expectRejected=True, expectHasSession=False),
    step(0, grant(sess=SESS.upper()), [], "idle", expectRejected=True),
    step(0, grant(sess=SESS + "0"), [], "idle", expectRejected=True),
    step(0, grant(host="73900058"), [], "idle", expectRejected=True),
    step(1, grant(), [A_TEARDOWN], "connecting", expectHasSession=True,
         expectPeerDeviceId=CTRLID),
], role="host")

scen("a_malformed_controller_device_id_is_shown_as_another_mac", [
    step(0, auth(), [], "idle"),
    step(0, grant(ctrl="Evil Mac 123"), [A_TEARDOWN], "connecting", expectPeerDeviceId=""),
    step(1, grant(sess=OTHER, ctrl="48193027"), [A_TEARDOWN], "connecting",
         expectPeerDeviceId=""),
    step(2, grant(sess=STALE), [A_TEARDOWN], "connecting", expectPeerDeviceId=CTRLID),
], role="host", note="the prompt names only a well-formed Device ID")

scen("a_connect_to_a_malformed_device_id_is_refused", [
    step(0, auth(), [], "idle"),
    step(0, {"event": "connectRequested", "deviceId": "739 000 587",
             "accessCode": CODE, "remember": False}, [], "idle", expectRejected=True),
])

scen("a_malformed_advertised_session_is_ignored", [
    step(0, {"event": "connectRequested", "deviceId": HOSTID,
             "accessCode": CODE, "remember": False}, [], "connecting"),
    step(1, auth("x|y"), [a_connect()], "connecting"),
])

scen("a_resume_ok_for_another_session_is_refused_and_retried", [
    *live_controller(),
    step(5, {"event": "signalingLost"}, []),
    step(8, auth(SESS), [a_resume()]),
    step(8, {"event": "resumeSucceeded", "sessionId": OTHER, "sessionToken": TOK2},
         [], "live", expectRejected=True, expectResumeInFlight=False),
    step(9, {"event": "tick"}, [a_resume()]),
])

scen("renew_ok_with_a_malformed_session_id_is_refused", [
    *live_controller(),
    step(1, {"event": "renewSucceeded", "sessionId": "not-our-session",
             "sessionToken": "evil"}, None, expectRejected=True),
    step(2, {"event": "signalingLost"}, []),
    step(3, auth(SESS), [a_resume(tok=TOK)]),
])

# ---- the controller outlasts the host's prompt ----------------------------

scen("a_controller_waits_45s_for_the_peer_before_giving_up", [
    step(0, auth(), [], "idle"),
    step(0, {"event": "connectRequested", "deviceId": HOSTID,
             "accessCode": CODE, "remember": False}, [a_connect()], "connecting"),
    *granted(0, True),
    step(30, {"event": "tick"}, [], "connecting"),
    step(44.9, {"event": "tick"}, [], "connecting"),
    step(45, {"event": "tick"},
         [a_bye(SESS, "timeout"), *CLOSE_SET], "closed:timeout", expectHasSession=False),
], note="longer than the host's 30 s prompt, so a slow Allow still connects")

scen("a_host_that_allows_late_still_connects", [
    step(0, auth(), [], "idle"),
    step(0, {"event": "connectRequested", "deviceId": HOSTID,
             "accessCode": CODE, "remember": False}, [a_connect()], "connecting"),
    *granted(0, True),
    step(31, ice("checking"), [], "connecting"),
    step(32, ice("connected"), [A_RESET], "live"),
    step(60, {"event": "tick"}, [], "live"),
])

scen("a_declined_controller_closes_with_the_hosts_reason", [
    step(0, auth(), [], "idle"),
    step(0, {"event": "connectRequested", "deviceId": HOSTID,
             "accessCode": CODE, "remember": True}, [a_connect()], "connecting"),
    *granted(0, True),
    step(12, {"event": "closeLocally", "reason": "declined"},
         CLOSE_SET, "closed:declined"),
    step(60, {"event": "tick"}, [], "closed:declined"),
    step(61, {"event": "signalingLost"}, []),
    step(62, auth(SESS), [], "closed:declined"),
], note="declined is terminal: no retry, no resume")

# ---- signaling flutter (PLAN.md §2.1) -------------------------------------

scen("losing_signaling_does_not_tear_down_media", [
    *live_controller(),
    step(5, {"event": "signalingLost"}, [], "live",
         expectHasSession=True),
], note="the control plane dying must not interrupt an established media path")

scen("signaling_loss_with_media_down_shows_reconnecting_never_disconnected", [
    step(0, auth(), [], "idle"),
    step(0, {"event": "connectRequested", "deviceId": HOSTID,
             "accessCode": CODE, "remember": False}, [a_connect()], "connecting"),
    *granted(0, True),
    step(1, {"event": "signalingLost"}, [], "reconnecting"),
])

scen("reconnect_resumes_and_never_sends_connect_req", [
    *live_controller(),
    step(5, {"event": "signalingLost"}, [], "live"),
    step(8, auth(SESS), [a_resume()], "live", expectResumeInFlight=True),
])

scen("resume_is_sent_even_when_hello_ok_has_no_active_session_id", [
    *live_controller(),
    step(5, {"event": "signalingLost"}, []),
    step(8, auth(None), [a_resume()]),
], note="our own session record is enough; the server advertisement is a bonus")

scen("two_resumes_are_never_in_flight_at_once", [
    *live_controller(),
    step(5, {"event": "signalingLost"}, []),
    step(8, auth(SESS), [a_resume()]),
    step(9, auth(SESS), [], None, expectResumeInFlight=True),
])

scen("a_failed_resume_frees_the_slot_and_tick_retries", [
    *live_controller(),
    step(5, {"event": "signalingLost"}, []),
    step(8, auth(SESS), [a_resume()]),
    step(9, {"event": "resumeFailed", "code": "internal", "retryAfterSec": 0},
         [], None, expectResumeInFlight=False, expectHasSession=True),
    step(10, {"event": "tick"}, [a_resume()]),
], note="a transient error keeps the session and retries; only no_session/bad_token discard it")

scen("resume_ok_rotates_the_token_and_the_next_resume_uses_it", [
    *live_controller(),
    step(5, {"event": "signalingLost"}, []),
    step(8, auth(SESS), [a_resume()]),
    step(8, {"event": "resumeSucceeded", "sessionId": SESS, "sessionToken": TOK2},
         [A_WATCHES, A_RESET], "live"),
    step(20, {"event": "signalingLost"}, []),
    step(22, auth(SESS), [a_resume(tok=TOK2)]),
])

# ---- renew ---------------------------------------------------------------

scen("renew_fires_on_schedule_and_not_before", [
    *live_controller(),
    step(299, {"event": "tick"}, []),
    step(300, {"event": "tick"}, [{"action": "sendRenew", "sessionId": SESS,
                                   "sessionToken": TOK}]),
    step(301, {"event": "tick"}, []),
], note="granted at t=0 with a 300s renew interval")

scen("renew_ok_rotates_the_token_only_for_the_matching_session", [
    *live_controller(),
    step(1, {"event": "renewSucceeded", "sessionId": OTHER,
             "sessionToken": "evil"}, None),
    step(2, {"event": "signalingLost"}, []),
    step(3, auth(SESS), [a_resume(tok=TOK)]),
])

scen("renew_failure_with_bad_token_discards_like_a_failed_resume", [
    *live_controller(remember=True),
    step(5, {"event": "renewFailed", "code": "bad_token"},
         [A_TEARDOWN, A_CLEAR, a_connect()], "connecting"),
])

scen("renew_failure_with_a_transient_code_is_ignored", [
    *live_controller(),
    step(5, {"event": "renewFailed", "code": "internal"}, [], "live",
         expectHasSession=True),
])

# ---- resume failure branching (§4.3 steps 5-6) ----------------------------

scen("no_session_without_a_remembered_code_prompts_and_nothing_else_does", [
    *live_controller(remember=False),
    step(5, {"event": "signalingLost"}, []),
    step(8, auth(None), [a_resume()]),
    step(9, {"event": "resumeFailed", "code": "no_session", "retryAfterSec": 0},
         [A_TEARDOWN, A_CLEAR, {"action": "promptForAccessCode", "reason": "no_session"}],
         "idle", expectHasSession=False),
])

scen("bad_token_behaves_identically_to_no_session", [
    *live_controller(remember=False),
    step(5, {"event": "signalingLost"}, []),
    step(8, auth(None), [a_resume()]),
    step(9, {"event": "resumeFailed", "code": "bad_token", "retryAfterSec": 0},
         [A_TEARDOWN, A_CLEAR, {"action": "promptForAccessCode", "reason": "bad_token"}],
         "idle"),
])

scen("server_restart_with_a_remembered_code_reconnects_silently", [
    *live_controller(remember=True),
    step(5, {"event": "signalingLost"}, []),
    step(8, auth(None), [a_resume()]),
    step(9, {"event": "resumeFailed", "code": "no_session", "retryAfterSec": 0},
         [A_TEARDOWN, A_CLEAR, a_connect()], "connecting"),
], note="every session died with the server; prompting the user would be wrong")

scen("a_host_never_silently_reconnects", [
    step(0, auth(), [], "idle"),
    *granted(0, False),
    step(5, {"event": "signalingLost"}, []),
    step(8, auth(None), [a_resume()]),
    step(9, {"event": "resumeFailed", "code": "no_session", "retryAfterSec": 0},
         [A_TEARDOWN, A_CLEAR, {"action": "promptForAccessCode", "reason": "no_session"}],
         "idle"),
], role="host", note="a host holds no access code to offer")

scen("rate_limited_backs_off_exactly_as_told", [
    *live_controller(),
    step(5, {"event": "signalingLost"}, []),
    step(8, auth(SESS), [a_resume()]),
    step(9, {"event": "resumeFailed", "code": "rate_limited", "retryAfterSec": 30},
         [{"action": "scheduleResume", "afterSec": 30}], None, expectHasSession=True),
])

scen("rate_limited_with_zero_retry_still_waits_at_least_one_second", [
    *live_controller(),
    step(5, {"event": "signalingLost"}, []),
    step(8, auth(SESS), [a_resume()]),
    step(9, {"event": "resumeFailed", "code": "rate_limited", "retryAfterSec": 0},
         [{"action": "scheduleResume", "afterSec": 1}]),
])

# ---- resume_ok side effects ----------------------------------------------

scen("resume_ok_with_ice_up_reissues_watches_and_resets_input_but_no_restart", [
    *live_controller(),
    step(5, {"event": "signalingLost"}, []),
    step(8, auth(SESS), [a_resume()]),
    step(8, {"event": "resumeSucceeded", "sessionId": SESS, "sessionToken": TOK2},
         [A_WATCHES, A_RESET], "live"),
])

scen("resume_ok_with_ice_down_orders_a_restart_from_the_controller", [
    step(0, auth(), [], "idle"),
    step(0, {"event": "connectRequested", "deviceId": HOSTID,
             "accessCode": CODE, "remember": False}, [a_connect()], "connecting"),
    *granted(0, True),
    step(1, ice("connected"), [A_RESET], "live"),
    step(2, ice("disconnected"), [A_RESET], "reconnecting"),
    step(3, {"event": "signalingLost"}, []),
    step(6, auth(SESS), [a_resume()]),
    step(6, {"event": "resumeSucceeded", "sessionId": SESS, "sessionToken": TOK2},
         [A_WATCHES, A_RESET, A_RESTART], "reconnecting"),
])

scen("a_host_does_not_offer_the_ice_restart", [
    step(0, auth(), [], "idle"),
    *granted(0, False),
    step(1, ice("connected"), [A_RESET], "live"),
    step(2, ice("disconnected"), [A_RESET], "reconnecting"),
    step(3, {"event": "signalingLost"}, []),
    step(6, auth(SESS), [a_resume()]),
    step(6, {"event": "resumeSucceeded", "sessionId": SESS, "sessionToken": TOK2},
         [A_WATCHES, A_RESET], "reconnecting"),
], role="host")

# ---- ICE timing (PLAN.md §2.1) -------------------------------------------

scen("ice_disconnected_holds_the_session_and_restarts_after_exactly_3s", [
    *live_controller(),
    step(10, ice("disconnected"), [A_RESET], "reconnecting"),
    step(12.9, {"event": "tick"}, []),
    step(13, {"event": "tick"}, [A_RESTART], "reconnecting", expectHasSession=True),
    step(14, {"event": "tick"}, [], None),
])

scen("a_link_that_recovers_before_3s_never_restarts", [
    *live_controller(),
    step(10, ice("disconnected"), [A_RESET], "reconnecting"),
    step(12, ice("connected"), [A_RESET], "live"),
    step(14, {"event": "tick"}, []),
    step(60, {"event": "tick"}, []),
])

scen("failed_alone_does_not_close_but_failed_plus_45s_does", [
    *live_controller(),
    step(10, ice("failed"), [A_RESET, A_RESTART_RELAY], "reconnecting",
         expectHasSession=True),
    step(54, {"event": "tick"}, [], "reconnecting"),
    step(55, {"event": "tick"},
         [*CLOSE_SET, a_bye(SESS, "failed")], "closed:failed",
         expectHasSession=False),
])

scen("a_first_ice_failure_retries_on_relay_immediately_instead_of_waiting", [
    *live_controller(),
    step(10, ice("failed"), [A_RESET, A_RESTART_RELAY], "reconnecting",
         expectHasSession=True, expectRelayOnly=True),
    step(11, {"event": "tick"}, [], "reconnecting"),
    step(54, {"event": "tick"}, [], "reconnecting", expectHasSession=True),
    step(55, {"event": "tick"},
         [*CLOSE_SET, a_bye(SESS, "failed")], "closed:failed",
         expectHasSession=False, expectRelayOnly=False),
], note="the 45s grace now covers the relay attempt, not a hopeless wait on the failed path")

scen("the_relay_retry_is_offered_at_most_once_per_session", [
    *live_controller(),
    step(10, ice("failed"), [A_RESET, A_RESTART_RELAY], "reconnecting"),
    step(20, ice("connected"), [A_RESET], "live", expectRelayOnly=True),
    step(30, ice("failed"), [A_RESET], "reconnecting", expectRelayOnly=True),
], note="relay is the last resort; failing on relay too must not loop")

scen("a_session_that_is_already_relay_only_never_asks_for_a_relay_retry", [
    step(0, auth(), [], "idle"),
    step(0, {"event": "setRelayOnly", "relayOnly": True}, [], "idle",
         expectRelayOnly=True),
    step(0, {"event": "connectRequested", "deviceId": HOSTID,
             "accessCode": CODE, "remember": False}, [a_connect()], "connecting"),
    *granted(0, True),
    step(0, ice("connected"), [A_RESET], "live"),
    step(10, ice("failed"), [A_RESET], "reconnecting", expectRelayOnly=True),
], note="RC_ICE_POLICY=relay already: there is nothing left to fall back to")

scen("a_host_never_offers_the_relay_retry", [
    step(0, auth(), [], "idle"),
    *granted(0, False),
    step(1, ice("connected"), [A_RESET], "live"),
    step(10, ice("failed"), [A_RESET], "reconnecting", expectRelayOnly=False),
    step(55, {"event": "tick"},
         [*CLOSE_SET, a_bye(SESS, "failed")], "closed:failed"),
], role="host", note="only the offerer restarts ICE (§4.3 step 4)")

scen("after_the_relay_retry_a_later_disconnect_restarts_on_relay_too", [
    *live_controller(),
    step(10, ice("failed"), [A_RESET, A_RESTART_RELAY], "reconnecting"),
    step(20, ice("connected"), [A_RESET], "live"),
    step(30, ice("disconnected"), [A_RESET], "reconnecting"),
    step(33, {"event": "tick"}, [A_RESTART_RELAY], "reconnecting"),
], note="the policy sticks for the rest of the session")

scen("a_resume_while_relay_only_restarts_on_relay", [
    *live_controller(),
    step(10, ice("failed"), [A_RESET, A_RESTART_RELAY], "reconnecting"),
    step(12, {"event": "signalingLost"}, []),
    step(15, auth(SESS), [a_resume()]),
    step(15, {"event": "resumeSucceeded", "sessionId": SESS, "sessionToken": TOK2},
         [A_WATCHES, A_RESET, A_RESTART_RELAY], "reconnecting"),
])

scen("a_relay_fallback_ends_with_its_session", [
    *live_controller(),
    step(10, ice("failed"), [A_RESET, A_RESTART_RELAY], "reconnecting", expectRelayOnly=True),
    step(11, grant(sess=OTHER, tok=TOK2), [A_TEARDOWN], "connecting", expectRelayOnly=False),
    step(12, PAKE_OK, [offer(True)], "connecting"),
    step(13, ice("connected"), [A_RESET], "live"),
    step(20, ice("failed"), [A_RESET, A_RESTART_RELAY], "reconnecting", expectRelayOnly=True),
    step(21, {"event": "closeLocally", "reason": "user_ended"}, CLOSE_SET, "closed:user_ended",
         expectRelayOnly=False),
], note="review leftover: relay_only no longer carries into the next session")

scen("a_forced_relay_holds_for_every_session", [
    step(0, {"event": "setRelayOnly", "relayOnly": True}, [], "idle", expectRelayOnly=True),
    *live_controller(),
    step(5, {"event": "closeLocally", "reason": "user_ended"}, CLOSE_SET, "closed:user_ended",
         expectRelayOnly=True),
    step(6, grant(sess=OTHER, tok=TOK2), [A_TEARDOWN], "connecting", expectRelayOnly=True),
])

# ---- protocol v5: TURN arrives with the ice_servers push -------------------

scen("turn_credentials_restart_a_forced_relay_offer_that_found_nothing", [
    step(0, {"event": "setRelayOnly", "relayOnly": True}, [], "idle"),
    step(0, auth(), [], "idle"),
    step(0, {"event": "connectRequested", "deviceId": HOSTID,
             "accessCode": CODE, "remember": False}, [a_connect()], "connecting"),
    *granted(0, True),
    step(1, ice("checking"), [], "connecting"),
    step(2, servers(OTHER), [], "connecting", expectRejected=True),
    step(2, servers(), [A_RESTART_RELAY], "connecting"),
    step(2, servers(), [], "connecting"),
    step(3, ice("connected"), [A_RESET], "live"),
    step(4, servers(), [], "live"),
], note="connect_ok carries STUN only, so a relay-only offer gathers nothing until "
        "ice_servers arrives; one restart, not one per push")

scen("turn_credentials_change_nothing_for_a_direct_offer", [
    *live_controller(),
    step(1, servers(), [], "live"),
])

scen("turn_credentials_before_the_peer_starts_change_nothing", [
    step(0, {"event": "setRelayOnly", "relayOnly": True}, [], "idle"),
    step(0, auth(), [], "idle"),
    step(0, {"event": "connectRequested", "deviceId": HOSTID,
             "accessCode": CODE, "remember": False}, [a_connect()], "connecting"),
    step(0, grant(), [A_TEARDOWN], "connecting"),
    step(1, servers(), [], "connecting"),
    step(2, PAKE_OK, [offer(True)], "connecting"),
])

scen("a_host_never_restarts_for_turn_credentials", [
    step(0, {"event": "setRelayOnly", "relayOnly": True}, [], "idle"),
    step(0, auth(), [], "idle"),
    *granted(0, False),
    step(1, servers(), [], "connecting"),
], role="host", note="only the offerer restarts ICE; the host answers the restart offer")

scen("turn_credentials_without_a_session_are_refused", [
    step(0, auth(), [], "idle"),
    step(1, servers(), [], "idle", expectRejected=True),
    step(1, servers("S|offer"), [], "idle", expectRejected=True),
])

scen("recovering_inside_the_grace_window_keeps_the_session", [
    *live_controller(),
    step(10, ice("failed"), [A_RESET, A_RESTART_RELAY], "reconnecting"),
    step(40, ice("connected"), [A_RESET], "live"),
    step(60, {"event": "tick"}, [], "live", expectHasSession=True),
])

scen("an_up_to_up_ice_change_does_not_spam_input_reset", [
    *live_controller(),
    step(1, ice("completed"), [], "live"),
], note="connected -> completed is not a gap; resetting would drop held keys mid-drag")

# ---- endings -------------------------------------------------------------

scen("the_user_ending_a_session_tells_the_server_and_clears_everything", [
    *live_controller(),
    step(5, {"event": "userEnded", "reason": "user_ended"},
         [a_bye(SESS, "user_ended"), *CLOSE_SET], "closed:user_ended",
         expectHasSession=False),
])

scen("a_bye_from_the_peer_closes_with_the_peers_reason", [
    *live_controller(),
    step(5, {"event": "closeLocally", "reason": "host_ended"},
         CLOSE_SET, "closed:host_ended"),
])

scen("ending_with_no_session_is_a_quiet_no_op", [
    step(0, auth(), [], "idle"),
    step(1, {"event": "userEnded", "reason": "user_ended"}, [], "idle"),
])

# ---- the stale-session dead end (§4.4, field-tested) ----------------------

scen("a_session_we_own_but_cannot_resume_is_discarded_not_surfaced_as_busy", [
    step(0, {"event": "connectRequested", "deviceId": HOSTID,
             "accessCode": CODE, "remember": False}, [], "connecting"),
    step(1, auth(STALE),
         [a_bye(STALE, "stale_no_token"), a_connect()], "connecting"),
], note="app restarted, token died with the process, server still advertises the session")

scen("busy_against_our_own_session_clears_it_and_retries_exactly_once", [
    step(0, auth(STALE), [], "idle"),
    step(0, {"event": "connectRequested", "deviceId": HOSTID,
             "accessCode": CODE, "remember": False}, [a_connect()], "connecting"),
    step(1, {"event": "connectFailed", "code": "busy"},
         [a_bye(STALE, "stale_no_token"), a_connect()], "connecting"),
    step(2, {"event": "connectFailed", "code": "busy"}, [], "closed:busy"),
], note="the second busy is a genuine second controller and must surface")

scen("the_busy_retry_guard_survives_a_signaling_flap", [
    step(0, auth(STALE), [], "idle"),
    step(0, {"event": "connectRequested", "deviceId": HOSTID,
             "accessCode": CODE, "remember": False}, [a_connect()], "connecting"),
    step(1, {"event": "connectFailed", "code": "busy"},
         [a_bye(STALE, "stale_no_token"), a_connect()], "connecting"),
    step(2, {"event": "signalingLost"}, [], "connecting"),
    step(3, auth(STALE),
         [a_bye(STALE, "stale_no_token"), a_connect()], "connecting"),
    step(4, {"event": "connectFailed", "code": "busy"}, [], "closed:busy"),
], note="reconnecting re-advertises the stale session; without the one-shot guard "
        "connectFailed(busy) would bye-and-retry forever against a genuine second controller")

scen("busy_with_no_advertised_session_is_someone_elses_and_surfaces", [
    step(0, auth(None), [], "idle"),
    step(0, {"event": "connectRequested", "deviceId": HOSTID,
             "accessCode": CODE, "remember": False}, [a_connect()], "connecting"),
    step(1, {"event": "connectFailed", "code": "busy"}, [], "closed:busy"),
])

scen("a_resumable_session_is_never_discarded", [
    *live_controller(),
    step(5, {"event": "signalingLost"}, []),
    step(8, auth(SESS), [a_resume()], None, expectHasSession=True),
], note="holding a token means resume, never bye")

scen("a_deliberately_closed_session_is_not_resurrected", [
    *live_controller(),
    step(5, {"event": "userEnded", "reason": "user_ended"},
         [a_bye(SESS, "user_ended"), *CLOSE_SET], "closed:user_ended"),
    step(6, {"event": "signalingLost"}, []),
    step(9, auth(SESS), [], "closed:user_ended", expectHasSession=False),
], note="the regression the first stale-session fix caused: closed is closed")

out = {"version": 3, "clockNote": "at is seconds from scenario start",
       "scenarios": S}
path = sys.argv[1] if len(sys.argv) > 1 else "session-scenarios.json"
with open(path, "w") as f:
    json.dump(out, f, indent=1)
    f.write("\n")
total = sum(len(s["steps"]) for s in S)
print(f"wrote {len(S)} scenarios / {total} steps to {path}", file=sys.stderr)
