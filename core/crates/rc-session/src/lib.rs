//! PROTOCOL.md §4 as executable code: the session state machine. Performs no
//! I/O; every method returns the [`SessionAction`]s the owner must perform.

#![forbid(unsafe_code)]

pub mod input;

pub use input::InputError;

use rand_core::{OsRng, RngCore};

const PROMPT_ID_BYTES: usize = 16;

fn new_prompt_id() -> Option<String> {
    let mut bytes = [0u8; PROMPT_ID_BYTES];
    OsRng.try_fill_bytes(&mut bytes).ok()?;
    Some(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IceLinkState {
    New,
    Checking,
    Connected,
    Completed,
    Disconnected,
    Failed,
    Closed,
}

impl IceLinkState {
    pub fn is_up(self) -> bool {
        matches!(self, Self::Connected | Self::Completed)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionPhase {
    Idle,
    Connecting,
    AwaitingConsent,
    Live,
    Reconnecting,
    Closed { reason: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    Host,
    Controller,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionAction {
    SendConnectReq {
        device_id: String,
        access_code: String,
    },
    SendResume {
        session_id: String,
        session_token: String,
    },
    ScheduleResume {
        after_sec: i32,
    },
    SendRenew {
        session_id: String,
        session_token: String,
    },
    SendInputReset,
    StartPeerConnection {
        offerer: bool,
    },
    RestartIce {
        relay_only: bool,
    },
    ReissueWatches,
    TeardownPeerConnection,
    ClearStoredSession,
    PromptForAccessCode {
        reason: String,
    },
    SendBye {
        session_id: String,
        reason: String,
    },
    PromptForConsent {
        expires_at_ms: i64,
        prompt_id: String,
        replaces_previous: bool,
    },
    DismissConsentPrompt {
        outcome: ConsentOutcome,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConsentOutcome {
    Allowed,
    Declined,
    TimedOut,
    Cancelled,
}

impl ConsentOutcome {
    pub fn name(self) -> &'static str {
        match self {
            Self::Allowed => "allowed",
            Self::Declined => "declined",
            Self::TimedOut => "timedOut",
            Self::Cancelled => "cancelled",
        }
    }

    pub fn from_name(name: &str) -> Option<Self> {
        [
            Self::Allowed,
            Self::Declined,
            Self::TimedOut,
            Self::Cancelled,
        ]
        .into_iter()
        .find(|outcome| outcome.name() == name)
    }

    pub fn counts_as_decline(self) -> bool {
        self != Self::Allowed
    }
}

#[derive(Debug, Clone)]
pub struct SessionGrant {
    pub session_id: String,
    pub session_token: String,
    pub host_device_id: String,
    pub controller_device_id: String,
}

#[derive(Debug, Clone)]
pub struct ResumeOk {
    pub session_id: String,
    pub session_token: String,
}

pub type RenewOk = ResumeOk;

#[derive(Debug, Clone)]
pub struct SessionStateMachine {
    pub ice_restart_delay_ms: i64,
    pub ice_failure_grace_ms: i64,
    pub renew_interval_ms: i64,
    pub consent_timeout_ms: i64,
    pub consent_allow_delay_ms: i64,
    pub peer_start_timeout_ms: i64,
    pub consent_required: bool,

    role: Role,
    session_id: Option<String>,
    session_token: Option<String>,
    peer_device_id: Option<String>,
    pub remembered_access_code: Option<String>,
    pending_access_code: Option<String>,

    phase: SessionPhase,
    signaling_up: bool,
    ice_state: IceLinkState,
    resume_in_flight: bool,

    disconnected_since: Option<i64>,
    failed_since: Option<i64>,
    ice_restart_requested: bool,
    relay_only: bool,
    relay_only_baseline: bool,
    last_renew: Option<i64>,
    resume_wanted: bool,

    pub server_advertised_session_id: Option<String>,
    cleared_stale_session: bool,

    consent_deadline: Option<i64>,
    consent_allow_after: Option<i64>,
    consent_prompt_id: Option<String>,
    prompt_replaced: bool,
    peer_start_since: Option<i64>,
    peer_started: bool,
    last_rejection: Option<InputError>,
}

impl SessionStateMachine {
    pub fn new(role: Role) -> Self {
        Self {
            ice_restart_delay_ms: 3_000,
            ice_failure_grace_ms: 45_000,
            renew_interval_ms: 300_000,
            consent_timeout_ms: 30_000,
            consent_allow_delay_ms: 1_500,
            peer_start_timeout_ms: 45_000,
            consent_required: false,
            role,
            session_id: None,
            session_token: None,
            peer_device_id: None,
            remembered_access_code: None,
            pending_access_code: None,
            phase: SessionPhase::Idle,
            signaling_up: false,
            ice_state: IceLinkState::New,
            resume_in_flight: false,
            disconnected_since: None,
            failed_since: None,
            ice_restart_requested: false,
            relay_only: false,
            relay_only_baseline: false,
            last_renew: None,
            resume_wanted: false,
            server_advertised_session_id: None,
            cleared_stale_session: false,
            consent_deadline: None,
            consent_allow_after: None,
            consent_prompt_id: None,
            prompt_replaced: false,
            peer_start_since: None,
            peer_started: false,
            last_rejection: None,
        }
    }

    pub fn role(&self) -> Role {
        self.role
    }
    pub fn phase(&self) -> &SessionPhase {
        &self.phase
    }
    pub fn session_id(&self) -> Option<&str> {
        self.session_id.as_deref()
    }
    pub fn session_token(&self) -> Option<&str> {
        self.session_token.as_deref()
    }
    pub fn peer_device_id(&self) -> Option<&str> {
        self.peer_device_id.as_deref()
    }
    pub fn signaling_up(&self) -> bool {
        self.signaling_up
    }
    pub fn ice_state(&self) -> IceLinkState {
        self.ice_state
    }
    pub fn resume_in_flight(&self) -> bool {
        self.resume_in_flight
    }
    pub fn relay_only(&self) -> bool {
        self.relay_only
    }
    /// The relay policy every session starts with (a forced relay, for
    /// example); a session's own fallback to relay ends with the session.
    pub fn set_relay_only(&mut self, relay_only: bool) {
        self.relay_only_baseline = relay_only;
        self.relay_only = relay_only;
    }

    pub fn is_offerer(&self) -> bool {
        self.role == Role::Controller
    }

    pub fn has_session(&self) -> bool {
        self.session_id.is_some() && self.session_token.is_some()
    }

    pub fn consent_expires_at_ms(&self) -> Option<i64> {
        self.consent_deadline
    }

    pub fn peer_started(&self) -> bool {
        self.peer_started
    }

    /// The local, random name of the open consent prompt. It is never the
    /// server's session id, so the server cannot aim an answer at a prompt.
    pub fn consent_prompt_id(&self) -> Option<&str> {
        self.consent_prompt_id.as_deref()
    }

    /// Why the last event was refused, if it was. A refused event performs
    /// no action.
    pub fn take_rejection(&mut self) -> Option<InputError> {
        self.last_rejection.take()
    }

    fn reject(&mut self, error: InputError) -> Vec<SessionAction> {
        self.last_rejection = Some(error);
        vec![]
    }

    fn leave_consent(&mut self, outcome: ConsentOutcome) -> Vec<SessionAction> {
        self.consent_allow_after = None;
        self.consent_prompt_id = None;
        match self.consent_deadline.take() {
            Some(_) => vec![SessionAction::DismissConsentPrompt { outcome }],
            None => vec![],
        }
    }

    pub fn connect_requested(
        &mut self,
        device_id: &str,
        access_code: &str,
        remember: bool,
    ) -> Vec<SessionAction> {
        if let Err(error) = input::device_id(device_id) {
            return self.reject(error);
        }
        if self.has_session() {
            return vec![];
        }
        self.peer_device_id = Some(device_id.to_string());
        self.pending_access_code = Some(access_code.to_string());
        if remember {
            self.remembered_access_code = Some(access_code.to_string());
        }
        self.phase = SessionPhase::Connecting;
        if !self.signaling_up {
            return vec![];
        }
        vec![SessionAction::SendConnectReq {
            device_id: device_id.to_string(),
            access_code: access_code.to_string(),
        }]
    }

    /// A new session never inherits the previous one's peer connection, link
    /// state or prompt: the teardown comes before anything else.
    pub fn session_granted(&mut self, grant: &SessionGrant, now_ms: i64) -> Vec<SessionAction> {
        let checked = input::session_id(&grant.session_id)
            .and_then(|_| input::device_id(&grant.host_device_id));
        if let Err(error) = checked {
            return self.reject(error);
        }
        let mut actions = vec![SessionAction::TeardownPeerConnection];
        let dismissed = self.leave_consent(ConsentOutcome::Cancelled);
        self.prompt_replaced = !dismissed.is_empty();
        actions.extend(dismissed);
        self.session_id = Some(grant.session_id.clone());
        self.session_token = Some(grant.session_token.clone());
        self.peer_device_id = match self.role {
            Role::Controller => Some(grant.host_device_id.clone()),
            Role::Host => input::device_id(&grant.controller_device_id)
                .ok()
                .map(|_| grant.controller_device_id.clone()),
        };
        if self.role == Role::Host {
            self.remembered_access_code = None;
        }
        self.pending_access_code = None;
        self.peer_start_since = None;
        self.peer_started = false;
        self.ice_state = IceLinkState::New;
        self.disconnected_since = None;
        self.failed_since = None;
        self.ice_restart_requested = false;
        self.relay_only = self.relay_only_baseline;
        self.resume_in_flight = false;
        self.resume_wanted = false;
        self.phase = SessionPhase::Connecting;
        self.last_renew = Some(now_ms);
        actions
    }

    /// The §2.17 exchange verified. The peer connection starts now, unless
    /// this host asks its owner first (§2.17 Consent).
    pub fn pake_succeeded(&mut self, now_ms: i64) -> Vec<SessionAction> {
        let waiting = matches!(
            self.phase,
            SessionPhase::Connecting | SessionPhase::Reconnecting
        );
        if !self.has_session() || !waiting || self.peer_started {
            return vec![];
        }
        if self.role == Role::Host && self.consent_required {
            let Some(prompt_id) = new_prompt_id() else {
                return self.user_ended(rc_proto::consts::bye::DECLINED);
            };
            let expires_at_ms = now_ms.saturating_add(self.consent_timeout_ms);
            self.consent_deadline = Some(expires_at_ms);
            self.consent_allow_after = Some(now_ms.saturating_add(self.consent_allow_delay_ms));
            self.consent_prompt_id = Some(prompt_id.clone());
            self.phase = SessionPhase::AwaitingConsent;
            return vec![SessionAction::PromptForConsent {
                expires_at_ms,
                prompt_id,
                replaces_previous: std::mem::take(&mut self.prompt_replaced),
            }];
        }
        self.start_peer(now_ms)
    }

    /// `prompt_id` names the prompt being answered (`consent_prompt_id`); an
    /// answer for any other prompt changes nothing. Allow needs that name, the
    /// machine still waiting, and the prompt on screen for at least
    /// `consent_allow_delay_ms`; an earlier Allow is refused, not deferred.
    /// Decline without a name is this machine's own decision.
    pub fn consent_answered(
        &mut self,
        allow: bool,
        prompt_id: Option<&str>,
        now_ms: i64,
    ) -> Vec<SessionAction> {
        let Some(open) = self.consent_prompt_id.as_deref() else {
            return vec![];
        };
        if prompt_id.is_some_and(|id| id != open) {
            return vec![];
        }
        if allow {
            let too_early = self.consent_allow_after.is_some_and(|at| now_ms < at);
            if prompt_id.is_none() || self.phase != SessionPhase::AwaitingConsent || too_early {
                return vec![];
            }
            let mut actions = self.leave_consent(ConsentOutcome::Allowed);
            self.phase = SessionPhase::Connecting;
            actions.extend(self.start_peer(now_ms));
            return actions;
        }
        self.decline(ConsentOutcome::Declined)
    }

    fn decline(&mut self, outcome: ConsentOutcome) -> Vec<SessionAction> {
        let mut actions = self.leave_consent(outcome);
        actions.extend(self.user_ended(rc_proto::consts::bye::DECLINED));
        actions
    }

    fn start_peer(&mut self, now_ms: i64) -> Vec<SessionAction> {
        self.peer_start_since = Some(now_ms);
        self.peer_started = true;
        vec![SessionAction::StartPeerConnection {
            offerer: self.is_offerer(),
        }]
    }

    pub fn connect_failed(&mut self, code: &str) -> Vec<SessionAction> {
        if code == rc_proto::consts::err::BUSY && !self.cleared_stale_session {
            if let (Some(stale), Some(peer), Some(access_code)) = (
                self.server_advertised_session_id.clone(),
                self.peer_device_id.clone(),
                self.pending_access_code
                    .clone()
                    .or_else(|| self.remembered_access_code.clone()),
            ) {
                self.cleared_stale_session = true;
                self.server_advertised_session_id = None;
                return vec![
                    SessionAction::SendBye {
                        session_id: stale,
                        reason: "stale_no_token".into(),
                    },
                    SessionAction::SendConnectReq {
                        device_id: peer,
                        access_code,
                    },
                ];
            }
        }
        self.pending_access_code = None;
        self.phase = SessionPhase::Closed {
            reason: code.to_string(),
        };
        vec![]
    }

    pub fn signaling_lost(&mut self) -> Vec<SessionAction> {
        self.signaling_up = false;
        self.resume_in_flight = false;
        if self.has_session() {
            self.resume_wanted = true;
            if !self.ice_state.is_up() && self.phase != SessionPhase::AwaitingConsent {
                self.phase = SessionPhase::Reconnecting;
            }
        }
        vec![]
    }

    pub fn signaling_authenticated(
        &mut self,
        active_session_id: Option<&str>,
    ) -> Vec<SessionAction> {
        let active_session_id = active_session_id.filter(|id| input::session_id(id).is_ok());
        self.signaling_up = true;
        self.server_advertised_session_id = active_session_id.map(str::to_string);

        if self.session_id.is_none() && self.session_token.is_some() {
            if let Some(id) = active_session_id {
                self.session_id = Some(id.to_string());
            }
        }

        if self.phase == SessionPhase::Connecting
            && self.session_id.is_none()
            && self.session_token.is_none()
        {
            if let (Some(stale), Some(peer), Some(code)) = (
                active_session_id,
                self.peer_device_id.clone(),
                self.pending_access_code
                    .clone()
                    .or_else(|| self.remembered_access_code.clone()),
            ) {
                return vec![
                    SessionAction::SendBye {
                        session_id: stale.to_string(),
                        reason: "stale_no_token".into(),
                    },
                    SessionAction::SendConnectReq {
                        device_id: peer,
                        access_code: code,
                    },
                ];
            }
        }

        if self.has_session() {
            self.resume_wanted = true;
            return self.begin_resume_if_possible();
        }
        if self.phase == SessionPhase::Connecting {
            if let (Some(peer), Some(code)) = (
                self.peer_device_id.clone(),
                self.pending_access_code
                    .clone()
                    .or_else(|| self.remembered_access_code.clone()),
            ) {
                return vec![SessionAction::SendConnectReq {
                    device_id: peer,
                    access_code: code,
                }];
            }
        }
        vec![]
    }

    fn begin_resume_if_possible(&mut self) -> Vec<SessionAction> {
        if !self.resume_wanted || !self.signaling_up || self.resume_in_flight {
            return vec![];
        }
        let (Some(id), Some(token)) = (self.session_id.clone(), self.session_token.clone()) else {
            return vec![];
        };
        self.resume_in_flight = true;
        self.resume_wanted = false;
        vec![SessionAction::SendResume {
            session_id: id,
            session_token: token,
        }]
    }

    pub fn resume_succeeded(&mut self, ok: &ResumeOk, now_ms: i64) -> Vec<SessionAction> {
        if let Err(error) = self.check_own_session(&ok.session_id) {
            if self.resume_in_flight {
                self.resume_in_flight = false;
                self.resume_wanted = true;
            }
            return self.reject(error);
        }
        self.resume_in_flight = false;
        self.session_id = Some(ok.session_id.clone());
        self.session_token = Some(ok.session_token.clone());
        self.last_renew = Some(now_ms);
        let mut actions = vec![SessionAction::ReissueWatches, SessionAction::SendInputReset];
        if self.phase == SessionPhase::AwaitingConsent {
            return actions;
        }
        if !self.ice_state.is_up() {
            self.phase = SessionPhase::Reconnecting;
            if self.is_offerer() {
                self.ice_restart_requested = true;
                actions.push(SessionAction::RestartIce {
                    relay_only: self.relay_only,
                });
            }
        } else {
            self.phase = SessionPhase::Live;
        }
        actions
    }

    pub fn resume_failed(&mut self, code: &str, retry_after_sec: i32) -> Vec<SessionAction> {
        use rc_proto::consts::err;
        self.resume_in_flight = false;

        if code == err::RATE_LIMITED {
            self.resume_wanted = true;
            return vec![SessionAction::ScheduleResume {
                after_sec: retry_after_sec.max(1),
            }];
        }

        if code != err::NO_SESSION && code != err::BAD_TOKEN {
            self.resume_wanted = true;
            return vec![];
        }

        let dismissed = self.leave_consent(ConsentOutcome::Cancelled);
        self.session_id = None;
        self.session_token = None;
        self.ice_restart_requested = false;
        self.disconnected_since = None;
        self.failed_since = None;
        self.peer_start_since = None;
        self.peer_started = false;

        if self.role == Role::Controller {
            if let (Some(peer), Some(code)) = (
                self.peer_device_id.clone(),
                self.remembered_access_code.clone(),
            ) {
                self.phase = SessionPhase::Connecting;
                let mut actions = vec![
                    SessionAction::TeardownPeerConnection,
                    SessionAction::ClearStoredSession,
                ];
                if self.signaling_up {
                    actions.push(SessionAction::SendConnectReq {
                        device_id: peer,
                        access_code: code,
                    });
                }
                return actions;
            }
        }

        self.phase = SessionPhase::Idle;
        let mut actions = dismissed;
        actions.extend([
            SessionAction::TeardownPeerConnection,
            SessionAction::ClearStoredSession,
            SessionAction::PromptForAccessCode {
                reason: code.to_string(),
            },
        ]);
        actions
    }

    fn check_own_session(&self, session_id: &str) -> Result<(), InputError> {
        input::session_id(session_id)?;
        match self.session_id.as_deref() {
            Some(own) if own != session_id => Err(InputError::SessionMismatch),
            _ => Ok(()),
        }
    }

    /// Only the peer connection this machine started moves the phase, and
    /// never while the owner is being asked.
    pub fn ice_state_changed(
        &mut self,
        new_state: IceLinkState,
        now_ms: i64,
    ) -> Vec<SessionAction> {
        if !self.peer_started || self.phase == SessionPhase::AwaitingConsent {
            return vec![];
        }
        let previous = self.ice_state;
        self.ice_state = new_state;
        if !self.has_session() {
            return vec![];
        }

        match new_state {
            IceLinkState::Connected | IceLinkState::Completed => {
                self.peer_start_since = None;
                self.disconnected_since = None;
                self.failed_since = None;
                self.ice_restart_requested = false;
                self.phase = SessionPhase::Live;
                if previous.is_up() {
                    vec![]
                } else {
                    vec![SessionAction::SendInputReset]
                }
            }
            IceLinkState::Disconnected => {
                if self.disconnected_since.is_none() {
                    self.disconnected_since = Some(now_ms);
                }
                self.failed_since = None;
                self.phase = SessionPhase::Reconnecting;
                vec![SessionAction::SendInputReset]
            }
            IceLinkState::Failed => {
                if self.failed_since.is_none() {
                    self.failed_since = Some(now_ms);
                }
                self.phase = SessionPhase::Reconnecting;
                let mut actions = vec![SessionAction::SendInputReset];
                if !self.relay_only && self.is_offerer() {
                    self.relay_only = true;
                    self.ice_restart_requested = true;
                    self.disconnected_since = None;
                    actions.push(SessionAction::RestartIce { relay_only: true });
                }
                actions
            }
            IceLinkState::Closed | IceLinkState::New | IceLinkState::Checking => vec![],
        }
    }

    /// The server's `ice_servers` push (protocol v5): this session's relay
    /// credentials arrived. A relay-only offerer whose link never came up
    /// gathered nothing without them, so it restarts ICE once they are here.
    pub fn ice_servers_arrived(&mut self, session_id: &str) -> Vec<SessionAction> {
        if let Err(error) = input::session_id(session_id) {
            return self.reject(error);
        }
        if self.session_id.as_deref() != Some(session_id) {
            return self.reject(InputError::SessionMismatch);
        }
        let waiting_on_relay = self.relay_only
            && self.is_offerer()
            && self.peer_started
            && !self.ice_state.is_up()
            && !self.ice_restart_requested;
        if !waiting_on_relay {
            return vec![];
        }
        self.ice_restart_requested = true;
        vec![SessionAction::RestartIce { relay_only: true }]
    }

    pub fn tick(&mut self, now_ms: i64) -> Vec<SessionAction> {
        let mut actions = vec![];
        if !self.has_session() {
            return actions;
        }

        if self
            .consent_deadline
            .is_some_and(|deadline| now_ms >= deadline)
        {
            return self.decline(ConsentOutcome::TimedOut);
        }

        if let Some(since) = self.peer_start_since {
            if now_ms - since >= self.peer_start_timeout_ms {
                return self.user_ended(rc_proto::consts::bye::TIMEOUT);
            }
        }

        if let Some(since) = self.disconnected_since {
            if !self.ice_restart_requested && now_ms - since >= self.ice_restart_delay_ms {
                self.ice_restart_requested = true;
                if self.is_offerer() {
                    actions.push(SessionAction::RestartIce {
                        relay_only: self.relay_only,
                    });
                }
            }
        }

        if let Some(since) = self.failed_since {
            if now_ms - since >= self.ice_failure_grace_ms {
                let id = self.session_id.clone();
                let reason = rc_proto::consts::bye::FAILED;
                actions.extend(self.close_locally(reason));
                if let Some(id) = id {
                    actions.push(SessionAction::SendBye {
                        session_id: id,
                        reason: reason.to_string(),
                    });
                }
                return actions;
            }
        }

        if self.signaling_up && !self.resume_in_flight {
            if let (Some(id), Some(token), Some(last)) = (
                self.session_id.clone(),
                self.session_token.clone(),
                self.last_renew,
            ) {
                if now_ms - last >= self.renew_interval_ms {
                    self.last_renew = Some(now_ms);
                    actions.push(SessionAction::SendRenew {
                        session_id: id,
                        session_token: token,
                    });
                }
            }
        }

        actions.extend(self.begin_resume_if_possible());
        actions
    }

    pub fn renew_succeeded(&mut self, ok: &RenewOk, now_ms: i64) {
        if let Err(error) = input::session_id(&ok.session_id) {
            self.last_rejection = Some(error);
            return;
        }
        if Some(ok.session_id.as_str()) != self.session_id.as_deref() {
            return;
        }
        self.session_token = Some(ok.session_token.clone());
        self.last_renew = Some(now_ms);
    }

    pub fn renew_failed(&mut self, code: &str) -> Vec<SessionAction> {
        use rc_proto::consts::err;
        if code != err::NO_SESSION && code != err::BAD_TOKEN {
            return vec![];
        }
        self.resume_failed(code, 0)
    }

    pub fn close_locally(&mut self, reason: &str) -> Vec<SessionAction> {
        let mut actions = self.leave_consent(ConsentOutcome::Cancelled);
        self.peer_start_since = None;
        self.peer_started = false;
        self.session_id = None;
        self.session_token = None;
        self.pending_access_code = None;
        self.resume_in_flight = false;
        self.resume_wanted = false;
        self.disconnected_since = None;
        self.failed_since = None;
        self.ice_restart_requested = false;
        self.relay_only = self.relay_only_baseline;
        self.prompt_replaced = false;
        self.ice_state = IceLinkState::Closed;
        self.phase = SessionPhase::Closed {
            reason: reason.to_string(),
        };
        actions.extend([
            SessionAction::SendInputReset,
            SessionAction::TeardownPeerConnection,
            SessionAction::ClearStoredSession,
        ]);
        actions
    }

    pub fn user_ended(&mut self, reason: &str) -> Vec<SessionAction> {
        let Some(id) = self.session_id.clone() else {
            self.phase = SessionPhase::Idle;
            return vec![];
        };
        let mut actions = vec![SessionAction::SendBye {
            session_id: id,
            reason: reason.to_string(),
        }];
        actions.extend(self.close_locally(reason));
        actions
    }
}
