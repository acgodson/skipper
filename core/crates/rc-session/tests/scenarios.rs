use rc_session::{
    ConsentOutcome, IceLinkState, ResumeOk, Role, SessionAction, SessionGrant, SessionPhase,
    SessionStateMachine,
};
use serde_json::Value;

const SCENARIOS: &str = include_str!("../../../../protocol/vectors/session-scenarios.json");

fn ice_state(name: &str) -> IceLinkState {
    match name {
        "new" => IceLinkState::New,
        "checking" => IceLinkState::Checking,
        "connected" => IceLinkState::Connected,
        "completed" => IceLinkState::Completed,
        "disconnected" => IceLinkState::Disconnected,
        "failed" => IceLinkState::Failed,
        "closed" => IceLinkState::Closed,
        other => panic!("unknown ice state {other:?} in scenarios"),
    }
}

fn phase_matches(phase: &SessionPhase, expected: &str) -> bool {
    match (phase, expected) {
        (SessionPhase::Idle, "idle") => true,
        (SessionPhase::Connecting, "connecting") => true,
        (SessionPhase::AwaitingConsent, "awaitingConsent") => true,
        (SessionPhase::Live, "live") => true,
        (SessionPhase::Reconnecting, "reconnecting") => true,
        (SessionPhase::Closed { reason }, e) => {
            e.strip_prefix("closed:").is_some_and(|r| r == reason)
        }
        _ => false,
    }
}

fn action_from_json(v: &Value) -> SessionAction {
    let s = |k: &str| -> String {
        v[k].as_str()
            .unwrap_or_else(|| panic!("action {v} missing string {k:?}"))
            .to_string()
    };
    match v["action"].as_str().expect("action name") {
        "sendConnectReq" => SessionAction::SendConnectReq {
            device_id: s("deviceId"),
            access_code: s("accessCode"),
        },
        "sendResume" => SessionAction::SendResume {
            session_id: s("sessionId"),
            session_token: s("sessionToken"),
        },
        "scheduleResume" => SessionAction::ScheduleResume {
            after_sec: v["afterSec"].as_i64().expect("afterSec") as i32,
        },
        "sendRenew" => SessionAction::SendRenew {
            session_id: s("sessionId"),
            session_token: s("sessionToken"),
        },
        "sendInputReset" => SessionAction::SendInputReset,
        "startPeerConnection" => SessionAction::StartPeerConnection {
            offerer: v["offerer"].as_bool().expect("offerer"),
        },
        "restartICE" => SessionAction::RestartIce {
            relay_only: v["relayOnly"].as_bool().expect("relayOnly"),
        },
        "reissueWatches" => SessionAction::ReissueWatches,
        "teardownPeerConnection" => SessionAction::TeardownPeerConnection,
        "clearStoredSession" => SessionAction::ClearStoredSession,
        "promptForAccessCode" => SessionAction::PromptForAccessCode {
            reason: s("reason"),
        },
        "sendBye" => SessionAction::SendBye {
            session_id: s("sessionId"),
            reason: s("reason"),
        },
        "promptForConsent" => SessionAction::PromptForConsent {
            expires_at_ms: (v["expiresAt"].as_f64().expect("expiresAt") * 1000.0).round() as i64,
            prompt_id: String::new(),
            replaces_previous: v["replacesPrevious"].as_bool().expect("replacesPrevious"),
        },
        "dismissConsentPrompt" => SessionAction::DismissConsentPrompt {
            outcome: ConsentOutcome::from_name(&s("outcome"))
                .unwrap_or_else(|| panic!("unknown consent outcome in {v}")),
        },
        other => panic!("unknown action {other:?} in scenarios"),
    }
}

fn without_prompt_ids(actions: &[SessionAction]) -> Vec<SessionAction> {
    actions
        .iter()
        .cloned()
        .map(|action| match action {
            SessionAction::PromptForConsent {
                expires_at_ms,
                replaces_previous,
                ..
            } => SessionAction::PromptForConsent {
                expires_at_ms,
                prompt_id: String::new(),
                replaces_previous,
            },
            other => other,
        })
        .collect()
}

fn prompt_id_for(event: &Value, prompt_ids: &[String]) -> Option<String> {
    let nth_from_end = |n: usize| {
        prompt_ids
            .len()
            .checked_sub(n)
            .map(|index| prompt_ids[index].clone())
            .or_else(|| Some("0".repeat(32)))
    };
    match event["prompt"].as_str() {
        Some("current") => nth_from_end(1),
        Some("previous") => nth_from_end(2),
        Some(other) => panic!("unknown prompt reference {other:?}"),
        None => event["promptId"].as_str().map(str::to_string),
    }
}

#[test]
fn every_shared_scenario_passes_against_the_rust_machine() {
    let file: Value = serde_json::from_str(SCENARIOS).expect("scenarios parse");
    let scenarios = file["scenarios"].as_array().expect("scenarios array");
    assert!(scenarios.len() >= 80, "scenario file looks truncated");

    let mut steps_run = 0usize;
    for scenario in scenarios {
        let name = scenario["name"].as_str().expect("name");
        let role = match scenario["role"].as_str().expect("role") {
            "controller" => Role::Controller,
            "host" => Role::Host,
            other => panic!("{name}: unknown role {other:?}"),
        };
        let mut machine = SessionStateMachine::new(role);
        let mut prompt_ids: Vec<String> = vec![];

        for (i, step) in scenario["steps"]
            .as_array()
            .expect("steps")
            .iter()
            .enumerate()
        {
            let at = step["at"].as_f64().expect("at");
            let now_ms = (at * 1000.0).round() as i64;
            let ctx = || format!("scenario {name:?} step {i} (at {at}s)");
            let e = &step["do"];

            let actions: Option<Vec<SessionAction>> = match e["event"].as_str().expect("event") {
                "connectRequested" => Some(machine.connect_requested(
                    e["deviceId"].as_str().unwrap(),
                    e["accessCode"].as_str().unwrap(),
                    e["remember"].as_bool().unwrap(),
                )),
                "sessionGranted" => Some(machine.session_granted(
                    &SessionGrant {
                        session_id: e["sessionId"].as_str().unwrap().into(),
                        session_token: e["sessionToken"].as_str().unwrap().into(),
                        host_device_id: e["hostDeviceId"].as_str().unwrap().into(),
                        controller_device_id: e["controllerDeviceId"].as_str().unwrap().into(),
                    },
                    now_ms,
                )),
                "connectFailed" => Some(machine.connect_failed(e["code"].as_str().unwrap())),
                "signalingLost" => Some(machine.signaling_lost()),
                "signalingAuthenticated" => {
                    Some(machine.signaling_authenticated(e["activeSessionId"].as_str()))
                }
                "resumeSucceeded" => Some(machine.resume_succeeded(
                    &ResumeOk {
                        session_id: e["sessionId"].as_str().unwrap().into(),
                        session_token: e["sessionToken"].as_str().unwrap().into(),
                    },
                    now_ms,
                )),
                "resumeFailed" => Some(machine.resume_failed(
                    e["code"].as_str().unwrap(),
                    e["retryAfterSec"].as_i64().unwrap() as i32,
                )),
                "iceStateChanged" => {
                    Some(machine.ice_state_changed(ice_state(e["state"].as_str().unwrap()), now_ms))
                }
                "tick" => Some(machine.tick(now_ms)),
                "renewSucceeded" => {
                    machine.renew_succeeded(
                        &ResumeOk {
                            session_id: e["sessionId"].as_str().unwrap().into(),
                            session_token: e["sessionToken"].as_str().unwrap().into(),
                        },
                        now_ms,
                    );
                    None
                }
                "renewFailed" => Some(machine.renew_failed(e["code"].as_str().unwrap())),
                "setRelayOnly" => {
                    machine.set_relay_only(e["relayOnly"].as_bool().unwrap());
                    Some(vec![])
                }
                "closeLocally" => Some(machine.close_locally(e["reason"].as_str().unwrap())),
                "userEnded" => Some(machine.user_ended(e["reason"].as_str().unwrap())),
                "pakeSucceeded" => Some(machine.pake_succeeded(now_ms)),
                "consentAnswered" => {
                    let prompt_id = prompt_id_for(e, &prompt_ids);
                    Some(machine.consent_answered(
                        e["allow"].as_bool().unwrap(),
                        prompt_id.as_deref(),
                        now_ms,
                    ))
                }
                "iceServersArrived" => {
                    Some(machine.ice_servers_arrived(e["sessionId"].as_str().unwrap()))
                }
                "setConsentRequired" => {
                    machine.consent_required = e["required"].as_bool().unwrap();
                    Some(vec![])
                }
                other => panic!("{}: unknown event {other:?}", ctx()),
            };

            for action in actions.iter().flatten() {
                if let SessionAction::PromptForConsent { prompt_id, .. } = action {
                    assert_eq!(prompt_id.len(), 32, "{}: prompt id {prompt_id:?}", ctx());
                    assert!(
                        machine.session_id() != Some(prompt_id.as_str()),
                        "{}: a prompt is never named by the session id",
                        ctx()
                    );
                    assert!(
                        !prompt_ids.contains(prompt_id),
                        "{}: reused prompt id",
                        ctx()
                    );
                    prompt_ids.push(prompt_id.clone());
                }
            }
            let rejected = machine.take_rejection();
            let expect_rejected = step
                .get("expectRejected")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            assert_eq!(
                rejected.is_some(),
                expect_rejected,
                "{}: rejection {rejected:?}",
                ctx()
            );
            if let Some(expected) = step.get("expectActions") {
                let expected: Vec<SessionAction> = expected
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(action_from_json)
                    .collect();
                let actions =
                    without_prompt_ids(actions.as_ref().unwrap_or_else(|| {
                        panic!("{}: expectActions on a non-action event", ctx())
                    }));
                assert_eq!(
                    actions,
                    expected,
                    "{}: actions differ\n  got:      {actions:?}\n  expected: {expected:?}",
                    ctx()
                );
            }
            if let Some(phase) = step.get("expectPhase").and_then(Value::as_str) {
                assert!(
                    phase_matches(machine.phase(), phase),
                    "{}: phase is {:?}, expected {phase:?}",
                    ctx(),
                    machine.phase()
                );
            }
            if let Some(v) = step.get("expectHasSession").and_then(Value::as_bool) {
                assert_eq!(machine.has_session(), v, "{}: hasSession", ctx());
            }
            if let Some(v) = step.get("expectResumeInFlight").and_then(Value::as_bool) {
                assert_eq!(machine.resume_in_flight(), v, "{}: resumeInFlight", ctx());
            }
            if let Some(v) = step.get("expectConsentRequired").and_then(Value::as_bool) {
                assert_eq!(machine.consent_required, v, "{}: consentRequired", ctx());
            }
            if let Some(v) = step.get("expectRelayOnly").and_then(Value::as_bool) {
                assert_eq!(machine.relay_only(), v, "{}: relayOnly", ctx());
            }
            if let Some(v) = step.get("expectPeerStarted").and_then(Value::as_bool) {
                assert_eq!(machine.peer_started(), v, "{}: peerStarted", ctx());
            }
            if let Some(v) = step.get("expectPeerDeviceId") {
                let expected = v.as_str().filter(|id| !id.is_empty());
                assert_eq!(
                    machine.peer_device_id(),
                    expected,
                    "{}: peerDeviceId",
                    ctx()
                );
            }
            steps_run += 1;
        }
    }
    assert!(
        steps_run >= 550,
        "only {steps_run} steps ran; file looks truncated"
    );
}
