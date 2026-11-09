#!/usr/bin/env bash
# Common disk-space commands (handled before any build side effects).
# Paths are restricted to this script's own direct-child workspace/output.
modframework_disk_command() {
    local action='' dry_run=0 assume_yes=0 arg
    for arg in "$@"; do
        case "$arg" in
            --status|--clean|--clean-all)
                if [[ -n "$action" ]]; then echo 'ERROR: choose one of --status, --clean or --clean-all' >&2; return 2; fi
                action="$arg" ;;
            --dry-run) dry_run=1 ;;
            --yes) assume_yes=1 ;;
            --help)
                printf '%s\n' 'Usage: ./BUILDER.sh [--status | --clean [--dry-run] [--yes] | --clean-all [--dry-run] [--yes]]' '' \
                    '  --status    Report hidden workspace and output sizes; no changes.' \
                    '  --clean     Remove hidden build workspace only (confirmation required).' \
                    '  --clean-all Remove hidden workspace AND generated output (confirmation required).' \
                    '  --dry-run   Preview cleanup without deleting anything.' \
                    '  --yes       Skip interactive confirmation.' \
                    '  No flags    Run the existing build workflow unchanged.'
                return 0 ;;
            *) echo "ERROR: unknown argument: $arg" >&2; return 2 ;;
        esac
    done
    if [[ -z "$action" ]]; then
        if ((dry_run || assume_yes)); then echo 'ERROR: --dry-run/--yes require --clean or --clean-all' >&2; return 2; fi
        return 99
    fi
    if [[ "$action" == --status ]] && ((dry_run || assume_yes)); then
        echo 'ERROR: --status cannot be combined with --dry-run or --yes' >&2; return 2
    fi
    local script_root work_dir output_dir work_size output_size answer target
    script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 2
    work_dir="$script_root/.modmediainfo-macos15"
    output_dir="$script_root/output-ModMediaInfo"
    # Fail closed if the workspace/output are symlinks, even if they point inside the root.
    for target in "$work_dir" "$output_dir"; do
        if [[ -L "$target" ]]; then echo "ERROR: refusing symlinked directory: $target" >&2; return 2; fi
        if [[ -e "$target" && ! -d "$target" ]]; then echo "ERROR: expected directory: $target" >&2; return 2; fi
    done
    work_size='not present'; output_size='not present'
    [[ ! -d "$work_dir" ]] || work_size="$(du -sh "$work_dir" 2>/dev/null | awk '{print $1}')"
    [[ ! -d "$output_dir" ]] || output_size="$(du -sh "$output_dir" 2>/dev/null | awk '{print $1}')"
    printf '\n%s — disk-space management\n' 'ModMediaInfo'
    printf 'Hidden workspace: %s (%s)\n' "$work_dir" "$work_size"
    printf 'Generated output:  %s (%s)\n' "$output_dir" "$output_size"
    df -h "$script_root" | awk 'NR==1 || NR==2 {print}'
    if [[ "$action" == --status ]]; then
        printf '\nRun --clean --dry-run to preview removal.\n'
        return 0
    fi
    printf '\nWill remove hidden build workspace: %s\n' "$work_dir"
    if [[ "$action" == --clean-all ]]; then
        printf 'Will ALSO remove generated output: %s\n' "$output_dir"
    else
        printf 'Will preserve generated output: %s\n' "$output_dir"
    fi
    printf 'WARNING: compiled caches and source checkouts will be lost; PACKAGE_ONLY=1 will no longer work until rebuilt.\n'
    if ((dry_run)); then printf 'DRY RUN: nothing deleted.\n'; return 0; fi
    if ((!assume_yes)); then
        if [[ ! -t 0 ]]; then echo 'ERROR: interactive confirmation unavailable; use --yes to authorize cleanup.' >&2; return 2; fi
        printf 'Type DELETE to confirm: '
        IFS= read -r answer || return 2
        if [[ "$answer" != DELETE ]]; then echo 'Cancelled; nothing deleted.'; return 0; fi
    fi
    if [[ -d "$work_dir" ]]; then rm -rf -- "$work_dir" || return 1; fi
    if [[ "$action" == --clean-all && -d "$output_dir" ]]; then rm -rf -- "$output_dir" || return 1; fi
    printf 'Cleanup complete.\n'
}
if (($#)); then
    modframework_disk_result=0
    modframework_disk_command "$@" || modframework_disk_result=$?
    if ((modframework_disk_result != 99)); then exit "$modframework_disk_result"; fi
fi

set -Eeuo pipefail

# Sign embedded Mach-O libraries before their enclosing framework, and record
# the actual identity and dependency closure for host-app library validation.
sign_framework_and_report() {
    local bundle="$1" report="$2" identity="$3" enabled="$4"
    local binary="${bundle}/Versions/A/${FRAMEWORK_NAME}"
    local nested
    {
        printf 'Framework: %s\nRequested signing identity: %s\n' "$bundle" "$identity"
        printf 'Signing enabled: %s\n' "$enabled"
        printf '\nEmbedded Mach-O libraries:\n'
    } > "$report"
    # -type f deliberately excludes symlink aliases (e.g. libvulkan.1.dylib).
    while IFS= read -r -d '' nested; do
        [[ "$nested" == "$binary" ]] && continue
        if /usr/bin/file -b "$nested" | grep -q 'Mach-O'; then
            printf '%s\n' "$nested" >> "$report"
            if [[ "$enabled" == 1 ]]; then
                codesign --force --sign "$identity" --timestamp=none "$nested"
                codesign --verify --strict --verbose=2 "$nested" >> "$report" 2>&1
            fi
            otool -L "$nested" >> "$report" 2>&1
        fi
    done < <(find "$bundle/Versions/A" -type f \( -name '*.dylib' -o -name '*.so' \) -print0)
    if [[ "$enabled" == 1 ]]; then
        codesign --force --sign "$identity" --timestamp=none "$bundle"
        codesign --verify --strict --verbose=2 "$bundle" >> "$report" 2>&1
        codesign -dv --verbose=4 "$bundle" >> "$report" 2>&1
    fi
    printf '\nFramework dependencies:\n' >> "$report"
    otool -L "$binary" >> "$report" 2>&1
    printf '\nSigning report completed. Host app Team ID compatibility must be tested in the consuming app.\n' >> "$report"
}

sign_xcframework_and_report() {
    local xc="$1" report="$2" identity="$3" enabled="$4"
    [[ "$enabled" == 1 ]] || return 0
    codesign --force --sign "$identity" --timestamp=none "$xc"
    codesign --verify --strict --verbose=2 "$xc" >> "$report" 2>&1
    codesign -dv --verbose=4 "$xc" >> "$report" 2>&1
}

on_build_error() {
    local status="$1" line="$2"
    trap - ERR
    echo "ERROR: ModMediaInfo build failed near line $line (exit $status)" >&2
    if [[ -n "${OUT:-}" && -d "$OUT" ]]; then
        printf 'FAIL: build stopped near line %s (exit %s); see build.log\n' "$line" "$status" >> "$OUT/ModMediaInfo-validation.txt"
    fi
    exit "$status"
}
trap 'on_build_error "$?" "$LINENO"' ERR

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$ROOT/.modmediainfo-macos15"
OUT="$ROOT/output-ModMediaInfo"
PREFIX="$WORK/stage"
BUILD="$WORK/build"
MIN_MACOS="${MIN_MACOS:-15.4}"
MEDIAINFO_REF="${MEDIAINFO_REF:-v26.10}"
ZENLIB_REF="${ZENLIB_REF:-v0.4.41}"
VERSION="${VERSION:-1.0.0}"
BUNDLE_ID="${BUNDLE_ID:-org.modframeworks.ModMediaInfo}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
XCFRAMEWORK="${XCFRAMEWORK:-1}"
SIGN="${SIGN:-1}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
SIGN_MODE="${SIGN_MODE:-auto}"
# Portable signing: auto prefers one available Apple Development identity,
# otherwise falls back to ad-hoc. Never select an ambiguous certificate.
# Explicit SIGN_MODE=development requires an Apple Development certificate.
modframework_resolve_signing() {
    local mode="${SIGN_MODE:-auto}" requested="${CODESIGN_IDENTITY:-${SIGN_IDENTITY:-}}" identities count
    if [[ "${SIGN:-1}" == 0 ]]; then
        if [[ "${SIGN_MODE:-auto}" != auto && "${SIGN_MODE:-auto}" != none ]]; then
            echo 'ERROR: SIGN=0 conflicts with SIGN_MODE; use SIGN_MODE=none.' >&2; return 2
        fi
        mode=none
    fi
    case "$mode" in auto|development|adhoc|none) ;; *) echo "ERROR: invalid SIGN_MODE=$mode" >&2; return 2;; esac
    if [[ "$mode" == auto && "$requested" == '-' ]]; then mode=adhoc; fi
    if [[ "$mode" == auto || "$mode" == development ]]; then
        if [[ -z "$requested" ]]; then
            command -v security >/dev/null || { echo 'ERROR: macOS security tool unavailable' >&2; return 2; }
            identities="$(security find-identity -v -p codesigning 2>/dev/null | sed -nE 's/^[[:space:]]*[0-9]+\) ([A-Fa-f0-9]{40}) "Apple Development:.*$/\1/p' || true)"
            count="$(printf '%s\n' "$identities" | grep -cE '^[A-Fa-f0-9]{40}$' || true)"
            if [[ "$count" == 1 ]]; then
                requested="$identities"
                mode=development
            elif [[ "$mode" == development ]]; then
                echo "ERROR: expected exactly one Apple Development identity, found $count. Set CODESIGN_IDENTITY explicitly or use SIGN_MODE=adhoc." >&2
                return 2
            else
                mode=adhoc
                if [[ "$count" -gt 1 ]]; then
                    echo 'NOTE: multiple Apple Development identities found; using ad-hoc. Set CODESIGN_IDENTITY to select one.'
                else
                    echo 'NOTE: no Apple Development identity found; using ad-hoc.'
                fi
            fi
        else
            [[ "$requested" != '-' ]] || { echo 'ERROR: use SIGN_MODE=adhoc for ad-hoc signing' >&2; return 2; }
            mode=development
        fi
    fi
    if [[ "$mode" == adhoc ]]; then
        [[ -z "${SIGNING_TEAM:-}" ]] || { echo 'ERROR: SIGNING_TEAM is incompatible with ad-hoc signing' >&2; return 2; }
        requested='-'
    elif [[ "$mode" == none ]]; then
        [[ -z "${SIGNING_TEAM:-}" ]] || { echo 'ERROR: SIGNING_TEAM requires development signing' >&2; return 2; }
        requested=''
    fi
    if [[ "$mode" != none ]]; then
        command -v codesign >/dev/null || { echo 'ERROR: codesign unavailable' >&2; return 2; }
        SIGN=1
    else
        SIGN=0
    fi
    SIGN_MODE="$mode"
    CODESIGN_IDENTITY="$requested"
    SIGN_IDENTITY="$requested"
    printf 'Signing mode: %s%s\n' "$mode" "${requested:+ (identity=$requested)}"
}
modframework_resolve_signing
CLEAN_BUILD="${CLEAN_BUILD:-0}"
CHECK_ONLY="${CHECK_ONLY:-0}"

[[ "$MIN_MACOS" =~ ^[0-9]+\.[0-9]+$ ]] || {
    echo "ERROR: MIN_MACOS must be major.minor (for example 15.4)" >&2
    exit 2
}
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || {
    echo "ERROR: VERSION must contain two or three numeric components" >&2
    exit 2
}
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: JOBS must be a positive integer" >&2
    exit 2
}
for flag in XCFRAMEWORK SIGN CLEAN_BUILD CHECK_ONLY; do
value="${!flag}"
[[ "$value" == 0 || "$value" == 1 ]] || {
    echo "ERROR: $flag must be 0 or 1" >&2
    exit 2
}
done
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
    echo "ERROR: this builder requires an Apple Silicon Mac" >&2
    exit 1
}

TOOLS=(git cmake ninja xcrun clang clang++ swiftc lipo otool nm python3 shasum install_name_tool plutil tar gzip)
[[ "$XCFRAMEWORK" != 1 ]] || TOOLS+=(xcodebuild)
[[ "$SIGN" != 1 ]] || TOOLS+=(codesign)
for tool in "${TOOLS[@]}"; do
command -v "$tool" >/dev/null 2>&1 || {
    echo "ERROR: required tool not found: $tool" >&2
    exit 2
}
done

if [[ "$CHECK_ONLY" == 1 ]]; then
printf 'Preflight passed for ModMediaInfo (%s, arm64, macOS %s).\n' \
"$(xcrun --find clang)" "$MIN_MACOS"
exit 0
fi

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun --sdk macosx -f clang)"
CXX="$(xcrun --sdk macosx -f clang++)"
mkdir -p "$WORK" "$OUT"
: > "$OUT/ModMediaInfo-validation.txt"
exec > >(tee "$OUT/build.log") 2>&1

fetch_source() {
    local url="$1" path="$2" ref="$3"
    if [[ -d "$path/.git" ]]; then
    if [[ -n "$(git -C "$path" status --porcelain)" ]]; then
    echo "ERROR: refusing to overwrite modified source checkout: $path" >&2
    return 2
    fi
    git -C "$path" fetch --depth 1 origin "$ref"
    git -C "$path" checkout --detach --force FETCH_HEAD
    elif [[ -e "$path" ]]; then
    echo "ERROR: refusing to replace non-Git source path: $path" >&2
    return 2
    else
    git clone --depth 1 --branch "$ref" "$url" "$path"
    git -C "$path" checkout --detach
    fi
}

MEDIAINFO_SOURCE="$WORK/MediaInfoLib"
ZENLIB_SOURCE="$WORK/ZenLib"
fetch_source https://github.com/MediaArea/MediaInfoLib.git "$MEDIAINFO_SOURCE" "$MEDIAINFO_REF"
fetch_source https://github.com/MediaArea/ZenLib.git "$ZENLIB_SOURCE" "$ZENLIB_REF"

# Force ZenLib's own CMake directory to build a static archive, while
# keeping MediaInfoLib shared in the parent CMake directory.
# Restore the pinned upstream file on exit (including build failures).
ZEN_CMAKE_FILE="$ZENLIB_SOURCE/Project/CMake/CMakeLists.txt"
[[ -f "$ZEN_CMAKE_FILE" ]] || { echo "ERROR: missing ZenLib CMakeLists.txt" >&2; exit 1; }
ZEN_CMAKE_BACKUP="$WORK/ZenLib-CMakeLists.original"
cp "$ZEN_CMAKE_FILE" "$ZEN_CMAKE_BACKUP"
restore_zen_cmake() {
    if [[ -f "$ZEN_CMAKE_BACKUP" ]]; then
        cp "$ZEN_CMAKE_BACKUP" "$ZEN_CMAKE_FILE"
        rm -f "$ZEN_CMAKE_BACKUP"
    fi
}
trap restore_zen_cmake EXIT
python3 - "$ZEN_CMAKE_FILE" <<'PY_FORCE_STATIC_ZEN'
from pathlib import Path
import re
import sys
path = Path(sys.argv[1])
original = path.read_text()
# CMP0077 NEW prevents option(BUILD_SHARED_LIBS ...) from discarding
# the directory-local OFF setting. Insert after cmake_minimum_required,
# which otherwise resets policies and defeats the override.
pattern = r'(?im)^(cmake_minimum_required\s*\([^\n]*\)\s*)$'
match = re.search(pattern, original)
if not match:
    raise SystemExit('ERROR: cannot locate ZenLib cmake_minimum_required')
patched = original[:match.end()] + '\ncmake_policy(SET CMP0077 NEW)\nset(BUILD_SHARED_LIBS OFF)\n' + original[match.end():]
if not re.search(r'(?i)option\s*\(\s*BUILD_SHARED_LIBS\b', original):
    raise SystemExit('ERROR: ZenLib CMake structure changed: BUILD_SHARED_LIBS option not found')
path.write_text(patched)
PY_FORCE_STATIC_ZEN

MEDIAINFO_REVISION="$(git -C "$MEDIAINFO_SOURCE" rev-parse HEAD)"
ZENLIB_REVISION="$(git -C "$ZENLIB_SOURCE" rev-parse HEAD)"
echo "MediaInfoLib $MEDIAINFO_REF ($MEDIAINFO_REVISION)"
echo "ZenLib $ZENLIB_REF ($ZENLIB_REVISION)"
echo "Target: macOS $MIN_MACOS arm64; SDK: $SDK_PATH"
echo "Compiler: $("$CC" --version | head -n 1)"
echo "CMake: $(cmake --version | head -n 1)"

if [[ "$CLEAN_BUILD" == 1 ]]; then
echo "Removing only generated CMake build and staging directories."
rm -rf "$BUILD" "$PREFIX"
fi
mkdir -p "$PREFIX"

cmake -S "$MEDIAINFO_SOURCE/Project/CMake" -B "$BUILD" -G Ninja \
-DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
-DCMAKE_BUILD_TYPE=Release \
-DCMAKE_INSTALL_PREFIX="$PREFIX" \
-DCMAKE_C_COMPILER="$CC" \
-DCMAKE_CXX_COMPILER="$CXX" \
-DCMAKE_OSX_ARCHITECTURES=arm64 \
-DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
-DCMAKE_OSX_SYSROOT="$SDK_PATH" \
-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
-DCMAKE_SKIP_INSTALL_RPATH=ON \
-DCMAKE_FIND_ROOT_PATH="$SDK_PATH" \
-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
-DCMAKE_FIND_PACKAGE_NO_PACKAGE_REGISTRY=ON \
-DCMAKE_PREFIX_PATH= \
-DBUILD_SHARED_LIBS=ON \
-DBUILD_ZENLIB=ON \
-DBUILD_ZLIB=OFF \
-DCMAKE_DISABLE_FIND_PACKAGE_CURL=ON \
-DCMAKE_DISABLE_FIND_PACKAGE_TinyXML=ON \
-DCMAKE_C_VISIBILITY_PRESET=default \
-DCMAKE_CXX_VISIBILITY_PRESET=default \
-DCMAKE_VISIBILITY_INLINES_HIDDEN=OFF
cmake --build "$BUILD" --parallel "$JOBS"
# Fail immediately if ZenLib was not actually compiled as a static archive.
ZEN_STATIC="$BUILD/ZenLib/libzen.a"
[[ -s "$ZEN_STATIC" ]] || { echo "ERROR: ZenLib is not static; inspect ZenLib CMake policy and build.log" >&2; exit 1; }
cmake --install "$BUILD"

MEDIAINFO_LIBRARY=""
for candidate in "$PREFIX"/lib/libmediainfo.*.dylib "$PREFIX"/lib/libmediainfo.dylib; do
if [[ -f "$candidate" ]]; then
MEDIAINFO_LIBRARY="$candidate"
break
fi
done
[[ -n "$MEDIAINFO_LIBRARY" ]] || {
    echo "ERROR: CMake did not install the MediaInfo dynamic library under $PREFIX/lib" >&2
    exit 1
}
[[ -d "$PREFIX/include/MediaInfo" && -d "$PREFIX/include/MediaInfoDLL" &&
-d "$PREFIX/include/ZenLib" ]] || {
    echo "ERROR: expected installed MediaInfo, MediaInfoDLL, or ZenLib headers are missing" >&2
    exit 1
}

FRAMEWORK="$OUT/ModMediaInfo.framework"
XCFRAMEWORK_PATH="$OUT/ModMediaInfo.xcframework"
rm -rf "$FRAMEWORK" "$XCFRAMEWORK_PATH"
rm -f "$OUT/ModMediaInfo-source-compliance.tar.gz" \
"$OUT/ModMediaInfo-header-inventory.json" \
"$OUT/ModMediaInfo-exported-symbols.txt"
mkdir -p "$FRAMEWORK/Versions/A/Headers" \
"$FRAMEWORK/Versions/A/Modules" \
"$FRAMEWORK/Versions/A/Resources/Legal"
cp -R "$PREFIX/include/." "$FRAMEWORK/Versions/A/Headers/"
cp -L "$MEDIAINFO_LIBRARY" "$FRAMEWORK/Versions/A/ModMediaInfo"
# ZenLib is static in its own CMake directory and linked into libmediainfo.
# No separate ZenLib dylib is expected or packaged.
ZEN_STATIC="$BUILD/ZenLib/libzen.a"
if [[ ! -s "$ZEN_STATIC" ]]; then
    ZEN_STATIC="$(find "$BUILD/ZenLib" -name 'libzen.a' -type f -print -quit)"
fi
[[ -n "$ZEN_STATIC" && -s "$ZEN_STATIC" ]] || {
    echo "ERROR: bundled static ZenLib archive not found in CMake build" >&2
    exit 1
}
echo "PASS: bundled ZenLib static archive built: $ZEN_STATIC"

PUBLIC_MEDIAINFO_HEADERS=(
MediaInfo/MediaInfo.h
MediaInfo/MediaInfoList.h
MediaInfo/MediaInfo_Const.h
MediaInfo/MediaInfo_Events.h
MediaInfoDLL/MediaInfoDLL.h
MediaInfoDLL/MediaInfoDLL_Static.h
)
for header in "${PUBLIC_MEDIAINFO_HEADERS[@]}"; do
installed="$FRAMEWORK/Versions/A/Headers/$header"
source="$MEDIAINFO_SOURCE/Source/$header"
[[ -s "$installed" && -s "$source" ]] || {
    echo "ERROR: required public header is missing: $header" >&2
    exit 1
}
cmp -s "$source" "$installed" || {
    echo "ERROR: installed public header differs from the pinned source: $header" >&2
    exit 1
}
done

cat >"$FRAMEWORK/Versions/A/Headers/ModMediaInfo.h" <<'EOF_UMBRELLA'
#ifndef MOD_MEDIAINFO_H
#define MOD_MEDIAINFO_H

#include "MediaInfoDLL/MediaInfoDLL_Static.h"

#endif
EOF_UMBRELLA

cat >"$FRAMEWORK/Versions/A/Modules/module.modulemap" <<'EOF_MODULE'
framework module ModMediaInfo {
    umbrella header "ModMediaInfo.h"
    exclude header "MediaInfoDLL/MediaInfoDLL.h"
    export *
}
EOF_MODULE

python3 - "$FRAMEWORK/Versions/A/Resources/Info.plist" \
"$BUNDLE_ID" "$VERSION" "$MIN_MACOS" <<'PY_PLIST'
import plistlib
import sys

path, bundle_id, version, minimum = sys.argv[1:]
plist = {
    "CFBundleDevelopmentRegion": "en",
    "CFBundleExecutable": "ModMediaInfo",
    "CFBundleIdentifier": bundle_id,
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": "ModMediaInfo",
    "CFBundlePackageType": "FMWK",
    "CFBundleShortVersionString": version,
    "CFBundleVersion": version,
    "CFBundleSupportedPlatforms": ["MacOSX"],
    "LSMinimumSystemVersion": minimum,
}
with open(path, "wb") as output:
    plistlib.dump(plist, output, sort_keys=True)
PY_PLIST

ln -s A "$FRAMEWORK/Versions/Current"
ln -s Versions/Current/ModMediaInfo "$FRAMEWORK/ModMediaInfo"
ln -s Versions/Current/Headers "$FRAMEWORK/Headers"
ln -s Versions/Current/Modules "$FRAMEWORK/Modules"
ln -s Versions/Current/Resources "$FRAMEWORK/Resources"

install_name_tool -id \
"@rpath/ModMediaInfo.framework/Versions/A/ModMediaInfo" \
"$FRAMEWORK/Versions/A/ModMediaInfo"

cp "$MEDIAINFO_SOURCE/LICENSE" \
"$FRAMEWORK/Versions/A/Resources/Legal/LICENSE.MediaInfoLib.txt"
cp "$MEDIAINFO_SOURCE/License.html" \
"$FRAMEWORK/Versions/A/Resources/Legal/License.MediaInfoLib.html"
cp "$ZENLIB_SOURCE/License.txt" \
"$FRAMEWORK/Versions/A/Resources/Legal/LICENSE.ZenLib.txt"
cat >"$FRAMEWORK/Versions/A/Resources/Legal/DISTRIBUTION_NOTES.txt" <<'EOF_NOTICES'
MediaInfoLib and ZenLib notices are included alongside this file. The source
archive contains the pinned upstream source trees and their in-tree third-party
notices. Review all source notices and applicable licenses before redistribution.
EOF_NOTICES

cat >"$FRAMEWORK/Versions/A/Resources/Legal/BUILD_INFO.txt" <<EOF_BUILD
MediaInfoLib ref: $MEDIAINFO_REF
MediaInfoLib commit: $MEDIAINFO_REVISION
ZenLib ref: $ZENLIB_REF
ZenLib commit: $ZENLIB_REVISION
Architecture: arm64 (macOS)
Minimum macOS: $MIN_MACOS
Version: $VERSION
SDK: $SDK_PATH
Compiler: $("$CC" --version | head -n 1)
CMake: $(cmake --version | head -n 1)
Build configuration: Release, shared framework, statically linked ZenLib, SDK zlib.
CURL package lookup disabled to prevent linking a non-SDK host dependency.
EOF_BUILD

python3 - "$FRAMEWORK/Versions/A/Headers" "$OUT/ModMediaInfo-header-inventory.json" <<'PY_HEADERS'
import hashlib
import json
import os
import sys

root, output = sys.argv[1:]
headers = []
for directory, _, filenames in os.walk(root):
    for filename in filenames:
        if filename.endswith(".h"):
            path = os.path.join(directory, filename)
            relative = os.path.relpath(path, root).replace(os.sep, "/")
            with open(path, "rb") as source:
                digest = hashlib.sha256(source.read()).hexdigest()
            headers.append({"path": relative, "sha256": digest})
headers.sort(key=lambda header: header["path"])
if not headers:
    raise SystemExit("ERROR: framework contains no public headers")
with open(output, "w", encoding="utf-8") as inventory:
    json.dump(headers, inventory, indent=2)
    inventory.write("\n")
print(f"PASS: inventoried {len(headers)} installed public headers with SHA-256")
PY_HEADERS

BIN="$FRAMEWORK/Versions/A/ModMediaInfo"
EXPORTS="$OUT/ModMediaInfo-exported-symbols.txt"
nm -gU "$BIN" >"$EXPORTS"
grep -Eq '[[:space:]]_MediaInfoA_New$' "$EXPORTS" || {
    echo "ERROR: MediaInfo C API symbol MediaInfoA_New is not exported" >&2
    exit 1
}
grep -Eq '[[:space:]]_MediaInfoA_Get$' "$EXPORTS" || {
    echo "ERROR: MediaInfo C API symbol MediaInfoA_Get is not exported" >&2
    exit 1
}
lipo -verify_arch arm64 "$BIN"
lipo -verify_arch arm64 "$ZEN_STATIC"
plutil -lint "$FRAMEWORK/Versions/A/Resources/Info.plist"
if otool -L "$BIN" | grep -E '(/opt/homebrew/|/usr/local/|/opt/local/|libzen|ZenLib|''"$WORK"'')'; then
    echo "ERROR: ModMediaInfo has an unexpected external dynamic dependency" >&2
    exit 1
fi
if ! otool -D "$BIN" |
grep -Fx '@rpath/ModMediaInfo.framework/Versions/A/ModMediaInfo' >/dev/null; then
echo "ERROR: unexpected ModMediaInfo install name" >&2
otool -L "$BIN" >&2
exit 1
fi
xcrun vtool -show-build "$BIN" >"$OUT/ModMediaInfo-mach-o-build.txt"
grep -Eq 'platform[[:space:]]+MACOS' "$OUT/ModMediaInfo-mach-o-build.txt" || {
    echo "ERROR: framework binary does not target macOS" >&2
    exit 1
}

python3 - "$BIN" "$OUT/ModMediaInfo-linkage.txt" <<'PY_LINKAGE'
import subprocess
import sys
image, destination = sys.argv[1:]
output = subprocess.check_output(["otool", "-L", image], text=True)
for line in output.splitlines()[1:]:
    if not line.strip():
        continue
    dependency = line.strip().split()[0]
    if dependency.startswith(("/usr/lib/", "/System/Library/")):
        continue
    if dependency == "@rpath/ModMediaInfo.framework/Versions/A/ModMediaInfo":
        continue
    raise SystemExit(f"ERROR: unexpected dynamic dependency {dependency!r}")
with open(destination, "w", encoding="utf-8") as report:
    report.write(output)
print("PASS: no external ZenLib dylib dependency; only macOS system runtime dependencies")
PY_LINKAGE

python3 - "$WORK/mediainfo-smoke.wav" <<'PY_WAV'
import struct
import sys
sample_rate = 8000
sample_count = sample_rate // 4
payload = bytes((128 + (index % 32) for index in range(sample_count)))
fmt = struct.pack("<HHIIHH", 1, 1, sample_rate, sample_rate, 1, 8)
with open(sys.argv[1], "wb") as output:
    output.write(b"RIFF")
    output.write(struct.pack("<I", 36 + len(payload)))
    output.write(b"WAVEfmt ")
    output.write(struct.pack("<I", len(fmt)))
    output.write(fmt)
    output.write(b"data")
    output.write(struct.pack("<I", len(payload)))
    output.write(payload)
PY_WAV
cat >"$WORK/mediainfo-c-smoke.c" <<'EOF_C'
#include <MediaInfoDLL/MediaInfoDLL_Static.h>
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv)
{
    if (argc != 2)
    return 2;
    void *handle = MediaInfoA_New();
    if (!handle)
    return 3;
    if (!MediaInfoA_Open(handle, argv[1])) {
        MediaInfoA_Delete(handle);
        return 4;
    }
    const char *format = MediaInfoA_Get(
    handle, MediaInfo_Stream_General, 0, "Format",
    MediaInfo_Info_Text, MediaInfo_Info_Name);
    if (!format || !*format) {
        MediaInfoA_Close(handle);
        MediaInfoA_Delete(handle);
        return 5;
    }
    printf("PASS: parsed WAV; general format: %s\n", format);
    MediaInfoA_Close(handle);
    MediaInfoA_Delete(handle);
    return 0;
}
EOF_C
"$CC" -std=c11 -arch arm64 -isysroot "$SDK_PATH" \
  -mmacosx-version-min="$MIN_MACOS" \
  -I"$FRAMEWORK/Versions/A/Headers" -F"$OUT" \
  "$WORK/mediainfo-c-smoke.c" -framework ModMediaInfo \
  -Wl,-rpath,"$OUT" -o "$WORK/mediainfo-c-smoke"
DYLD_FRAMEWORK_PATH="$OUT" "$WORK/mediainfo-c-smoke" "$WORK/mediainfo-smoke.wav"
echo "PASS: standalone C consumer compiled, linked, and parsed WAV"
cat >"$WORK/mediainfo-cpp-smoke.cpp" <<'EOF_CPP'
#include <MediaInfo/MediaInfo.h>
#include <MediaInfo/MediaInfoList.h>
int main()
{
    MediaInfoLib::MediaInfo media;
    return media.Count_Get(MediaInfoLib::Stream_General, 0) == 0 ? 0 : 1;
}
EOF_CPP
"$CXX" -std=c++20 -arch arm64 -isysroot "$SDK_PATH" \
  -mmacosx-version-min="$MIN_MACOS" \
  -I"$FRAMEWORK/Versions/A/Headers" -F"$OUT" \
  "$WORK/mediainfo-cpp-smoke.cpp" -framework ModMediaInfo \
  -Wl,-rpath,"$OUT" -o "$WORK/mediainfo-cpp-smoke"
DYLD_FRAMEWORK_PATH="$OUT" "$WORK/mediainfo-cpp-smoke"
echo "PASS: standalone C++ consumer compiled, linked, and ran"
cat >"$WORK/mediainfo-swift-smoke.swift" <<'EOF_SWIFT'
import ModMediaInfo
guard let handle = MediaInfoA_New() else {
    fatalError("MediaInfoA_New returned null")
}
MediaInfoA_Delete(handle)
EOF_SWIFT
swiftc -cxx-interoperability-mode=default -Xcc -std=c++20 \
  -F "$OUT" -framework ModMediaInfo \
  "$WORK/mediainfo-swift-smoke.swift" -o "$WORK/mediainfo-swift-smoke"
DYLD_FRAMEWORK_PATH="$OUT" "$WORK/mediainfo-swift-smoke"
echo "PASS: standalone Swift consumer imported ModMediaInfo, linked, and ran"
# Generate agent documentation before signing so the code signature remains valid.
DOC_DIR="$FRAMEWORK/Versions/A/Resources/Documentation"
mkdir -p "$DOC_DIR"
python3 - "$OUT" "$DOC_DIR" "$MEDIAINFO_REF" "$MEDIAINFO_REVISION" "$ZENLIB_REF" "$ZENLIB_REVISION" "$MIN_MACOS" "$VERSION" <<'PY_DOCS'
import json, pathlib, re, sys
out, docs = map(pathlib.Path, sys.argv[1:3])
mi_ref, mi_rev, zen_ref, zen_rev, min_os, version = sys.argv[3:]
headers = json.loads((out/'ModMediaInfo-header-inventory.json').read_text())
exports = (out/'ModMediaInfo-exported-symbols.txt').read_text()
api = sorted(set(re.findall(r'\b_MediaInfoA_[A-Za-z0-9_]+\b', exports)))
data = {
  'schema_version': 1, 'framework': 'ModMediaInfo', 'version': version,
  'platform': {'os': 'macOS', 'minimum': min_os, 'architecture': 'arm64'},
  'purpose': 'Read-only media metadata and stream inspection',
  'upstream': {'MediaInfoLib': {'ref': mi_ref, 'commit': mi_rev}, 'ZenLib': {'ref': zen_ref, 'commit': zen_rev, 'linkage': 'static'}},
  'public_headers': headers, 'exported_c_api_symbols': [s[1:] for s in api],
  'verified': ['C API opened synthetic WAV and read General/Format', 'C++ consumer compiled and ran', 'Swift import and C API allocation', 'Mach-O architecture and dependency audit'],
  'not_verified': ['all upstream API declarations exported', 'real-world media format coverage', 'clean Xcode project without custom header search paths', 'distribution license compliance'],
  'routing': {'inspect': 'ModMediaInfo', 'write_general_metadata': 'ModFFmpeg (supported formats only)', 'write_matroska_metadata': 'ModMKV (supported edits only)', 'playback': 'ModMPV', 'hap_avfoundation': 'HapInAVFoundation'},
  'metadata_writing': False, 'release_approved': False
}
(out/'capabilities.json').write_text(json.dumps(data, indent=2)+'\n')
files = {
'AGENTS.md': f'''# ModMediaInfo — AI Agent Instructions

Use ModMediaInfo for **read-only media inspection** on macOS {min_os}+ arm64.

## Framework routing
- Inspection and stream metadata reads: ModMediaInfo.
- General metadata writes: ModFFmpeg, where the format and field are supported.
- Matroska-specific metadata edits: ModMKV, within its verified limits.
- Playback/rendering: ModMPV; Hap via AVFoundation: HapInAVFoundation.

## API
Swift: `import ModMediaInfo`; use `MediaInfoA_New`, `MediaInfoA_Open`, `MediaInfoA_Get`, `MediaInfoA_Close`, `MediaInfoA_Delete`.
C: use packaged `MediaInfoDLL/MediaInfoDLL_Static.h` with appropriate header search path.
C++: use `MediaInfo/MediaInfo.h` and `MediaInfoLib::MediaInfo`.
Check the bundled public headers and exported-symbol inventory before assuming a function is available.

## Evidence and limitations
C WAV parsing, C++ construction and Swift import are smoke-tested. Complete API export coverage, real-world format coverage and license compliance are **not yet verified**. This is not a metadata-writing framework.
''',
'FRAMEWORK_INFO.md': f'''# ModMediaInfo Framework Capabilities

**Purpose:** Inspect media containers, technical stream information and metadata. Read-only.

**Sources:** MediaInfoLib {mi_ref} (`{mi_rev}`); ZenLib {zen_ref} (`{zen_rev}`), statically linked.
**Platform:** macOS {min_os}+ arm64. **Framework version:** {version}.
**Interfaces:** C `MediaInfoA_*`, MediaInfoLib C++ public headers, Swift import through Clang module.
**Verified:** Synthetic WAV format read via C, C++ object construction, Swift API allocation, dependency/architecture checks.
**Not verified:** All formats, every public C++ symbol, release licensing, clean Xcode application integration.
**Writes:** Not supported by this framework contract. Use ModFFmpeg or ModMKV as appropriate.
''',
'README.md': f'''# ModMediaInfo — Developer Integration

MediaInfoLib-based, read-only media inspection for macOS {min_os}+ arm64, with static ZenLib.

```swift
import ModMediaInfo
if let handle = MediaInfoA_New() {{
    defer {{ MediaInfoA_Delete(handle) }}
    // Open a file with MediaInfoA_Open, inspect using MediaInfoA_Get,
    // then call MediaInfoA_Close before deleting the handle.
}}
```

See `AGENTS.md` for framework routing and `capabilities.json` for verified features, pinned source revisions and exported C API symbols. Build output includes framework/XCFramework, build.log, linkage and Mach-O reports, source archive, header inventory and validation report. Passing smoke tests do not establish release approval.
'''
}
for name, content in files.items():
    (out/name).write_text(content)
for name in [*files, 'capabilities.json', 'ModMediaInfo-header-inventory.json', 'ModMediaInfo-exported-symbols.txt']:
    (docs/name).write_bytes((out/name).read_bytes())
print(f'PASS: generated agent documentation ({len(headers)} headers, {len(api)} exported C API symbols)')
PY_DOCS
FRAMEWORK_NAME=ModMediaInfo
sign_framework_and_report "$FRAMEWORK" "$OUT/ModMediaInfo-signing.txt" "$CODESIGN_IDENTITY" "$SIGN"
if [[ "$XCFRAMEWORK" == 1 ]]; then
xcodebuild -create-xcframework \
    -framework "$FRAMEWORK" \
    -output "$XCFRAMEWORK_PATH"
plutil -lint "$XCFRAMEWORK_PATH/Info.plist"
python3 - "$XCFRAMEWORK_PATH" "$BUNDLE_ID" "$MIN_MACOS" <<'PY_XCFRAMEWORK'
import os
import plistlib
import sys
root, bundle_id, minimum = sys.argv[1:]
with open(os.path.join(root, "Info.plist"), "rb") as source:
    info = plistlib.load(source)
slices = info.get("AvailableLibraries", [])
assert len(slices) == 1, f"expected one XCFramework slice, got {len(slices)}"
entry = slices[0]
assert entry.get("SupportedPlatform") == "macos", entry
assert entry.get("SupportedArchitectures") == ["arm64"], entry
framework = os.path.join(root, entry["LibraryIdentifier"], entry["LibraryPath"])
with open(os.path.join(framework, "Versions", "A", "Resources", "Info.plist"), "rb") as source:
    framework_info = plistlib.load(source)
assert framework_info["CFBundleIdentifier"] == bundle_id
assert framework_info["LSMinimumSystemVersion"] == minimum
assert os.path.isfile(os.path.join(framework, "Versions", "A", "ModMediaInfo"))
print("PASS: XCFramework macOS arm64 slice and framework metadata verified")
PY_XCFRAMEWORK
if [[ "$SIGN" == 1 ]]; then
codesign --verify --deep --strict --verbose=2 \
    "$XCFRAMEWORK_PATH/macos-arm64/ModMediaInfo.framework"
fi
fi
if [[ "$XCFRAMEWORK" == 1 ]]; then
    sign_xcframework_and_report "$XCFRAMEWORK_PATH" "$OUT/ModMediaInfo-signing.txt" "$CODESIGN_IDENTITY" "$SIGN"
fi

{
    printf 'MediaInfoLib ref: %s\nMediaInfoLib commit: %s\n' "$MEDIAINFO_REF" "$MEDIAINFO_REVISION"
    printf 'ZenLib ref: %s\nZenLib commit: %s\n' "$ZENLIB_REF" "$ZENLIB_REVISION"
    printf 'Architecture: arm64 (macOS)\nMinimum macOS: %s\n' "$MIN_MACOS"
    
    git -C "$MEDIAINFO_SOURCE" archive --format=tar --prefix=MediaInfoLib/ "$MEDIAINFO_REVISION" | \
      gzip -n >"$WORK/MediaInfoLib-source.tar.gz"
    git -C "$ZENLIB_SOURCE" archive --format=tar --prefix=ZenLib/ "$ZENLIB_REVISION" | \
      gzip -n >"$WORK/ZenLib-source.tar.gz"
    
    mkdir -p "$WORK/source-compliance"
    cp "$WORK/MediaInfoLib-source.tar.gz" "$WORK/ZenLib-source.tar.gz" "$WORK/source-compliance/"
    cp "${BASH_SOURCE[0]}" "$OUT/build.log" \
      "$FRAMEWORK/Versions/A/Resources/Legal/BUILD_INFO.txt" \
      "$OUT/AGENTS.md" "$OUT/FRAMEWORK_INFO.md" "$OUT/capabilities.json" \
      "$WORK/source-compliance/"
    if [[ -f "$ROOT/README.md" ]]; then
      cp "$ROOT/README.md" "$WORK/source-compliance/"
    fi
    
    (
      cd "$WORK/source-compliance"
      shasum -a 256 ./* >SHA256SUMS.txt
    )
    tar -C "$WORK" -czf "$OUT/ModMediaInfo-source-compliance.tar.gz" source-compliance
    rm -rf "$WORK/source-compliance"
}
cat >"$OUT/ModMediaInfo-validation.txt" <<EOF_VALIDATION
PASS: pinned MediaInfoLib and ZenLib source revisions recorded
PASS: all six MediaInfoLib CMake-declared public headers match source byte-for-byte
PASS: installed MediaInfo and ZenLib headers inventoried with SHA-256
PASS: C API exports validated and standalone C consumer parsed a generated WAV
PASS: standalone C++ consumer compiled, linked, and ran
PASS: standalone Swift consumer imported ModMediaInfo, linked, and ran
PASS: agent-readable documentation and capability manifest generated before signing
PASS: static ZenLib archive built and framework has no external ZenLib dependency
PASS: framework architecture, macOS platform, install name, and dependency paths checked
$(if [[ "$XCFRAMEWORK" == 1 ]]; then echo 'PASS: one-slice macOS arm64 XCFramework metadata verified'; else echo 'SKIPPED: XCFramework creation disabled'; fi)
EOF_VALIDATION
echo "Framework: $FRAMEWORK"
[[ "$XCFRAMEWORK" != 1 ]] || echo "XCFramework: $XCFRAMEWORK_PATH"
echo "Source/compliance archive: $OUT/ModMediaInfo-source-compliance.tar.gz"
echo "Validation report: $OUT/ModMediaInfo-validation.txt"

echo "PASS: ModMediaInfo engineering packaging complete"


# Embedded agent documentation generation
_DOCS_OUT="${OUT:-$(pwd)/output-ModMediaInfo}"
mkdir -p "$_DOCS_OUT"
python3 - "$_DOCS_OUT" "$(basename "${BASH_SOURCE[0]}")" <<'EMBEDDED_DOCS'
import sys, base64, tempfile
from pathlib import Path

out = Path(sys.argv[1])
builder = sys.argv[2]
generator = base64.b64decode('IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJHZW5lcmF0ZSBjb25zaXN0ZW50IGJ1aWxkIGFuZCBhZ2VudCBlbnRyeXBvaW50IGRvY3Mgd2l0aG91dCBjaGFuZ2luZyBidWlsZCBhcnRpZmFjdHMuIiIiCmltcG9ydCBhcmdwYXJzZSwgcGF0aGxpYiwgc2h1dGlsLCBzeXMKcD1hcmdwYXJzZS5Bcmd1bWVudFBhcnNlcigpCnAuYWRkX2FyZ3VtZW50KCctLWZyYW1ld29yaycscmVxdWlyZWQ9VHJ1ZSkKcC5hZGRfYXJndW1lbnQoJy0tb3V0JyxyZXF1aXJlZD1UcnVlKQpwLmFkZF9hcmd1bWVudCgnLS1idWlsZGVyJyxyZXF1aXJlZD1UcnVlKQpwLmFkZF9hcmd1bWVudCgnLS1pbnN0cnVjdGlvbnMnLGRlZmF1bHQ9JycpCmE9cC5wYXJzZV9hcmdzKCk7IG91dD1wYXRobGliLlBhdGgoYS5vdXQpOyBvdXQubWtkaXIocGFyZW50cz1UcnVlLGV4aXN0X29rPVRydWUpCm5hbWU9YS5mcmFtZXdvcmsKYnVpbGRlcj1wYXRobGliLlBhdGgoYS5idWlsZGVyKS5uYW1lCnNvdXJjZT17J0hhcEluQVZGb3VuZGF0aW9uJzonaHR0cHM6Ly9naXRodWIuY29tL2ZsZXh2aXN1YWwvaGFwLWluLWF2Zm91bmRhdGlvbid9LmdldChuYW1lLCdTZWUgdGhlIHBpbm5lZCBzb3VyY2UgcmVmZXJlbmNlcyBhbmQgc291cmNlLWNvbXBsaWFuY2UgYXJjaGl2ZSBzdXBwbGllZCB3aXRoIHRoaXMgcmVsZWFzZS4nKQppbnM9b3V0L2Yne25hbWV9Lmluc3RydWN0aW9ucy5tZCcKaWYgYS5pbnN0cnVjdGlvbnMgYW5kIHBhdGhsaWIuUGF0aChhLmluc3RydWN0aW9ucykuaXNfZmlsZSgpOgogICAgc2h1dGlsLmNvcHkyKGEuaW5zdHJ1Y3Rpb25zLGlucykKZXh0cmE9Zic0LiBSZWFkIGB7aW5zLm5hbWV9YCBmb3IgZnJhbWV3b3JrLXNwZWNpZmljIGludGVncmF0aW9uIGFuZCBNZXRhbC9jb2RlYyBjb25zdHJhaW50cy5cbicgaWYgaW5zLmlzX2ZpbGUoKSBlbHNlICc0LiBDb25zdWx0IHRoZSBmcmFtZXdvcmsgcHVibGljIGhlYWRlcnMgYW5kIGV4aXN0aW5nIGludGVncmF0aW9uIG5vdGVzOyBubyBzZXBhcmF0ZSBpbnRlZ3JhdGlvbiBndWlkZSB3YXMgc3VwcGxpZWQuXG4nCihvdXQvJ0FHRU5UUy5tZCcpLndyaXRlX3RleHQoZicnJyMge25hbWV9IOKAlCBBZ2VudCBpbnN0cnVjdGlvbnMKCkJlZm9yZSBpbnRlZ3JhdGluZywgbW9kaWZ5aW5nLCBkaXN0cmlidXRpbmcgb3IgcmVidWlsZGluZzoKCjEuIFJlYWQgYEJVSUxESU5HLm1kYCBmb3IgcmVwcm9kdWNpYmxlIHNvdXJjZS1idWlsZCBzdGVwcyBhbmQgcHJlcmVxdWlzaXRlcy4KMi4gUmVhZCBgUkVBRE1FLm1kYCBhbmQgYEZSQU1FV09SS19JTkZPLm1kYCB3aGVuIHByZXNlbnQuCjMuIENoZWNrIGBjYXBhYmlsaXRpZXMuanNvbmAgYW5kIHRoZSB2YWxpZGF0aW9uLCBoZWFkZXIsIHN5bWJvbCBhbmQgbGlua2FnZSByZXBvcnRzOyBkbyBub3QgaW5mZXIgdW5zdXBwb3J0ZWQgQVBJcy4Ke2V4dHJhfTUuIFRyZWF0IHRoZSAqKnNoaXBwZWQgcHVibGljIGhlYWRlcnMgYW5kIG1hdGNoaW5nIGJpbmFyeSoqIGFzIGF1dGhvcml0YXRpdmUgZm9yIHRoaXMgcmVsZWFzZS4KNi4gUHJlc2VydmUgZHluYW1pYyBmcmFtZXdvcmsgZW1iZWRkaW5nLCBgQHJwYXRoYCwgcmVwbGFjZWFiaWxpdHkgYW5kIHRoZSBob3N0IGFwcGxpY2F0aW9uJ3Mgc2lnbmluZyByZXF1aXJlbWVudHMuCjcuIFJlYWQgdGhlIGFwcGxpY2FibGUgbGljZW5zZSBub3RpY2VzIGFuZCBleGFjdCBzb3VyY2UgcmV2aXNpb24gcmVjb3JkcyBiZWZvcmUgZGlzdHJpYnV0aW9uLgoKQnVpbGQgc2NyaXB0OiBge2J1aWxkZXJ9YCAoc2hpcHBlZCBhbG9uZ3NpZGUgdGhpcyByZWxlYXNlIGRvY3VtZW50YXRpb24sIG5vdCBuZWNlc3NhcmlseSBpbnNpZGUgdGhlIG91dHB1dCBkaXJlY3RvcnkpLgpTb3VyY2U6IHtzb3VyY2V9CicnJykKKG91dC8nQlVJTERJTkcubWQnKS53cml0ZV90ZXh0KGYnJycjIEJ1aWxkaW5nIHtuYW1lfSBmcm9tIHNvdXJjZQoKIyMgUHJlcmVxdWlzaXRlcwoKLSBBbiBBcHBsZSBTaWxpY29uIE1hYyB3aXRoIFhjb2RlIGFuZCB0aGUgbWFjT1MgU0RLIHN1cHBvcnRlZCBieSB0aGlzIGJ1aWxkZXIuCi0gWGNvZGUgY29tbWFuZC1saW5lIHRvb2xzIHNlbGVjdGVkIChgeGNvZGUtc2VsZWN0IC1wYCksIEdpdCBhbmQgdGhlIGNvbW1hbmQtbGluZSB1dGlsaXRpZXMgdXNlZCBieSB0aGUgYnVpbGRlci4KLSBJbnRlcm5ldCBhY2Nlc3MgdG8gZmV0Y2ggdGhlIGJ1aWxkZXIncyBwaW5uZWQgZGVwZW5kZW5jaWVzLCB1bmxlc3MgYWxyZWFkeSBjYWNoZWQuCgojIyBCdWlsZAoKUGxhY2UgYHtidWlsZGVyfWAgaW4gdGhlIGludGVuZGVkIE1vZEZyYW1ld29ya3Mgd29ya2luZyBkaXJlY3RvcnkgYW5kIHJ1bjoKCmBgYGJhc2gKY2htb2QgK3ggIntidWlsZGVyfSIKLi8ie2J1aWxkZXJ9IgpgYGAKClRoaXMgZG9jdW1lbnRhdGlvbiBpcyBnZW5lcmF0ZWQgZm9yIHRoZSAqKnNwZWNpZmljIHNjcmlwdCB2ZXJzaW9uKiogbmFtZWQgYWJvdmUuIFJldmlldyB0aGF0IHNjcmlwdCdzIGNvbmZpZ3VyYWJsZSBlbnZpcm9ubWVudCB2YXJpYWJsZXMgYW5kIGNsZWFuL3JlYnVpbGQgb3B0aW9ucyBiZWZvcmUgdXNpbmcgdGhlbTsgbm8gY29tbW9uIGZsYWdzIGFyZSBhc3N1bWVkIGFjcm9zcyBidWlsZGVycy4KCiMjIE91dHB1dHMgYW5kIGNoZWNrcwoKLSBJbnNwZWN0IGBidWlsZC5sb2dgIGZvciBhY3R1YWwgY29tcGlsYXRpb24gc3VjY2VzczsgZXhpc3RlbmNlIG9mIGEgZnJhbWV3b3JrIGZvbGRlciBhbG9uZSBpcyBub3QgcHJvb2Ygb2YgYSBmcmVzaCBidWlsZC4KLSBWZXJpZnkgdGhlIGZyYW1ld29yayBhbmQgWENGcmFtZXdvcmsgZGlyZWN0b3JpZXMgaWYgdGhpcyBidWlsZCBlbmFibGVzIGJvdGguCi0gQ2hlY2sgYCotdmFsaWRhdGlvbi50eHRgLCBgKi1saW5rYWdlLnR4dGAsIGAqLW1hY2gtby1idWlsZC50eHRgLCBgKi1oZWFkZXItaW52ZW50b3J5Lmpzb25gLCBgKi1leHBvcnRlZC1zeW1ib2xzLnR4dGAsIGFuZCBgY2FwYWJpbGl0aWVzLmpzb25gIHdoZW4gZ2VuZXJhdGVkLgotIFZlcmlmeSBzaWduYXR1cmVzIHdpdGggYGNvZGVzaWduIC0tdmVyaWZ5IC0tc3RyaWN0IC0tdmVyYm9zZT0yYCBvbiB0aGUgZnJhbWV3b3JrIGFuZCBYQ0ZyYW1ld29yay4gQSBkZXZlbG9wbWVudCBhZC1ob2Mgc2lnbmF0dXJlIGlzICoqbm90KiogYSBEZXZlbG9wZXIgSUQgc2lnbmF0dXJlIG9yIG5vdGFyaXphdGlvbi4KLSBWZXJpZnkgdGhlIGFyY2hpdGVjdHVyZSB3aXRoIGB4Y3J1biBsaXBvIC1pbmZvYCBhbmQgbWluaW11bSBkZXBsb3ltZW50IHZlcnNpb24gd2l0aCBgeGNydW4gdnRvb2wgLXNob3ctYnVpbGRgIG9uIHRoZSBmcmFtZXdvcmsgZXhlY3V0YWJsZS4KLSBVc2UgZXhhY3QgcmV2aXNpb25zIGluIHRoZSBnZW5lcmF0ZWQgZGVwZW5kZW5jeS9zb3VyY2UgbWFuaWZlc3QgZm9yIHJlcHJvZHVjaWJpbGl0eTsgZG8gbm90IHN1YnN0aXR1dGUgY3VycmVudCBicmFuY2ggSEVBRC4KCiMjIERpc3RyaWJ1dGlvbgoKVGhlIHNvdXJjZSByZXBvc2l0b3J5IHJlZmVyZW5jZSBpczoge3NvdXJjZX0KClRoZSBmcmFtZXdvcmsgaXMgaW50ZW5kZWQgdG8gcmVtYWluIGR5bmFtaWNhbGx5IHJlcGxhY2VhYmxlLiBVc2VycyBvZiBhbiBlbWJlZGRlZCBmcmFtZXdvcmsgbWF5IG5lZWQgdG8gcmUtc2lnbiB0aGVpciBhcHBsaWNhdGlvbiBhZnRlciByZXBsYWNlbWVudCwgc3ViamVjdCB0byBpdHMgcnVudGltZSBhbmQgZGlzdHJpYnV0aW9uIHJlc3RyaWN0aW9ucy4gUHVibGlzaGVkIHNvdXJjZSBhbmQgcmVwbGFjZWFiaWxpdHkgYXJlIGltcG9ydGFudCBidXQgZG8gbm90IGJ5IHRoZW1zZWx2ZXMgY2VydGlmeSBsaWNlbnNlIGNvbXBsaWFuY2UuIFJldmlldyB0aGUgZXhhY3Qgbm90aWNlcyBhbmQgY29ycmVzcG9uZGluZyBzb3VyY2UvYnVpbGQgbWF0ZXJpYWxzLgoKIyMgVHJvdWJsZXNob290aW5nCgpJZiBhIGNsZWFuIGJ1aWxkIGZhaWxzLCBrZWVwIGBidWlsZC5sb2dgIGFuZCB0aGUgcmVwb3J0ZWQgdG9vbGNoYWluIHZlcnNpb24sIGluc3BlY3QgdGhlIGZpcnN0IGZhaWx1cmUgKG5vdCBqdXN0IHRoZSBsYXN0IGVycm9yKSwgYW5kIGNoZWNrIHRoZSBwaW5uZWQgZGVwZW5kZW5jeSBjaGVja291dHMuIERvIG5vdCBzaWxlbnRseSBjaGFuZ2UgcGlubmVkIHJldmlzaW9ucyB0byBtYWtlIGEgZmFpbGluZyBidWlsZCBwYXNzLgonJycpCnByaW50KGYnRG9jdW1lbnRhdGlvbiBnZW5lcmF0ZWQ6IHtvdXR9L0FHRU5UUy5tZCBhbmQgQlVJTERJTkcubWQnICsgKGYnIChpbnRlZ3JhdGlvbiBpbnN0cnVjdGlvbnMgaW5jbHVkZWQpJyBpZiBpbnMuaXNfZmlsZSgpIGVsc2UgJycpKQo=')

sys.argv = ["modframeworks_docs.py",
            "--framework", 'ModMediaInfo',
            "--out", str(out),
            "--builder", builder]
exec(compile(generator, "embedded_docs.py", "exec"))
EMBEDDED_DOCS
