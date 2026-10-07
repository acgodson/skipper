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
| Keys | `pubkey`: canonical base64 (std, padded) of the uncompressed DER SPKI of an ECDSA P-256 public key — byte-identical to the signaling `pubkey` (PROTOCOL.md §0). Any other spelling is `bad_request`. |
| Signatures | `sig`: base64 of the ASN.1 DER ECDSA-P256/SHA-256 signature over the **domain-separated** message `"skipperdesk/api-challenge/v1\|"` ‖ the 32 raw bytes of the §1.3 nonce — PROTOCOL.md §3.1, purpose `api-challenge`. A signature made for signaling never verifies here, and vice versa. |
| Client address | The direct peer, unless it is in the configured trusted-proxy list (`RC_API_TRUSTED_PROXIES`, CIDRs), in which case the rightmost `X-Forwarded-For` hop that is not itself trusted. Every "per IP" limit in §8 keys on it; `X-Forwarded-For` from anyone else is ignored. |
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
| **unauthenticated** | none | anyone | Only the link/token bootstrap, `/v1/health` and the release feed (§10). Rate limited by IP. |
| **user session** | `Authorization: Bearer <Cognito ID token>` | the website, in the browser | Short-lived, refreshed by Cognito. The desktop app never holds one. The **ID** token, not the access token: the server requires `token_use: "id"` and refuses anything else as `unauthenticated`, because the check needs an `email` claim and Cognito puts one only in the ID token. Do not relax this — an access token from the same pool verifies under the same keys and names the same app client, so `token_use` is the only claim that tells the two apart. `aud` must be our own app client; an access token's `client_id` is never accepted in its place. |
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
| `idempotency_replay_unavailable` | 409 | Same `Idempotency-Key` and body as a call that already **succeeded** on an endpoint whose answer carries a credential (§0.6). The credential was not kept, so it cannot be replayed. | Treat the first call's outcome as unknown: repeat the operation with a **new** key (for §1.4 that means a new link attempt; for §1.5 a new challenge). |
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

- The server stores key → (request body hash, response status, response hash, replay body) for
  **24 hours**, scoped to the caller (the account, the device, or for the unauthenticated
  bootstrap calls the client address).
- A repeat with the same key and the same body replays the stored response verbatim and sets
  `Idempotency-Replayed: true`.
- **Credential-bearing answers are never stored.** A successful answer of `POST /v1/auth/link`
  (the one-time code), `POST /v1/auth/device/token` and `POST /v1/auth/device/refresh` (the
  device token) keeps only its status and SHA-256; a repeat of that call is
  `409 idempotency_replay_unavailable`, and the server never re-issues a credential for a
  replay. Error answers of those endpoints carry no credential and replay normally.
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
  │ 4. redirect skipperdesk://link?code=C&nonce=N                           │
  │◄────────────────────────────────────┤                                   │
  │ 5. POST /v1/auth/device/challenge {code}                                │
  ├────────────────────────────────────────────────────────────────────────►│
  │◄─── {nonce, expiresAt} ─────────────────────────────────────────────────┤
  │ 6. POST /v1/auth/device/token {code, nonce, pubkey, sig, platform, …}   │
  ├────────────────────────────────────────────────────────────────────────►│
  │◄─── {deviceToken, expiresAt, deviceId, accountId} ──────────────────────┤
```

`nonce` at step 1 is generated by the **app** (32 random bytes, base64url, no padding), held in
memory only, and carried through the browser and back so that the app can reject a
`skipperdesk://link` callback it did not start. The server binds the one-time code to it at step 3
and requires it again at step 6. It is **not** the nonce that is signed. The signed nonce is minted by the server at step 5,
exactly as the signaling `challenge` of PROTOCOL.md §2.1 is.

Normative rules:

1. The app **must** discard any `skipperdesk://link?code=…&nonce=…` callback whose in-memory link
   attempt has expired (**15 minutes**) or was never started, or whose `nonce` is missing or
   differs from the attempt's (compared in constant time). Any such mismatch also ends the pending
   attempt; the app logs it and shows nothing. The browser is an untrusted messenger.

   The 15 minutes bound how long the app waits, nothing more. A first-time user signs up, waits
   for a verification email and reads it on another device, and 120 s could not fit that, so
   every first attempt died and the person had to choose Sign in twice. Nothing about the
   handoff's security rests on this number: the code is bound to the `nonce` (rule 2) and to the
   `pubkey` (rule 4), is single-use and lives 120 s from the moment the server mints it at step 3
   — *after* sign-in — and the `nonce` comparison is constant-time. A callback that arrives late
   carries a code the server has already expired. The website refuses to mint a code past
   **14 minutes**, a minute inside the app's window, because it starts counting at page load and
   so always reads later than the app does.
2. The one-time `code` is bound to the step 1 `nonce`. The server stores only
   `SHA-256(code)` and `SHA-256(nonce)`, never either value. A step 6 request whose `nonce` is missing or different is
   `400 bad_request` with `reason: nonce_mismatch`, and the code is burned. This is what stops a
   code minted on another account (with this device's public key, which every controller sees)
   being injected into this device's own link attempt.
3. The one-time `code` is single-use, valid **120 s**, and is invalidated by a successful
   `/v1/auth/device/token`, by expiry, by a nonce mismatch, or by a second attempt with a
   different `pubkey`.
4. The `pubkey` presented at step 6 must byte-equal the `pubkey` recorded at step 3. Anything else
   is `forbidden`. This is what stops a code phished out of the browser being redeemed elsewhere.
5. The signature is verified by the same function PROTOCOL.md §3.1 uses for `hello`, with the
   purpose `api-challenge`: ECDSA-P256/SHA-256 over `"skipperdesk/api-challenge/v1|"` ‖ the 32
   raw nonce bytes, DER, base64. One implementation, two surfaces, separated domains.
6. `hardwareId` is sent once, at step 6. The server stores only `HMAC-SHA256(serverSalt, hardwareId)`
   as the device's `hardwareHash` and **discards the raw value before the response is written**.
   The salt never leaves the server. The hash is used for trial-abuse accounting only (§3.2) and
   is never returned by any endpoint.

### 1.2 `POST /v1/auth/link` — user session, idem

Called by the website once the user is signed in. Creates the pending link and mints the one-time
code. Body: `nonce`, `pubkey`, `platform`, optional `label`.

Response `201`: `code`, `expiresAt`, `deviceId` if this key is already linked to this account.

The website then redirects to `skipperdesk://link?code=<code>&nonce=<nonce>`, echoing the `nonce`
it was given at step 1 unchanged.

This is the **only** endpoint a browser calls, and the website is a different origin from the
API (`skipperdesk.app` against `api.skipperdesk.app`). It therefore has CORS, and no other
route does:

- `OPTIONS /v1/auth/link` answers `204` with `Access-Control-Allow-Methods: POST`,
  `Access-Control-Allow-Headers: Authorization, Content-Type, Idempotency-Key` and
  `Access-Control-Max-Age: 600` — the longest preflight cache Chrome honours.
- `Access-Control-Allow-Origin` and `Vary: Origin` are on **every** answer from the route,
  the `201` and each of `400`, `401`, `403`, `409`, `426`, `429` and `5xx`. A 409 whose body
  the browser may not read becomes an unexplained failure on screen, and the one message that
  tells an owner their Mac belongs to another account never appears.
- The allowed origin is the exact origin of `-web-base-url`, never `*` and never reflected
  from the request. A request from any other origin gets no CORS header at all and the browser
  does the refusing; there is no status code for it, because there is no page to read one.
- `Access-Control-Allow-Credentials` stays **off**. The credential is a bearer header the page
  sets itself, not a cookie the browser attaches.

Linking a key that is already linked to **another** account is `409 conflict` with
`reason: linked_elsewhere`; the owner must unlink it first (§3.6).

### 1.3 `POST /v1/auth/device/challenge` — unauthenticated

Body carries exactly one of `code` (first token for a device) or `deviceId` (refresh, §1.5).
Response `200`: `nonce` (base64, 32 random bytes), `serverTime`, `expiresAt`.

The nonce is single-use, valid **60 s**, and bound to the `code` (stored as its SHA-256) or the
`deviceId` it was requested for. A replayed, expired or foreign nonce is `unauthenticated`. The
endpoint does not reveal whether a `deviceId` exists: an unknown device gets a well-formed nonce
that will simply fail at §1.5. It is limited **per client address only** — a per-device budget
here would let anyone who knows a Device ID stop that device from refreshing — and requesting a
new nonce never invalidates an earlier one, so a stranger's challenges cannot break a device's
own refresh.

### 1.4 `POST /v1/auth/device/token` — unauthenticated, idem

Body: `code`, `nonce` (the step 1 app nonce), `pubkey`, `sig`, `platform`, `hardwareId`,
optional `label`. The `nonce` check (§1.1 rule 2) runs before the `pubkey` check. `sig` is over
the newest live §1.3 nonce requested for this `code`; the server finds and spends that nonce in
a single SQL statement, so two requests can never both use it, and then checks the signature.
Response `200`: `deviceToken`, `expiresAt`, `ttlSec`, `deviceId`, `accountId`, and
`accountEmail` when the identity provider gave one — the app shows that address as the
signed-in account and never the `accountId`, which is ours, not the person's (DESIGN.md §4
rule 8). The server stores only `SHA-256(deviceToken)`. A repeat with the same `Idempotency-Key` is
`409 idempotency_replay_unavailable` (§0.6).

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
- **Revocable**: by §1.6, by unlinking the device (§3.6), or by the account being closed. Revocation
  is effective server-side within 5 seconds; there is no client-side expiry to wait out.
- **A secret**: Keychain (macOS) or DPAPI/TPM-wrapped storage (Windows). Never logged, never in a
  URL, never in a query string.

### 1.5 `POST /v1/auth/device/refresh` — unauthenticated, idem

Body: `deviceId`, `pubkey`, `nonce`, `sig`. `nonce` is **the exact** §1.3 nonce, as returned,
that `sig` signs (purpose `api-challenge`); all four are required. Response is the same shape as
§1.4, and a repeat with the same `Idempotency-Key` is `409 idempotency_replay_unavailable`.

The server checks, in this order, and charges each limit only when the step before it passed:

1. The per-client-address limit (§8).
2. It spends `nonce` in one SQL statement that matches it to this `deviceId`, unused and
   unexpired. Anything else is `401 unauthenticated`.
3. `sig` verifies over that nonce under the presented `pubkey`. Otherwise `401 unauthenticated`.
4. `pubkey` is the key registered for `deviceId`. Otherwise `403 forbidden`,
   `reason: unlinked`.
5. The per-device limit (§8) — so only a caller holding the device's key can spend the device's
   budget.
6. The device is linked. Otherwise `403 forbidden`, `reason: unlinked`, and the app must run the
   §1.1 flow again.

Refresh proves possession of the private key rather than of the old token, so a device that lost
its token — a restore, a Keychain reset — recovers without the user returning to the browser.

`nonce` became required before launch, in `/v1`, together with PROTOCOL.md v4: a server that
checked only the newest nonce for a device let anyone who knew the Device ID invalidate the
device's pending refresh.

The app should refresh when the remaining TTL drops below **7 days**, and on any `401` once.

### 1.6 `POST /v1/auth/device/revoke` — device token, idem

Revokes **the calling token only**. Body `{}`. Response `204`. The device stays linked; a later
§1.5 refresh mints a new token. To break the link entirely — which is what the app's sign out
does, because a revoked token alone leaves the device linked, entitled and still able to host —
unlink the device (§3.6).

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
| `trialEndsAt` | int64 | Unix ms the device's starting credits expire. `0` when it was never granted any (§4). |

`hardwareHash` is part of the stored record and is **never** part of any response. It exists only
to make trial farming expensive (§3.2) and is not a stable identifier the product relies on.

### 3.2 `hardwareHash`, stated plainly

- Computed server-side as `HMAC-SHA256(serverSalt, hardwareId)`, where `hardwareId` is the
  platform serial the app reads once at §1.4.
- Used for exactly one decision: whether a *new* device is eligible for *new* starting credits.
- Never exposed, never used to link accounts to each other, never used for any other purpose.
- An OS wipe produces a new hash. That is accepted: the cost of the wipe is the deterrent.

### 3.3 `GET /v1/devices` — user session

Response: `devices` array of §3.1 records, `nextCursor`. Query: `cursor`, `limit` (1–100,
default 50).

### 3.4 `GET /v1/devices/{deviceId}` — user session **or** device token for itself

A device token may read only its own record; any other `deviceId` is `forbidden`.

### 3.5 `PATCH /v1/devices/{deviceId}` — user session, idem

Body: `label`. The only mutable field. Response: the updated record.

### 3.6 `DELETE /v1/devices/{deviceId}` — user session, **or** device token for itself, idem

Unlinks the device from the account. A device token may unlink **only its own** `deviceId`; any
other id is `403 forbidden`. That is what the app's **sign out** does, so a Mac can stop
accepting remote sessions without the owner returning to the website.

Effects, all immediate:

1. Every device token for that device is revoked, including the one that made the call.
2. The device's entitlement becomes `unlinked`; the next `connect_req` naming it as host is
   refused with `error{entitlement, reason: "unlinked"}` (PROTOCOL.md §2.9).
3. Any live session with that device as host or controller is closed with
   `bye{reason:"host_ended"}`: rc-api asks rc-signal over `POST /internal/sessions/close` (§6).
   A deployment with no signaling URL configured, or a signaling server that cannot be reached,
   logs the failure and leaves that one session to the §6.2 sweep; no new session can start
   either way.
4. The device record is retained, unlinked, with its `trialEndsAt` intact, so that a re-link
   keeps the same `deviceId` and the same trial history. Unlinking is not a way to restart a
   trial, and signing back in does not grant a second one.

Response `204`.

---

## 4. Entitlement

### 4.1 `GET /v1/entitlement` — device token

The one endpoint the desktop app polls. It answers a single question: **may this device host a
session right now, and what should the UI say if not?**

| Field | Type | Req | Meaning |
|---|---|:--:|---|
| `status` | string | yes | `trial`, `active`, `exhausted` or `unlinked`. Closed enum; an unrecognised value is treated as `exhausted`. `trial` means the balance is entirely unexpired starting credits; the first paid credit on the account makes it `active`. |
| `tier` | string | yes | `base` or `skipper`. Open enum — what a tier unlocks is server policy. |
| `balanceCents` | int64 | no | Present when the device is linked to an account. Absent is not zero; absent means "not applicable to this status". Starting credits (§7.2) are part of it, so a device on a trial carries a balance too. |
| `minutesRemaining` | int | no | Whole minutes of hosting the balance still buys, at the account's rate. Present whenever `balanceCents` is. Computed server-side: the client must not divide a balance by a rate (§4.2). |
| `trialEndsAt` | int64 | no | Unix ms. Present only when `status` is `trial`: the moment the starting credits expire. |
| `concurrency` | object | yes | `{"maxActivePairs": 1}`. The server states the limit; the client renders it. |
| `refreshAfterSec` | int | yes | How long this answer may be cached. Currently **60**. |

```json
{
  "status": "trial",
  "tier": "base",
  "balanceCents": 50,
  "minutesRemaining": 300,
  "trialEndsAt": 1756000000000,
  "concurrency": {"maxActivePairs": 1},
  "refreshAfterSec": 60
}
```

### 4.2 Policy lives on the server

The client **must not** compute entitlement. It must not compare `balanceCents` to a rate, infer
an expiry from `trialEndsAt`, or decide that `exhausted` means "show the payment screen" as
anything other than a rendering of what the server said. `minutesRemaining` exists so that the
one division a client would be tempted to do is done here: the trial size, the rate, the
cents-per-hour, lock-out behaviour and tier contents all change server-side with no client
release (SCOPE §6, §7).

The client's whole contract is: render `status`, `tier`, `balanceCents`, `minutesRemaining`,
`trialEndsAt`; re-fetch after `refreshAfterSec`; and, on `error{entitlement}` from signaling,
re-fetch once and render the reason.

### 4.3 Entitlement reasons

The `reason` on a `402 entitlement` here, and on `error{entitlement}` over signaling
(PROTOCOL.md §7), come from the same closed set:

| `reason` | Meaning |
|---|---|
| `unlinked` | The host device is not linked to any account, or no device with that id exists. |
| `trial_expired` | The device's starting credits expired or ran out, and no balance remains. |
| `no_balance` | The device never had starting credits (§3.2) and the balance is zero or below the minimum a session requires. |
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
| `startedAt` | int64 | yes | Unix ms at which the host relayed its first `sdp` for the session — the moment the session was proved and metering began (PROTOCOL.md §3.4). A session that never got there has no record. |
| `endedAt` | int64 | no | Unix ms, session `closed`, or for a row closed by reconciliation (§6.2) the last time signaling was seen holding it. Absent while the session is still live. |
| `relayUsed` | bool | yes | Whether any traffic went through a TURN relay. Always present, including `false`. |
| `bytesRelayed` | int64 | no | Bytes relayed through TURN. Absent when unknown or when `relayUsed` is `false`. Never the peer-to-peer byte count — the server cannot know it. |

Ordering is `startedAt` descending. A session that is still live appears with no `endedAt` and
may appear again, completed, in a later query.

### 5.2 What a session costs

A session is billed on its end, from `startedAt` to `endedAt`, by its **whole seconds**. The rate
is per **hour**, so a session's seconds are worth a fraction of a cent: whole cents are charged and
the remainder stays on the account as a carry that the next session's charge starts from. Nothing
is rounded away in either direction, so many short sessions cost what one long session of the same
total length costs, to within the single cent still sitting in the carry.

A session too short to be worth a cent therefore charges **nothing** — at 10¢/hour that is anything
under six minutes on an empty carry — but the time is still owed and the next session's charge
starts from it. The free window is an allowance on the account, not a property of each session:
there is no session length that can be repeated for free.

The charge is one `session_charge` ledger entry (§7.2) per session — and no entry at all when the
session and the carry together do not reach a cent — and it may be **less than the seconds were
worth**: a charge is clamped to the balance available, never taken past zero (§7.2),
and a clamped charge drops the carry rather than holding a shortfall against a later top-up. A
session whose charge clamps is closed, and the account's next session is refused `no_balance`
(§4.3). A session is settled when it ends, so between settlements it can outrun its balance; the
reconciliation sweep (§6.2) closes a live session whose account has nothing left, which bounds the
overrun to one sweep.

Policy lives in the server (`server/internal/policy`); the client never computes it.

### 5.3 What is deliberately not here

No session content endpoint exists, in any form, at any version. There is no screenshot, no
transcript, no event list, no "what was clicked". If a future feature appears to need one, it is
the feature that is wrong (SCOPE §2, principle 2).

---

## 6. Internal surface (not part of the client contract)

The two services talk over a private path. It is documented here only so that both are written
against one shape, and it carries the same metadata as §5.1 — no content.

**Where it is served.** Never next to the public API. rc-api serves the calls below only on its
**internal listener** (`RC_API_INTERNAL_LISTEN`, default `127.0.0.1:18081`); on the public
listener every `/internal/...` path is `404`. rc-signal likewise serves its one internal call
only on its own internal listener (`RC_INTERNAL_LISTEN`, default `127.0.0.1:18444`), never next
to `/ws`. Each service refuses to start with an internal listener on its public port.
TODO: make both listeners mutually authenticated (mTLS) or reachable only inside the VPC in
Phase 5; today they are plain HTTP bound to loopback.

Every internal call carries `Authorization: Bearer <internal token>`, a secret shared by the two
services and nothing else, compared in constant time. A device token or user session is
`401 unauthenticated` here.

rc-api's internal listener:

| Call | Body | Effect |
|---|---|---|
| `POST /internal/devices/register` | `pubkey` (canonical, else `400`), optional `label`, optional `platform`, optional `preferredDeviceId` (9 digits, else `400`), optional `idCert` | The device registry. Answers `{deviceId, existing, idCert}` — `201` for a new key, `200` for a known one. Idempotent by `pubkey`: a known key always gets its existing `deviceId`. A new key gets `preferredDeviceId` only when `idCert` certifies it for this `pubkey` (§6.1); otherwise a fresh id. |
| `GET /internal/devices/{deviceId}` | — | `{deviceId, pubkey, codeEpoch}`, used to pin both keys at `connect_req`. No `idCert`: a lookup never signs (v5). Unknown id is `404 not_found`. |
| `POST /internal/devices/{deviceId}/cert` | `{pubkey}` | *v5.* The only lookup that signs: called by signaling after a `hello` signature verified (PROTOCOL.md §2.4). `200 {deviceId, pubkey, codeEpoch, idCert}` when `pubkey` owns `deviceId`; `404 not_found`, with no signature made, when the id is unknown or bound to another key. |
| `POST /internal/devices/{deviceId}/epoch` | `{}` | Bumps `codeEpoch` (PROTOCOL.md §2.15 `refresh_code`, §3.2 session-token epoch). Answers the updated `{deviceId, pubkey, codeEpoch}`; unknown id is `404`. |
| `POST /internal/sessions/start` | `sessionId` (32 hex), `hostDeviceId`, `controllerDeviceId`, `startedAt` | Opens the accounting record and claims the host's concurrency slot. Sent when the host's first `sdp` is relayed (PROTOCOL.md §3.4), not at `connect_ok`. `402 entitlement` when the account's slot is already taken; signaling then ends the session. |
| `POST /internal/sessions/stop` | `sessionId` (32 hex), `endedAt`, `relayUsed`, `bytesRelayed`, `reason` (a PROTOCOL.md §2.14 reason, else `400`) | Closes the record, settles the charge against the balance (§5.2), frees the slot. A stop for a record that is already closed is `204` and charges nothing. |
| `GET /internal/entitlement/{deviceId}` | — | Gates `connect_req`. `200` with the §4.1 body when the host may open a session; otherwise `402 entitlement` with the §4.3 `reason`. An id the registry does not hold, or a registered device that is not linked, is `unlinked`. This call never creates a record. |
| `GET /internal/pairs/{hostDeviceId}/{controllerDeviceId}` | — | *v5.* `{known: bool}`: whether this controller has had a metered session with this host — a session row exists (`POST /internal/sessions/start`). Signaling asks it for a `connect_req` that is about to be delivered, so a known pair spends its own rate-limit bucket instead of the host's (PROTOCOL.md §3.3). Durable: it is the session table, so it survives restarts of either service. Malformed ids are `400`. |
| `POST /internal/releases` | The §6.3 release body: `platform`, `arch`, `channel` (default `stable`), `version`, `build`, `minimumOS`, `url`, `sha256`, `size`, optional `notes`, `critical` | Publishes a §10 release. Republishing a build on the same track replaces it. `201` with the §10.1 body. **This is how a release reaches production**; `POST /v1/dev/releases` (§6.3) is `404` under any identity provider but `dev`. It lives here rather than on the public listener because this surface is already loopback-only and token-authenticated: a public authenticated publish endpoint would be new attack surface for one call the owner makes by hand. The caller is `scripts/publish-release.sh`, over SSM. |
| `GET /healthz` | — | `200 ok`, no bearer needed. |

rc-signal's internal listener:

| Call | Body | Effect |
|---|---|---|
| `GET /internal/sessions/live` | — | `{sessionIds: [string], serverTime: int64}`: every **metered** session rc-signal still holds, sorted, and its clock. Used by §6.2. |
| `POST /internal/sessions/close` | `deviceId` (9 digits, else `400`), `reason` (a PROTOCOL.md §2.14 reason, else `400`) | Closes every live session that device takes part in, as host or controller, with `bye{reason}` to both sides and a stop report for a metered one. Answers `204`, including when it holds no session for that device. Used by §3.6. |

rc-signal sends start and stop reports through one ordered lane per session (PROTOCOL.md
§3.4): at most one report per session in flight, the stop never before the start, retries with
back-off for transport failures, `5xx` and `429` (6 attempts), no retry for other `4xx`, and a
bounded queue. A report that is finally dropped is logged and left to §6.2.

### 6.1 One registry

This API is the only place a `deviceId` is minted. The signaling server holds no device records of
its own in a deployment; it asks the calls above, with bounded timeouts (3 s per call), and may
cache `GET /internal/devices/{deviceId}` answers briefly, dropping a device's entry whenever it
bumps that device's epoch or registers a key under that id.

The registry holds a P-256 **device-ID certificate key** — either a KMS asymmetric
`ECC_NIST_P256` key whose private half never leaves KMS (`-id-cert-kms-key-id`,
`RC_API_ID_CERT_KMS_KEY_ID`, how a deployment runs) or a PEM PKCS#8 file
(`RC_API_ID_CERT_KEY_FILE`), the two being mutually exclusive — and signs a binding only on register and on
`POST /internal/devices/{deviceId}/cert` (PROTOCOL.md §3.1.1). `preferredDeviceId` is honoured
only together with an `idCert` that verifies for exactly that id and the registering `pubkey`,
and only when the claims database (below) names that key for the id or names nobody. Should a
device record for the id under another key exist anyway, that record is removed and its device
tokens are revoked. Without a valid certificate a new key always gets a fresh id, whether or not
the preferred one is free, so the call reveals nothing about which ids exist. The process refuses
to start without one of the two key sources unless it runs in local `-insecure-http` mode, where
it makes a throwaway key. With a KMS key it fetches the public key once at startup and, **by
design, refuses to start if that fetch fails** — a wrong key id, a wrong region and a missing
`kms:Sign` grant all surface there, and they must stop a deploy loudly rather than leave a
process that reports healthy and then fails every registration. Once running, a signing failure
fails that one call and never yields a device a bad certificate; the whole signing call,
including its retries, stays inside the 3 s budget above.

**The claims database — operator rules.** Every id the registry ever assigned is recorded with
the key it was given to in `device_id_claims`, which lives in its **own SQLite file**:
`RC_API_CLAIMS_DB` (`-claims-db`), default `<RC_API_DB without extension>-claims<extension>`,
e.g. `rc-api.db` → `rc-api-claims.db` (rc-signal's stand-alone mode: `RC_CLAIMS_DB`, default
`rc-signal-claims.db`). It is what guarantees that no id is ever given to two keys, so:

- **Never delete, reset or recreate it together with the main database.** Resetting
  `RC_API_DB` (a wipe, a restore from an old snapshot, a move to a new account) is safe only if
  the claims file is kept; devices then re-register with their certificates and get their own
  ids back, and nobody else can obtain them.
- **Back it up on its own schedule** and restore the newest copy. It only grows (one small row
  per id ever assigned; rows are never changed or removed), so a newer copy is always a
  superset.
- Keep it on durable storage next to, but not inside, anything that is routinely wiped (a data
  volume that a redeploy recreates, a `rm rc-api.db*` in a script).
- If it is lost anyway, the first certified key to come back for an id keeps it; a second key
  holding a certificate for the same id (possible only because an earlier loss let the id be
  reissued) gets a fresh id instead, so ids never flip between keys.
- On first start a build that finds the table in the main database (an older build kept it
  there) copies it, adds a claim for every device row, and drops the old table. Every start
  adds a claim for any device row that lacks one; an existing claim is never changed.
- `TODO:` Phase 5 moves the claims into a DynamoDB table with point-in-time recovery and
  deletion protection, separate from the registry table.

When this API cannot be reached or answers `5xx`, the signaling server refuses `register`,
`hello`, `refresh_code` and `connect_req` with `error{code:"unavailable", retryAfterSec}`. It never
falls back to minting or trusting an id of its own. A client treats `unavailable` like `internal`:
back off and retry, keeping any live peer-to-peer session running.

The signaling server's stand-alone mode (`RC_ENTITLEMENT=static`, local development and the
smoke test only) keeps an equivalent registry in its own database (`RC_DB`) with its claims in
`RC_CLAIMS_DB` under the same rules, records known pairs in its own database when a session is
metered, signs certificates with its own key file (`RC_ID_CERT_KEY_FILE`), has no link to this
API, and does not start its internal listener.

### 6.2 Reconciliation

Every minute rc-api, when configured with `RC_API_SIGNAL_INTERNAL_URL`, lists its open session
rows, **then** asks rc-signal for `GET /internal/sessions/live`. Reading the rows first means a
session that starts in between is never mistaken for a lost one. For each open row:

- held by signaling: the row's last-alive time becomes the answer's `serverTime`;
- not held: the row is closed with `reason: "reconciled"`, ended at its last-alive time (its
  start if it was never seen alive), and billed per §5.2 up to then.

If rc-signal cannot be reached or answers anything but `200`, nothing is closed. A late stop
report for a reconciled row changes nothing and charges nothing. `TODO:` with several rc-signal
instances in Phase 5, ask every instance and close only what none holds.

### 6.3 Development-only calls

TODO: remove both at launch. They exist only when the API runs with the local development
identity provider (`Bearer dev:<email>`), and are `404` otherwise.

| Call | Auth | Effect |
|---|---|---|
| `POST /v1/credits/dev-topup` | user session, idem | Credits the account with `amountCents`. |
| `POST /v1/dev/expire-trial` | user session | Body `{}`. Ends every running trial on the account's devices. `204`. |
| `POST /v1/dev/releases` | user session | Publishes a §10 release. Body: `platform`, `arch`, `channel` (default `stable`), `version`, `build`, `minimumOS`, `url`, `sha256`, `size`, optional `notes`, `critical`. Republishing a build on the same track replaces it. `201` with the §10.1 body. Production uses `POST /internal/releases` (§6) instead; this one stays for `scripts/dev-backend.sh`. |

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
| `type` | string | yes | `topup`, `session_charge`, `gift_sent`, `gift_received`, `gift_refund`, `trial_grant`, `trial_expiry`, `adjustment`. Open enum. |
| `amountCents` | int64 | yes | Signed. Negative is a debit. |
| `balanceAfterCents` | int64 | yes | Balance after this entry. Makes the ledger self-checking. |
| `createdAt` | int64 | yes | Unix ms. |
| `sessionId` | string | no | Present on `session_charge`. |
| `giftId` | string | no | Present on the gift types. |
| `memo` | string | no | Short human text, ≤ 140 chars. Never contains a secret. |

The ledger is **append-only**. A correction is a new `adjustment` entry, never an edit.

**No entry may take a balance below zero.** A debit larger than the balance is refused; the one
exception is a `session_charge`, which is clamped to the balance available because the session has
already happened (§5.2). `balanceAfterCents` is therefore always what it says, and always ≥ 0.

**Starting credits** are a `trial_grant` on the device's first link (§3.2) — one entry, positive,
with an expiry window. Session charges consume grant before paid credit. When the window closes,
one `trial_expiry` entry takes back the part of the grant no session spent, and never more than
the balance, so credit the user paid for survives it. A window that expires with nothing left to
take still gets its `trial_expiry`, worth zero: the entry is what records that the window closed.
`trial_expiry` is a type of its own rather than an `adjustment` so that an operator correction can
never be mistaken for expired grant.

Accounts that predate starting credits are migrated once, at startup: a device that held a
calendar trial gets its `trial_grant` and a fresh window, and a balance the old code had driven
below zero gets an `adjustment` bringing it to exactly `0`, memo `corrected`. The old balances are
left in the ledger — it is append-only — so entries written before the correction may still read a
negative `balanceAfterCents`. Nothing from the correction forward does. There is **no user-facing
notice**: the app shows the current state, and the current state is a working trial.

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

Limits are per the stated key, as token buckets that refill evenly over the stated window. "Per
IP" means the client address of §0. Over the limit is `429 rate_limited` with `retryAfterSec`.
Limits are a floor, not a promise: the server may be stricter under load and says so through the
same response. Idle buckets are dropped once full, so the limiter's memory is bounded.

| Method | Path | Auth | Idem | Rate limit |
|---|---|---|:--:|---|
| `POST` | `/v1/auth/link` | user session | yes | 10 / hour per account |
| `POST` | `/v1/auth/device/challenge` | none | no | 30 / hour per IP (no per-device limit, §1.3) |
| `POST` | `/v1/auth/device/token` | none | yes | 10 / hour per IP, 5 / hour per `code` |
| `POST` | `/v1/auth/device/refresh` | none | yes | 30 / hour per IP, charged first; 12 / day per device, charged only after the signature verified under the device's registered key (§1.5) |
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
| `GET` | `/v1/app/releases/latest` | none | — | 60 / hour per IP (cacheable for 300 s) |

`GET /v1/health` returns `200 {"status":"ok","serverTime":<unix ms>}` and is the only endpoint
that reveals nothing about anyone.

---

## 9. Privacy guarantees (normative)

The API server **must not** log, persist, or transmit to third parties: device tokens, one-time
link codes, Cognito tokens, raw `hardwareId` values, the `hardwareHash` salt, the device-ID
certificate key, gift messages, or anything from the peer-to-peer surfaces of PROTOCOL.md. Log
lines may contain: `requestId`, `accountId`, `deviceId`, `sessionId`, method, path, status,
error `code`, byte counts and timings. Anything else is a bug in the server.

What is persisted in place of a credential, and nothing more:

| Credential | Stored as |
|---|---|
| device token | `SHA-256(token)` in the token table; never in the idempotency table (§0.6) |
| one-time link code | `SHA-256(code)` in the link table and on its challenge nonces; never in the idempotency table |
| link-attempt nonce | `SHA-256(nonce)` |
| `hardwareId` | `HMAC-SHA256(serverSalt, hardwareId)` |

A database written by an earlier build is migrated on open: the plaintext link-code and nonce
tables are dropped (their rows live for at most 120 s and 60 s), and stored idempotent answers of
the credential-bearing endpoints lose their bodies.

---

## 10. App releases

The desktop app updates itself without a third-party updater. This endpoint says **what** to
install; it is never trusted to say the download is **safe**. The app's own checks (hash, size,
code signature pinned to the running app's Team ID, notarization, no downgrade) decide that —
`docs/SECURITY.md` "Updates".

Because of that, the feed carries **no signature of its own** and needs no publishing key: a
forged feed can delay an update or point at bytes the app will refuse, but it cannot get foreign
code installed. What fills it is `POST /internal/releases` (§6).

### 10.1 `GET /v1/app/releases/latest` — unauthenticated

Query: `platform` (required, `macos`), `arch` (required, `arm64` or `x86_64`), `channel`
(`stable` or `beta`, default `stable`). Any other parameter or value is `bad_request`. No track
with a release is `404 not_found`.

The answer is the most recently **published** release on the track, not the highest build: a bad
release is pulled by republishing the previous one, and the client's no-downgrade rule keeps
machines that already took the bad build where they are until a newer one ships.

| Field | Type | Req | Meaning |
|---|---|:--:|---|
| `version` | string | yes | `CFBundleShortVersionString`, dot-separated numbers. Shown to the user. |
| `build` | string | yes | `CFBundleVersion`, dot-separated numbers. The only value compared. |
| `minimumOS` | string | yes | `LSMinimumSystemVersion`. A client below it does not offer the update. |
| `url` | string | yes | The `.dmg`. `https`, or `http` on a loopback host in development. |
| `sha256` | string | yes | Lowercase hex SHA-256 of the `.dmg`. |
| `size` | int64 | yes | Byte length of the `.dmg`. |
| `notes` | string | no | Plain text, ≤ 4000 chars. |
| `publishedAt` | int64 | yes | Unix ms. |
| `critical` | bool | yes | The update fixes a security problem. The app asks the user to restart when convenient; it still never interrupts a live session. |

The response carries `Cache-Control: public, max-age=300` and nothing about the caller, so it may
be served from a CDN.
