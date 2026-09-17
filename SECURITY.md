# Security Policy

SkipperDesk is a private, unattended remote-desktop tool. Its threat model puts the
operator (us) outside the trust boundary — see `docs/SECURITY.md` for the public
write-up. We take reports against that model seriously.

## Reporting a vulnerability

Email **security@skipperdesk.app** (placeholder until the domain is live). Include:

- A description of the issue and its impact.
- Steps to reproduce, or a proof of concept.
- The affected component (desktop app, shared Rust core, protocol, or server).
- Whether you believe it is already being exploited.

Do not open a public GitHub issue for a security report. Do not test against
accounts, devices, or sessions you do not own.

PGP is not yet set up; if you need an encrypted channel, say so in your first
email and we will arrange one before you send details.

## Scope

In scope:

- The open-source desktop client (`apps/macos`, `apps/windows` once shipped).
- The shared Rust core (`core/crates/rc-proto`, `rc-session`, `rc-identity`, `rc-ffi`).
- The wire protocol (`protocol/`), including the signaling server's handling of it
  (`server/`).

Out of scope:

- The web app (`skipperdesk.app`) and billing/account backend — not yet public.
- Denial of service against the shared, temporary EC2 relay (`infra/legacy`, frozen).
- Social engineering, physical access, or attacks that require a compromised OS.
- Findings that only reproduce against a self-modified build.

## Our commitment

- We acknowledge a report within **48 hours**.
- We will tell you whether it is accepted, and roughly when a fix is expected, as
  soon as we have triaged it.
- We credit reporters (by name or handle, your choice) in the release notes once a
  fix ships, unless you ask us not to.

## Bounty

There is no paid bug bounty program yet. This may change post-launch; this file
will be updated first if it does.
