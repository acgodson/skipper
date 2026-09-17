# RemoteControl wire protocol

Version: **3** (`v: 3` in every envelope)
Status: normative. This document is the single source of truth. `protocol/protocol.go`
(and the Swift mirror) must match it exactly; if they disagree, this file wins.

Three surfaces are specified:

1. **Signaling** — client ↔ `rc-signal` over WebSocket (WSS in production).
2. **`ctrl` data channel** — reliable, ordered, peer ↔ peer (WebRTC SCTP).
3. **`hi` data channel** — unreliable, unordered (`maxRetransmits: 0`), peer ↔ peer.

The server sees only surface 1. It never sees, parses or stores anything from 2 or 3.

---

## v3 changes (summary)

Version **3** is what the server, the shared core and the Mac app now speak. It closes three
ways a compromised server could still get between two peers after v2. A v3 endpoint rejects a
`v: 2` envelope with `error{unsupported_version}`; nothing below is negotiated.

| # | Change | Why | Where |
|---|---|---|---|
| 1 | Every device-key signature is **domain-separated**: the key signs `"skipperdesk/" purpose "/v1\|" ‖ payload`, never raw bytes. Purposes: `hello`, `register`, `sdp`, `api-challenge`. | A server chose the challenge nonce, so under v2 it could send an SDP signing string as the "nonce" and harvest a valid `sdp` signature from `hello`. | §0, §3.1 |
| 2 | `hello` and `register` sign `"skipperdesk/hello/v1\|" ‖ nonce` and `"skipperdesk/register/v1\|" ‖ nonce`. The nonce is **exactly 32 bytes**; both client and server refuse any other length. | Same attack; the fixed length also stops a nonce from carrying a structured message. | §2.1, §2.2, §2.4 |
| 3 | `sdp` gains a required **`mac`**: HMAC-SHA256 under `sdpMacKey`, a key derived from the §2.17 session key, over the same bytes `sig` signs. An `sdp` that arrives before the exchange completes is dropped. | Channel binding: a signature proves *which device* sent the fingerprints; the MAC proves it was the device that just proved the access code **in this session**. The v2 session key was derived and never used. | §2.12, §2.17 |
| 4 | A receiver refuses an `sdp` body containing a NUL byte or a CR that is not followed by LF, and, after `setRemoteDescription`, requires the fingerprints the WebRTC stack actually installed to equal the verified `fp`. | A NUL let the verifier (which read a C string) see a different SDP from the one the WebRTC stack installed. | §2.12 |
| 5 | The host adds a **host-wide guess budget** (20 failures per rolling hour across all controllers) next to the per-key counter, and a failure is recorded **before** step 2 leaves the host, withdrawn only when step 3 verifies. | Under v2 a server could present a fresh `controllerPubkey` per guess, or end the exchange by starting a new session, and never be counted. | §2.17 |

The `sdp` signing string itself is unchanged: `"skipperdesk/sdp/v1|" sessionId "|" sdpType "|" fp`
is exactly the domain-separated message for purpose `sdp` with payload
`sessionId "|" sdpType "|" fp`. `protocol/vectors/signing-vectors.json` pins every purpose.

---

## v2 changes (summary)

Version **2** is what the server, the shared core and the Mac app now speak. Everything below
marked *v1 only* or *REMOVED in v2* is kept for the record: a v2 server rejects those fields
rather than ignoring them, so the sections say exactly what is refused and why.

What changes, and why:

| # | Change | Where |
|---|---|---|
| 1 | The `code` verifier object is **REMOVED**. The server stores nothing about any access code. | §2.3 |
| 2 | `register` no longer carries `code`; its payload is `pubkey`, `sig` and the optional `label`. | §2.2 |
| 3 | `refresh_code` no longer carries a verifier; its payload is `{}`. Every side effect in §2.15 is unchanged — it still kills sessions, tokens and the trusted-controller list. | §2.15 |
| 4 | `connect_req` no longer carries `accessCode`. It carries **only** `deviceId`. | §2.9 |
| 5 | `connect_req` is authorised by **entitlement**, not by a code. The server replies `connect_ok` only if the host's entitlement allows a session and the host has no active session; otherwise `error{entitlement, reason}` or `error{busy}`. | §2.9, §3.3 |
| 6 | New error code `entitlement`, carrying a `reason`. `bad_code` is retired; a v2 server never sends it. | §7 |
| 7 | New relayed message `pake`: the access code is proved **peer to peer** by a SPAKE2 exchange that the server relays as opaque bytes. | §2.17 |
| 8 | `sdp` carries **signed DTLS fingerprints**: `fp`, `pubkey` and `sig`. The peer verifies them against the key it expects, so a compromised server cannot MITM the media. `connect_ok` gains `hostPubkey`, `pake` steps 1 and 2 carry each sender's pubkey, and `bye` gains the reason `peer_auth_failed`. | §2.12, §2.9, §2.17, §2.14 |
| 9 | Access-code rate limiting moves to the host. The server's §3.3 limiter no longer applies to codes; the host counts and throttles failed PAKE attempts itself, because the server no longer knows what a failure is. | §3.3 |
| 10 | `session_start` gains `controllerPubkey`, and `bye` gains the reason `auth_failed` — the host's answer to a code it refused, or to a controller it is currently locked out. | §2.9, §2.14 |

The point of the change: after it, a server operator who reads every byte the server ever sees
still cannot connect to a host. The code never reaches the server in any form — not as plaintext,
not as a verifier it could grind offline. Authorisation the server *can* make (is this host paid
up, is it already busy) stays on the server; authorisation it *must not* be able to forge (does
this controller know the code) moves to the two peers. The crypto itself — the SPAKE2 group, the
key schedule, and what the derived key is then used for — is specified separately; §2.17 defines
only the envelope that carries it.

`protocol/API.md` is the other half of change 5: it defines the entitlement the server reads.

---

## 0. Conventions

| Convention | Rule |
|---|---|
| Encoding | UTF-8 JSON, one message per WebSocket **text** frame. Binary frames are a protocol error. |
| Time | All absolute times are **Unix milliseconds**, `int64`, UTC. Durations are named `...Sec` (seconds, `int`) or `...Ms`. |
| Coordinates | Normalised `double` in `[0.0, 1.0]`; `x` = left→right, `y` = top→bottom of the host's captured display. Receivers **must** clamp. |
| IDs | `deviceId`: exactly 9 ASCII digits, e.g. `"481930275"`. Leading zeros are significant; it is a string, never a number. `sessionId`: 32 lowercase hex chars. Message `id`: opaque client string ≤ 64 chars. |
| Keys | `pubkey`: base64 (std, padded) of the **DER SPKI** encoding of an ECDSA P-256 public key. |
| Signatures | `sig`: base64 of the **ASN.1 DER** ECDSA-P256/SHA-256 signature over a **domain-separated message** (§3.1): `"skipperdesk/" purpose "/v1\|"` followed by the purpose's payload. A device key never signs anything else. |
| Unknown fields | Receivers **must** ignore unknown object members. Senders **must not** rely on that. |
| Unknown types | A receiver that does not recognise `type` ignores the message (server replies `error{unsupported}` for client→server only). |
| Max frame | 256 KiB. Larger frames are closed with WebSocket code 1009. |

### 0.1 Envelope

Every message on every surface uses the same envelope:

```json
{
  "v": 3,
  "type": "connect_req",
  "id": "c-17",
  "re": null,
  "ts": 1755600000000,
  "payload": { }
}
```

| Field | Type | Req | Meaning |
|---|---|:--:|---|
| `v` | int | yes | Protocol version. Must be `3`. Server rejects anything else with `error{unsupported_version}` and closes. |
| `type` | string | yes | Message type; see tables below. |
| `id` | string | no | Sender-assigned correlation id. Required if the sender wants to match the reply. Servers echo it in `re`. |
| `re` | string | no | Set on a reply/error to the `id` of the request it answers. Absent on unsolicited pushes. |
| `ts` | int64 | no | Sender clock, Unix ms. Informational only; never trusted for authorisation. |
| `payload` | object | yes | Type-specific body. `{}` when the type has no fields. Never `null`. |

**Every error is the same shape** (`type: "error"`), and carries `re` when it answers a request:

```json
{"v":3,"type":"error","re":"c-17","ts":1755600000001,
 "payload":{"code":"entitlement","message":"trial has ended","reason":"trial_expired"}}
```

| Field | Type | Req | Meaning |
|---|---|:--:|---|
| `code` | string | yes | Machine-readable, from §6. Clients branch on this, never on `message`. |
| `message` | string | yes | Human-readable, English, safe to log. Never contains a secret. |
| `retryAfterSec` | int | no | Present on `rate_limited`; seconds until the next attempt may succeed. |
| `reason` | string | no | *v2.* Present on `entitlement`; see §7. Absent on every other code. |

---

## 1. Signaling transport

- Production: `wss://<host>:8443/ws`, TLS 1.2+, self-signed certificate **pinned by SHA-256
  fingerprint** in the app (see PLAN.md §3). No CA validation is performed.
- Local development only: `ws://127.0.0.1:8443/ws` when the server runs with `-insecure-http`.
- `GET /healthz` returns `200 ok` (plain text) and is the only non-WebSocket route.
- Sub-protocol: none required. Origin is not checked (native clients).

### 1.1 Connection lifecycle

```
        TCP+TLS up
            │
            ▼
  ┌───────────────────┐  server sends immediately
  │  CHALLENGED       │◄──────── challenge{nonce}
  └───────────────────┘
       │            │
  register     hello(deviceId,pubkey,sig)
       │            │
       ▼            ▼
 register_ok    ┌───────────────────┐
 (conn stays    │  AUTHENTICATED    │  hello_ok{iceServers,...}
  CHALLENGED,   └───────────────────┘
  new nonce)         │
                     ├── heartbeat / watch / connect_req / resume / renew /
                     │   sdp / ice / pake / bye / refresh_code / unwatch
                     ▼
                  (close)
```

- The server sends `challenge` **within 1 s of the socket opening**, unsolicited, with no `re`.
- A connection that sends anything other than `register` or `hello` while `CHALLENGED` gets
  `error{unauthenticated}`; three such messages close the socket (1008).
- A connection that does not authenticate within **20 s** is closed (1008, `auth_timeout`).
- After `register_ok` the connection is still `CHALLENGED` and the server issues a **fresh
  `challenge`**; the client then sends `hello` with the newly assigned `deviceId`.
- Each nonce is single-use. A replayed nonce is `error{bad_signature}`.
- At most **one** authenticated connection per `deviceId`. A second successful `hello` for the
  same device **displaces** the first: the older socket is sent
  `error{displaced}` and closed with 1000. (Presence is a single-device fact; this keeps it
  unambiguous. Sessions are *not* dropped — see §4.)

---

## 2. Signaling messages

### 2.1 `challenge` — server → client (unsolicited, on connect and after `register_ok`)

| Field | Type | Req | Notes |
|---|---|:--:|---|
| `nonce` | string | yes | base64 of **exactly** 32 random bytes. Single-use, valid 20 s. *v3:* a client refuses to sign a nonce of any other length and drops the connection. |
| `serverTime` | int64 | yes | Unix ms. |

### 2.2 `register` — client → server

First-run only. Creates a device record and mints a `deviceId`.

| Field | Type | Req | Notes |
|---|---|:--:|---|
| `pubkey` | string | yes | base64 DER SPKI, P-256. |
| `sig` | string | yes | *v3:* base64 DER ECDSA-SHA256 over `"skipperdesk/register/v1\|"` ‖ the raw 32 `nonce` bytes of the current challenge (§3.1). Proves possession of the private key. |
| `label` | string | no | Human label, ≤ 64 chars, e.g. `"Studio Mac"`. Stored verbatim; not secret. |
| `code` | object | yes | *v1 only.* Access-code verifier, see §2.3. **REMOVED in v2.** |

If this `pubkey` is already registered, the server **does not** create a second device: it
returns `register_ok` with the existing `deviceId` and leaves the stored code untouched.
Registration is therefore idempotent per key.

Reply: **`register_ok`**

| Field | Type | Req | Notes |
|---|---|:--:|---|
| `deviceId` | string | yes | 9 digits. Permanent. |
| `existing` | bool | yes | `true` if the key was already registered. |

### 2.3 The `code` verifier object — *v1 only, REMOVED in v2*

**REMOVED in v2.** A v2 server stores nothing about any access code: no plaintext, no salt, no
hash, no parameters. The code is proved directly between the two peers by the SPAKE2 exchange of
§2.17, and `connect_req` is authorised by entitlement instead (§2.9). A v2 client sends no `code`
object anywhere, and a v2 server rejects one with `error{bad_request}`. The section is kept whole
because v1 servers and v1 clients are still in the field.

The plaintext access code **never leaves the client that owns it**, except inside
`connect_req` from the peer that is trying to connect. The owning host sends only a verifier:

| Field | Type | Req | Notes |
|---|---|:--:|---|
| `alg` | string | yes | Must be `"argon2id"`. |
| `salt` | string | yes | base64 of ≥ 16 random bytes. |
| `hash` | string | yes | base64 of the Argon2id output over the UTF-8 plaintext code. |
| `time` | int | yes | Argon2 iterations. Server accepts 1–10. Recommended **3**. |
| `memKiB` | int | yes | Argon2 memory in KiB. Server accepts 8192–262144. Recommended **65536**. |
| `par` | int | yes | Argon2 parallelism (lanes). Server accepts 1–4. Recommended **1**. |
| `len` | int | yes | Output length in bytes. Server accepts 16–64. Recommended **32**. |

The server stores exactly these fields and nothing else about the code. Verification is
`argon2id(plaintext, salt, time, memKiB, par, len) == hash`, constant-time compared.

Access codes are generated client-side: **8 characters from a 32-symbol
Crockford-style alphabet** (`23456789ABCDEFGHJKMNPQRSTVWXYZ` minus look-alikes), from a CSPRNG
≈ 40 bits of entropy. Server-side rate limiting (§3.3) is what makes that sufficient.

### 2.4 `hello` — client → server

| Field | Type | Req | Notes |
|---|---|:--:|---|
| `deviceId` | string | yes | 9 digits. |
| `pubkey` | string | yes | base64 DER SPKI. Must byte-equal the stored key for `deviceId`, else `error{bad_signature}`. |
| `sig` | string | yes | *v3:* base64 DER ECDSA-SHA256 over `"skipperdesk/hello/v1\|"` ‖ the raw 32 bytes of the current challenge nonce (§3.1). A `register` or undomained signature is `error{bad_signature}`. |
| `role` | string | yes | `"host"` or `"controller"`. Advisory: it describes the app's current mode and is used for logging and for rejecting nonsense (a `controller` cannot receive `connect_req`s). A device may reconnect with the other role. |

Reply: **`hello_ok`**

| Field | Type | Req | Notes |
|---|---|:--:|---|
| `deviceId` | string | yes | Echoed. |
| `serverTime` | int64 | yes | Unix ms; clients may use it to detect clock skew. |
| `iceServers` | array | yes | See §2.5. STUN entries first, TURN last. |
| `heartbeatSec` | int | yes | How often the client must send `heartbeat`. Currently **15**. |
| `offlineAfterSec` | int | yes | Silence after which the server marks the device offline. Currently **40**. |
| `sessionTokenTtlSec` | int | yes | Session-token lifetime. Currently **600**. |
| `activeSessionId` | string | no | Present iff a live session for this device already exists (the client dropped and came back). The client **must** attempt `resume` (§4) rather than `connect_req`. |

### 2.5 `iceServers` entries

| Field | Type | Req | Notes |
|---|---|:--:|---|
| `urls` | array of string | yes | e.g. `["stun:stun.l.google.com:19302"]`, `["turn:1.2.3.4:3478?transport=udp"]`. |
| `username` | string | no | TURN only. `"<unixExpirySeconds>:<deviceId>"`. |
| `credential` | string | no | TURN only. base64 of `HMAC-SHA1(username, turnSecret)` — coturn `use-auth-secret` REST form. |
| `expiresAt` | int64 | no | TURN only, Unix ms. TTL is **12 h**. |

Credentials are ephemeral and minted per `hello_ok`. A client that has been connected longer
than 12 h and needs a new ICE gathering pass should reconnect the signaling socket first.

### 2.6 `heartbeat` — client → server, every 15 s

Payload `{}`. Reply: **`heartbeat_ok`** `{"serverTime": int64}`.
Any authenticated message also refreshes liveness; `heartbeat` exists so an idle client still
proves it is there. Missing heartbeats do **not** close the socket — they only flip presence.

### 2.7 `watch` / `unwatch` — client → server

| Field | Type | Req | Notes |
|---|---|:--:|---|
| `deviceId` | string | yes | The peer to observe. May be a device that does not exist yet: the watch is accepted and reports `online:false`. |

Reply: **`watch_ok`** `{"deviceId": string}`, immediately followed by one `presence` push with
the current state. Thereafter a `presence` push on **every change**, until `unwatch` or socket
close. Watches are per-connection and are **not** restored on reconnect — a reconnecting client
re-issues `watch`. A device may watch at most 8 peers.

`unwatch` takes the same payload and replies `unwatch_ok {deviceId}`.

### 2.8 `presence` — server → client (push, no `re`)

| Field | Type | Req | Notes |
|---|---|:--:|---|
| `deviceId` | string | yes | Which device. |
| `online` | bool | yes | |
| `since` | int64 | yes | Unix ms at which the device entered this state. `0` if never seen. |

Online means: authenticated socket present **and** last activity within `offlineAfterSec`.
The transition to offline is detected by a server sweep that runs at least every 5 s, so an
offline edge is reported within `offlineAfterSec + 5 s`. A socket close reports it immediately.

### 2.9 `connect_req` — controller → server

| Field | Type | Req | Notes |
|---|---|:--:|---|
| `deviceId` | string | yes | The **host** to connect to. |
| `accessCode` | string | yes | *v1 only.* Plaintext, ≤ 64 chars. Never logged, never stored, never forwarded to the host. **REMOVED in v2:** a v2 `connect_req` carries only `deviceId`, and a v2 server rejects the field with `error{bad_request}`. |

**v2 authorisation.** A v2 server grants `connect_ok` when, and only when, both hold:

1. The **host's** entitlement allows a session — `status` is `trial` or `active` and the account's
   `maxActivePairs` is not already in use (API.md §4). Otherwise:
   `error{entitlement}` with a `reason` from §7.
2. The host has no session in any state but `closed`. Otherwise: `error{busy}`.

Nothing about the access code is checked, because the server no longer knows it. The session that
`connect_ok` opens is a *signaling* session: the two peers then run the §2.17 exchange over it,
and a controller that does not know the code cannot complete it, cannot derive the session key,
and gets nothing but a relayed handshake that fails. The host ends the session itself, with
`bye{reason:"auth_failed"}` when the code was refused and `bye{reason:"failed"}` when the
exchange broke for any other reason (§2.14).

Reply: **`connect_ok`**

| Field | Type | Req | Notes |
|---|---|:--:|---|
| `sessionId` | string | yes | 32 hex chars. |
| `sessionToken` | string | yes | Opaque bearer string for `resume`/`renew`. Treat as a secret; Keychain or memory only. |
| `expiresAt` | int64 | yes | Unix ms at which `sessionToken` stops being accepted. |
| `ttlSec` | int | yes | `= (expiresAt - now)/1000`, i.e. 600. |
| `hostDeviceId` | string | yes | |
| `controllerDeviceId` | string | yes | |
| `hostPubkey` | string | no | *v2.* The host's registered `pubkey` (base64 DER SPKI), which the server has held since `register`. It is the key the controller **requires** on every `sdp` the host sends (§2.12). A v2 server MUST send it; a controller that does not receive it cannot pin the host key and must treat the session as unauthenticated until §2.17 supplies the key instead. |

Errors, v1: `bad_code`, `offline`, `busy`, `rate_limited`, `unknown_device`, `self_connect`.
Errors, v2: `entitlement`, `offline`, `busy`, `rate_limited`, `unknown_device`, `self_connect`.

Simultaneously the host receives a push **`session_start`** with the same fields plus its own
`sessionToken` (each side gets a *different* token bound to its own deviceId) and one field of
its own:

| Field | Type | Req | Meaning |
|---|---|:--:|---|
| `controllerPubkey` | string | no | *v2.* The **controller's** registered `pubkey` (base64 DER SPKI), which the server has held since that device registered. The host keys its §2.17 guess counter and its trusted-controller list (§4) on it, and it must byte-equal the key the controller puts in its own `pake` step 1 — if the two disagree the host abandons the exchange with `bye{auth_failed}`. A v2 server MUST send it. |

**Ordering rule:** the controller must not send `sdp` before it has `connect_ok`, and the host
must not send `sdp` before it has `session_start`. The **controller is always the offerer** for
the initial negotiation; either side may be the offerer for a later ICE restart.

### 2.10 `resume` — client → server

See §4 for the state machine. Payload:

| Field | Type | Req | Notes |
|---|---|:--:|---|
| `sessionId` | string | yes | |
| `sessionToken` | string | yes | The most recent token issued to *this* device for this session. |

Reply: **`resume_ok`**

| Field | Type | Req | Notes |
|---|---|:--:|---|
| `sessionId` | string | yes | Unchanged. |
| `sessionToken` | string | yes | **Rotated.** The old token is dead the moment this is issued. |
| `expiresAt` | int64 | yes | Unix ms, now + 600 s. |
| `ttlSec` | int | yes | 600. |
| `peerAttached` | bool | yes | Whether the other side currently has a live socket on this session. |
| `role` | string | yes | `"host"` or `"controller"` — this device's role *in this session*. |

Errors: `no_session` (unknown/expired/closed), `bad_token` (forged, expired, wrong device,
or superseded by rotation), `busy` (another socket already attached as this role — should not
happen given §1.1 displacement, but is specified for completeness).

The peer, if attached, receives a push **`peer_state`** `{"sessionId":..., "attached": true}`.

### 2.11 `renew` — client → server

Keeps a long-lived session's token fresh **while connected**, so a drop at minute 59 is still
resumable. Clients should renew every 5 minutes.

Payload: `{"sessionId": string, "sessionToken": string}`.
Reply **`renew_ok`**: `{"sessionId","sessionToken","expiresAt","ttlSec"}` — token rotated,
same rules and errors as `resume`, but the connection must already be attached to the session.

### 2.12 `sdp` — client ↔ client, relayed

| Field | Type | Req | Notes |
|---|---|:--:|---|
| `sessionId` | string | yes | Must be a session this connection is attached to, else `error{no_session}`. |
| `sdpType` | string | yes | `"offer"`, `"answer"`, `"pranswer"` or `"rollback"`. |
| `sdp` | string | yes | The SDP body, verbatim. |
| `restart` | bool | no | `true` marks an ICE-restart renegotiation. Advisory for the peer. |
| `fp` | string | yes | *v2.* Every `a=fingerprint` value in `sdp`, de-duplicated, sorted, joined with `\n`. The value is the whole attribute value, e.g. `sha-256 7B:8C:…`. |
| `pubkey` | string | yes | *v2.* The **sender's** device key, base64 DER SPKI (§0). |
| `sig` | string | yes | *v2.* base64 DER ECDSA-SHA256 over the UTF-8 bytes of `"skipperdesk/sdp/v1|" sessionId "|" sdpType "|" fp` — the §3.1 message for purpose `sdp`. |
| `mac` | string | yes | *v3.* base64 HMAC-SHA256 under `sdpMacKey` (§2.17) over exactly the bytes `sig` signs. |

The server **routes and forgets**: it validates `sessionId` and attachment, rewrites nothing,
parses nothing, stores nothing, logs no part of `sdp`. If the peer is detached, the server
replies `error{peer_offline}`; SDP is **not** queued (a stale offer is worse than none).
The server relays `fp`, `pubkey`, `sig` and `mac` **unchanged and never validates `sig` or `mac`**. It cannot —
it holds neither device key — and it must not need to: the whole point of the signature is that
it is checked by the peer, against a key the server did not choose.

#### Why the fingerprints are signed

DTLS-SRTP already keeps everyone but the two peers out of the media. Everyone *but the server*:
the server relays the SDP, so a compromised one could put its own fingerprint in each direction,
complete two DTLS handshakes and read the desktop. Signing the fingerprint with the device key
closes that, because the server has neither private key.

A peer neither sends nor accepts an `sdp` until its §2.17 exchange for this `sessionId` has
completed: an `sdp` that arrives earlier is dropped. A receiver **must**, before
`setRemoteDescription`:

1. refuse an `sdp` body that contains a NUL byte, or a CR that is not immediately followed by
   LF, and treat the body as the exact bytes received — never as a terminated C string. Every
   implementation passes it across language boundaries as (pointer, length);
2. check that `fp` is exactly the fingerprint set in the `sdp` body (same de-duplication, same
   sort) — a signature over fingerprints that are not the ones being installed proves nothing;
3. verify `mac` under its own `sdpMacKey` — a missing or wrong `mac` means the sender is not
   the device that completed this session's exchange;
4. verify `sig` over `"skipperdesk/sdp/v1|" sessionId "|" sdpType "|" fp` with `pubkey`;
5. check that `pubkey` is **the peer it expects**:
   - the **host** expects the controller key it learned in the §2.17 exchange, where that key is
     bound into the SPAKE2 transcript and into the guess-policy counter;
   - the **controller** expects `connect_ok.hostPubkey`, and, once §2.17 completes, requires the
     host key it learned there to be the same one.

And **after** `setRemoteDescription`, before applying any remote ICE candidate, it re-extracts
the fingerprints from the description the WebRTC stack reports as installed
(`remoteDescription.sdp`) and requires them to equal `fp` exactly. That closes any gap between
the verifier's SDP parser and the WebRTC stack's.

Any failure is terminal for the session: `bye{reason:"peer_auth_failed"}` (§2.14), tear the peer
connection down, and tell the user the other device could not be verified. Never fall back to an
unverified description.

`sessionId` in the signed string binds the signature to one session, so a captured offer cannot
be replayed into another, and `sdpType` stops an offer being replayed as an answer. An ICE
restart is an ordinary re-offer: it is signed again, over its own fingerprints.

### 2.13 `ice` — client ↔ client, relayed

| Field | Type | Req | Notes |
|---|---|:--:|---|
| `sessionId` | string | yes | |
| `candidate` | string | yes | Candidate line, verbatim. Empty string = end-of-candidates. |
| `sdpMid` | string | no | |
| `sdpMLineIndex` | int | no | |

Same routing/opacity rules as `sdp`. Trickle ICE is expected; candidates arriving while the
peer is detached are dropped with `error{peer_offline}` and re-gathered after resume.

### 2.14 `bye` — client ↔ client, relayed, and terminal

| Field | Type | Req | Notes |
|---|---|:--:|---|
| `sessionId` | string | yes | |
| `reason` | string | yes | One of `user_ended`, `host_ended`, `timeout`, `failed`, `code_refreshed`, `replaced`, `shutdown`, `error`, `peer_auth_failed`, `auth_failed`. |

`peer_auth_failed` is *v2* and means exactly one thing: the peer's `sdp` did not pass §2.12 —
a bad signature, fingerprints that are not the ones in the SDP, or the wrong device key. It is
not a network failure and must never be retried automatically.

`auth_failed` is *v2* and means the §2.17 exchange failed **authentication**: a confirmation
that did not verify (the access code is wrong), a `pake` step 1 whose key was not the
`controllerPubkey` of `session_start`, or a controller serving a lockout, whose step 1 the host
refuses without running SPAKE2 at all. It is about the **code**, where `peer_auth_failed` is
about the **device key**; the two are never interchangeable. It replaces `bye{failed}` for those
cases only — an exchange that broke for a non-authentication reason (a malformed payload, a step
out of order, the 10-second timeout) is still `failed`.

Either side may send it. A wrong code fails for the controller at step 2 and for the host at
step 3, so in practice the **controller** speaks first and the host is the one told. A guesser
gains nothing by hanging up before step 3: the host counted the guess when it sent step 2
(§2.17). A controller that receives it shows "wrong access code", forgets any code it had
remembered for that host, and does not retry without the user.

On `bye` the server closes the session **immediately and permanently**: both tokens die, the
host's 1:1 slot frees, and the peer (if attached) receives the same `bye`. A later `resume` for
that `sessionId` returns `no_session`. `bye` is also pushed by the server on its own initiative
(e.g. `code_refreshed`, `timeout`, `shutdown`).

### 2.15 `refresh_code` — host → server

Replaces the stored access-code verifier for the **calling device only**.

Payload, v1: the `code` object of §2.3. Payload, v2: `{}` — there is no stored verifier to
replace, and the host rotates its own code locally. Every side effect below is unchanged in v2.
Reply: **`refresh_code_ok`** `{"deviceId": string, "updatedAt": int64}`.

Side effects, all immediate and atomic:
1. The old verifier is overwritten (never retained, never versioned). *v2:* there is none; the
   host rotates its own code locally and clears its trusted-controller list and guess counters
   at the same moment (§4.5).
2. Every live session in which this device participates is closed; both peers get
   `bye{reason:"code_refreshed"}`.
3. Every outstanding session token for this device is invalidated.
4. The failure/rate-limit counter for this device is reset.

### 2.16 Message index

| `type` | Direction | Reply |
|---|---|---|
| `challenge` | S→C push | — |
| `register` | C→S | `register_ok` |
| `hello` | C→S | `hello_ok` |
| `heartbeat` | C→S | `heartbeat_ok` |
| `watch` | C→S | `watch_ok` (+ `presence`) |
| `unwatch` | C→S | `unwatch_ok` |
| `presence` | S→C push | — |
| `connect_req` | C→S | `connect_ok` (peer gets `session_start`) |
| `session_start` | S→C push | — |
| `resume` | C→S | `resume_ok` (peer gets `peer_state`) |
| `renew` | C→S | `renew_ok` |
| `peer_state` | S→C push | — |
| `sdp` | C↔C | relayed as `sdp` |
| `ice` | C↔C | relayed as `ice` |
| `bye` | C↔C, S→C | relayed as `bye` |
| `refresh_code` | C→S | `refresh_code_ok` |
| `pake` | C↔C | relayed as `pake` *(v2)* |
| `error` | S→C | — |

### 2.17 `pake` — client ↔ client, relayed — *v2*

One message of the peer-to-peer SPAKE2 exchange that proves the access code. The server treats it
exactly as it treats `sdp` and `ice`: it checks `sessionId` and attachment, routes it verbatim,
and parses, stores and logs **nothing** of its contents.

| Field | Type | Req | Notes |
|---|---|:--:|---|
| `sessionId` | string | yes | Must be a session this connection is attached to, else `error{no_session}`. |
| `step` | int | yes | 1-based index of this message within the exchange, strictly increasing per sender. The server does not interpret it; a receiver that gets a `step` it did not expect abandons the exchange. |
| `payload` | string | yes | base64 (std, padded) of the opaque PAKE message. ≤ 4096 base64 chars. |

The controller sends `step: 1`. The peer is detached ⇒ `error{peer_offline}`; `pake` is **not**
queued. A client must abandon an exchange that has not completed within **10 s** of `step: 1` and
send `bye{reason:"failed"}`.

#### The exchange

Three steps, implemented in `core/crates/rc-identity` (`pake`) and pinned by
`protocol/vectors/pake-vectors.json`:

| `step` | From | `payload` (before base64) |
|:--:|---|---|
| 1 | controller | `len32(controllerPubkey)` ‖ `controllerPubkey` ‖ the controller's SPAKE2 message |
| 2 | host | `len32(hostPubkey)` ‖ `hostPubkey` ‖ the host's SPAKE2 message ‖ `confirmH` (32 bytes) |
| 3 | controller | `confirmC` (32 bytes) |

Steps 1 and 2 each carry the sender's **device pubkey** — the raw DER SPKI bytes, with a
big-endian 4-byte length prefix — ahead of the SPAKE2 message. Both keys are in the transcript
below, so a relay that forwarded a genuine exchange but substituted a key would fail the
confirmation it cannot compute. That is what makes the key learned here safe to use as the
expected signer of the peer's `sdp` fingerprints (§2.12): the host pins the controller key it
reads at step 1 (and keys its guess-policy counter on it), the controller pins the host key it
reads at step 2 and requires it to equal `connect_ok.hostPubkey`.

*This extends the step-1 and step-2 payloads, which previously held the bare 33-byte SPAKE2
message.* `protocol/vectors/pake-vectors.json` was regenerated: the key schedule changed, because
the transcript gained the two keys.

Symmetric SPAKE2 over Ed25519 (RustCrypto `spake2`), with

```
password = access code, normalised: uppercase, separators dropped, Crockford aliases applied
identity = "skipperdesk/pake/v1|" deviceId "|" sessionId
```

The host `deviceId` and the `sessionId` are bound **into the SPAKE2 identity**, so a captured
exchange cannot be replayed into another session or against another host: the two sides would
derive different keys and confirmation would fail. The role names are not identities — symmetric
SPAKE2 has exactly one — they are the HKDF `info` that separates the two confirmation keys.

Key schedule over the 32-byte SPAKE2 output, with `len32(x)` a big-endian length prefix:

```
transcript = len32("skipperdesk/pake/v1") ‖ len32(deviceId) ‖ len32(sessionId)
             ‖ len32(controllerPubkey) ‖ len32(hostPubkey)
             ‖ len32(controllerMessage) ‖ len32(hostMessage)
prk        = HKDF-SHA256-Extract(salt = transcript, ikm = sharedKey)
sessionKey = HKDF-Expand(prk, "skipperdesk/pake/v1 session-key", 32)
sdpMacKey  = HKDF-SHA256(salt = "" , ikm = sessionKey, info = "skipperdesk/sdp-mac/v1", 32)
kcC        = HKDF-Expand(prk, "skipperdesk/pake/v1 confirm skipperdesk-controller", 32)
kcH        = HKDF-Expand(prk, "skipperdesk/pake/v1 confirm skipperdesk-host", 32)
confirmC   = HMAC-SHA256(kcC, transcript)
confirmH   = HMAC-SHA256(kcH, transcript)
```

`sessionKey` never leaves the shared core; its one use is `sdpMacKey`, which MACs every `sdp`
of the session (§2.12). Remembered-code and trusted-controller connects run this exchange
too (§4.5), so every session has the key. `protocol/vectors/pake-vectors.json` pins
`sdpMacKey` and one `sdp` MAC per case.

A wrong code therefore fails for the controller at step 2 and for the **host** at step 3, before
the host has done anything else with the session. Either side treats a failed confirmation, an
out-of-order `step`, an oversized payload or a reflected message as the end of the exchange:
`bye`, and the state is not reusable. The reason follows §2.14: a failed confirmation is
`auth_failed`; an out-of-order `step`, an oversized or malformed payload, a reflected message
or the timeout is `failed`.

#### Guessing

Guess rate limiting is the **host's** job in v2 (§3.3): the host counts failed exchanges per
controller device key and per unit time, and refuses to start another one while it is throttling.
The server cannot do this for it, because a failed exchange is indistinguishable, from the
server's side, from a dropped one.

Step 2 carries `confirmH`, which lets whoever sent step 1 check **one** guess offline. So a
guess costs the host exactly when step 2 leaves it, and the host accounts for it then:

- **A failure is an exchange in which the host sent step 2 and step 3 never verified** — for
  any reason: a wrong `confirmC`, the 10-second timeout, a `bye`, a new `session_start`, the
  session being cleared, or the host process dying. The host records the failure **before** it
  sends step 2 and withdraws it only when step 3 verifies, so no way of ending the exchange
  escapes the count.
- Two budgets are charged together, and step 1 is refused while **either** is exhausted:
  - **per controller key**, keyed on `session_start.controllerPubkey` (which step 1's own key
    prefix must match — a mismatch is refused before step 2 is sent). The **5th** failure
    locks that key out and every further failure doubles the lockout:
    `lockout = min(60 min, 1 min × 2^(failures − 5))` → 1, 2, 4, 8, 16, 32, 60, 60 … minutes.
    Failures are forgotten after **15 minutes** of quiet, measured from the later of the last
    failure and the end of any lockout being served. A verified step 3 clears this counter.
  - **host-wide**, across every controller: at most **20** failures in any rolling hour. The
    20th locks every controller out until the oldest of those failures is an hour old. A
    verified step 3 withdraws only its own failure. This is what bounds a server that invents
    a fresh `controllerPubkey` for every guess.
- A refused step 1 is answered `bye{auth_failed}` (§2.14) without running SPAKE2 and **without
  recording a failure** — no step 2 was sent, so no guess was spent, and a lockout costs the
  host nothing.
- Both budgets are pure policy in `core/crates/rc-identity` (`GuessLedger`), stored by the
  host next to each other: the per-key counters by pubkey, the host-wide one under the key
  `host` with its failure timestamps (`failureTimesMs`). Refresh Code (§2.15) clears both.

---

## 3. Authorisation, rate limiting and session tokens

### 3.1 Device authentication
1. Server sends a 32-byte random `nonce`.
2. Client decodes it, refuses anything that is not exactly 32 bytes, signs the
   **domain-separated message** below with ECDSA-P256/SHA-256 and sends the DER signature,
   base64-encoded.
3. The server loads the stored SPKI for `deviceId`, requires the presented `pubkey` to be
   byte-identical, and verifies the signature over the same message. Any failure ⇒
   `error{bad_signature}`; the server does not distinguish "unknown key" from "bad maths" in
   the message text.

*v3.* A device key signs **only** `"skipperdesk/" purpose "/v1|"` followed by the purpose's
payload, built by one function in the shared core (`rc_identity::signing_message`); the
platform signing API accepts a purpose and a payload, never raw bytes.

| Purpose | Payload | Used by |
|---|---|---|
| `hello` | the 32 raw nonce bytes | §2.4 |
| `register` | the 32 raw nonce bytes | §2.2 |
| `api-challenge` | the 32 raw nonce bytes | `API.md` device challenge |
| `sdp` | `sessionId "\|" sdpType "\|" fp` (UTF-8) | §2.12 |

A nonce purpose with a payload of any length but 32 is refused by every implementation, and
the server never verifies an `sdp`-purpose signature. No prefix is a prefix of another, so a
signature for one purpose never verifies for another.

### 3.2 Session tokens
Opaque to clients. Structurally:

```
token   = base64url(body) "." base64url(HMAC-SHA256(body, serverSecret))
body    = sessionId ":" deviceId ":" expiryUnixSeconds ":" epoch ":" nonce
```

`epoch` is bumped on `refresh_code`; `nonce` is rotated on every issue, which is what makes an
old token dead after `resume`/`renew`. Verification requires **all** of: MAC valid,
`expiry > now`, session exists and is open, `deviceId` is a participant, `epoch` current, and
`nonce` equal to the session's current nonce for that device. Tokens are bearer credentials
with a 10-minute TTL; they are never logged.

### 3.3 Access-code rate limiting (per host `deviceId`, server-wide) — *v1 only*

**v2:** this limiter no longer applies to access codes; the server cannot see a code attempt, let
alone a failed one. The host rate-limits the §2.17 exchange itself, with the same shape of policy.
The server keeps the limiter for `connect_req` as a whole — the counter then measures connection
attempts against a host, not code guesses — and still answers `rate_limited` with `retryAfterSec`.

- A sliding window of **15 minutes** counts failed `connect_req` attempts.
- Attempts 1–5 that present the wrong code return `bad_code`.
- From the **6th** failure onward the device is **locked out**: every `connect_req` returns
  `rate_limited` with `retryAfterSec`, without the code being checked at all.
- Lockout is exponential in the number of failures beyond the threshold:
  `lockout = min(60 min, 1 min × 2^(failures − 5))` → 1, 2, 4, 8, 16, 32, 60, 60 … minutes.
- A **successful** `connect_req` clears the counter, as does `refresh_code`.
- Failures older than the 15-minute window are discarded, so the counter decays on its own.
- The limiter keys on the *host* device, not the source IP: the threat is code guessing, and
  the attacker chooses the IP but not the target device.

---

## 4. Session lifecycle and the reconnect/resume state machine

This is the part implementations get wrong. Read it twice.

### 4.1 The invariant

> A **session** is server-side state that outlives any particular WebSocket.
> Dropping the socket does **not** end the session. Only `bye`, token expiry with nobody
> attached, `refresh_code`, or server shutdown end it.

The server holds, per session: `sessionId`, `hostDeviceId`, `controllerDeviceId`, `state`,
per-side attachment (socket or `nil`), per-side current token nonce and expiry, `createdAt`,
`lastAttachedAt`. It holds **no** SDP, no candidates, no media state.

### 4.2 States

| State | Meaning | Entered by | Left by |
|---|---|---|---|
| `pending` | Created; host not yet acknowledged. | `connect_req` success | first host attach → `open`; 30 s with no host attach → `closed(timeout)` |
| `open` | Both sides attached. The normal state. | both sides attached | either side detaching → `half_open`; `bye` → `closed` |
| `half_open` | Exactly one side attached. The network-flutter state. **The session is alive.** | a socket dropping | the missing side `resume` → `open`; token TTL elapsing → `closed(timeout)` |
| `orphaned` | Neither side attached. Still resumable. | second socket dropping | either side `resume` → `half_open`; token TTL elapsing → `closed(timeout)` |
| `closed` | Terminal. | `bye`, timeout, `refresh_code`, shutdown | — |

A session in `half_open` or `orphaned` survives for as long as the detached side's token is
valid — up to **10 minutes** from its last issue. Because clients `renew` every 5 minutes while
connected, a drop is always followed by ≥ 5 minutes of resumable window. That is deliberately
far longer than the app's own 45-second media grace window (PLAN.md §2.1): the *app* decides
the session is dead long before the *server* does, and the server's slack exists so a
resume attempt is never rejected for a reason the user cannot understand.

```
 connect_ok
     │
     ▼
 ┌─────────┐  host attaches   ┌──────┐  one side drops   ┌───────────┐
 │ pending │─────────────────►│ open │──────────────────►│ half_open │
 └─────────┘                  └──────┘◄──────────────────└───────────┘
     │                            │      resume_ok            │
     │ 30s                        │ bye                       │ other side drops
     ▼                            ▼                           ▼
 ┌────────┐                  ┌────────┐  token TTL     ┌──────────┐
 │ closed │◄─────────────────│ closed │◄───────────────│ orphaned │
 └────────┘                  └────────┘                └──────────┘
                                                            │ resume
                                                            └──► half_open
```

### 4.3 Client algorithm on signaling-socket loss

1. **Do not** tear down the peer connection. Keep rendering the last frame; show
   "Reconnecting…". Media over an already-established WebRTC path is unaffected by the
   signaling socket being down — this is a *control-plane* outage.
2. Reconnect the WebSocket with exponential backoff **0.5 s → 15 s with jitter, indefinitely**.
3. On reconnect: `challenge` → `hello` → `hello_ok`. If `hello_ok.activeSessionId` is present,
   or the client remembers a session, send **`resume`** — never `connect_req`, and **never
   prompt for the access code**.
4. On `resume_ok`: store the rotated token, re-issue any `watch`es, send `input_reset` on the
   `ctrl` channel (§5), and if ICE is not `connected`, start an ICE restart by sending a new
   `sdp{restart:true}` offer. The controller restarts by default; if the host detects
   `disconnected` for 3 s and the controller has not offered, the host may offer.
5. On `resume` → `error{no_session}` or `error{bad_token}`: the session is genuinely gone.
   Tear down the peer connection, clear the stored session, and return the UI to
   "Connect" — this is the **only** path that may ask for the access code again.
6. On `resume` → `error{rate_limited}`: back off `retryAfterSec` and retry; do not prompt.

### 4.4 Rules that fall out of this, stated explicitly

- A client **must** persist `sessionId` + the newest `sessionToken` in memory for the whole
  session and rotate its copy on every `resume_ok`/`renew_ok`. Losing the token means losing
  the resume path.
- A client **must not** send `connect_req` for a session it believes is alive. Doing so is how
  you end up with `busy` against your own orphaned session.
- If a controller does get `busy` and believes the session is its own, the correct recovery is
  `resume`, not retrying `connect_req`.
- The host frees its 1:1 slot only on `closed`. `half_open` and `orphaned` still hold the slot.
- Both sides send `input_reset` on the `ctrl` channel after every resume and after every
  detected disconnect, so no modifier or mouse button is left logically held down.
- Token rotation means an in-flight duplicate `resume` (e.g. the client retried) will fail with
  `bad_token`. Clients must not have two `resume`s in flight.

### 4.5 Note: what "trusted controller" means, and what it does not

A trusted controller is **not** a wire feature. There is no message that skips §2.17 and none is
wanted: an exchange the host could be talked out of running is an exchange an attacker can talk
it out of running. Every controller runs the full SPAKE2 exchange on every session, trusted or
not — it costs one round trip and it is the only thing that proves the code.

What "trusted" removes is the **prompt**, and it lives on the controller:

- **Controller side — a remembered code.** After a successful exchange the controller may store
  the host's access code locally, encrypted at rest (the Keychain on macOS). A later session
  runs §2.17 with the remembered code instead of asking the user. Nothing about this reaches the
  wire: the frames are byte-for-byte what a freshly typed code produces.
- **Host side — an allow-list.** The host records the `controllerPubkey` of every controller that
  has completed an exchange, with a label and first/last-seen times. The list does **not** gate
  §2.17: an unknown key may still attempt the exchange, because a controller with the right code
  is by definition allowed. It exists so the host can *show* who has connected and so Refresh
  Code has something concrete to revoke.

Because the trusted path still runs §2.17 in full, it still derives `sdpMacKey`; there is no
session whose `sdp` goes unMACed.

**Refresh Code** (§2.15) is therefore the whole revocation story, and it is one button: the host
mints a new code, the server bumps the epoch and kills every session and token, and the host
clears its trusted list and its guess counters. Every remembered code on every controller now
fails §2.17 and prompts its user again — which is exactly what revoking a shared secret should
look like.

---

## 5. `ctrl` data channel (reliable, ordered)

Same envelope, same versioning. Peer-to-peer only; the server never sees these.
`sessionId` is **not** repeated — the channel already belongs to exactly one session.

| `type` | Payload | Notes |
|---|---|---|
| `mouse_down` | `{button:int, x:double, y:double}` | `button`: 0 left, 1 right, 2 middle. |
| `mouse_up` | `{button:int, x:double, y:double}` | |
| `mouse_drag` | `{button:int, x:double, y:double}` | Movement with a button held. Reliable on purpose: dropping a drag point mid-gesture visibly breaks window dragging. |
| `click` | `{button:int, x:double, y:double, count:int}` | `count` 1–3. Optional convenience; a host may synthesise from down/up. |
| `key_down` | `{keycode:int, mods:int, chars:string?}` | `keycode` is a **macOS virtual keycode** (`kVK_*`). `mods` is a bitmask: 1 shift, 2 control, 4 option, 8 command, 16 capslock, 32 fn. |
| `key_up` | `{keycode:int, mods:int}` | |
| `scroll` | `{dx:double, dy:double, phase:string}` | Pixel units at the host's resolution, positive `dy` = content moves up (natural). `phase`: `begin`, `changed`, `end`, `momentum`. |
| `clipboard_text` | `{text:string, originId:string, hash:string}` | UTF-8, ≤ 256 KiB after envelope. `originId` = the deviceId that produced it; `hash` = base64 SHA-256 of `text`. A receiver **must** drop a message whose `hash` equals its own last set/received hash — this is the echo-loop guard. Contents are never logged. |
| `gesture` | `{name:string}` | One of `mission_control`, `app_expose`, `show_desktop`, `launchpad`, `spotlight`, `app_switcher`, `screenshot_region`, `force_quit`, `lock_screen`. |
| `input_reset` | `{}` | Receiver releases all held keys, modifiers and mouse buttons. Sent after every resume and every disconnect. Must be idempotent. |
| `display_info` | `{w:int, h:int, scale:double, os:string?}` | Host → controller. Pixel dimensions of the captured display and its backing scale, so the controller can size its window and convert scroll units. Sent on session start and on any display change. `os` is `macos` or `windows`; **absent means `macos`** (every build shipped before the field existed was a Mac). Purely additive under §0 — no version bump. The controller uses it to label the gesture palette in the host's own vocabulary. |
| `cursor_shape` | `{shape:string}` | Host → controller. The host's current system cursor, sent when the ctrl channel opens and then **on change only**. `shape` is one of `arrow`, `ibeam`, `crosshair`, `pointing_hand`, `open_hand`, `closed_hand`, `resize_lr`, `resize_ud`, `resize_diag_nesw`, `resize_diag_nwse`, `not_allowed`, `busy`. A host maps any cursor it cannot name to `arrow`; a controller draws an unknown value as `arrow`. The controller draws the shape locally (the host hides its cursor from capture). Purely additive under §0 — no version bump. |
| `quality` | `{mode:string}` | Controller → host. `auto`, `sharp` (prefer resolution), `smooth` (prefer frame rate). |
| `ping` | `{t:int64}` | Sender's Unix ms. |
| `pong` | `{t:int64}` | Echoes the `ping`'s `t` verbatim; RTT = now − t. |
| `session_close` | `{reason:string}` | Peer-initiated teardown. Reasons as in §2.14. The sender should also send signaling `bye`. |

Unknown `ctrl` types are ignored (forward compatibility).

## 6. `hi` data channel (unreliable, unordered, `maxRetransmits: 0`)

| `type` | Payload | Notes |
|---|---|---|
| `mouse_move` | `{x:double, y:double, seq:int64}` | `seq` strictly increases per sender. The receiver **must** drop any packet whose `seq` is ≤ the highest seen: out-of-order stale positions are the whole reason this channel is unreliable. Never send drags here — see `mouse_drag`. |

Nothing else may be sent on `hi`.

---

## 7. Error codes

| Code | Meaning | Client action |
|---|---|---|
| `bad_request` | Malformed JSON, missing required field, bad type, out-of-range value. | Bug. Log and fix. |
| `unsupported_version` | `v` ≠ 3. Socket is closed. | Prompt to update the app. |
| `unsupported` | Unknown `type` for this surface. | Ignore. |
| `unauthenticated` | Sent an authenticated message while `CHALLENGED`. | Complete `hello` first. |
| `bad_signature` | Signature invalid, key mismatch, or nonce replayed/expired. | Re-challenge and retry once; then treat the identity as broken. |
| `unknown_device` | No such `deviceId`. | Surface "device not found". |
| `bad_code` | *v1 only.* Access code did not verify. A v2 server never sends it. | Prompt again; count locally too. |
| `offline` | Target host has no live authenticated socket. | Show ○ Offline, keep watching presence. |
| `busy` | Host already has an active session (any state but `closed`). | If it might be *your* session, `resume`. Otherwise surface "in use". |
| `rate_limited` | Locked out per §3.3. `retryAfterSec` is set. | Back off exactly that long; do not retry sooner. |
| `self_connect` | `connect_req` targeted the caller's own `deviceId`. | Bug. |
| `no_session` | Session unknown, closed, or this connection is not attached to it. | Terminal for the session; return to Connect. |
| `bad_token` | Session token forged, expired, rotated away, or bound to another device. | Terminal for the session; return to Connect. |
| `peer_offline` | Relay target is detached right now. | Hold; retry after `peer_state{attached:true}`. |
| `displaced` | Another socket authenticated as this `deviceId`. Socket is closed. | Do **not** reconnect in a loop; the other instance won. |
| `forbidden` | Operation not allowed for this role (e.g. `refresh_code` for another device). | Bug. |
| `entitlement` | *v2.* The host's account may not open a session. `reason` is one of `unlinked`, `trial_expired`, `no_balance`, `concurrency`, `suspended` — the same set as API.md §4.3. | Render the reason; re-fetch `GET /v1/entitlement` once. Do not retry until the user acts. |
| `internal` | Server fault. | Retry with backoff. |
| `unavailable` | *v2.* A backend the server depends on (the device registry) is unreachable, so `register`, `hello`, `refresh_code` or `connect_req` cannot be answered safely. `retryAfterSec` is set. The server never falls back to minting or trusting an id on its own. | Back off `retryAfterSec`, then reconnect normally. Not the user's fault; show "temporarily unavailable". |

## 8. Server-side privacy guarantees (normative)

The server **must not** log, persist, or transmit to third parties: plaintext access codes,
access-code verifiers, `pake` payloads, session tokens, SDP bodies, ICE candidates, clipboard
text, keystrokes, mouse coordinates, or any media. Log lines may contain: `deviceId`, `sessionId`, message `type`, error `code`,
byte counts, and timings. Anything else is a bug in the server.
