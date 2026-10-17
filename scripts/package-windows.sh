#!/usr/bin/env bash
# Packages the Windows host as a portable, UNSIGNED x64 ZIP for private beta testers. Builds on a Mac
# with mingw-w64; ships rc-host.exe, the mingw runtime DLLs it really imports, notices and a README.
# There is no installer and no Authenticode step: that is a later milestone.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="x86_64-pc-windows-gnu"
PKG_DIR="apps/windows/package"
OBJDUMP="x86_64-w64-mingw32-objdump"
GCC="x86_64-w64-mingw32-gcc"
STRIP="x86_64-w64-mingw32-strip"

for tool in "$OBJDUMP" "$GCC" "$STRIP" zip shasum cargo; do
  command -v "$tool" >/dev/null || { echo "FAIL: $tool not found (brew install mingw-w64)" >&2; exit 1; }
done

VERSION="$(cargo pkgid -p rc-host)"
VERSION="${VERSION##*[#@]}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || { echo "FAIL: cannot read the rc-host version" >&2; exit 1; }
NAME="SkipperDesk-win-x64-${VERSION}"
ZIP="dist/${NAME}.zip"
EXE="target/${TARGET}/release/rc-host.exe"
ROOT="$PWD"
STAGE="$(mktemp -d -t rc-winzip)"
trap 'rm -rf "$STAGE"' EXIT

imports() {
  "$OBJDUMP" -p "$1" | awk '/DLL Name:/ {print tolower($3)}' | sort -u
}

find_runtime_dll() {
  local found dir
  found="$("$GCC" -print-file-name="$1")"
  if [[ -f "$found" ]]; then echo "$found"; return 0; fi
  dir="$(dirname "$("$GCC" -print-file-name=libstdc++-6.dll)")"
  for candidate in "$dir/../bin/$1" "$dir/$1"; do
    [[ -f "$candidate" ]] && { echo "$candidate"; return 0; }
  done
  return 1
}

echo "==> Building rc-host for $TARGET"
cargo build --release --locked --target "$TARGET" -p rc-host

[[ -f "$EXE" ]] || { echo "FAIL: $EXE was not produced" >&2; exit 1; }

echo "==> Verifying the executable is an x64 PE"
FORMAT="$("$OBJDUMP" -f "$EXE")"
grep -q "file format pei-x86-64" <<<"$FORMAT" || { echo "FAIL: $EXE is not a 64-bit PE" >&2; exit 1; }
grep -q "architecture: i386:x86-64" <<<"$FORMAT" || { echo "FAIL: $EXE is not x86-64" >&2; exit 1; }

mkdir -p "$STAGE/$NAME"
cp "$EXE" "$STAGE/$NAME/rc-host.exe"

echo "==> Resolving the DLLs it really imports"
DLLS=()
PENDING=("$EXE")
while [[ ${#PENDING[@]} -gt 0 ]]; do
  CURRENT="${PENDING[0]}"
  PENDING=("${PENDING[@]:1}")
  while read -r dll; do
    [[ "$dll" == lib*.dll ]] || continue
    [[ " ${DLLS[*]:-} " == *" $dll "* ]] && continue
    path="$(find_runtime_dll "$dll")" || { echo "FAIL: required DLL $dll not found in the mingw-w64 toolchain" >&2; exit 1; }
    cp "$path" "$STAGE/$NAME/$dll"
    "$STRIP" --strip-unneeded "$STAGE/$NAME/$dll"
    DLLS+=("$dll")
    PENDING+=("$path")
  done < <(imports "$CURRENT")
done
if [[ ${#DLLS[@]} -eq 0 ]]; then
  echo "  fully static apart from Windows system DLLs: shipping the exe alone"
else
  printf '  bundled %s\n' "${DLLS[@]}"
fi

echo "==> Writing notices and README"
{
  cat "$PKG_DIR/NOTICES-header.txt"
  cargo tree --locked -p rc-host --target "$TARGET" -e normal --prefix none --format '  {p}  [{l}]' | sed 's/ (\*)$//' | sort -u
} >"$STAGE/$NAME/THIRD-PARTY-NOTICES.txt"
cp "$PKG_DIR/README.txt" "$STAGE/$NAME/README.txt"

mkdir -p dist
rm -f "$ZIP"
(cd "$STAGE" && zip -X -q -r "$ROOT/$ZIP" "$NAME")

echo
echo "UNSIGNED private beta build: not for public download."
echo "Artifact: $ZIP"
echo "SHA-256:  $(shasum -a 256 "$ZIP" | awk '{print $1}')"
