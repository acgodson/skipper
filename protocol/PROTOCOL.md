# RemoteControl wire protocol

Version: **5** (`v: 5` in every envelope)
Status: normative. This document is the single source of truth. `protocol/protocol.go`,
`core/crates/rc-proto` (and the Swift mirror) must match it exactly; if they disagree, this file wins.

Three surfaces are specified:

1. **Signaling** — client ↔ `rc-signal` over WebSocket (WSS in production).
2. **`ctrl` data channel** — reliable, ordered, peer ↔ peer (WebRTC SCTP).
3. **`hi` data channel** — unreliable, unordered (`maxRetransmits: 0`), peer ↔ peer.

The server sees only surface 1. It never sees, parses or stores anything from 2 or 3.

---

## v5 changes (summary)

Version **5** closes what the third security review found in the server's side of the contract
(S1–S6, and the server half of C1). A v5 endpoint rejects a `v: 4` envelope with
`error{unsupported_version}`. Go (`protocol/protocol.go`, `protocol/relay.go`), Rust
(`core/crates/rc-proto`, `relay`) and Swift speak it; `protocol/vectors/vectors.json` pins it.

| # | Change | Why | Where |
|---|---|---|---|
| 1 | **`pake.step` is a JSON integer 1…3.** Anything else — 0, 4, negative, ≥ 2³¹, `1.0`, `1e0`, `"1"`, `null` — is `error{bad_request}` at the server and is refused at decode by every client (Swift: `Int32(exactly:)` plus the range check). The server also relays step 1 and step 3 only from the controller and step 2 only from the host, each once per session and in order (`bad_request` otherwise). | A controller crashed the host with `step: 4294967296` before the guess budget was charged (C1). | §2.17 |
| 2 | **Relayed messages are decoded strictly and re-encoded.** `sdp`, `ice` and `pake` payloads must match their exact schema: exact-case keys, each at most once, no `null`, no unknown key, every field within its limit (§2.12, §2.13, §2.17). The server relays only its own re-encoding (schema order, no whitespace, `id`/`re` dropped); the client's bytes are never forwarded. `ice.candidate` must match the §2.13 grammar (≤ 1024 bytes); `sdp.sdp` is ≤ 64 KiB and begins with `v=0`. Before a session is metered the server relays at most 64 `ice` per side and 4 `sdp` from the controller. Violations are `error{bad_request}` and nothing is relayed. | Peers carried SDP inside `ice`/`pake`, so sessions were never billed (S1); the server matched `SESSIONID` case-insensitively while clients read `sessionId` (S5). | §0, §2.12, §2.13, §2.17 |
| 3 | **TURN only after proof.** `connect_ok` and `session_start` carry STUN only. A new push **`ice_servers {sessionId, iceServers}`** goes to both peers the moment metering starts (the host's first relayed `sdp`), before that `sdp` is relayed. TURN credentials live **10 minutes**; `renew_ok.iceServers` is present, with fresh TURN, only for a metered, live session. Clients drop a session's TURN credentials when it ends. | Any controller that sent `connect_req` to an entitled host got 2 h TURN, without the code, valid long after `bye` (S2). | §2.5, §2.9, §2.11, §2.18 |
| 4 | **Fair `connect_req` limits.** Every attempt is charged to its client address (30/min). The controller's own bucket (6/min, 60/h) is checked up front but charged, together with the target's, only when the attempt is **delivered** as `session_start`; refusals (`unknown_device`, `offline`, `busy`, `entitlement`) charge neither. A controller that has had a metered session with the host before (a durable ledger of pairs, §3.3) spends a per-pair bucket (6/min, 60/h) and is never blocked by the host's bucket. | Five controller keys from one address locked every legitimate controller out of a host, and refusals burned the caller's own budget (S3). | §2.9, §3.3 |
| 5 | **Durable id claims; signatures only when earned.** The record of which key each `deviceId` was given to lives in a separate database file that is never reset with the registry (API.md §6.1). An id is never given to a second key: a certified restore is honoured only for the key the id is claimed by, or for an id nobody claims. The registry signs a certificate only on `register` and on a `hello` whose signature and key already verified — never on a lookup. `hello` checks the signature before it asks the registry. | After a registry reset two keys could hold valid certificates for one id and take it from each other on every reconnect (S4); every lookup cost an ECDSA signature (S6). | §2.2, §2.4, §3.1.1 |

Wire summary for implementers — every field that is new or changed in v5:

| Message | Field | Type | Presence |
|---|---|---|---|
| envelope | `v` | int | `5` |
| `pake` | `step` | JSON integer | 1, 2 or 3; anything else is refused at decode |
| `sdp`, `ice`, `pake` | *all keys* | — | exactly the documented keys, exact case, once each, never `null`; relayed as the server's re-encoding |
| `ice` | `candidate` | string | `""` or a §2.13 candidate line, ≤ 1024 bytes |
| `ice` | `sdpMLineIndex` | int | optional, 0…2³¹−1; an explicit `0` is relayed as `0` |
| `sdp` | `sdp` | string | ≤ 64 KiB, begins with `v=0`, no NUL |
| `connect_ok`, `session_start` | `iceServers` | array of §2.5 | STUN entries only, never `username`/`credential`; omitted when the server has no STUN server |
| `ice_servers` *(new push)* | `sessionId`, `iceServers` | string, array of §2.5 | both always present; the complete list, TURN included (`username` `<expiry>:<sessionId>`, `expiresAt` = now + 10 min) |
| `renew_ok` | `iceServers` | array of §2.5 | present only while the session is metered; absent otherwise |
| `error` | `code` | string | `bad_request` for every relay violation above; `rate_limited` per the v5 §3.3 table |

---

## v4 changes (summary)

Version **4** closes the holes the second security review found in the server's side of the
contract. A v4 endpoint rejects a `v: 3` envelope with `error{unsupported_version}`.

| # | Change | Why | Where |
|---|---|---|---|
| 1 | **Device-ID certificates.** `register_ok` always carries `idCert`, and `hello_ok` carries it for the authenticated binding: the registry's P-256 signature over `"skipperdesk/device-id-cert/v1\|" ‖ deviceId ‖ SHA-256(pubkey DER)`. `register` gains optional `idCert`; `preferredDeviceId` is honoured **only** with an `idCert` that verifies for that id and this key, and then it wins even over another key that holds the id after a reset (that key's record is dropped, its socket gets `error{displaced}` and its sessions `bye{displaced}`). Without a valid certificate a new key always gets a fresh id. | After a backend reset anyone could ask for a victim's free id and receive it (H-A). | §2.2, §2.4, §3.1 |
| 2 | **No existence oracle.** `hello` verifies the signature over the presented key first; an unknown `deviceId` and a `deviceId` bound to another key both answer `unknown_device`. A client re-registers with its certificate on `unknown_device`. | `unknown_device` vs `bad_signature` told a stranger which ids were free. | §2.4, §3.1, §7 |
| 3 | **TURN per session.** `hello_ok.iceServers` is STUN only. `connect_ok`, `session_start` and `renew_ok` carry `iceServers` with TURN credentials whose username is `<expiry>:<sessionId>`, valid **2 h**, issued only for a session the host's entitlement allowed. The TURN secret is read from a file. | Any registered device got 12 h relay credentials; the secret was a command-line flag. | §2.5, §2.9, §2.11 |
| 4 | **Metering starts on proof.** The server reports a session to accounting only when it relays the host's **first `sdp`** for it (the host sends one only after §2.17 verified and, with unattended access off, the owner allowed). Sessions that never get there are not billed and do not count for concurrency. No wire change. | A stranger without the code could open and bill sessions at will (H-B). | §3.4 |
| 5 | **`bye.reason` is a closed set** (§2.14, now including `displaced`). Any other value is `error{bad_request}` and is not relayed. `sessionId` everywhere must be 32 lowercase hex or is refused before it is looked up or logged. Stop/start reports go through one ordered, retrying queue per session, and accounting reconciles open rows against the live session list. | A 70 KiB reason made the stop report fail; unordered reports left rows open (H-C). | §2.10, §2.14, §3.4, §8 |
| 6 | **Rate limits.** `connect_req`: 6/min and 60/h per controller, 30/min and 300/h per target host. `register`: one per connection and 20/h per client address. Unauthenticated sockets are closed 20 s after opening whatever they send. Excess is `error{rate_limited, retryAfterSec}`. | Unlimited `connect_req` let anyone flood a host and burn its guess budget (H-D). | §1.1, §2.2, §3.3 |
| 7 | **Roles are enforced.** `connect_req` is accepted only from a connection that said `hello` as `controller` (else `error{forbidden}`); `session_start` goes only to a connection that said `hello` as `host` (a device connected as controller is `offline` as a target). | A host connected as controller still received `session_start`. | §2.4, §2.9 |
| 8 | **One spelling per key.** `pubkey` must be canonical padded standard base64 of the uncompressed DER SPKI; anything else is `error{bad_request}`. | The same key in another base64 spelling got a fresh per-key budget. | §0, §2.2 |

Wire summary for implementers — every field that is new or changed in v4:

| Message | Field | Type | Presence |
|---|---|---|---|
| `register` | `idCert` | string (base64 DER ECDSA) | optional, omitted when empty |
| `register_ok` | `idCert` | string | always present |
| `hello_ok` | `idCert` | string | present on success (omitted only when empty) |
| `hello_ok` | `iceServers` | array | STUN entries only, never `username`/`credential` |
| `connect_ok`, `session_start` | `iceServers` | array of §2.5 | present when the server has any ICE server; omitted when empty |
| `renew_ok` | `iceServers` | array of §2.5 | as `connect_ok` |
| `bye` | `reason` | string | one of §2.14, `displaced` added |
| `error` | `code` | string | `forbidden` for a role violation; `rate_limited` with `retryAfterSec` per §3.3 |

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
| 6 | *Additive.* `bye` gains the reason **`declined`**: a host with unattended access off asks its owner after the exchange verifies, and says `declined` on Decline or after 30 s. A controller waits up to 45 s for the peer, then `bye{timeout}`. No envelope or message changes. | Unattended access used to be only a sleep setting: with it off, the right code still connected with nobody asked. | §2.14, §2.17 Consent, §4.2 |

The `sdp` signing string itself is unchanged: `"skipperdesk/sdp/v1|" sessionId "|" sdpType "|" fp`
is exactly the domain-separated message for purpose `sdp` with payload
`sessionId "|" sdpType "|" fp`. `protocol/vectors/signing-vectors.json` pins every purpose.

A later, additive v3 change: `register` accepted an optional `preferredDeviceId`, so a device
kept its id after the registry lost its data. *v4* honours it only together with an `idCert`
(§2.2), because honouring it for any free id let a stranger take a victim's id.

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
| IDs | `deviceId`: exactly 9 ASCII digits, e.g. `"481930275"`. Leading zeros are significant; it is a string, never a number. `sessionId`: exactly 32 lowercase hex chars; *v4:* the server refuses any other shape with `bad_request` before it looks the value up or logs it. Message `id`: opaque client string ≤ 64 chars. |
| Keys | `pubkey`: base64 (std, padded) of the **uncompressed DER SPKI** encoding of an ECDSA P-256 public key. *v4:* that spelling is the only one accepted — a key re-encoded any other way (line breaks, missing padding, URL alphabet, compressed point) is `bad_request` — so one key has exactly one string. |
| Signatures | `sig`: base64 of the **ASN.1 DER** ECDSA-P256/SHA-256 signature over a **domain-separated message** (§3.1): `"skipperdesk/" purpose "/v1\|"` followed by the purpose's payload. A device key must never sign anything else, so an implementation must not expose a signer that takes raw bytes. |
| Unknown fields | Receivers **must** ignore unknown object members. Senders **must not** rely on that. *v5 exception:* the payloads of the relayed messages `sdp`, `ice` and `pake` (§2.12, §2.13, §2.17) are decoded strictly — an unknown, repeated, `null` or differently-cased key is `error{bad_request}` at the server, and a client refuses it too. |
| Unknown types | A receiver that does not recognise `type` ignores the message (server replies `error{unsupported}` for client→server only). |
| Max frame | 256 KiB. Larger frames are closed with WebSocket code 1009. |

### 0.1 Envelope

Every message on every surface uses the same envelope:

```json
{
  "v": 5,
  "type": "connect_req",
  "id": "c-17",
  "re": null,
  "ts": 1755600000000,
  "payload": { }
}
```

| Field | Type | Req | Meaning |
|---|---|:--:|---|
| `v` | int | yes | Protocol version. Must be `5`. Server rejects anything else with `error{unsupported_version}` and closes. |
| `type` | string | yes | Message type; see tables below. |
| `id` | string | no | Sender-assigned correlation id. Required if the sender wants to match the reply. Servers echo it in `re`. |
| `re` | string | no | Set on a reply/error to the `id` of the request it answers. Absent on unsolicited pushes. |
| `ts` | int64 | no | Sender clock, Unix ms. Informational only; never trusted for authorisation. |
| `payload` | object | yes | Type-specific body. `{}` when the type has no fields. Never `null`. |

**Every error is the same shape** (`type: "error"`), and carries `re` when it answers a request:

```json
{"v":5,"type":"error","re":"c-17","ts":1755600000001,
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

- Production: `wss://<api base domain>/ws`, TLS 1.2+ with ordinary CA validation. The app is
  configured with one value, the API base domain, and derives this URL from it; there is no
  compiled-in address and no certificate pin.
- Local development only: `ws://127.0.0.1:<port>/ws` when the server runs with `-insecure-http`
  (rc-api passes `/ws` through to rc-signal, so the app still needs only the API base URL).
- `GET /healthz` returns `200 ok` (plain text) and is the only other route on the public
  listener. *v4:* rc-signal's internal surface (`GET /internal/sessions/live`, API.md §6) is
  served on a **separate** listener that is never exposed publicly.
- Sub-protocol: none required. Origin is not checked (native clients).
- Client address: the direct peer, unless the peer is a configured trusted proxy, in which case
  the rightmost `X-Forwarded-For` hop that is not itself trusted. The per-address limits of
  §3.3 key on it.

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
- A connection that has not authenticated **20 s** after it opened is closed (1008,
  `auth_timeout`). *v4:* this is a timer on the server's sweep (it fires within 25 s), not a
  check made when a message arrives, so neither silence nor WebSocket pings nor rejected
  messages keep an unauthenticated socket open.
- After `register_ok` the connection is still `CHALLENGED` and the server issues a **fresh
  `challenge`**; the client then sends `hello` with the newly assigned `deviceId`.
- *v4:* a connection may `register` **once**; a second `register` is `error{bad_request}` and
  the client must reconnect to register again.
- Each nonce is single-use, whatever the outcome of the message that used it. A replayed nonce
  is `error{bad_signature}`. A refusal that happens before the signature is checked
  (`bad_request`) leaves the nonce usable; every other refusal of `register` or `hello` —
  *v5:* including `unavailable` on `hello`, whose signature is now checked before the registry is
  asked — is followed by a fresh `challenge`.
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

First run, and again after `hello` answers `unknown_device` (see "Re-registering" below).
Creates a device record and mints a `deviceId`.

| Field | Type | Req | Notes |
|---|---|:--:|---|
| `pubkey` | string | yes | Canonical base64 DER SPKI, P-256 (§0); any other spelling is `error{bad_request}`. |
| `sig` | string | yes | *v3:* base64 DER ECDSA-SHA256 over `"skipperdesk/register/v1\|"` ‖ the raw 32 `nonce` bytes of the current challenge (§3.1). Proves possession of the private key. |
| `label` | string | no | Human label, e.g. `"Studio Mac"`. The server drops control characters and invalid UTF-8 and keeps at most 64 **bytes**, cut on a character boundary. Not secret. |
| `preferredDeviceId` | string | no | 9 digits. The `deviceId` this key held before the registry lost its record. Omitted when empty; any other shape is `error{bad_request}`. *v4:* ignored unless `idCert` certifies it. |
| `idCert` | string | no | *v4.* The certificate the registry issued for (`preferredDeviceId`, this `pubkey`) in an earlier `register_ok` or `hello_ok`. Opaque to the client. Omitted when empty. |
| `code` | object | yes | *v1 only.* Access-code verifier, see §2.3. **REMOVED in v2.** |

If this `pubkey` is already registered, the server **does not** create a second device: it
returns `register_ok` with the existing `deviceId`. Registration is therefore idempotent per key.

*v4.* The registry decides the `deviceId` in this order:

1. **Known `pubkey`:** its existing `deviceId`, `existing: true`. `preferredDeviceId` is ignored.
2. **New `pubkey` with a valid certificate:** `idCert` verifies under the registry's key for
   exactly (`preferredDeviceId`, `pubkey`), **and** *v5* the durable claims record (API.md
   §6.1) names this `pubkey` for the id or names nobody (then this key's claim is recorded).
   The key gets that id, `existing: false`. Should a device record for the id under another
   key exist anyway, that record is dropped (its device tokens revoked), its live socket is
   sent `error{displaced}` and closed, and every session it holds under that id ends with
   `bye{displaced}`. A certificate for an id claimed by another key falls through to step 3.
3. **Otherwise:** a fresh random id, `existing: false`, whether or not `preferredDeviceId` is
   free. *v5:* a fresh id never repeats an id in the claims record, which outlives any reset of
   the registry, so no id is ever given to two keys and at most one key can ever hold a
   certificate that the registry will honour for it.

So asking for an id reveals nothing about whether it exists, and only the key an id was
certified to can get it back. The certificate outlives the registry's data because the client
keeps it and the registry's signing key is not part of the database: a device keeps its id
across a fresh registry database (the claims record kept) or a move to a new deployment that
uses the same key. If the claims record is lost as well, the first certified key to come back
for an id keeps it, and later certificates for that id fall through to step 3.

**Limits.** One `register` per connection (a second is `bad_request`) and at most **20** per
client address per hour (`rate_limited` with `retryAfterSec`, charged once the signature has
verified). A limited `register` is followed by a fresh `challenge`, so the connection can still
`hello`.

**Re-registering.** A client whose identity says it is registered, but whose `hello` is answered
with `error{unknown_device}`, sends `register` once — on a connection that has not registered
yet — with the **same key**, `preferredDeviceId` set to its current id and `idCert` set to its
stored certificate, then sends `hello` with the id `register_ok` returned. If that id differs
(the client had no valid certificate), the client adopts it and records the change in its log;
it does not interrupt the user for it. It never generates a new key for this. If `hello` still
fails, the connection attempt ends and the client reconnects with its normal backoff (§4.3); it
does not retry in a tight loop.

Reply: **`register_ok`**

| Field | Type | Req | Notes |
|---|---|:--:|---|
| `deviceId` | string | yes | 9 digits. Permanent. |
| `existing` | bool | yes | `true` if the key was already registered. |
| `idCert` | string | yes | *v4.* base64 DER ECDSA-P256/SHA-256 signature by the **registry's** key over `"skipperdesk/device-id-cert/v1\|"` ‖ `deviceId` ‖ SHA-256(DER SPKI of `pubkey`) (§3.1). The client stores it (macOS: Keychain account `device-id-cert`) and replaces its copy whenever a newer one arrives; it never parses or verifies it. |

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
| `pubkey` | string | yes | base64 DER SPKI. The signature is checked against this key first; then it must byte-equal the stored key for `deviceId`. *v4:* a mismatch is `error{unknown_device}`, exactly like an id that does not exist. *v5:* the server asks the registry only after the signature verified, and the registry certifies (signs) the binding only when `pubkey` owns `deviceId`. |
| `sig` | string | yes | *v3:* base64 DER ECDSA-SHA256 over `"skipperdesk/hello/v1\|"` ‖ the raw 32 bytes of the current challenge nonce (§3.1). A `register`, undomained or otherwise invalid signature is `error{bad_signature}`, whatever `deviceId` says. |
| `role` | string | yes | `"host"` or `"controller"`: this connection's mode. *v4, enforced:* only a `controller` connection may send `connect_req` (§2.9), and only a `host` connection receives `session_start`. A device may reconnect with the other role. |

The answers therefore depend only on what the caller can prove: a caller that cannot sign for
`pubkey` always gets `bad_signature`, and one that can always gets `unknown_device` unless
`pubkey` really owns `deviceId`. Neither reveals whether `deviceId` exists.

Reply: **`hello_ok`**

| Field | Type | Req | Notes |
|---|---|:--:|---|
| `deviceId` | string | yes | Echoed. |
| `serverTime` | int64 | yes | Unix ms; clients may use it to detect clock skew. |
| `iceServers` | array | yes | See §2.5. *v4:* STUN entries only, never credentials. May be empty. |
| `heartbeatSec` | int | yes | How often the client must send `heartbeat`. Currently **15**. |
| `offlineAfterSec` | int | yes | Silence after which the server marks the device offline. Currently **40**. |
| `sessionTokenTtlSec` | int | yes | Session-token lifetime. Currently **600**. |
| `activeSessionId` | string | no | Present iff a live session for this device already exists (the client dropped and came back). The client **must** attempt `resume` (§4) rather than `connect_req`. |
| `idCert` | string | no | *v4.* The registry's certificate for this authenticated (`deviceId`, `pubkey`), as in `register_ok`. Present whenever the registry issued one; a client stores it, so a device registered before v4 obtains a certificate without re-registering. |

### 2.5 `iceServers` entries

| Field | Type | Req | Notes |
|---|---|:--:|---|
| `urls` | array of string | yes | e.g. `["stun:stun.l.google.com:19302"]`, `["turn:1.2.3.4:3478?transport=udp"]`. |
| `username` | string | no | TURN only. *v4:* `"<unixExpirySeconds>:<sessionId>"` — the credential names the one session it was issued for. |
| `credential` | string | no | TURN only. base64 of `HMAC-SHA1(username, turnSecret)` — coturn `use-auth-secret` REST form. |
| `expiresAt` | int64 | no | TURN only, Unix ms. *v5:* TTL is **10 minutes** (v4: 2 h). |

STUN entries come first, TURN last. *v5.* TURN credentials are minted **per metered session**
only: never in `hello_ok`, `connect_ok` or `session_start` (STUN only), but in the
`ice_servers` push (§2.18) when the host's first `sdp` starts metering (§3.4), and in
`renew_ok` while the session stays metered. Each such list is the complete list for that
session and replaces the one the peer connection was using. A client that needs a new ICE
gathering pass after the credentials expire uses the list from its latest `renew_ok`; `renew`
every 5 minutes keeps it fresh. A client drops a session's TURN credentials, and any
relay-only setting derived from them, when the session ends. The server cannot revoke a
credential it issued, which is why it lives only 10 minutes. The TURN secret is read by the
server from a file, never from its command line.

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

**Authorisation.** A v5 server checks, in this order:

1. The sending connection said `hello` as `controller`. Otherwise: `error{forbidden}`.
2. The payload is well formed and does not target the caller. Otherwise: `bad_request` /
   `self_connect`.
3. The §3.3 per-address bucket allows another attempt, and is charged. Otherwise:
   `error{rate_limited}` with `retryAfterSec`.
4. The controller's own §3.3 buckets have room (checked, **not** charged). Otherwise:
   `error{rate_limited}`.
5. The target exists and is connected **as a host**. Otherwise: `unknown_device` / `offline` (a
   device connected as `controller` is `offline` as a target and never receives
   `session_start`).
6. The host has no session in any state but `closed`. Otherwise: `error{busy}`.
7. The **host's** entitlement allows a session — `status` is `trial` or `active` and the account's
   `maxActivePairs` is not already in use (API.md §4). Otherwise:
   `error{entitlement}` with a `reason` from §7.
8. *v5.* The attempt is about to be delivered, so it is charged: to the controller's buckets and,
   if this controller has had a metered session with this host before, to the pair's buckets,
   otherwise to the host's. If any of them is empty: `error{rate_limited}`, and nothing is
   charged. A refusal at steps 5–7 charges neither the controller nor the host.

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
| `iceServers` | array | no | *v5:* STUN only (§2.5); TURN for this session arrives in `ice_servers` (§2.18) once it is metered. Omitted when the server has no STUN server. |

Errors, v1: `bad_code`, `offline`, `busy`, `rate_limited`, `unknown_device`, `self_connect`.
Errors, v4: `forbidden`, `entitlement`, `offline`, `busy`, `rate_limited`, `unknown_device`, `self_connect`, `unavailable`.

Opening a session does not start billing; §3.4 says when it does.

Simultaneously the host receives a push **`session_start`** with the same fields (the same
STUN-only `iceServers`) plus its own `sessionToken` (each side gets a *different* token bound to its own
deviceId) and one field of its own:

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
| `sessionId` | string | yes | 32 lowercase hex; any other shape is `bad_request`. |
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
Reply **`renew_ok`**: `{"sessionId","sessionToken","expiresAt","ttlSec","iceServers"}` — token
rotated, same rules and errors as `resume`, but the connection must already be attached to the
session. *v5:* `iceServers` is present only while the session is metered (§3.4), and is then a
fresh session list (§2.5) with new 10-minute TURN credentials that the client uses for any later
ICE restart; for a session that is not metered it is absent and the client keeps its list.

### 2.12 `sdp` — client ↔ client, relayed

| Field | Type | Req | Notes |
|---|---|:--:|---|
| `sessionId` | string | yes | 32 lowercase hex (else `bad_request`), and a session this connection is attached to (else `error{no_session}`). |
| `sdpType` | string | yes | `"offer"`, `"answer"`, `"pranswer"` or `"rollback"`. |
| `sdp` | string | yes | The SDP body. *v5:* at most 64 KiB, begins with `v=0`, no NUL byte. |
| `restart` | bool | no | `true` marks an ICE-restart renegotiation. Advisory for the peer. |
| `fp` | string | yes | *v2.* Every `a=fingerprint` value in `sdp`, de-duplicated, sorted, joined with `\n`. The value is the whole attribute value, e.g. `sha-256 7B:8C:…`. *v5:* ≤ 1024 bytes of letters, digits, `:`, `-`, space and `\n`. |
| `pubkey` | string | yes | *v2.* The **sender's** device key, base64 DER SPKI (§0). *v5:* ≤ 256 base64 characters. |
| `sig` | string | yes | *v2.* base64 DER ECDSA-SHA256 over the UTF-8 bytes of `"skipperdesk/sdp/v1|" sessionId "|" sdpType "|" fp` — the §3.1 message for purpose `sdp`. *v5:* ≤ 256 base64 characters. |
| `mac` | string | yes | *v3.* base64 HMAC-SHA256 under `sdpMacKey` (§2.17) over exactly the bytes `sig` signs. *v5:* ≤ 128 base64 characters. |

*v5.* The server decodes the payload into exactly these keys (exact case, each once, none
`null`, no other key), checks every limit above, and relays **its own re-encoding** of the
decoded message — keys in the order of this table, empty optional fields omitted, no `id` or
`re` — never the bytes the client sent. Anything else is `error{bad_request}` and nothing is
relayed. Before the session is metered it relays at most 4 `sdp` from the controller.

The server **routes and forgets**: it validates the payload, `sessionId` and attachment, stores
nothing, logs no part of `sdp`. If the peer is detached, the server replies
`error{peer_offline}`; SDP is **not** queued (a stale offer is worse than none).
The server relays `fp`, `pubkey`, `sig` and `mac` **with their values unchanged and never validates `sig` or `mac`**. It cannot —
it holds neither device key — and it must not need to: the whole point of the signature is that
it is checked by the peer, against a key the server did not choose. The only thing the server
takes from an `sdp` is the fact that the **host** sent one: the first such relay per session
starts metering (§3.4).

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
   implementation passes it across language boundaries as (pointer, length). Then remove every
   `a=candidate` and `a=end-of-candidates` line from the body it will install: candidates only
   ever arrive through `ice`, so none can be applied before the post-install check below;
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

And **after** `setRemoteDescription`, before applying any remote `ice` candidate, it
re-extracts the fingerprints from the description the WebRTC stack reports as installed
(`remoteDescription.sdp`) and requires them to equal `fp` exactly. That closes any gap between
the verifier's SDP parser and the WebRTC stack's, and because step 1 stripped inline candidates,
"before any remote candidate" is literally true.

Any failure is terminal for the session: `bye{reason:"peer_auth_failed"}` (§2.14), tear the peer
connection down, and tell the user the other device could not be verified. Never fall back to an
unverified description.

`sessionId` in the signed string binds the signature to one session, so a captured offer cannot
be replayed into another, and `sdpType` stops an offer being replayed as an answer. An ICE
restart is an ordinary re-offer: it is signed again, over its own fingerprints.

### 2.13 `ice` — client ↔ client, relayed

| Field | Type | Req | Notes |
|---|---|:--:|---|
| `sessionId` | string | yes | 32 lowercase hex. |
| `candidate` | string | yes | *v5:* `""` (end-of-candidates) or a candidate line in the grammar below. |
| `sdpMid` | string | no | *v5:* ≤ 32 bytes of letters, digits and `_ . + / -`. |
| `sdpMLineIndex` | int | no | *v5:* a JSON integer 0…2³¹−1. An explicit `0` is relayed as `0`. |

*v5.* A candidate line is, with single spaces between fields and at most 1024 bytes in all:

```
"candidate:" foundation component transport priority address port "typ" type *(name value)
foundation = 1*32 (ALPHA / DIGIT / "+" / "/")
component  = 1*3 DIGIT, value 1..256
transport  = "udp" / "tcp"                                  ; ASCII case-insensitive
priority   = 1*10 DIGIT, value 0..4294967295
address    = an IPv4 or IPv6 literal (no zone), or an mDNS name <8-4-4-4-12 hex>.local
port       = 1*5 DIGIT, value 0..65535
type       = "host" / "srflx" / "prflx" / "relay"
name       = 1*32 (lower-case ALPHA / DIGIT / "-")           ; at most 16 name value pairs
value      = 1*256 (ALPHA / DIGIT / "+" / "/" / "=" / "." / ":" / "_" / "-")
```

Same strict decoding and re-encoding as `sdp`; before the session is metered the server relays at
most 64 `ice` from each side. Trickle ICE is expected; candidates arriving while the
peer is detached are dropped with `error{peer_offline}` and re-gathered after resume. A receiver
applies a candidate only when `sessionId` is its current session and only after the §2.12
checks passed for that session's remote description; `sdpMLineIndex` outside `0…2³¹−1` is
dropped.

### 2.14 `bye` — client ↔ client, relayed, and terminal

| Field | Type | Req | Notes |
|---|---|:--:|---|
| `sessionId` | string | yes | 32 lowercase hex; any other shape is `bad_request`. |
| `reason` | string | yes | *v4, a closed set:* exactly one of `user_ended`, `host_ended`, `timeout`, `failed`, `code_refreshed`, `replaced`, `shutdown`, `error`, `peer_auth_failed`, `auth_failed`, `declined`, `displaced`; *v5, additive:* `no_balance` (§2.14.2). Any other value — including the empty string — is answered `error{bad_request}`; the session is left as it was and nothing is relayed. `protocol/vectors/vectors.json` lists the set (`byeReasons`) and values that must be refused (`invalidByeReasons`). |
| `relayUsed` | bool | no | *v5, additive.* The **host's** claim that its own media left through a TURN relay. Measurement only, never billed (§2.14.1). |
| `bytesRelayed` | int64 | no | *v5, additive.* Bytes the host's selected candidate pair carried, sent plus received. Meaningful only with `relayUsed: true`. Measurement only, never billed (§2.14.1). |

#### 2.14.1 The two relay fields are a measurement, not a price

`bye` is **not** in §0's strict-decode set — that set is exactly `sdp`, `ice` and `pake`
(v5 change 2), which the server re-encodes from its own schema. `bye` is decoded
permissively, so these two fields are additive: a v5 peer that never sends them is
unchanged on the wire, and every `bye` vector that existed before them still encodes to
the same bytes.

Three rules make the trust boundary explicit, and all three are enforced in code rather
than documented and hoped for:

1. **Only the host's own `bye` is read.** The host is the party whose account would pay,
   so the only self-report accepted is the one that costs its author. The same fields on a
   controller's `bye` are discarded without comment: a controller must not be able to
   write a number into a host's record.
2. **Nothing prices it.** `server/internal/policy.Charge` takes a duration and the
   account's carry. It has no parameter that could carry a relay figure, so a future
   change cannot start pricing this number by accident — it would have to change the
   signature, which is the point.
3. **It is a claim, not evidence.** A host that under-reports under-pays nothing, because
   nothing is charged for it; a host that over-reports only distorts our own cost model.
   coturn's own `usage:` accounting is the server-side truth (`docs/PHASE5.md` §8.2), and
   no relay price may rest on this field before the two agree.

`API.md` §5.1 and §5.4 say the same about the column these fields land in.

#### 2.14.2 `no_balance` — *v5, additive*

`no_balance` means **the host's account has no credit left**, and nothing else. Like `displaced`
it is sent only by the server, on its own initiative, to both peers; no client ever sends it.

It exists because the alternative was untrue to both parties at once. The money path —
`meter` when a charge clamps, and the reconciliation sweep when it finds a live session with
nothing behind it — closed the session with `host_ended`, the same reason as an unlink. So the
controller was told the host hung up, and the host was told it had ended the session itself,
at the one moment the product has to ask for money (`docs/AUDIT.md` finding 3). A reason the
server already knows and neither peer can otherwise discover is exactly what the field is for.

**A client older than this reason behaves correctly without knowing it.** `bye` is not in §0's
strict-decode set, so the frame decodes as it always did; the reason is a string, the set is
validated only on the way *in* from a client, and both peers already treat any `bye` for their
current session as terminal. An older client therefore ends the session and shows whatever it
shows for a reason it does not recognise — a generic ending, which is what it would have shown
for `host_ended` anyway. Nothing regresses; it simply does not get the better sentence.

Every `bye` vector that existed before this reason encodes to the same bytes: `byeReasons` gains
one entry at the end and `bye_no_balance` is a new case.

`displaced` is *v4* and sent only by the server: the host's `deviceId` was restored to the key
its certificate names (§2.2), so a session held under another key for that id ended.

`declined` means the §2.17 exchange **succeeded** — the controller knows the code — but the
host's owner did not let it in: they clicked Decline, did not answer within 30 s, or the host
declined on its own because this controller was declined twice in the last 10 minutes
(§2.17 Consent). It is sent only by a host with unattended access off, only after step 3
verified, and always before the **host** has started its peer connection (the controller has
already started its side and sent its offer, see Consent 3). It is **not** a guess
failure: the host does not charge the guess policy for it. A controller that receives it
shows "The other Mac declined the connection.", keeps any remembered code (the code was
right), and does not retry without the user.

A controller whose peer connection has not come up **45 s** after its exchange completed
ends the session with `bye{timeout}`. The 45 s is deliberately longer than the host's 30 s
prompt, so an owner who clicks Allow late still gets a working session.

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

`host_ended` is also pushed by the server on its own initiative when the host device is
unlinked from its account — the app's **sign out** (API.md §3.6) — because the owner of that Mac
ended the session by signing it out. The controller is refused `entitlement{unlinked}` if it
tries again.

On a `bye` with a defined reason the server closes the session **immediately and permanently**:
both tokens die, the host's 1:1 slot frees, and the peer (if attached) receives the same `bye`. A later `resume` for
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
| `ice_servers` | S→C push | — *(v5)* |
| `error` | S→C | — |

### 2.17 `pake` — client ↔ client, relayed — *v2*

One message of the peer-to-peer SPAKE2 exchange that proves the access code. The server treats it
exactly as it treats `sdp` and `ice`: it decodes it strictly, checks `sessionId` and attachment,
relays its own re-encoding, and parses, stores and logs **nothing** of the opaque `payload`.

| Field | Type | Req | Notes |
|---|---|:--:|---|
| `sessionId` | string | yes | Must be a session this connection is attached to, else `error{no_session}`. |
| `step` | int | yes | 1-based index of this message within the exchange. *v5:* a JSON integer 1, 2 or 3 — anything else (0, 4, negative, ≥ 2³¹, `1.0`, `1e0`, a string, `null`) is `error{bad_request}` at the server and is refused **at decode** by a client (Swift: `Int32(exactly:)` and the range check), before any other handling. A receiver that gets a `step` it did not expect abandons the exchange. |
| `payload` | string | yes | base64 (std, padded) of the opaque PAKE message: non-empty, length a multiple of 4, at most two trailing `=`, ≤ 4096 characters. |

*v5.* The server relays steps 1 and 3 only from the controller and step 2 only from the host,
each at most once per session and only after the step before it; any other `pake` is
`error{bad_request}` and is not relayed.

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
The server cannot do this for it. It does see the `bye` reason that ends an exchange
(`auth_failed` usually means a wrong code), so an operator can tell a failed guess from a clean
hang-up; but it cannot verify that reason, a guesser can end the exchange without sending it,
and the server learns nothing about the code itself either way. Only the host knows a guess was
spent. The server's own `connect_req` limits (§3.3) bound how fast anyone can start exchanges
against one host.

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

#### Consent

The access code proves a controller *may* connect. Whether it connects *now* is the host
owner's call, and the host's **Unattended access** setting says which rule applies:

- **On** — the code is the permission. The peer connection starts as soon as step 3
  verifies, as described above.
- **Off** (the default on a new install) — the host asks its owner first. Nothing on the
  wire changes; the host simply holds its side:
  1. Only **after** step 3 verifies does the host ask. A controller that has not proved the
     code never causes a prompt: a prompt for an unauthenticated peer would be a nuisance
     and a phishing vector.
  2. The host shows "Allow <controller> to control this Mac?" with Allow and Decline and a
     30-second countdown. The 10-second exchange timer has already stopped; nothing else
     times out while the owner decides.
  3. The host has no peer connection for this session and applies no remote `sdp` or `ice`
     while it waits. A `session_start` tears down any peer connection left from an earlier
     session before the new exchange starts, and an ICE or connection event from a torn-down
     peer never changes the state of the new one; so nothing but Allow can leave
     `awaitingConsent` towards `live`. The controller has already started its own side and sent
     its offer; the host keeps the latest offer and up to 64 candidates for this `sessionId`,
     and applies them — after the usual §2.12 checks — only on Allow.
  4. **Allow** starts the host's peer connection. **Decline**, or no answer within 30 s, is
     `bye{declined}` (§2.14). A `bye` from either side, a new `session_start` or a lost
     session withdraws the prompt. *v5:* a prompt is named by a random id the host's core
     makes for it — never by the server-chosen `sessionId` — and an answer counts only for the
     prompt it names that is still open. Allow is refused, not queued, until the prompt has
     been on screen for **1.5 s**; the owner has to click again. A prompt that replaced an open
     one says so ("A different request replaced the previous one."), and every prompt shows the
     controller's key fingerprint, which that Mac shows as its own.
  5. The controller cannot tell a slow network from an owner deciding. From 2 s after its
     exchange completes until the peer connection is up it says "Waiting for the other Mac
     to accept…", and it gives up after 45 s with `bye{timeout}`.

Prompts are rate-limited so an owner is never spammed: at most one prompt is open at a time
(a new `session_start` replaces it), and a prompt counts against two budgets the moment it
opens:

- **per controller key** — a key with **two** prompts within 10 minutes that were not allowed
  (declined, unanswered, replaced, or ended by a hang-up or a crash) is declined without a
  prompt until the older of those two is 10 minutes old. Allow clears that key's record.
- **host-wide** — at most **3** prompts in any 10 minutes, across every controller; further
  attempts are declined without a prompt until the oldest is 10 minutes old. Allow gives back
  its own prompt only.

*v5:* a hang-up during the prompt is counted like a decline — only Allow gives a prompt back —
so a controller cannot prompt repeatedly for free by hanging up first. The policy is pure, in
`core/crates/rc-identity` (`consent`, stored in the `GuessLedger` next to the guess counters),
keyed like the guess policy on the controller's pubkey; the state it gates (`awaitingConsent`)
is part of the §4 session state machine in `core/crates/rc-session`.

### 2.18 `ice_servers` — server → client (push, no `re`) — *v5*

Sent to **both** attached peers of a session at the moment it becomes metered (§3.4: the host's
first relayed `sdp`), before that `sdp` is relayed to the controller. Sent once per session.

| Field | Type | Req | Notes |
|---|---|:--:|---|
| `sessionId` | string | yes | The session the list belongs to. A client ignores a push for any other session. |
| `iceServers` | array | yes | The session's complete §2.5 list: STUN, then TURN with `username` `<expiry>:<sessionId>` and `expiresAt` 10 minutes ahead. It replaces the list the peer connection was using (for example with `setConfiguration`); later lists come in `renew_ok`. |

A client keeps these credentials only for the session's lifetime and drops them when it ends.

---

## 3. Authorisation, rate limiting and session tokens

### 3.1 Device authentication
1. Server sends a 32-byte random `nonce`.
2. Client decodes it, refuses anything that is not exactly 32 bytes, signs the
   **domain-separated message** below with ECDSA-P256/SHA-256 and sends the DER signature,
   base64-encoded.
3. *v4.* The server spends the nonce and verifies the signature over the same message with the
   **presented** `pubkey`; a failure is `error{bad_signature}`. Only then does it compare the
   presented key with the stored SPKI for `deviceId`: a missing device and a different key are
   the same `error{unknown_device}` (§2.4).

*v3.* A device key signs **only** `"skipperdesk/" purpose "/v1|"` followed by the purpose's
payload, built by one function in the shared core (`rc_identity::signing_message`); the
platform signing API must accept a purpose and a payload, never raw bytes.

| Purpose | Payload | Used by |
|---|---|---|
| `hello` | the 32 raw nonce bytes | §2.4 |
| `register` | the 32 raw nonce bytes | §2.2 |
| `api-challenge` | the 32 raw nonce bytes | `API.md` device challenge |
| `sdp` | `sessionId "\|" sdpType "\|" fp` (UTF-8) | §2.12 |

A nonce purpose with a payload of any length but 32 is refused by every implementation, and
the server never verifies an `sdp`-purpose signature. No prefix is a prefix of another, so a
signature for one purpose never verifies for another.

#### 3.1.1 Device-ID certificates — *v4*

The registry holds its own P-256 key (never a device key; a KMS asymmetric key whose private
half never leaves KMS in a deployment, a PEM file locally — the choice changes no byte here).
A certificate is that key's ASN.1 DER ECDSA-SHA256 signature, base64, over

```
"skipperdesk/device-id-cert/v1|" ‖ deviceId (9 ASCII digits) ‖ SHA-256(DER SPKI of the device key) (32 bytes)
```

`device-id-cert` is deliberately not a device signing purpose: no device key ever signs it, and
its prefix overlaps none of the purposes above. The registry issues a certificate in every
`register_ok` and `hello_ok` and honours `register.preferredDeviceId` only with one (§2.2).
*v5:* those are the only two signing moments — for `hello`, only after the device's own
signature verified and its key matched — so looking a device up never costs a signature.
A server started without a key refuses to run outside local `-insecure-http` mode; in
local mode it makes a throwaway key whose certificates die with the process.

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

### 3.3 Signaling rate limits — *v5*

The server cannot see a code attempt, so the host rate-limits the §2.17 exchange itself
(§2.17 Guessing). What the server limits is how fast anyone can start work for a host:

| What | Limit | Keyed on | Charged |
|---|---|---|---|
| `connect_req` | **30** per minute | the client address (§1) | every attempt that passes the role and shape checks (§2.9 step 3) |
| `connect_req` | **6** per minute and **60** per hour | the sending controller's `deviceId` | checked at §2.9 step 4; charged only when the attempt is delivered as `session_start` (§2.9 step 8) |
| `connect_req` | **30** per minute and **300** per hour | the target `deviceId` | only on delivery, and only for a controller that is not a known pair |
| `connect_req` | **6** per minute and **60** per hour | the (host, controller) pair | only on delivery, instead of the host's bucket, for a controller that has had a metered session with this host |
| `register` | **1** per connection | the connection | — (a second one is `bad_request`) |
| `register` | **20** per hour | the client address (§1) | each `register` whose signature verified |
| unauthenticated connection | closed **20 s** after opening | the connection | — |

*v5 — known pairs.* A controller has had a metered session with a host once the host sent it an
`sdp` in some session (§3.4), which the host does only after the code was proved and, with
unattended access off, the owner allowed it. The record is durable and survives a restart of
rc-signal: in a deployment it is rc-api's session table (API.md §6, `GET /internal/pairs/…`); in
rc-signal's stand-alone mode it is a table in rc-signal's own database. rc-signal keeps a bounded
in-memory copy and asks the durable record on a miss; if the record cannot be reached the attempt
is treated as a stranger's. A stranger can therefore still find a host's bucket spent by others,
but never a controller the owner has let in before.

The limits are token buckets (a full bucket of the stated size, refilling evenly over the
window); an attempt is charged against all of its buckets only if every one of them has room.
Exceeding one answers `error{rate_limited}` with `retryAfterSec`, the whole seconds until every
bucket involved has room again. A client backs off exactly that long. Idle buckets are
forgotten once they have refilled, so the limiter's memory is bounded by recent activity.
`TODO:` in Phase 5 the buckets move to a store shared by every server instance.

*v1 only, kept for the record — the access-code limiter this replaced:*

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

### 3.4 Metering — *v4, v5*

Billing (API.md §5, §6.3) follows **proof**, not grant:

1. `connect_ok` opens a signaling session and reports nothing to accounting.
2. The first time the server relays an `sdp` **sent by the host** for a session, it records the
   session as metered, with that moment as its start, queues a start report, records the
   (host, controller) pair as known (§3.3), and pushes `ice_servers` with the session's TURN
   credentials to both peers (§2.18). The host sends `sdp` only after §2.17 verified the code
   and, with unattended access off, after its owner allowed the connection. A controller's
   `sdp`, a `pake`, an `ice` or anything else never starts metering, and *v5* none of them can
   carry a description: §2.12, §2.13 and §2.17 admit only their exact schemas, and an unmetered
   session relays a bounded amount (4 controller `sdp`, 64 `ice` per side, 3 `pake` in all).
3. Ending a metered session queues a stop report with the end time and the §2.14 reason. An
   unmetered session is never reported, is never billed, and never counts against the account's
   `maxActivePairs`.
4. Reports for one session travel through **one ordered lane**: the stop is sent only after the
   start was delivered or given up on, never concurrently, with bounded retries and a bounded
   queue. **A start report that does not land ends the session with `bye{error}`, whatever stopped
   it landing** — an entitlement refusal, a permanent rejection, an exhausted retry budget, or a
   queue too full to accept it. A session accounting never recorded has no billing row, so the
   session is un-metered and closed rather than left relaying; its stop report is not sent, because
   there is nothing to settle. This couples a new session to accounting's availability on purpose:
   the alternative was a session that ran its whole life for free (review5 H7).
5. A **stop** report that is finally lost leaves an open row. Accounting's periodic sweep asks
   signaling (on its internal listener, API.md §6) which metered sessions it still holds, and
   closes every open row signaling no longer knows, billed up to the last time the sweep saw it
   alive. A lost *start* leaves no row for that sweep to find, which is why item 4 does not rely
   on it.

Sessions bill by their whole seconds at an hourly rate, with the sub-cent remainder carried on the
account; a session too short to be worth a cent charges nothing but still owes its time (API.md §5.2).

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

The **client** machine (`core/crates/rc-session`, pinned by
`protocol/vectors/session-scenarios.json`) has its own phases: `idle`, `connecting`,
`awaitingConsent`, `live`, `reconnecting`, `closed(reason)`. A session grant never starts the
peer connection by itself; the verified §2.17 exchange does (`pakeSucceeded`). A host with
unattended access off goes `connecting → awaitingConsent` there and emits
`promptForConsent{expiresAtMs}`; the owner's answer or the 30 s `tick` leaves it with
`dismissConsentPrompt{outcome}` (`allowed`, `declined`, `timedOut`, `cancelled`) and either
`startPeerConnection` or `bye{declined}`. A signaling flap does not move a host out of
`awaitingConsent`; the prompt and its deadline survive a resume. Only the owner's answer, its
deadline or the session ending leaves `awaitingConsent`: an ICE or connection-state event never
does, and while in it the host applies no remote `sdp` or `ice` (§2.17 Consent 3).

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
| `bad_request` | Malformed JSON, missing required field, bad type, out-of-range value, a non-canonical `pubkey`, a `sessionId` that is not 32 lowercase hex, a `bye` reason outside §2.14, a second `register` on one connection. *v5:* a relayed payload outside its exact schema or limits (§2.12, §2.13, §2.17), a `pake` step out of turn, or relay beyond the unmetered budget (§3.4). The message names the rule, at most 160 bytes. | Bug. Log and fix (for the second `register`: reconnect first). |
| `unsupported_version` | `v` ≠ 5. Socket is closed. | Prompt to update the app. |
| `unsupported` | Unknown `type` for this surface. | Ignore. |
| `unauthenticated` | Sent an authenticated message while `CHALLENGED`. | Complete `hello` first. |
| `bad_signature` | The signature does not verify under the presented `pubkey`, or the nonce was replayed/expired. | Re-challenge and retry once; then treat the identity as broken. |
| `unknown_device` | *v4:* no such `deviceId`, **or** `deviceId` is bound to a different key — the two are indistinguishable by design. | On `hello`: re-register once with `preferredDeviceId` and the stored `idCert` (§2.2), then `hello` again; if that fails, reconnect with backoff. Elsewhere: surface "device not found". |
| `bad_code` | *v1 only.* Access code did not verify. A v2 server never sends it. | Prompt again; count locally too. |
| `offline` | Target host has no live authenticated socket. | Show ○ Offline, keep watching presence. |
| `busy` | Host already has an active session (any state but `closed`). | If it might be *your* session, `resume`. Otherwise surface "in use". |
| `rate_limited` | A §3.3 limit refused the request. `retryAfterSec` is set. | Back off exactly that long; do not retry sooner. |
| `self_connect` | `connect_req` targeted the caller's own `deviceId`. | Bug. |
| `no_session` | Session unknown, closed, or this connection is not attached to it. | Terminal for the session; return to Connect. |
| `bad_token` | Session token forged, expired, rotated away, or bound to another device. | Terminal for the session; return to Connect. |
| `peer_offline` | Relay target is detached right now. | Hold; retry after `peer_state{attached:true}`. |
| `displaced` | Another socket authenticated as this `deviceId`, or *v4* the id was restored to the key its certificate names (§2.2). Socket is closed. | Do **not** reconnect in a loop; the other instance won. |
| `forbidden` | Operation not allowed for this connection's role: *v4* `connect_req` from a connection that said `hello` as `host`. | Bug. Reconnect with the right role. |
| `entitlement` | *v2.* The host's account may not open a session. `reason` is one of `unlinked`, `trial_expired`, `no_balance`, `concurrency`, `suspended` — the same set as API.md §4.3. | Render the reason; re-fetch `GET /v1/entitlement` once. Do not retry until the user acts. |
| `internal` | Server fault. | Retry with backoff. |
| `unavailable` | *v2.* A backend the server depends on (the device registry) is unreachable, so `register`, `hello`, `refresh_code` or `connect_req` cannot be answered safely. `retryAfterSec` is set. The server never falls back to minting or trusting an id on its own. | Back off `retryAfterSec`, then reconnect normally. Not the user's fault; show "temporarily unavailable". |

## 8. Server-side privacy guarantees (normative)

The server **must not** log, persist, or transmit to third parties: plaintext access codes,
access-code verifiers, `pake` payloads, session tokens, TURN secrets or credentials, device-id
certificates, SDP bodies, ICE candidates, clipboard text, keystrokes, mouse coordinates, or any
media. Log lines may contain: `deviceId`, `sessionId`, message `type`, error `code`, a §2.14
`bye` reason, byte counts, and timings. Anything else is a bug in the server.

*v4.* The server never logs a free-form client string: a `sessionId` is checked against its
32-hex shape and a `bye` reason against the §2.14 set **before** either can reach a log line or
a report, and a label is trimmed (§2.2) before it is stored.

*v5.* The explanation in a relay `bad_request` goes only to the sender and is never logged.
