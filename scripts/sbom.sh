#!/usr/bin/env bash
# Produces a CycloneDX 1.5 JSON SBOM per language into dist/sbom/.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR="dist/sbom"
mkdir -p "$OUT_DIR"

echo "== Rust SBOM =="
if command -v cargo-cyclonedx >/dev/null 2>&1; then
    cargo cyclonedx --format json --override-filename rust-sbom
    find . -maxdepth 3 -name 'rust-sbom.cdx.json' -exec mv {} "$OUT_DIR/rust.cdx.json" \;
else
    echo "  cargo-cyclonedx not installed; generating from cargo metadata"
    cargo metadata --format-version=1 --locked > "$OUT_DIR/.cargo-metadata.json"
    python3 - "$OUT_DIR/.cargo-metadata.json" "$OUT_DIR/rust.cdx.json" <<'PY'
import json, sys, uuid

metadata_path, out_path = sys.argv[1], sys.argv[2]
with open(metadata_path) as f:
    metadata = json.load(f)

workspace_members = set(metadata.get("workspace_members", []))
components = []
seen = set()
for pkg in metadata["packages"]:
    pkg_id = pkg.get("id", "")
    if pkg_id in workspace_members:
        continue
    key = (pkg["name"], pkg["version"])
    if key in seen:
        continue
    seen.add(key)
    purl = f"pkg:cargo/{pkg['name']}@{pkg['version']}"
    components.append({
        "type": "library",
        "bom-ref": purl,
        "name": pkg["name"],
        "version": pkg["version"],
        "purl": purl,
        "licenses": ([{"license": {"id": pkg["license"]}}] if pkg.get("license") else []),
    })

sbom = {
    "bomFormat": "CycloneDX",
    "specVersion": "1.5",
    "serialNumber": f"urn:uuid:{uuid.uuid4()}",
    "version": 1,
    "metadata": {
        "component": {
            "type": "application",
            "name": "skipperdesk-core",
            "version": "0.1.0",
        }
    },
    "components": components,
}
with open(out_path, "w") as f:
    json.dump(sbom, f, indent=2, sort_keys=True)
    f.write("\n")
print(f"  {len(components)} third-party Rust components")
PY
    rm -f "$OUT_DIR/.cargo-metadata.json"
fi
echo "  wrote ${OUT_DIR}/rust.cdx.json"

echo "== Go SBOM =="
(cd server && go list -m -json all) > "$OUT_DIR/.go-modules.json"
python3 - "$OUT_DIR/.go-modules.json" "$OUT_DIR/go.cdx.json" <<'PY'
import json, sys, uuid

modules_path, out_path = sys.argv[1], sys.argv[2]
components = []
with open(modules_path) as f:
    raw = f.read()

decoder = json.JSONDecoder()
idx = 0
raw = raw.strip()
modules = []
while idx < len(raw):
    obj, end = decoder.raw_decode(raw, idx)
    modules.append(obj)
    idx = end
    while idx < len(raw) and raw[idx].isspace():
        idx += 1

for mod in modules:
    if mod.get("Main"):
        continue
    path = mod.get("Path")
    version = mod.get("Version") or "unknown"
    if not path:
        continue
    purl = f"pkg:golang/{path}@{version}"
    components.append({
        "type": "library",
        "bom-ref": purl,
        "name": path,
        "version": version,
        "purl": purl,
    })

sbom = {
    "bomFormat": "CycloneDX",
    "specVersion": "1.5",
    "serialNumber": f"urn:uuid:{uuid.uuid4()}",
    "version": 1,
    "metadata": {
        "component": {
            "type": "application",
            "name": "rc-signal",
            "version": "0.0.0",
        }
    },
    "components": components,
}
with open(out_path, "w") as f:
    json.dump(sbom, f, indent=2, sort_keys=True)
    f.write("\n")
print(f"  {len(components)} Go modules (direct + transitive)")
PY
rm -f "$OUT_DIR/.go-modules.json"
echo "  wrote ${OUT_DIR}/go.cdx.json"

echo "== Swift SBOM =="
python3 - apps/macos/Package.resolved "$OUT_DIR/swift.cdx.json" <<'PY'
import json, sys, uuid

resolved_path, out_path = sys.argv[1], sys.argv[2]
with open(resolved_path) as f:
    data = json.load(f)

components = []
for pin in data.get("pins", []):
    state = pin.get("state", {})
    version = state.get("version") or state.get("revision", "unknown")
    purl = f"pkg:swift/{pin.get('location', pin.get('identity'))}@{version}"
    components.append({
        "type": "library",
        "bom-ref": purl,
        "name": pin.get("identity", "unknown"),
        "version": version,
        "purl": purl,
        "externalReferences": [{"type": "vcs", "url": pin.get("location", "")}],
    })

sbom = {
    "bomFormat": "CycloneDX",
    "specVersion": "1.5",
    "serialNumber": f"urn:uuid:{uuid.uuid4()}",
    "version": 1,
    "metadata": {
        "component": {
            "type": "application",
            "name": "SkipperDesk-macos",
            "version": "1.0.0",
        }
    },
    "components": components,
}
with open(out_path, "w") as f:
    json.dump(sbom, f, indent=2, sort_keys=True)
    f.write("\n")
print(f"  {len(components)} Swift package(s)")
PY
echo "  wrote ${OUT_DIR}/swift.cdx.json"

echo
echo "== SBOM files =="
ls -la "$OUT_DIR"
