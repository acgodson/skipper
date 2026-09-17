//! PROTOCOL.md §4 as executable code: the session state machine. Performs no
//! I/O; every method returns the [`SessionAction`]s the owner must perform.

#![forbid(unsafe_code)]

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
        matches!(self, Self::Declined | Self::TimedOut)
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
    last_renew: Option<i64>,
    resume_wanted: bool,

    pub server_advertised_session_id: Option<String>,
    cleared_stale_session: bool,

    consent_deadline: Option<i64>,
    peer_start_since: Option<i64>,
    peer_started: bool,
}

impl SessionStateMachine {
    pub fn new(role: Role) -> Self {
        Self {
            ice_restart_delay_ms: 3_000,
            ice_failure_grace_ms: 45_000,
            renew_interval_ms: 300_000,
            consent_timeout_ms: 30_000,
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
            last_renew: None,
            resume_wanted: false,
            server_advertised_session_id: None,
            cleared_stale_session: false,
            consent_deadline: None,
            peer_start_since: None,
            peer_started: false,
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
    pub fn set_relay_only(&mut self, relay_only: bool) {
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

    fn leave_consent(&mut self, outcome: ConsentOutcome) -> Vec<SessionAction> {
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

    pub fn session_granted(&mut self, grant: &SessionGrant, now_ms: i64) -> Vec<SessionAction> {
        self.session_id = Some(grant.session_id.clone());
        self.session_token = Some(grant.session_token.clone());
        self.peer_device_id = Some(match self.role {
            Role::Controller => grant.host_device_id.clone(),
            Role::Host => grant.controller_device_id.clone(),
        });
        if self.role == Role::Host {
            self.remembered_access_code = None;
        }
        self.pending_access_code = None;
        let actions = self.leave_consent(ConsentOutcome::Cancelled);
        self.peer_start_since = None;
        self.peer_started = false;
        self.phase = SessionPhase::Connecting;
        self.last_renew = Some(now_ms);
        self.ice_restart_requested = false;
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
            let expires_at_ms = now_ms.saturating_add(self.consent_timeout_ms);
            self.consent_deadline = Some(expires_at_ms);
            self.phase = SessionPhase::AwaitingConsent;
            return vec![SessionAction::PromptForConsent { expires_at_ms }];
        }
        self.start_peer(now_ms)
    }

    pub fn consent_answered(&mut self, allow: bool, now_ms: i64) -> Vec<SessionAction> {
        if self.phase != SessionPhase::AwaitingConsent {
            return vec![];
        }
        if allow {
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

    pub fn ice_state_changed(
        &mut self,
        new_state: IceLinkState,
        now_ms: i64,
    ) -> Vec<SessionAction> {
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
        self.relay_only = false;
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
