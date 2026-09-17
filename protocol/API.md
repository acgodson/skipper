# SkipperDesk REST API

Version: **v1** (`/v1` path prefix)
Status: normative. This document is the single source of truth for the REST surface between
the desktop app / the website and `api.skipperdesk.app`. `protocol/api.go` is the typed Go
mirror; if the two disagree, this file wins.

`protocol/PROTOCOL.md` covers the other surface — the signaling WebSocket and the two peer-to-peer
data channels. The two documents meet in exactly one place: a `connect_req` is authorised by the
**entitlement** this API reports, and no longer by an access code (PROTOCOL.md "v2 changes").

---

## 0. Conventions

| Convention | Rule |
|---|---|
| Base URL | `https://api.skipperdesk.app`. The client holds **one** config value, the API domain. No IP, no certificate pin. |
| TLS | TLS 1.2+, public CA. A client that cannot validate the chain fails the call; it never falls back. |
| Encoding | `application/json; charset=utf-8` on request and response bodies. |
| Time | Absolute times are **Unix milliseconds**, `int64`, UTC — the same convention as PROTOCOL.md §0. Durations are named `...Sec`. |
| Money | Integer **cents**, `int64`, currency `USD`. Never a float. A negative amount is a debit. |
| IDs | `deviceId`: 9 ASCII digits, as PROTOCOL.md §0. `accountId`, `sessionId`, `entryId`, `giftId`: opaque strings ≤ 64 chars. Clients never parse them. |
| Keys | `pubkey`: base64 (std, padded) DER SPKI of an ECDSA P-256 public key — byte-identical to the signaling `pubkey`. |
| Signatures | `sig`: base64 of the ASN.1 DER ECDSA signature over the **raw nonce bytes**, SHA-256. Identical scheme to PROTOCOL.md §3.1. |
| Unknown fields | Clients **must** ignore unknown response members. Servers **must** reject unknown request members with `bad_request`. |
| Paging | Cursor-based. A list response carries `nextCursor`; an absent or empty `nextCursor` means the end. Cursors are opaque and expire after 15 minutes. |
| Max body | 64 KiB on any request. Larger is `413` with `bad_request`. |
| Request id | Every response carries `X-Request-Id`. It appears in the error envelope as `requestId` and is the only thing worth quoting in a support ticket. |
| Clock | `Date` is present on every response. Clients that detect skew > 60 s should surface it rather than retry blindly. |

### 0.1 Client header

Every request from the desktop app sends `X-SkipperDesk-Client: <platform>/<appVersion>`, e.g.
`macos/1.4.0`. It is advisory: used for compatibility metrics and for the "update your app"
message on `unsupported_version`. It is never used for authorisation.

### 0.2 Authentication classes

Every endpoint in §7 is exactly one of these three.

| Class | Credential | Who holds it | Notes |
|---|---|---|---|
| **unauthenticated** | none | anyone | Only the link/token bootstrap. Rate limited by IP. |
| **user session** | `Authorization: Bearer <Cognito access token>` | the website, in the browser | Short-lived, refreshed by Cognito. The desktop app never holds one. |
| **device token** | `Authorization: Bearer <device token>` | the desktop app | Long-lived, revocable, bound to one device public key. See §1. |

A device token presented to a user-session endpoint is `forbidden`, and vice versa. There is no
endpoint that accepts either, because "whichever credential you have" is how authorisation bugs
get written.

### 0.3 Error envelope

Every non-2xx response has this body and no other:

```json
{
  "error": {
    "code": "entitlement",
    "message": "trial has ended",
    "requestId": "01J8Z2Q5C3N4K0",
    "reason": "trial_expired",
    "retryAfterSec": 0
  }
}
```

| Field | Type | Req | Meaning |
|---|---|:--:|---|
| `code` | string | yes | Machine-readable, from §0.4. Clients branch on this, never on `message`. |
| `message` | string | yes | Human-readable English, safe to log. Never contains a secret. |
| `requestId` | string | yes | Echo of `X-Request-Id`. |
| `reason` | string | no | Sub-reason. Defined for `entitlement` (§4) and `idempotency_conflict`. |
| `retryAfterSec` | int | no | Present on `rate_limited` and on `503`. Mirrors the `Retry-After` header. |

### 0.4 Error codes

| Code | HTTP | Meaning | Client action |
|---|:--:|---|---|
| `bad_request` | 400 | Malformed JSON, missing or unknown field, bad type, out-of-range value. | Bug. Log and fix. |
| `unauthenticated` | 401 | Missing, malformed, expired or revoked credential. | Device token: try §1.5 refresh once, then re-link. User session: re-run Cognito sign-in. |
| `forbidden` | 403 | Valid credential, wrong class or not the owner of the addressed resource. | Bug, or the device was unlinked. |
| `not_found` | 404 | No such resource, or one this caller may not see. | Surface plainly. |
| `conflict` | 409 | The resource is not in a state that allows this transition (e.g. accepting an already-accepted gift). | Re-read the resource. |
| `idempotency_conflict` | 409 | Same `Idempotency-Key`, different request body. `reason` is `body_mismatch`. | Bug. Never reuse a key for a different body. |
| `entitlement` | 402 | The account may not do this yet. `reason` is one of §4.3. | Render the reason; do not retry until the user acts. |
| `rate_limited` | 429 | Over the limit in §8. `retryAfterSec` is set. | Back off exactly that long. |
| `unsupported_version` | 426 | The `/v1` surface no longer serves this client build. | Prompt to update the app. |
| `internal` | 500 | Server fault. | Retry with backoff; at most 3 attempts. |
| `unavailable` | 503 | Planned or partial outage. `retryAfterSec` is set. | Back off; keep any live session running. |

### 0.5 Versioning

- The path prefix `/v1` is the version. There is no version header.
- **Additive** changes — a new optional request field, a new response field, a new enum member in
  a field documented as open — do not bump the version. Clients must tolerate them (§0).
- **Breaking** changes get `/v2` served in parallel. `/v1` is then announced as deprecated with a
  `Sunset` header and served for at least 180 days.
- A client that receives `426 unsupported_version` must stop calling and prompt for an update.
- The REST version and the wire-protocol version of PROTOCOL.md are **independent**. The REST
  surface does not move when the wire protocol does.

### 0.6 Idempotency

Every `POST`, `PATCH` and `DELETE` in §7 marked **idem** requires an `Idempotency-Key` header:
a client-generated opaque string, 16–64 chars, unique per logical operation (a UUIDv4 is fine).

- The server stores key → (request body hash, response status, response body) for **24 hours**,
  scoped to the caller's account.
- A repeat with the same key and the same body replays the stored response verbatim and sets
  `Idempotency-Replayed: true`.
- A repeat with the same key and a different body is `409 idempotency_conflict`.
- A repeat while the first is still in flight is `409 conflict` with `reason: in_progress`.
- `GET` is always safe and never takes the header.
- A missing key on an endpoint that requires one is `bad_request`.

---

## 1. Auth handoff: browser sign-in to device token

The desktop app never sees a password and never embeds a Cognito client secret. Sign-in happens
in the browser; the app receives a one-time code over a custom URL scheme and exchanges it for a
device token bound to its own key.

### 1.1 The flow

```
 app                          browser (skipperdesk.app)            api.skipperdesk.app
  │                                     │                                   │
  │ 1. open https://skipperdesk.app/link?nonce=N&device=<pubkey>            │
  ├────────────────────────────────────►│                                   │
  │                                     │ 2. Cognito sign-in (if needed)    │
  │                                     │ 3. POST /v1/auth/link  {nonce,pubkey,...}
  │                                     ├──────────────────────────────────►│
  │                                     │◄─── {code, expiresAt} ────────────┤
  │ 4. redirect skipperdesk://link?code=C                                   │
  │◄────────────────────────────────────┤                                   │
  │ 5. POST /v1/auth/device/challenge {code}                                │
  ├────────────────────────────────────────────────────────────────────────►│
  │◄─── {nonce, expiresAt} ─────────────────────────────────────────────────┤
  │ 6. POST /v1/auth/device/token {code, pubkey, sig, platform, hardwareId} │
  ├────────────────────────────────────────────────────────────────────────►│
  │◄─── {deviceToken, expiresAt, deviceId, accountId} ──────────────────────┤
```

`nonce` at step 1 is generated by the **app** (32 random bytes, base64url, no padding) and is
carried through the browser so that the app can reject a `skipperdesk://link` callback it did not
start. It is **not** the nonce that is signed. The signed nonce is minted by the server at step 5,
exactly as the signaling `challenge` of PROTOCOL.md §2.1 is.

Normative rules:

1. The app **must** discard any `skipperdesk://link?code=…` callback whose in-memory link attempt
   has expired (120 s) or was never started. The browser is an untrusted messenger.
2. The one-time `code` is single-use, valid **120 s**, and is invalidated by a successful
   `/v1/auth/device/token`, by expiry, or by a second attempt with a different `pubkey`.
3. The `pubkey` presented at step 6 must byte-equal the `pubkey` recorded at step 3. Anything else
   is `forbidden`. This is what stops a code phished out of the browser being redeemed elsewhere.
4. The signature is verified exactly as PROTOCOL.md §3.1 verifies `hello`: raw nonce bytes,
   ECDSA-P256/SHA-256, DER, base64. One implementation, two surfaces.
5. `hardwareId` is sent once, at step 6. The server stores only `HMAC-SHA256(serverSalt, hardwareId)`
   as the device's `hardwareHash` and **discards the raw value before the response is written**.
   The salt never leaves the server. The hash is used for trial-abuse accounting only (§3.2) and
   is never returned by any endpoint.

### 1.2 `POST /v1/auth/link` — user session, idem

Called by the website once the user is signed in. Creates the pending link and mints the one-time
code. Body: `nonce`, `pubkey`, `platform`, optional `label`.

Response `201`: `code`, `expiresAt`, `deviceId` if this key is already linked to this account.

Linking a key that is already linked to **another** account is `409 conflict` with
`reason: linked_elsewhere`; the owner must unlink it first (§3.5).

### 1.3 `POST /v1/auth/device/challenge` — unauthenticated

Body carries exactly one of `code` (first token for a device) or `deviceId` (refresh, §1.5).
Response `200`: `nonce` (base64, 32 random bytes), `serverTime`, `expiresAt`.

The nonce is single-use and valid **60 s**. A replayed nonce is `unauthenticated`. The endpoint
does not reveal whether a `deviceId` exists: an unknown device gets a well-formed nonce that will
simply fail at §1.4.

### 1.4 `POST /v1/auth/device/token` — unauthenticated, idem

Body: `code`, `pubkey`, `sig`, `platform`, `hardwareId`, optional `label`.
Response `200`: `deviceToken`, `expiresAt`, `ttlSec`, `deviceId`, `accountId`.

This call **never mints a `deviceId`**. The key must already be in the device registry, which
happens when the app first sends signaling `register` (PROTOCOL.md §2.2, §6 below). The token
links that existing record to the account, so the `deviceId` returned here is byte-equal to the
one `register_ok` returned. A key the registry has never seen is `400 bad_request` with
`reason: unregistered`; the code is not consumed, and the app registers with signaling, requests
a fresh §1.3 nonce and retries.

The first link of a device starts its trial, subject to §3.2. Re-linking a device — to the same
or another account — never starts a second trial.

The device token is:

- **Opaque** to the client. Structure is a server implementation detail; clients store and present.
- **Long-lived**: TTL **90 days**, refreshed by §1.5.
- **Device-scoped**: it names one `deviceId` and one account. It grants nothing about any other
  device, and it is never accepted on a user-session endpoint.
- **Revocable**: by §1.6, by unlinking the device (§3.5), or by the account being closed. Revocation
  is effective server-side within 5 seconds; there is no client-side expiry to wait out.
- **A secret**: Keychain (macOS) or DPAPI/TPM-wrapped storage (Windows). Never logged, never in a
  URL, never in a query string.

### 1.5 `POST /v1/auth/device/refresh` — unauthenticated, idem

Body: `deviceId`, `pubkey`, `sig` over the nonce from §1.3. Response is the same shape as §1.4.

Refresh proves possession of the private key rather than of the old token, so a device that lost
its token — a restore, a Keychain reset — recovers without the user returning to the browser. It
succeeds only while the device is still linked and not revoked; otherwise `forbidden` with
`reason: unlinked` or `reason: revoked`, and the app must run the §1.1 flow again.

The app should refresh when the remaining TTL drops below **7 days**, and on any `401` once.

### 1.6 `POST /v1/auth/device/revoke` — device token, idem

Revokes **the calling token only**. Body `{}`. Response `204`. Used on sign-out in the app. The
device stays linked; a later §1.5 refresh mints a new token. To break the link entirely, unlink
the device (§3.5).

---

## 2. What the app does with the token

| Surface | Credential |
|---|---|
| REST (`api.skipperdesk.app`) | device token |
| Signaling WebSocket (PROTOCOL.md) | the device **key**, via `challenge`/`hello`. No token. |

The two surfaces authenticate independently against the same key. The signaling server asks this
API for the host's entitlement at `connect_req` time over the internal surface (§6); the client is
never asked to forward a device token over the WebSocket.

---

## 3. Devices

### 3.1 The device record

| Field | Type | Notes |
|---|---|---|
| `deviceId` | string | 9 digits, minted once by the device registry this API owns, when signaling `register` (PROTOCOL.md §2.2) first presents the key (§6). The link reuses it. |
| `label` | string | Human name, ≤ 64 chars. User-editable. Not secret. |
| `platform` | string | `macos` or `windows`. Open enum — clients render an unknown value verbatim. |
| `pubkey` | string | base64 DER SPKI P-256. Immutable for the life of the device record. |
| `createdAt` | int64 | Unix ms, first link. |
| `linkedAt` | int64 | Unix ms, most recent link to the **current** account. |
| `lastSeen` | int64 | Unix ms of the most recent authenticated activity on either surface. `0` if never. |
| `trialEndsAt` | int64 | Unix ms. `0` when the device has no trial (§4). |

`hardwareHash` is part of the stored record and is **never** part of any response. It exists only
to make trial farming expensive (§3.2) and is not a stable identifier the product relies on.

### 3.2 `hardwareHash`, stated plainly

- Computed server-side as `HMAC-SHA256(serverSalt, hardwareId)`, where `hardwareId` is the
  platform serial the app reads once at §1.4.
- Used for exactly one decision: whether a *new* device is eligible for a *new* trial.
- Never exposed, never used to link accounts to each other, never used for any other purpose.
- An OS wipe produces a new hash. That is accepted: the cost of the wipe is the deterrent.

### 3.3 `GET /v1/devices` — user session

Response: `devices` array of §3.1 records, `nextCursor`. Query: `cursor`, `limit` (1–100,
default 50).

### 3.4 `GET /v1/devices/{deviceId}` — user session **or** device token for itself

A device token may read only its own record; any other `deviceId` is `forbidden`.

### 3.5 `PATCH /v1/devices/{deviceId}` — user session, idem

Body: `label`. The only mutable field. Response: the updated record.

### 3.6 `DELETE /v1/devices/{deviceId}` — user session, idem

Unlinks the device from the account. Effects, all immediate:

1. Every device token for that device is revoked.
2. The device's entitlement becomes `unlinked`; the next `connect_req` naming it as host is
   refused with `error{entitlement, reason: "unlinked"}` (PROTOCOL.md §2.9).
3. Any live session with that device as host or controller is closed with
   `bye{reason:"replaced"}`.
4. The device record is retained, unlinked, so that a re-link keeps the same `deviceId` and the
   same trial history. Unlinking is not a way to restart a trial.

Response `204`.

---

## 4. Entitlement

### 4.1 `GET /v1/entitlement` — device token

The one endpoint the desktop app polls. It answers a single question: **may this device host a
session right now, and what should the UI say if not?**

| Field | Type | Req | Meaning |
|---|---|:--:|---|
| `status` | string | yes | `trial`, `active`, `exhausted` or `unlinked`. Closed enum; an unrecognised value is treated as `exhausted`. |
| `tier` | string | yes | `base` or `skipper`. Open enum — what a tier unlocks is server policy. |
| `balanceCents` | int64 | no | Present when the account has a credit balance. Absent is not zero; absent means "not applicable to this status". |
| `trialEndsAt` | int64 | no | Unix ms. Present only when `status` is `trial`. |
| `concurrency` | object | yes | `{"maxActivePairs": 1}`. The server states the limit; the client renders it. |
| `refreshAfterSec` | int | yes | How long this answer may be cached. Currently **60**. |

```json
{
  "status": "trial",
  "tier": "base",
  "trialEndsAt": 1756000000000,
  "concurrency": {"maxActivePairs": 1},
  "refreshAfterSec": 60
}
```

### 4.2 Policy lives on the server

The client **must not** compute entitlement. It must not compare `balanceCents` to a rate, infer
an expiry from `trialEndsAt`, or decide that `exhausted` means "show the payment screen" as
anything other than a rendering of what the server said. Trial length, cents-per-hour, lock-out
behaviour and tier contents all change server-side with no client release (SCOPE §6, §7).

The client's whole contract is: render `status`, `tier`, `balanceCents`, `trialEndsAt`; re-fetch
after `refreshAfterSec`; and, on `error{entitlement}` from signaling, re-fetch once and render the
reason.

### 4.3 Entitlement reasons

The `reason` on a `402 entitlement` here, and on `error{entitlement}` over signaling
(PROTOCOL.md §7), come from the same closed set:

| `reason` | Meaning |
|---|---|
| `unlinked` | The host device is not linked to any account, or no device with that id exists. |
| `trial_expired` | The device had a trial, it ended, and no balance remains. |
| `no_balance` | The device never had a trial (§3.2) and the balance is zero or below the minimum a session requires. |
| `concurrency` | The account's `maxActivePairs` is already in use by another pair. |
| `suspended` | The account is administratively suspended. |

A client that meets an unknown reason renders the `message` and treats it as `trial_expired`.

---

## 5. Sessions accounting

Session records exist for **billing and the user's own history**. They carry no content, ever:
no SDP, no candidates, no clipboard, no keystrokes, no frames, no access code. PROTOCOL.md §8
states the same guarantee for the signaling server, and it is not weakened here.

### 5.1 `GET /v1/sessions` — device token **or** user session

Query: `since` (Unix ms, inclusive, required; the server rejects an unbounded query with
`bad_request`), `until` (Unix ms, optional), `cursor`, `limit` (1–200, default 100), and
`deviceId` (user session only; filters to one device).

A device token sees only sessions in which the calling device took part. A user session sees all
sessions of all devices on the account.

| Field | Type | Req | Meaning |
|---|---|:--:|---|
| `sessionId` | string | yes | The signaling `sessionId`, 32 hex. |
| `peerDeviceId` | string | yes | The other device. For a user session this is the device that is not `deviceId`; for a device token it is the device that is not the caller. |
| `role` | string | yes | The **caller's** role in that session: `host` or `controller`. |
| `startedAt` | int64 | yes | Unix ms, session `open`. |
| `endedAt` | int64 | no | Unix ms, session `closed`. Absent while the session is still live. |
| `relayUsed` | bool | yes | Whether any traffic went through a TURN relay. Always present, including `false`. |
| `bytesRelayed` | int64 | no | Bytes relayed through TURN. Absent when unknown or when `relayUsed` is `false`. Never the peer-to-peer byte count — the server cannot know it. |

Ordering is `startedAt` descending. A session that is still live appears with no `endedAt` and
may appear again, completed, in a later query.

### 5.2 What is deliberately not here

No session content endpoint exists, in any form, at any version. There is no screenshot, no
transcript, no event list, no "what was clicked". If a future feature appears to need one, it is
the feature that is wrong (SCOPE §2, principle 2).

---

## 6. Internal surface (not part of the client contract)

The signaling server reports session start and stop to this API over a private network path
(VPC-internal, mutually authenticated, never exposed at `api.skipperdesk.app`). It is documented
here only so that the two services are written against one shape, and it carries the same
metadata as §5.1 — no content.

Every internal call carries `Authorization: Bearer <internal token>`, a secret shared by the two
services and nothing else. A device token or user session is `401 unauthenticated` here.

| Call | Body | Effect |
|---|---|---|
| `POST /internal/devices/register` | `pubkey`, optional `label`, optional `platform` | The device registry. Answers `{deviceId, existing}` — `201` for a new key, `200` for a known one. Idempotent by `pubkey`: a known key always gets its existing `deviceId` and nothing about the record changes. |
| `GET /internal/devices/{deviceId}` | — | `{deviceId, pubkey, codeEpoch}`, used to verify `hello` (PROTOCOL.md §2.4) and to pin both keys at `connect_req`. Unknown id is `404 not_found`. |
| `POST /internal/devices/{deviceId}/epoch` | `{}` | Bumps `codeEpoch` (PROTOCOL.md §2.15 `refresh_code`, §3.2 session-token epoch). Answers the updated `{deviceId, pubkey, codeEpoch}`; unknown id is `404`. |
| `POST /internal/sessions/start` | `sessionId`, `hostDeviceId`, `controllerDeviceId`, `startedAt` | Opens the accounting record and claims the host's concurrency slot. |
| `POST /internal/sessions/stop` | `sessionId`, `endedAt`, `relayUsed`, `bytesRelayed`, `reason` | Closes the record, settles the charge against the balance, frees the slot. |
| `GET /internal/entitlement/{deviceId}` | — | Gates `connect_req`. `200` with the §4.1 body when the host may open a session; otherwise `402 entitlement` with the §4.3 `reason`. An id the registry does not hold, or a registered device that is not linked, is `unlinked`. This call never creates a record. |

### 6.1 One registry

This API is the only place a `deviceId` is minted. The signaling server holds no device records of
its own in a deployment; it asks the calls above, with bounded timeouts (3 s per call), and may
cache `GET /internal/devices/{deviceId}` answers briefly, dropping a device's entry whenever it
bumps that device's epoch.

When this API cannot be reached or answers `5xx`, the signaling server refuses `register`,
`hello`, `refresh_code` and `connect_req` with `error{code:"unavailable", retryAfterSec}`. It never
falls back to minting or trusting an id of its own. A client treats `unavailable` like `internal`:
back off and retry, keeping any live peer-to-peer session running.

The signaling server's stand-alone mode (`RC_ENTITLEMENT=static`, local development and the
smoke test only) keeps an equivalent registry in its own database and has no link to this API.

### 6.2 Development-only calls

TODO: remove both at launch. They exist only when the API runs with the local development
identity provider (`Bearer dev:<email>`), and are `404` otherwise.

| Call | Auth | Effect |
|---|---|---|
| `POST /v1/credits/dev-topup` | user session, idem | Credits the account with `amountCents`. |
| `POST /v1/dev/expire-trial` | user session | Body `{}`. Ends every running trial on the account's devices. `204`. |

Clients never call these. They are listed in `protocol/api.go` because both Go services compile
against the same types.

---

## 7. Credits

### 7.1 `GET /v1/credits` — user session

Response: `balanceCents`, `currency` (`"USD"`), `updatedAt`.

### 7.2 `GET /v1/credits/ledger` — user session

Query: `since` (Unix ms, required), `until`, `cursor`, `limit` (1–200, default 100).
Response: `entries`, `nextCursor`. Newest first.

| Field | Type | Req | Meaning |
|---|---|:--:|---|
| `entryId` | string | yes | Opaque, stable, unique. |
| `type` | string | yes | `topup`, `session_charge`, `gift_sent`, `gift_received`, `gift_refund`, `adjustment`. Open enum. |
| `amountCents` | int64 | yes | Signed. Negative is a debit. |
| `balanceAfterCents` | int64 | yes | Balance after this entry. Makes the ledger self-checking. |
| `createdAt` | int64 | yes | Unix ms. |
| `sessionId` | string | no | Present on `session_charge`. |
| `giftId` | string | no | Present on the gift types. |
| `memo` | string | no | Short human text, ≤ 140 chars. Never contains a secret. |

The ledger is **append-only**. A correction is a new `adjustment` entry, never an edit.

### 7.3 Gifting

A gift moves credit from the sender's balance to a named email address. The amount is held —
debited from the sender at creation — until the gift is accepted, cancelled or expires.

The gift object:

| Field | Type | Req | Meaning |
|---|---|:--:|---|
| `giftId` | string | yes | Opaque. |
| `status` | string | yes | `pending`, `accepted`, `cancelled`, `expired`. Closed enum. |
| `amountCents` | int64 | yes | Positive. |
| `toEmail` | string | yes | Normalised lowercase. Returned in full to the sender; to the recipient only the sender's email is shown. |
| `fromEmail` | string | yes | The sender. |
| `message` | string | no | ≤ 280 chars, plain text. |
| `createdAt` | int64 | yes | Unix ms. |
| `expiresAt` | int64 | yes | Unix ms. Currently **30 days** after creation. |
| `acceptedAt` | int64 | no | Unix ms. Present only when `status` is `accepted`. |

#### `POST /v1/credits/gifts` — user session, idem

Body: `toEmail`, `amountCents`, optional `message`. Response `201`: the gift object.

- `amountCents` must be ≥ **500** and ≤ the sender's balance, else `bad_request` or
  `402 entitlement` with `reason: no_balance`.
- Gifting to the sender's own address is `bad_request`.
- The sender is debited immediately; the ledger gets a `gift_sent` entry.
- The recipient does not need an account yet. The gift is held against the email address and is
  claimable after sign-up.

#### `GET /v1/credits/gifts` — user session

Query: `direction` (`sent` or `received`, required), `status` (optional), `cursor`, `limit`.
Response: `gifts`, `nextCursor`.

#### `POST /v1/credits/gifts/{giftId}/accept` — user session, idem

The caller's verified email must equal `toEmail`, else `forbidden`. Only a `pending` gift may be
accepted; anything else is `409 conflict`. On success the recipient is credited and gets a
`gift_received` ledger entry. Response `200`: the gift object, `status: accepted`.

#### `POST /v1/credits/gifts/{giftId}/cancel` — user session, idem

Only the sender may cancel, and only while `pending`. The held amount returns to the sender as a
`gift_refund` entry. Response `200`: the gift object, `status: cancelled`. An expired gift is
refunded by the same mechanism, server-side, without a call.

### 7.4 TODO: payment top-up

TODO: top-up endpoints are out of scope for this contract and slot in here as
`POST /v1/credits/topup` (create an intent) and `GET /v1/credits/topup/{topupId}` (poll it), plus
a provider webhook on the internal surface of §6 that credits the ledger with a `topup` entry.
Nothing else in this document changes when they land: the balance in §7.1, the `topup` entry type
in §7.2 and the `no_balance` reason in §4.3 are already the whole client-visible surface of a
payment. Crypto settlement is handled entirely on the website (SCOPE §9); the desktop app has no
payment surface at all and must not grow one.

---

## 8. Endpoint index and rate limits

Limits are per the stated key, in a sliding window. Over the limit is `429 rate_limited` with
`retryAfterSec`. Limits are a floor, not a promise: the server may be stricter under load and
says so through the same response.

| Method | Path | Auth | Idem | Rate limit |
|---|---|---|:--:|---|
| `POST` | `/v1/auth/link` | user session | yes | 10 / hour per account |
| `POST` | `/v1/auth/device/challenge` | none | no | 30 / hour per IP, 10 / hour per `deviceId` |
| `POST` | `/v1/auth/device/token` | none | yes | 10 / hour per IP, 5 / hour per `code` |
| `POST` | `/v1/auth/device/refresh` | none | yes | 12 / day per device |
| `POST` | `/v1/auth/device/revoke` | device token | yes | 10 / hour per device |
| `GET` | `/v1/devices` | user session | — | 60 / minute per account |
| `GET` | `/v1/devices/{deviceId}` | user session or own device token | — | 60 / minute per caller |
| `PATCH` | `/v1/devices/{deviceId}` | user session | yes | 20 / hour per account |
| `DELETE` | `/v1/devices/{deviceId}` | user session | yes | 20 / hour per account |
| `GET` | `/v1/entitlement` | device token | — | 60 / hour per device (the app caches for `refreshAfterSec`) |
| `GET` | `/v1/sessions` | device token or user session | — | 60 / hour per device, 120 / hour per account |
| `GET` | `/v1/credits` | user session | — | 120 / hour per account |
| `GET` | `/v1/credits/ledger` | user session | — | 60 / hour per account |
| `POST` | `/v1/credits/gifts` | user session | yes | 10 / day per account |
| `GET` | `/v1/credits/gifts` | user session | — | 60 / hour per account |
| `POST` | `/v1/credits/gifts/{giftId}/accept` | user session | yes | 20 / day per account |
| `POST` | `/v1/credits/gifts/{giftId}/cancel` | user session | yes | 20 / day per account |
| `GET` | `/v1/health` | none | — | 60 / minute per IP |

`GET /v1/health` returns `200 {"status":"ok","serverTime":<unix ms>}` and is the only endpoint
that reveals nothing about anyone.

---

## 9. Privacy guarantees (normative)

The API server **must not** log, persist, or transmit to third parties: device tokens, one-time
link codes, Cognito tokens, raw `hardwareId` values, the `hardwareHash` salt, gift messages, or
anything from the peer-to-peer surfaces of PROTOCOL.md. Log lines may contain: `requestId`,
`accountId`, `deviceId`, `sessionId`, method, path, status, error `code`, byte counts and timings.
Anything else is a bug in the server.
