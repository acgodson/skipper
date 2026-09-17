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
"""
import json, sys

SESS, TOK, TOK2 = "8c7f1a2b3c4d5e6f708192a3b4c5d6e7", "tok-1", "tok-2"
HOSTID, CTRLID, CODE = "739000587", "481930275", "K7M2QX9P"
STALE = "feedfacefeedfacefeedfacefeedface"

def grant(sess=SESS, tok=TOK):
    return {"event": "sessionGranted", "sessionId": sess, "sessionToken": tok,
            "hostDeviceId": HOSTID, "controllerDeviceId": CTRLID}

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

def step(at, do, actions=None, phase=None, **extra):
    s = {"at": at, "do": do}
    if actions is not None:
        s["expectActions"] = actions
    if phase is not None:
        s["expectPhase"] = phase
    s.update(extra)
    return s

def live_controller(remember=True):
    """Steps that bring a controller to live: auth, connect, grant, ICE up."""
    return [
        step(0, auth(), [], "idle"),
        step(0, {"event": "connectRequested", "deviceId": HOSTID,
                 "accessCode": CODE, "remember": remember},
             [a_connect()], "connecting"),
        step(0, grant(), [offer(True)], "connecting"),
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
    step(0, grant(), [offer(True)], "connecting", expectHasSession=True),
    step(0, ice("checking"), [], "connecting"),
    step(0, ice("connected"), [A_RESET], "live"),
])

scen("host_is_never_the_offerer", [
    step(0, auth(), [], "idle"),
    step(0, grant(), [offer(False)], "connecting"),
], role="host")

scen("no_connect_req_while_a_session_is_believed_alive", [
    *live_controller(),
    step(1, {"event": "connectRequested", "deviceId": HOSTID,
             "accessCode": CODE, "remember": False}, [], "live"),
], note="§4.4: a client must never connect_req over its own live session")

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
    step(0, grant(), [offer(True)], "connecting"),
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
    step(1, {"event": "renewSucceeded", "sessionId": "not-our-session",
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
    step(0, grant(), [offer(False)], "connecting"),
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
    step(0, grant(), [offer(True)], "connecting"),
    step(1, ice("connected"), [A_RESET], "live"),
    step(2, ice("disconnected"), [A_RESET], "reconnecting"),
    step(3, {"event": "signalingLost"}, []),
    step(6, auth(SESS), [a_resume()]),
    step(6, {"event": "resumeSucceeded", "sessionId": SESS, "sessionToken": TOK2},
         [A_WATCHES, A_RESET, A_RESTART], "reconnecting"),
])

scen("a_host_does_not_offer_the_ice_restart", [
    step(0, auth(), [], "idle"),
    step(0, grant(), [offer(False)], "connecting"),
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
    step(0, grant(), [offer(True)], "connecting"),
    step(0, ice("connected"), [A_RESET], "live"),
    step(10, ice("failed"), [A_RESET], "reconnecting", expectRelayOnly=True),
], note="RC_ICE_POLICY=relay already: there is nothing left to fall back to")

scen("a_host_never_offers_the_relay_retry", [
    step(0, auth(), [], "idle"),
    step(0, grant(), [offer(False)], "connecting"),
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

out = {"version": 1, "clockNote": "at is seconds from scenario start",
       "scenarios": S}
path = sys.argv[1] if len(sys.argv) > 1 else "session-scenarios.json"
with open(path, "w") as f:
    json.dump(out, f, indent=1)
    f.write("\n")
total = sum(len(s["steps"]) for s in S)
print(f"wrote {len(S)} scenarios / {total} steps to {path}", file=sys.stderr)
