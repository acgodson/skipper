package protocol

import "encoding/json"

const APIVersion = "v1"

const (
	APIBasePath = "/" + APIVersion

	PathAuthLink            = APIBasePath + "/auth/link"
	PathAuthDeviceChallenge = APIBasePath + "/auth/device/challenge"
	PathAuthDeviceToken     = APIBasePath + "/auth/device/token"
	PathAuthDeviceRefresh   = APIBasePath + "/auth/device/refresh"
	PathAuthDeviceRevoke    = APIBasePath + "/auth/device/revoke"
	PathDevices             = APIBasePath + "/devices"
	PathEntitlement         = APIBasePath + "/entitlement"
	PathSessions            = APIBasePath + "/sessions"
	PathCredits             = APIBasePath + "/credits"
	PathCreditsLedger       = APIBasePath + "/credits/ledger"
	PathCreditsGifts        = APIBasePath + "/credits/gifts"
	PathHealth              = APIBasePath + "/health"

	PathInternalSessionStart = "/internal/sessions/start"
	PathInternalSessionStop  = "/internal/sessions/stop"
	PathInternalEntitlement  = "/internal/entitlement"
)

const (
	HeaderAuthorization       = "Authorization"
	HeaderClient              = "X-SkipperDesk-Client"
	HeaderRequestID           = "X-Request-Id"
	HeaderIdempotencyKey      = "Idempotency-Key"
	HeaderIdempotencyReplayed = "Idempotency-Replayed"
	HeaderRetryAfter          = "Retry-After"

	BearerPrefix = "Bearer "
)

const (
	APIMaxBodyBytes          = 64 * 1024
	LinkCodeTTLSec           = 120
	APINonceTTLSec           = 60
	DeviceTokenTTLSec        = 90 * 24 * 60 * 60
	DeviceTokenRefreshAtSec  = 7 * 24 * 60 * 60
	EntitlementRefreshSec    = 60
	IdempotencyRetentionSec  = 24 * 60 * 60
	CursorTTLSec             = 15 * 60
	GiftTTLSec               = 30 * 24 * 60 * 60
	MinGiftAmountCents       = 500
	MinIdempotencyKeyLen     = 16
	MaxIdempotencyKeyLen     = 64
	MaxLabelLen              = 64
	MaxGiftMessageLen        = 280
	MaxLedgerMemoLen         = 140
	DefaultPageLimit         = 50
	MaxDevicePageLimit       = 100
	MaxHistoryPageLimit      = 200
	DefaultHistoryPageLimit  = 100
	MaxActivePairs           = 1
	RevocationEffectiveInSec = 5
)

const (
	APIErrBadRequest          = "bad_request"
	APIErrUnauthenticated     = "unauthenticated"
	APIErrForbidden           = "forbidden"
	APIErrNotFound            = "not_found"
	APIErrConflict            = "conflict"
	APIErrIdempotencyConflict = "idempotency_conflict"
	APIErrEntitlement         = "entitlement"
	APIErrRateLimited         = "rate_limited"
	APIErrUnsupportedVersion  = "unsupported_version"
	APIErrInternal            = "internal"
	APIErrUnavailable         = "unavailable"
)

const (
	ReasonBodyMismatch    = "body_mismatch"
	ReasonInProgress      = "in_progress"
	ReasonLinkedElsewhere = "linked_elsewhere"
	ReasonRevoked         = "revoked"
)

const (
	StatusTrial     = "trial"
	StatusActive    = "active"
	StatusExhausted = "exhausted"
	StatusUnlinked  = "unlinked"
)

const (
	TierBase    = "base"
	TierSkipper = "skipper"
)

const (
	PlatformMacOS   = "macos"
	PlatformWindows = "windows"
)

const (
	LedgerTopup         = "topup"
	LedgerSessionCharge = "session_charge"
	LedgerGiftSent      = "gift_sent"
	LedgerGiftReceived  = "gift_received"
	LedgerGiftRefund    = "gift_refund"
	LedgerAdjustment    = "adjustment"
)

const (
	GiftPending   = "pending"
	GiftAccepted  = "accepted"
	GiftCancelled = "cancelled"
	GiftExpired   = "expired"
)

const (
	GiftDirectionSent     = "sent"
	GiftDirectionReceived = "received"
)

// CurrencyUSD is the only currency the ledger holds.
const CurrencyUSD = "USD"

type APIErrorBody struct {
	Error APIError `json:"error"`
}

type APIError struct {
	Code          string `json:"code"`
	Message       string `json:"message"`
	RequestID     string `json:"requestId"`
	Reason        string `json:"reason,omitempty"`
	RetryAfterSec int    `json:"retryAfterSec,omitempty"`
}

func (e APIError) Error() string { return e.Code + ": " + e.Message }

type LinkRequest struct {
	Nonce    string `json:"nonce"`
	Pubkey   string `json:"pubkey"`
	Platform string `json:"platform"`
	Label    string `json:"label,omitempty"`
}

type LinkResponse struct {
	Code      string `json:"code"`
	ExpiresAt int64  `json:"expiresAt"`
	DeviceID  string `json:"deviceId,omitempty"`
}

// DeviceChallengeRequest carries exactly one of Code or DeviceID.
type DeviceChallengeRequest struct {
	Code     string `json:"code,omitempty"`
	DeviceID string `json:"deviceId,omitempty"`
}

type DeviceChallengeResponse struct {
	Nonce      string `json:"nonce"`
	ServerTime int64  `json:"serverTime"`
	ExpiresAt  int64  `json:"expiresAt"`
}

// DeviceTokenRequest.HardwareID is the raw platform serial; the server keeps only its salted HMAC and discards the raw value.
type DeviceTokenRequest struct {
	Code       string `json:"code"`
	Pubkey     string `json:"pubkey"`
	Sig        string `json:"sig"`
	Platform   string `json:"platform"`
	HardwareID string `json:"hardwareId"`
	Label      string `json:"label,omitempty"`
}

type DeviceRefreshRequest struct {
	DeviceID string `json:"deviceId"`
	Pubkey   string `json:"pubkey"`
	Sig      string `json:"sig"`
}

type DeviceTokenResponse struct {
	DeviceToken string `json:"deviceToken"`
	ExpiresAt   int64  `json:"expiresAt"`
	TTLSec      int    `json:"ttlSec"`
	DeviceID    string `json:"deviceId"`
	AccountID   string `json:"accountId"`
}

// Device: the stored record also holds a server-salted hardwareHash, which no response ever carries.
type Device struct {
	DeviceID    string `json:"deviceId"`
	Label       string `json:"label"`
	Platform    string `json:"platform"`
	Pubkey      string `json:"pubkey"`
	CreatedAt   int64  `json:"createdAt"`
	LinkedAt    int64  `json:"linkedAt"`
	LastSeen    int64  `json:"lastSeen"`
	TrialEndsAt int64  `json:"trialEndsAt"`
}

type DeviceList struct {
	Devices    []Device `json:"devices"`
	NextCursor string   `json:"nextCursor,omitempty"`
}

// DeviceRenameRequest carries the only mutable field of a device record.
type DeviceRenameRequest struct {
	Label string `json:"label"`
}

type Concurrency struct {
	MaxActivePairs int `json:"maxActivePairs"`
}

// Entitlement is what the app renders; the client derives no policy from it.
type Entitlement struct {
	Status          string      `json:"status"`
	Tier            string      `json:"tier"`
	BalanceCents    *int64      `json:"balanceCents,omitempty"`
	TrialEndsAt     *int64      `json:"trialEndsAt,omitempty"`
	Concurrency     Concurrency `json:"concurrency"`
	RefreshAfterSec int         `json:"refreshAfterSec"`
}

// SessionRecord: no content of any session is ever recorded.
type SessionRecord struct {
	SessionID    string `json:"sessionId"`
	PeerDeviceID string `json:"peerDeviceId"`
	Role         string `json:"role"`
	StartedAt    int64  `json:"startedAt"`
	EndedAt      *int64 `json:"endedAt,omitempty"`
	RelayUsed    bool   `json:"relayUsed"`
	BytesRelayed *int64 `json:"bytesRelayed,omitempty"`
}

type SessionList struct {
	Sessions   []SessionRecord `json:"sessions"`
	NextCursor string          `json:"nextCursor,omitempty"`
}

type Balance struct {
	BalanceCents int64  `json:"balanceCents"`
	Currency     string `json:"currency"`
	UpdatedAt    int64  `json:"updatedAt"`
}

// LedgerEntry is append-only; a correction is a new entry, never an edit.
type LedgerEntry struct {
	EntryID           string `json:"entryId"`
	Type              string `json:"type"`
	AmountCents       int64  `json:"amountCents"`
	BalanceAfterCents int64  `json:"balanceAfterCents"`
	CreatedAt         int64  `json:"createdAt"`
	SessionID         string `json:"sessionId,omitempty"`
	GiftID            string `json:"giftId,omitempty"`
	Memo              string `json:"memo,omitempty"`
}

type LedgerPage struct {
	Entries    []LedgerEntry `json:"entries"`
	NextCursor string        `json:"nextCursor,omitempty"`
}

type Gift struct {
	GiftID      string `json:"giftId"`
	Status      string `json:"status"`
	AmountCents int64  `json:"amountCents"`
	ToEmail     string `json:"toEmail"`
	FromEmail   string `json:"fromEmail"`
	Message     string `json:"message,omitempty"`
	CreatedAt   int64  `json:"createdAt"`
	ExpiresAt   int64  `json:"expiresAt"`
	AcceptedAt  *int64 `json:"acceptedAt,omitempty"`
}

type GiftList struct {
	Gifts      []Gift `json:"gifts"`
	NextCursor string `json:"nextCursor,omitempty"`
}

type CreateGiftRequest struct {
	ToEmail     string `json:"toEmail"`
	AmountCents int64  `json:"amountCents"`
	Message     string `json:"message,omitempty"`
}

// TODO: payment top-up types slot in here, mirroring API.md §7.4:
// TopupRequest, TopupResponse and the provider webhook body. Nothing already in
// this file changes when they land.

type Health struct {
	Status     string `json:"status"`
	ServerTime int64  `json:"serverTime"`
}

type SessionStartReport struct {
	SessionID          string `json:"sessionId"`
	HostDeviceID       string `json:"hostDeviceId"`
	ControllerDeviceID string `json:"controllerDeviceId"`
	StartedAt          int64  `json:"startedAt"`
}

type SessionStopReport struct {
	SessionID    string `json:"sessionId"`
	EndedAt      int64  `json:"endedAt"`
	RelayUsed    bool   `json:"relayUsed"`
	BytesRelayed *int64 `json:"bytesRelayed,omitempty"`
	Reason       string `json:"reason"`
}

func NewAPIError(code, message, requestID string) APIErrorBody {
	return APIErrorBody{Error: APIError{Code: code, Message: message, RequestID: requestID}}
}

// DecodeAPIError returns an APIErrInternal error, not a zero value, when b is not the documented envelope.
func DecodeAPIError(b []byte) APIError {
	var body APIErrorBody
	if err := json.Unmarshal(b, &body); err != nil || body.Error.Code == "" {
		return APIError{Code: APIErrInternal, Message: "malformed error response"}
	}
	return body.Error
}

func ValidIdempotencyKey(s string) bool {
	if len(s) < MinIdempotencyKeyLen || len(s) > MaxIdempotencyKeyLen {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		ok := c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' ||
			c == '-' || c == '_'
		if !ok {
			return false
		}
	}
	return true
}
