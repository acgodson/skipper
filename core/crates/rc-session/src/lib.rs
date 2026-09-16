//! PROTOCOL.md §4 as executable code — the Rust port of
//! `app/Sources/RemoteControlCore/Signaling/SessionStateMachine.swift`.
//!
//! That file is the proven implementation: it carries the fixes that were paid
//! for in the field (the stale-session dead end, the busy-retry-once guard, the
//! flutter rules). This port is held equal to it not by review but by
//! `protocol/vectors/session-scenarios.json`, which both test suites execute.
//! If the two machines ever disagree on a scenario, one suite goes red.
//!
//! Like the original it performs no I/O and holds no timers: every method
//! returns the [`SessionAction`]s the owner must perform, and the owner calls
//! [`SessionStateMachine::tick`] with the current time. Time is Unix
//! milliseconds throughout, matching the protocol's convention.

#![forbid(unsafe_code)]

/// ICE connection states we care about, decoupled from any WebRTC library's
/// enum so this crate stays testable without a peer connection.
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

/// What the UI shows. `Reconnecting` is deliberately distinct from `Closed`:
/// PLAN.md §2.1 says a wobble must never look like a dead session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionPhase {
    Idle,
    Connecting,
    Live,
    Reconnecting,
    Closed { reason: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    Host,
    Controller,
}

/// The side effects the machine asks its owner to perform. Returning them
/// rather than performing them is what makes §4 testable without a network.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionAction {
    SendConnectReq { device_id: String, access_code: String },
    SendResume { session_id: String, session_token: String },
    /// Retry `resume` after a server-mandated delay (§4.3 step 6).
    ScheduleResume { after_sec: i32 },
    SendRenew { session_id: String, session_token: String },
    /// PROTOCOL.md §4.4: after every resume and every detected disconnect.
    SendInputReset,
    StartPeerConnection { offerer: bool },
    RestartIce,
    ReissueWatches,
    TeardownPeerConnection,
    ClearStoredSession,
    /// The ONLY action that may put the access-code prompt back on screen
    /// (§4.3 step 5).
    PromptForAccessCode { reason: String },
    SendBye { session_id: String, reason: String },
}

/// The fields of `connect_ok` / `session_start` the machine needs.
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
    // Configuration, in milliseconds.
    pub ice_restart_delay_ms: i64,
    pub ice_failure_grace_ms: i64,
    pub renew_interval_ms: i64,

    role: Role,
    session_id: Option<String>,
    /// The newest token. Rotated on every `resume_ok` / `renew_ok`; §4.4 says
    /// losing it means losing the resume path.
    session_token: Option<String>,
    peer_device_id: Option<String>,
    /// The access code the controller may silently reuse. Present only when the
    /// user chose Remember; without it a dead session must prompt.
    pub remembered_access_code: Option<String>,
    /// The code the user just typed for a connect that has not completed yet.
    pending_access_code: Option<String>,

    phase: SessionPhase,
    signaling_up: bool,
    ice_state: IceLinkState,
    /// §4.4: "Clients must not have two `resume`s in flight."
    resume_in_flight: bool,

    disconnected_since: Option<i64>,
    failed_since: Option<i64>,
    ice_restart_requested: bool,
    last_renew: Option<i64>,
    /// Set when a resume has been asked for but the socket was not up yet.
    resume_wanted: bool,

    /// Whatever the last `hello_ok` said we own. Kept so a `busy` can be
    /// recognised as OUR session rather than a stranger's.
    pub server_advertised_session_id: Option<String>,
    /// One-shot guard: clear a stale session and retry at most once, so a
    /// genuine `busy` from a real second controller can never become a retry loop.
    cleared_stale_session: bool,
}

impl SessionStateMachine {
    pub fn new(role: Role) -> Self {
        Self {
            ice_restart_delay_ms: 3_000,
            ice_failure_grace_ms: 45_000,
            renew_interval_ms: 300_000,
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
            last_renew: None,
            resume_wanted: false,
            server_advertised_session_id: None,
            cleared_stale_session: false,
        }
    }

    // Observable state.
    pub fn role(&self) -> Role { self.role }
    pub fn phase(&self) -> &SessionPhase { &self.phase }
    pub fn session_id(&self) -> Option<&str> { self.session_id.as_deref() }
    pub fn session_token(&self) -> Option<&str> { self.session_token.as_deref() }
    pub fn peer_device_id(&self) -> Option<&str> { self.peer_device_id.as_deref() }
    pub fn signaling_up(&self) -> bool { self.signaling_up }
    pub fn ice_state(&self) -> IceLinkState { self.ice_state }
    pub fn resume_in_flight(&self) -> bool { self.resume_in_flight }

    /// The controller offers by default, both for the first negotiation (§2.9)
    /// and for ICE restarts (§4.3 step 4).
    pub fn is_offerer(&self) -> bool {
        self.role == Role::Controller
    }

    pub fn has_session(&self) -> bool {
        self.session_id.is_some() && self.session_token.is_some()
    }

    // ------------------------------------------------------------------
    // Controller-initiated connect
    // ------------------------------------------------------------------

    /// The user pressed Connect. Only legal from `Idle`/`Closed`; a client must
    /// never `connect_req` for a session it believes is alive (§4.4).
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
            return vec![]; // sent as soon as the socket is up
        }
        vec![SessionAction::SendConnectReq {
            device_id: device_id.to_string(),
            access_code: access_code.to_string(),
        }]
    }

    /// `connect_ok` (controller) or `session_start` (host).
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
        self.phase = SessionPhase::Connecting;
        self.last_renew = Some(now_ms);
        self.ice_restart_requested = false;
        vec![SessionAction::StartPeerConnection { offerer: self.is_offerer() }]
    }

    pub fn connect_failed(&mut self, code: &str) -> Vec<SessionAction> {
        // `busy` caused by OUR OWN unusable session is recoverable, and it is
        // the single failure that has actually blocked this user in practice.
        // §4.4 says recover with `resume` — but that needs a token we no longer
        // have, so we discard the session instead and connect fresh. `bye` is
        // authorised by device identity server-side, so we may close it.
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
                    SessionAction::SendBye { session_id: stale, reason: "stale_no_token".into() },
                    SessionAction::SendConnectReq { device_id: peer, access_code },
                ];
            }
        }
        self.pending_access_code = None;
        self.phase = SessionPhase::Closed { reason: code.to_string() };
        vec![]
    }

    // ------------------------------------------------------------------
    // Signaling transitions (§4.3)
    // ------------------------------------------------------------------

    /// Step 1: the control plane died. **Nothing is torn down.** Media over an
    /// established WebRTC path keeps flowing; the UI only says "Reconnecting…"
    /// if the media path is also down.
    pub fn signaling_lost(&mut self) -> Vec<SessionAction> {
        self.signaling_up = false;
        self.resume_in_flight = false;
        if self.has_session() {
            self.resume_wanted = true;
            if !self.ice_state.is_up() {
                self.phase = SessionPhase::Reconnecting;
            }
        }
        // While Connecting: keep waiting; the connect_req is re-sent once the
        // socket is back.
        vec![]
    }

    /// Step 3: the socket is back and authenticated.
    pub fn signaling_authenticated(
        &mut self,
        active_session_id: Option<&str>,
    ) -> Vec<SessionAction> {
        self.signaling_up = true;
        self.server_advertised_session_id = active_session_id.map(str::to_string);

        // The server telling us a session is live is authoritative even if we
        // somehow lost our own copy of the id.
        if self.session_id.is_none() && self.session_token.is_some() {
            if let Some(id) = active_session_id {
                self.session_id = Some(id.to_string());
            }
        }

        // THE DEAD END, fixed (§4.4).
        //
        // The server says WE own a live session, but we hold no token for it —
        // the app was restarted or replaced, so the token died with the
        // process. We cannot `resume` without a token, and `connect_req` is
        // refused with `busy` by our own session. A session we own but cannot
        // use is rubbish, so throw it away: `bye` is authorised by DEVICE
        // IDENTITY server-side, not by the session token. Then connect
        // normally.
        //
        // Only while actually trying to connect. A session the user
        // deliberately ended is none of our business — touching a closed
        // session at all risks bringing it back to life.
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
                    SessionAction::SendConnectReq { device_id: peer, access_code: code },
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
                return vec![SessionAction::SendConnectReq { device_id: peer, access_code: code }];
            }
        }
        vec![]
    }

    fn begin_resume_if_possible(&mut self) -> Vec<SessionAction> {
        if !self.resume_wanted || !self.signaling_up || self.resume_in_flight {
            return vec![];
        }
        let (Some(id), Some(token)) = (self.session_id.clone(), self.session_token.clone())
        else {
            return vec![];
        };
        self.resume_in_flight = true;
        self.resume_wanted = false;
        vec![SessionAction::SendResume { session_id: id, session_token: token }]
    }

    /// Step 4. Token rotation, watch re-issue, `input_reset`, and an ICE
    /// restart if the media path is not already up.
    pub fn resume_succeeded(&mut self, ok: &ResumeOk, now_ms: i64) -> Vec<SessionAction> {
        self.resume_in_flight = false;
        self.session_id = Some(ok.session_id.clone());
        self.session_token = Some(ok.session_token.clone()); // rotated: old one is dead
        self.last_renew = Some(now_ms);
        let mut actions = vec![SessionAction::ReissueWatches, SessionAction::SendInputReset];
        if !self.ice_state.is_up() {
            self.phase = SessionPhase::Reconnecting;
            if self.is_offerer() {
                self.ice_restart_requested = true;
                actions.push(SessionAction::RestartIce);
            }
        } else {
            self.phase = SessionPhase::Live;
        }
        actions
    }

    /// Steps 5 and 6, plus the rule this project adds on top of PROTOCOL.md: if
    /// the SERVER restarted, every session died and `resume` legitimately
    /// returns `no_session`. A controller holding a remembered code must
    /// silently re-`connect_req`; prompting is only correct when there is no
    /// such code.
    pub fn resume_failed(&mut self, code: &str, retry_after_sec: i32) -> Vec<SessionAction> {
        use rc_proto::consts::err;
        self.resume_in_flight = false;

        if code == err::RATE_LIMITED {
            self.resume_wanted = true;
            return vec![SessionAction::ScheduleResume { after_sec: retry_after_sec.max(1) }];
        }

        // Anything other than no_session/bad_token is transient: keep the
        // session and try again when the socket next comes up.
        if code != err::NO_SESSION && code != err::BAD_TOKEN {
            self.resume_wanted = true;
            return vec![];
        }

        self.session_id = None;
        self.session_token = None;
        self.ice_restart_requested = false;
        self.disconnected_since = None;
        self.failed_since = None;

        if self.role == Role::Controller {
            if let (Some(peer), Some(code)) =
                (self.peer_device_id.clone(), self.remembered_access_code.clone())
            {
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
        vec![
            SessionAction::TeardownPeerConnection,
            SessionAction::ClearStoredSession,
            SessionAction::PromptForAccessCode { reason: code.to_string() },
        ]
    }

    // ------------------------------------------------------------------
    // ICE transitions (PLAN.md §2.1)
    // ------------------------------------------------------------------

    pub fn ice_state_changed(&mut self, new_state: IceLinkState, now_ms: i64) -> Vec<SessionAction> {
        let previous = self.ice_state;
        self.ice_state = new_state;
        if !self.has_session() {
            return vec![];
        }

        match new_state {
            IceLinkState::Connected | IceLinkState::Completed => {
                self.disconnected_since = None;
                self.failed_since = None;
                self.ice_restart_requested = false;
                self.phase = SessionPhase::Live;
                // A media path that just came back may be on the other side of
                // a gap in which keys were logically held down.
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
                vec![SessionAction::SendInputReset]
            }
            IceLinkState::Closed | IceLinkState::New | IceLinkState::Checking => vec![],
        }
    }

    /// Drives the two time-based rules. Call at least once a second.
    pub fn tick(&mut self, now_ms: i64) -> Vec<SessionAction> {
        let mut actions = vec![];
        if !self.has_session() {
            return actions;
        }

        // "On `disconnected`, hold the session and start an ICE restart after 3s."
        if let Some(since) = self.disconnected_since {
            if !self.ice_restart_requested && now_ms - since >= self.ice_restart_delay_ms {
                self.ice_restart_requested = true;
                if self.is_offerer() {
                    actions.push(SessionAction::RestartIce);
                }
            }
        }

        // "Only `failed` PLUS a 45s grace window closes the session."
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

        // Renew every 5 minutes while a session is live, so a drop at minute 59
        // is still resumable (§2.11).
        if self.signaling_up && !self.resume_in_flight {
            if let (Some(id), Some(token), Some(last)) =
                (self.session_id.clone(), self.session_token.clone(), self.last_renew)
            {
                if now_ms - last >= self.renew_interval_ms {
                    self.last_renew = Some(now_ms);
                    actions.push(SessionAction::SendRenew { session_id: id, session_token: token });
                }
            }
        }

        // A resume that could not be sent when the socket came up.
        actions.extend(self.begin_resume_if_possible());
        actions
    }

    /// `renew_ok` — token rotated, same rules as resume.
    pub fn renew_succeeded(&mut self, ok: &RenewOk, now_ms: i64) {
        if Some(ok.session_id.as_str()) != self.session_id.as_deref() {
            return;
        }
        self.session_token = Some(ok.session_token.clone());
        self.last_renew = Some(now_ms);
    }

    pub fn renew_failed(&mut self, code: &str) -> Vec<SessionAction> {
        use rc_proto::consts::err;
        // A renew failure is not itself terminal — the resume path is what
        // matters — but no_session/bad_token mean the session is genuinely gone.
        if code != err::NO_SESSION && code != err::BAD_TOKEN {
            return vec![];
        }
        self.resume_failed(code, 0)
    }

    // ------------------------------------------------------------------
    // Endings
    // ------------------------------------------------------------------

    /// The peer or the server said `bye`, or the local user ended it.
    pub fn close_locally(&mut self, reason: &str) -> Vec<SessionAction> {
        self.session_id = None;
        self.session_token = None;
        self.pending_access_code = None;
        self.resume_in_flight = false;
        self.resume_wanted = false;
        self.disconnected_since = None;
        self.failed_since = None;
        self.ice_restart_requested = false;
        self.ice_state = IceLinkState::Closed;
        self.phase = SessionPhase::Closed { reason: reason.to_string() };
        vec![
            SessionAction::SendInputReset,
            SessionAction::TeardownPeerConnection,
            SessionAction::ClearStoredSession,
        ]
    }

    /// The local user pressed End Session / Disconnect.
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
