#!/usr/bin/env bash
# Supply-chain gate: dependencies must be pinned and every language's lockfile
# must actually be present and complete. See docs/SCOPE.md §5 "Supply chain".
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
report() { echo "  FAIL  $1"; fail=1; }

echo "== Rust: Cargo.lock =="
if [[ ! -f Cargo.lock ]]; then
    report "Cargo.lock is missing"
else
    echo "  ok    Cargo.lock present"
    unpinned_git=$(grep '^source = "git+' Cargo.lock | grep -vE '#[0-9a-f]{40}"$' || true)
    if [[ -n "$unpinned_git" ]]; then
        echo "$unpinned_git"
        report "Cargo.lock has a git dependency without a pinned 40-char commit sha"
    else
        echo "  ok    every git dependency (if any) is pinned to a commit sha"
    fi

    rust_total=$(grep -c '^\[\[package\]\]' Cargo.lock || echo 0)
    rust_workspace=$(grep -c '^name = "rc-' Cargo.lock || echo 0)
    rust_third_party=$((rust_total - rust_workspace))
    echo "  Rust dependency graph: ${rust_total} resolved packages, ${rust_workspace} workspace crates, ${rust_third_party} third-party (direct + transitive)"
fi

echo
echo "== Swift: Package.resolved =="
RESOLVED="apps/macos/Package.resolved"
if [[ ! -f "$RESOLVED" ]]; then
    report "$RESOLVED is missing"
else
    webrtc_pin=$(python3 - "$RESOLVED" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for pin in data.get("pins", []):
    if "stasel/WebRTC" in pin.get("location", ""):
        state = pin.get("state", {})
        rev = state.get("revision", "")
        ver = state.get("version", "")
        print(f"{rev}|{ver}")
        break
PY
)
    if [[ -z "$webrtc_pin" ]]; then
        report "Package.resolved has no pin for stasel/WebRTC"
    else
        rev="${webrtc_pin%%|*}"
        ver="${webrtc_pin##*|}"
        if [[ ${#rev} -lt 40 || -z "$ver" ]]; then
            report "stasel/WebRTC pin is missing an exact revision or version (rev='${rev}' version='${ver}')"
        else
            echo "  ok    stasel/WebRTC pinned to ${ver} (${rev})"
        fi
    fi

    swift_deps=$(python3 - "$RESOLVED" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
print(len(data.get("pins", [])))
PY
)
    echo "  Swift dependency graph: ${swift_deps} pinned package(s) (stasel/WebRTC is the only third-party one; the rest is Apple-native)"
fi

echo
echo "== Go: go.sum vs go.mod =="
GO_MOD="server/go.mod"
GO_SUM="server/go.sum"
if [[ ! -f "$GO_SUM" ]]; then
    report "$GO_SUM is missing"
elif [[ ! -f "$GO_MOD" ]]; then
    report "$GO_MOD is missing"
else
    missing=0
    direct_count=0
    indirect_count=0
    requires=$(sed -n '/^require (/,/^)/p' "$GO_MOD" | grep -E '^\s+\S+\s+\S+' )
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        mod=$(awk '{print $1}' <<<"$line")
        [[ "$mod" == "rcprotocol" ]] && continue
        if [[ "$line" == *"// indirect"* ]]; then
            indirect_count=$((indirect_count + 1))
        else
            direct_count=$((direct_count + 1))
        fi
        if ! grep -q "^${mod} " "$GO_SUM"; then
            report "go.sum has no entry for ${mod} (required by go.mod)"
            missing=1
        fi
    done <<<"$requires"
    if [[ "$missing" -eq 0 ]]; then
        echo "  ok    go.sum covers every go.mod requirement"
    fi
    go_sum_modules=$(awk '{print $1}' "$GO_SUM" | sort -u | wc -l | tr -d ' ')
    echo "  Go dependency graph (server): ${direct_count} direct, ${indirect_count} indirect, ${go_sum_modules} unique modules recorded in go.sum"
fi

echo
echo "== Go toolchain =="
ci_go=$(sed -n 's/^  GO_VERSION: *//p' .github/workflows/ci.yml | head -n1)
for mod in server/go.mod protocol/go.mod; do
    pinned=$(sed -n 's/^toolchain go//p' "$mod")
    if [[ -n "$ci_go" && "$pinned" == "$ci_go" ]]; then
        echo "  ok    ${mod} toolchain go${pinned} matches CI"
    else
        report "${mod} toolchain '${pinned:-none}' does not match CI GO_VERSION '${ci_go:-none}'"
    fi
done

echo
if [[ $fail -eq 0 ]]; then
    echo "DEPENDENCY GATE PASSED"
else
    echo "DEPENDENCY GATE FAILED — see failures above." >&2
fi
exit $fail
