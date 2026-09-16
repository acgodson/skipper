#!/usr/bin/env bash
#
# Builds the shared Rust core as a static library for the Mac app to link.
#
# The app's Package.swift links `librc_ffi.a` out of core/target/release, so
# this script must run before `swift build`. scripts/build.sh calls it first.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="aarch64-apple-darwin"
LIB="librc_ffi.a"
STAGED_DIR="${REPO_ROOT}/core/target/release"

cd "${REPO_ROOT}"

echo "==> Building rc-ffi (release, ${TARGET})"
cargo build --release -p rc-ffi --target "${TARGET}"

BUILT="${REPO_ROOT}/target/${TARGET}/release/${LIB}"
if [[ ! -f "${BUILT}" ]]; then
    echo "error: cargo reported success but ${BUILT} does not exist" >&2
    exit 1
fi

mkdir -p "${STAGED_DIR}"
cp "${BUILT}" "${STAGED_DIR}/${LIB}"

echo "==> Staged ${STAGED_DIR}/${LIB}"
