#!/usr/bin/env bash
# Runs locally what CI runs, so a push is green the first time.
set -euo pipefail
cd "$(dirname "$0")/.."

CORE=(-p rc-proto -p rc-session -p rc-identity -p rc-ffi)
step() { echo; echo "== $*"; }

step "dependency gate"
./scripts/verify-deps.sh >/dev/null

step "rust format, lint, tests"
cargo fmt --check "${CORE[@]}"
cargo clippy "${CORE[@]}" --all-targets --all-features -- -D warnings
cargo test --workspace --quiet

step "go format, vet, tests"
test -z "$(gofmt -l server protocol)" || { gofmt -l server protocol; exit 1; }
(cd server && go vet ./... && go test ./...)
(cd protocol && go build ./... && go test ./...)
./scripts/smoke-signal.sh >/dev/null

step "macOS core, tests, app, release gate"
./scripts/build-core.sh >/dev/null
(cd apps/macos && swift run rc-tests)
./scripts/test-provision-profile.sh >/dev/null
./scripts/build.sh >/dev/null
./scripts/verify-launch.sh
./scripts/check-isolation.sh

echo
echo "PREFLIGHT PASSED"
