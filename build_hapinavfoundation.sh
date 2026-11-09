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
    work_dir="$script_root/.build-HapInAVFoundation-framework"
    output_dir="$script_root/output-HapInAVFoundation"
    # Fail closed if the workspace/output are symlinks, even if they point inside the root.
    for target in "$work_dir" "$output_dir"; do
        if [[ -L "$target" ]]; then echo "ERROR: refusing symlinked directory: $target" >&2; return 2; fi
        if [[ -e "$target" && ! -d "$target" ]]; then echo "ERROR: expected directory: $target" >&2; return 2; fi
    done
    work_size='not present'; output_size='not present'
    [[ ! -d "$work_dir" ]] || work_size="$(du -sh "$work_dir" 2>/dev/null | awk '{print $1}')"
    [[ ! -d "$output_dir" ]] || output_size="$(du -sh "$output_dir" 2>/dev/null | awk '{print $1}')"
    printf '\n%s — disk-space management\n' 'HapInAVFoundation'
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

# Portable, pinned-source HapInAVFoundation.framework builder v8 (macOS arm64)
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

IFS=$'\n\t'
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$ROOT/.build-HapInAVFoundation-framework}"
OUT="${OUT:-$ROOT/output-HapInAVFoundation}"
MIN_MACOS="${MIN_MACOS:-15.4}"
SIGN_IDENTITY="${SIGN_IDENTITY:-${CODESIGN_IDENTITY:-}}"
SIGN="${SIGN:-1}"
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
[[ "$SIGN" == 0 || "$SIGN" == 1 ]] || { echo "SIGN must be 0 or 1" >&2; exit 2; }
mkdir -p "$WORK" "$OUT"
# Remove release ZIPs from older builder versions; keep framework directories.
rm -f "$OUT/HapInAVFoundation.framework.zip" "$OUT/HapInAVFoundation.xcframework.zip"
WORK="$(cd "$WORK" && pwd)"; OUT="$(cd "$OUT" && pwd)"
exec > >(tee "$OUT/build.log") 2>&1
trap 'echo "FAILED at line $LINENO; see $OUT/build.log" >&2' ERR
for tool in git xcodebuild xcrun ditto otool codesign shasum nm python3 tar; do command -v "$tool" >/dev/null || { echo "Missing: $tool" >&2; exit 1; }; done
fetch() {
  local name="$1" url="$2" rev="$3" path="$WORK/$1"
  if [[ ! -e "$path" ]]; then
    echo "Cloning $name"
    git clone "$url" "$path"  # Normal checkout: avoids false dirty status from --no-checkout.
  fi
  [[ -d "$path/.git" ]] || { echo "Not a git checkout: $path" >&2; exit 1; }
  if [[ -n "$(git -C "$path" status --porcelain --untracked-files=normal)" ]]; then
    echo "Checkout has local changes; refusing to overwrite: $path" >&2
    exit 1
  fi
  git -C "$path" fetch --no-tags origin "$rev" || git -C "$path" fetch --no-tags origin
  git -C "$path" -c advice.detachedHead=false checkout --detach "$rev"
  [[ "$(git -C "$path" rev-parse HEAD)" == "$rev" ]] || { echo "Revision mismatch: $name" >&2; exit 1; }
}
echo '========== PHASE 1/2: DOWNLOAD ALL SOURCES =========='
fetch hap-in-avfoundation https://github.com/flexvisual/hap-in-avfoundation.git ddef0b163bd2781f54d55de30014c4173fce2f10
fetch snappy https://github.com/google/snappy.git 946606459314e55d029c85f9a8c46f8809467f0f
fetch hap https://github.com/Vidvox/hap.git d847f6bbd3be88575dd4ef33a877243780e3be76
fetch libsquish https://github.com/arves100/libsquish.git 56c75ba7d309fa486a08522da70d3782c347b8ee
fetch bc7enc_rdo https://github.com/richgel999/bc7enc_rdo.git b9438627eef73a1157e84201b6fa6eb2ffd6d9f0
# Xcode resolves all project-level local Swift packages even when building only the framework.
# Sparkle is used by companion apps; it is NOT linked into HapInAVFoundation.framework.
fetch Sparkle https://github.com/sparkle-project/Sparkle.git 14fdbf28dc7c6fd8741a144bff517ef86572e6c2
echo '========== VERIFY ALL SOURCES BEFORE BUILD =========='
for repo in hap-in-avfoundation snappy hap libsquish bc7enc_rdo Sparkle; do
  [[ -d "$WORK/$repo/.git" ]] || { echo "Missing Git checkout: $repo" >&2; exit 1; }
  echo "Ready: $repo ($(git -C "$WORK/$repo" rev-parse --short HEAD))"
done
# The Xcode project references sibling codec source trees via relative paths.
# Keep all five repositories directly under WORK so ../snappy, ../hap,
# ../libsquish and ../bc7enc_rdo resolve from the framework checkout.
for required in "$WORK/hap/source/hap.c" "$WORK/libsquish/squish.h" "$WORK/bc7enc_rdo/bc7enc.cpp" "$WORK/snappy/CMakeLists.txt" "$WORK/Sparkle/Package.swift"; do
  [[ -f "$required" ]] || { echo "Missing dependency source: $required" >&2; exit 1; }
done
PROJECT="$WORK/hap-in-avfoundation/HapInAVFoundation.xcodeproj"
[[ -d "$PROJECT" ]] || { echo "Missing Xcode project: $PROJECT" >&2; exit 1; }
# Only the codec framework target; never build or modify companion applications.
echo 'All six repositories downloaded and validated. No downloads remain.'
echo '========== PHASE 2/2: BUILD FRAMEWORK ONLY =========='
BUILD_DIR="$WORK/products"
mkdir -p "$BUILD_DIR"
xcodebuild build -project "$PROJECT" -target HapInAVFoundation -configuration Release \
  -sdk macosx -arch arm64 \
  SYMROOT="$WORK/products" OBJROOT="$WORK/objects" \
  MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS" ONLY_ACTIVE_ARCH=NO \
  CONFIGURATION_BUILD_DIR="$BUILD_DIR" CODE_SIGNING_ALLOWED=NO
SRC="$BUILD_DIR/HapInAVFoundation.framework"
[[ -d "$SRC" ]] || { echo "Framework not produced: $SRC" >&2; exit 1; }
DEST="$OUT/HapInAVFoundation.framework"
rm -rf "$DEST"
ditto "$SRC" "$DEST"
BIN="$DEST/Versions/A/HapInAVFoundation"
[[ -f "$BIN" ]] || BIN="$DEST/HapInAVFoundation"
[[ -f "$BIN" ]] || { echo 'Framework binary missing' >&2; exit 1; }
xcrun lipo -info "$BIN"
otool -L "$BIN" | tee "$OUT/linkage.txt"
if grep -Eiq 'Sparkle.framework|/opt/homebrew/|/usr/local/' "$OUT/linkage.txt"; then
  echo 'Unexpected external runtime linkage detected' >&2; exit 1
fi
echo '========== SIGN FRAMEWORK AND XCFRAMEWORK =========='
FRAMEWORK_NAME=HapInAVFoundation
sign_framework_and_report "$DEST" "$OUT/HapInAVFoundation-signing.txt" "$SIGN_IDENTITY" "$SIGN"
XC="$OUT/HapInAVFoundation.xcframework"
rm -rf "$XC"
xcodebuild -create-xcframework -framework "$DEST" -output "$XC"
sign_xcframework_and_report "$XC" "$OUT/HapInAVFoundation-signing.txt" "$SIGN_IDENTITY" "$SIGN"
if [[ "$SIGN" == 1 ]]; then
  codesign -dv --verbose=2 "$DEST" 2>&1 | tee "$OUT/framework-signature.txt"
  codesign -dv --verbose=2 "$XC" 2>&1 | tee "$OUT/xcframework-signature.txt"
fi
echo '========== GENERATE STANDARD MODFRAMEWORKS REPORTS =========='
cat > "$OUT/dependency-revisions.txt" <<MANIFEST
hap-in-avfoundation ddef0b163bd2781f54d55de30014c4173fce2f10
snappy 946606459314e55d029c85f9a8c46f8809467f0f
hap d847f6bbd3be88575dd4ef33a877243780e3be76
libsquish 56c75ba7d309fa486a08522da70d3782c347b8ee
bc7enc_rdo b9438627eef73a1157e84201b6fa6eb2ffd6d9f0
Sparkle 14fdbf28dc7c6fd8741a144bff517ef86572e6c2
MANIFEST

nm -gU "$BIN" > "$OUT/HapInAVFoundation-exported-symbols.txt"
{
  file "$BIN"
  xcrun lipo -info "$BIN"
  otool -hv "$BIN"
  xcrun vtool -show-build "$BIN" || true
} > "$OUT/HapInAVFoundation-mach-o-build.txt" 2>&1
cp "$OUT/linkage.txt" "$OUT/HapInAVFoundation-linkage.txt"

python3 - "$DEST" "$OUT" "$MIN_MACOS" "$SIGN_IDENTITY" <<'PY_REPORT'
import json, pathlib, plistlib, sys
framework, output, minimum = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
headers = sorted(str(p.relative_to(framework)) for p in framework.rglob('*.h'))
modules = sorted(str(p.relative_to(framework)) for p in framework.rglob('module.modulemap'))
resources = sorted(str(p.relative_to(framework)) for p in framework.rglob('*') if p.is_file() and ('metal' in p.name.lower() or p.suffix in ('.metallib', '.air')))
(output/'HapInAVFoundation-header-inventory.json').write_text(json.dumps({'framework':'HapInAVFoundation','public_header_candidates':headers,'module_maps':modules,'metal_resources':resources},indent=2)+'\n')
info = {}
for candidate in (framework/'Resources/Info.plist', framework/'Versions/A/Resources/Info.plist', framework/'Info.plist'):
    if candidate.exists():
        with candidate.open('rb') as f: info=plistlib.load(f)
        break
caps = {'framework':'HapInAVFoundation','platform':'macOS','architecture':'arm64','requested_minimum_macos':minimum,'bundle_identifier':info.get('CFBundleIdentifier'),'bundle_version':info.get('CFBundleVersion'),'public_header_count':len(headers),'module_map_count':len(modules),'metal_resource_count':len(resources),'ad_hoc_signed':(sys.argv[4] == '-') if len(sys.argv)>4 else False,'xcframework':True,'codec_support':'Verify against matching public headers and compatibility documentation; HDR is not assumed complete.'}
(output/'capabilities.json').write_text(json.dumps(caps,indent=2)+'\n')
PY_REPORT

cat > "$OUT/AGENTS.md" <<'AGENT'
# HapInAVFoundation integration agent

Use the installed public headers and matching repository README as API truth.
This release is a dynamically linked macOS arm64 framework with an XCFramework wrapper.
Embed the framework in the app and configure @rpath; ad-hoc signatures are for local builds; verify app Team ID compatibility.
Do not assume Hap HDR or BC7 features beyond those validated in this binary.
See HapInAVFoundation.instructions.md when provided.
Source: https://github.com/flexvisual/hap-in-avfoundation
AGENT
cat > "$OUT/FRAMEWORK_INFO.md" <<'INFO'
# HapInAVFoundation

- macOS arm64 dynamic framework, minimum macOS 15.4 (verify built binary).
- Framework and single-slice XCFramework use the configured signing identity (default: ad-hoc).
- Xcode client apps should embed and sign the dynamic framework.
- Source: https://github.com/flexvisual/hap-in-avfoundation
- Exact revisions: dependency-revisions.txt
- API: installed framework public headers and matching README.
INFO
cat > "$OUT/README.md" <<'README'
# HapInAVFoundation build output

Use `HapInAVFoundation.framework` directly or `HapInAVFoundation.xcframework` in Xcode.
Both are directories, not ZIP archives. Sign the final host app after embedding.
See `AGENTS.md`, `FRAMEWORK_INFO.md`, `capabilities.json`, and validation reports.
The published source is https://github.com/flexvisual/hap-in-avfoundation;
see `dependency-revisions.txt` for the exact build revision.
README
INSTRUCTIONS="$ROOT/HapInAVFoundation.instructions.md"
if [[ ! -f "$INSTRUCTIONS" && -f "$ROOT/HapInAVFoundation.instructions(1).md" ]]; then
  INSTRUCTIONS="$ROOT/HapInAVFoundation.instructions(1).md"
fi
if [[ -f "$INSTRUCTIONS" ]]; then
  cp "$INSTRUCTIONS" "$OUT/HapInAVFoundation.instructions.md"
fi

# Preserve published source provenance and upstream license material in an archive.
# Archive tracked source snapshots, not .git directories or generated build outputs.
SOURCE_STAGE="$WORK/source-compliance-stage"
rm -rf "$SOURCE_STAGE"
mkdir -p "$SOURCE_STAGE"
for repo in hap-in-avfoundation snappy hap libsquish bc7enc_rdo Sparkle; do
  mkdir -p "$SOURCE_STAGE/$repo"
  git -C "$WORK/$repo" archive HEAD | tar -xf - -C "$SOURCE_STAGE/$repo"
done
cp "$OUT/dependency-revisions.txt" "$SOURCE_STAGE/dependency-revisions.txt"
cat > "$SOURCE_STAGE/SOURCE.md" <<'SOURCE'
This archive contains the exact tracked source snapshots used by the builder.
The canonical published framework source is https://github.com/flexvisual/hap-in-avfoundation.
See dependency-revisions.txt for exact upstream revisions.
This archive does not itself constitute a legal compliance determination.
SOURCE
COPYFILE_DISABLE=1 tar -czf "$OUT/HapInAVFoundation-source-compliance.tar.gz" -C "$SOURCE_STAGE" .
rm -rf "$SOURCE_STAGE"

{
  echo 'HapInAVFoundation validation'
  echo "Framework: $DEST"
  echo "XCFramework: $XC"
  echo "Requested minimum macOS: $MIN_MACOS"
  echo 'Framework signature:'
  if [[ "$SIGN" == 1 ]]; then codesign --verify --strict --verbose=2 "$DEST" 2>&1; fi
  echo 'XCFramework signature:'
  if [[ "$SIGN" == 1 ]]; then codesign --verify --strict --verbose=2 "$XC" 2>&1; fi
  echo 'Architecture:'
  xcrun lipo -info "$BIN"
  echo 'Install name:'
  otool -D "$BIN"
  echo 'XCFramework slices:'
  /usr/libexec/PlistBuddy -c 'Print :AvailableLibraries' "$XC/Info.plist" || true
} > "$OUT/HapInAVFoundation-validation.txt" 2>&1

(
  cd "$OUT"
  shasum -a 256 HapInAVFoundation-source-compliance.tar.gz > SHA256SUMS.txt
)
echo "SUCCESS: $DEST"
echo "SUCCESS: $XC"
echo 'Release folders, source compliance and ModFrameworks reports created; no framework ZIPs.'


# Embedded agent documentation generation
_DOCS_OUT="${OUT:-$(pwd)/output-HapInAVFoundation}"
mkdir -p "$_DOCS_OUT"
python3 - "$_DOCS_OUT" "$(basename "${BASH_SOURCE[0]}")" <<'EMBEDDED_DOCS'
import sys, base64, tempfile
from pathlib import Path

out = Path(sys.argv[1])
builder = sys.argv[2]
generator = base64.b64decode('IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJHZW5lcmF0ZSBjb25zaXN0ZW50IGJ1aWxkIGFuZCBhZ2VudCBlbnRyeXBvaW50IGRvY3Mgd2l0aG91dCBjaGFuZ2luZyBidWlsZCBhcnRpZmFjdHMuIiIiCmltcG9ydCBhcmdwYXJzZSwgcGF0aGxpYiwgc2h1dGlsLCBzeXMKcD1hcmdwYXJzZS5Bcmd1bWVudFBhcnNlcigpCnAuYWRkX2FyZ3VtZW50KCctLWZyYW1ld29yaycscmVxdWlyZWQ9VHJ1ZSkKcC5hZGRfYXJndW1lbnQoJy0tb3V0JyxyZXF1aXJlZD1UcnVlKQpwLmFkZF9hcmd1bWVudCgnLS1idWlsZGVyJyxyZXF1aXJlZD1UcnVlKQpwLmFkZF9hcmd1bWVudCgnLS1pbnN0cnVjdGlvbnMnLGRlZmF1bHQ9JycpCmE9cC5wYXJzZV9hcmdzKCk7IG91dD1wYXRobGliLlBhdGgoYS5vdXQpOyBvdXQubWtkaXIocGFyZW50cz1UcnVlLGV4aXN0X29rPVRydWUpCm5hbWU9YS5mcmFtZXdvcmsKYnVpbGRlcj1wYXRobGliLlBhdGgoYS5idWlsZGVyKS5uYW1lCnNvdXJjZT17J0hhcEluQVZGb3VuZGF0aW9uJzonaHR0cHM6Ly9naXRodWIuY29tL2ZsZXh2aXN1YWwvaGFwLWluLWF2Zm91bmRhdGlvbid9LmdldChuYW1lLCdTZWUgdGhlIHBpbm5lZCBzb3VyY2UgcmVmZXJlbmNlcyBhbmQgc291cmNlLWNvbXBsaWFuY2UgYXJjaGl2ZSBzdXBwbGllZCB3aXRoIHRoaXMgcmVsZWFzZS4nKQppbnM9b3V0L2Yne25hbWV9Lmluc3RydWN0aW9ucy5tZCcKaWYgYS5pbnN0cnVjdGlvbnMgYW5kIHBhdGhsaWIuUGF0aChhLmluc3RydWN0aW9ucykuaXNfZmlsZSgpOgogICAgc2h1dGlsLmNvcHkyKGEuaW5zdHJ1Y3Rpb25zLGlucykKZXh0cmE9Zic0LiBSZWFkIGB7aW5zLm5hbWV9YCBmb3IgZnJhbWV3b3JrLXNwZWNpZmljIGludGVncmF0aW9uIGFuZCBNZXRhbC9jb2RlYyBjb25zdHJhaW50cy5cbicgaWYgaW5zLmlzX2ZpbGUoKSBlbHNlICc0LiBDb25zdWx0IHRoZSBmcmFtZXdvcmsgcHVibGljIGhlYWRlcnMgYW5kIGV4aXN0aW5nIGludGVncmF0aW9uIG5vdGVzOyBubyBzZXBhcmF0ZSBpbnRlZ3JhdGlvbiBndWlkZSB3YXMgc3VwcGxpZWQuXG4nCihvdXQvJ0FHRU5UUy5tZCcpLndyaXRlX3RleHQoZicnJyMge25hbWV9IOKAlCBBZ2VudCBpbnN0cnVjdGlvbnMKCkJlZm9yZSBpbnRlZ3JhdGluZywgbW9kaWZ5aW5nLCBkaXN0cmlidXRpbmcgb3IgcmVidWlsZGluZzoKCjEuIFJlYWQgYEJVSUxESU5HLm1kYCBmb3IgcmVwcm9kdWNpYmxlIHNvdXJjZS1idWlsZCBzdGVwcyBhbmQgcHJlcmVxdWlzaXRlcy4KMi4gUmVhZCBgUkVBRE1FLm1kYCBhbmQgYEZSQU1FV09SS19JTkZPLm1kYCB3aGVuIHByZXNlbnQuCjMuIENoZWNrIGBjYXBhYmlsaXRpZXMuanNvbmAgYW5kIHRoZSB2YWxpZGF0aW9uLCBoZWFkZXIsIHN5bWJvbCBhbmQgbGlua2FnZSByZXBvcnRzOyBkbyBub3QgaW5mZXIgdW5zdXBwb3J0ZWQgQVBJcy4Ke2V4dHJhfTUuIFRyZWF0IHRoZSAqKnNoaXBwZWQgcHVibGljIGhlYWRlcnMgYW5kIG1hdGNoaW5nIGJpbmFyeSoqIGFzIGF1dGhvcml0YXRpdmUgZm9yIHRoaXMgcmVsZWFzZS4KNi4gUHJlc2VydmUgZHluYW1pYyBmcmFtZXdvcmsgZW1iZWRkaW5nLCBgQHJwYXRoYCwgcmVwbGFjZWFiaWxpdHkgYW5kIHRoZSBob3N0IGFwcGxpY2F0aW9uJ3Mgc2lnbmluZyByZXF1aXJlbWVudHMuCjcuIFJlYWQgdGhlIGFwcGxpY2FibGUgbGljZW5zZSBub3RpY2VzIGFuZCBleGFjdCBzb3VyY2UgcmV2aXNpb24gcmVjb3JkcyBiZWZvcmUgZGlzdHJpYnV0aW9uLgoKQnVpbGQgc2NyaXB0OiBge2J1aWxkZXJ9YCAoc2hpcHBlZCBhbG9uZ3NpZGUgdGhpcyByZWxlYXNlIGRvY3VtZW50YXRpb24sIG5vdCBuZWNlc3NhcmlseSBpbnNpZGUgdGhlIG91dHB1dCBkaXJlY3RvcnkpLgpTb3VyY2U6IHtzb3VyY2V9CicnJykKKG91dC8nQlVJTERJTkcubWQnKS53cml0ZV90ZXh0KGYnJycjIEJ1aWxkaW5nIHtuYW1lfSBmcm9tIHNvdXJjZQoKIyMgUHJlcmVxdWlzaXRlcwoKLSBBbiBBcHBsZSBTaWxpY29uIE1hYyB3aXRoIFhjb2RlIGFuZCB0aGUgbWFjT1MgU0RLIHN1cHBvcnRlZCBieSB0aGlzIGJ1aWxkZXIuCi0gWGNvZGUgY29tbWFuZC1saW5lIHRvb2xzIHNlbGVjdGVkIChgeGNvZGUtc2VsZWN0IC1wYCksIEdpdCBhbmQgdGhlIGNvbW1hbmQtbGluZSB1dGlsaXRpZXMgdXNlZCBieSB0aGUgYnVpbGRlci4KLSBJbnRlcm5ldCBhY2Nlc3MgdG8gZmV0Y2ggdGhlIGJ1aWxkZXIncyBwaW5uZWQgZGVwZW5kZW5jaWVzLCB1bmxlc3MgYWxyZWFkeSBjYWNoZWQuCgojIyBCdWlsZAoKUGxhY2UgYHtidWlsZGVyfWAgaW4gdGhlIGludGVuZGVkIE1vZEZyYW1ld29ya3Mgd29ya2luZyBkaXJlY3RvcnkgYW5kIHJ1bjoKCmBgYGJhc2gKY2htb2QgK3ggIntidWlsZGVyfSIKLi8ie2J1aWxkZXJ9IgpgYGAKClRoaXMgZG9jdW1lbnRhdGlvbiBpcyBnZW5lcmF0ZWQgZm9yIHRoZSAqKnNwZWNpZmljIHNjcmlwdCB2ZXJzaW9uKiogbmFtZWQgYWJvdmUuIFJldmlldyB0aGF0IHNjcmlwdCdzIGNvbmZpZ3VyYWJsZSBlbnZpcm9ubWVudCB2YXJpYWJsZXMgYW5kIGNsZWFuL3JlYnVpbGQgb3B0aW9ucyBiZWZvcmUgdXNpbmcgdGhlbTsgbm8gY29tbW9uIGZsYWdzIGFyZSBhc3N1bWVkIGFjcm9zcyBidWlsZGVycy4KCiMjIE91dHB1dHMgYW5kIGNoZWNrcwoKLSBJbnNwZWN0IGBidWlsZC5sb2dgIGZvciBhY3R1YWwgY29tcGlsYXRpb24gc3VjY2VzczsgZXhpc3RlbmNlIG9mIGEgZnJhbWV3b3JrIGZvbGRlciBhbG9uZSBpcyBub3QgcHJvb2Ygb2YgYSBmcmVzaCBidWlsZC4KLSBWZXJpZnkgdGhlIGZyYW1ld29yayBhbmQgWENGcmFtZXdvcmsgZGlyZWN0b3JpZXMgaWYgdGhpcyBidWlsZCBlbmFibGVzIGJvdGguCi0gQ2hlY2sgYCotdmFsaWRhdGlvbi50eHRgLCBgKi1saW5rYWdlLnR4dGAsIGAqLW1hY2gtby1idWlsZC50eHRgLCBgKi1oZWFkZXItaW52ZW50b3J5Lmpzb25gLCBgKi1leHBvcnRlZC1zeW1ib2xzLnR4dGAsIGFuZCBgY2FwYWJpbGl0aWVzLmpzb25gIHdoZW4gZ2VuZXJhdGVkLgotIFZlcmlmeSBzaWduYXR1cmVzIHdpdGggYGNvZGVzaWduIC0tdmVyaWZ5IC0tc3RyaWN0IC0tdmVyYm9zZT0yYCBvbiB0aGUgZnJhbWV3b3JrIGFuZCBYQ0ZyYW1ld29yay4gQSBkZXZlbG9wbWVudCBhZC1ob2Mgc2lnbmF0dXJlIGlzICoqbm90KiogYSBEZXZlbG9wZXIgSUQgc2lnbmF0dXJlIG9yIG5vdGFyaXphdGlvbi4KLSBWZXJpZnkgdGhlIGFyY2hpdGVjdHVyZSB3aXRoIGB4Y3J1biBsaXBvIC1pbmZvYCBhbmQgbWluaW11bSBkZXBsb3ltZW50IHZlcnNpb24gd2l0aCBgeGNydW4gdnRvb2wgLXNob3ctYnVpbGRgIG9uIHRoZSBmcmFtZXdvcmsgZXhlY3V0YWJsZS4KLSBVc2UgZXhhY3QgcmV2aXNpb25zIGluIHRoZSBnZW5lcmF0ZWQgZGVwZW5kZW5jeS9zb3VyY2UgbWFuaWZlc3QgZm9yIHJlcHJvZHVjaWJpbGl0eTsgZG8gbm90IHN1YnN0aXR1dGUgY3VycmVudCBicmFuY2ggSEVBRC4KCiMjIERpc3RyaWJ1dGlvbgoKVGhlIHNvdXJjZSByZXBvc2l0b3J5IHJlZmVyZW5jZSBpczoge3NvdXJjZX0KClRoZSBmcmFtZXdvcmsgaXMgaW50ZW5kZWQgdG8gcmVtYWluIGR5bmFtaWNhbGx5IHJlcGxhY2VhYmxlLiBVc2VycyBvZiBhbiBlbWJlZGRlZCBmcmFtZXdvcmsgbWF5IG5lZWQgdG8gcmUtc2lnbiB0aGVpciBhcHBsaWNhdGlvbiBhZnRlciByZXBsYWNlbWVudCwgc3ViamVjdCB0byBpdHMgcnVudGltZSBhbmQgZGlzdHJpYnV0aW9uIHJlc3RyaWN0aW9ucy4gUHVibGlzaGVkIHNvdXJjZSBhbmQgcmVwbGFjZWFiaWxpdHkgYXJlIGltcG9ydGFudCBidXQgZG8gbm90IGJ5IHRoZW1zZWx2ZXMgY2VydGlmeSBsaWNlbnNlIGNvbXBsaWFuY2UuIFJldmlldyB0aGUgZXhhY3Qgbm90aWNlcyBhbmQgY29ycmVzcG9uZGluZyBzb3VyY2UvYnVpbGQgbWF0ZXJpYWxzLgoKIyMgVHJvdWJsZXNob290aW5nCgpJZiBhIGNsZWFuIGJ1aWxkIGZhaWxzLCBrZWVwIGBidWlsZC5sb2dgIGFuZCB0aGUgcmVwb3J0ZWQgdG9vbGNoYWluIHZlcnNpb24sIGluc3BlY3QgdGhlIGZpcnN0IGZhaWx1cmUgKG5vdCBqdXN0IHRoZSBsYXN0IGVycm9yKSwgYW5kIGNoZWNrIHRoZSBwaW5uZWQgZGVwZW5kZW5jeSBjaGVja291dHMuIERvIG5vdCBzaWxlbnRseSBjaGFuZ2UgcGlubmVkIHJldmlzaW9ucyB0byBtYWtlIGEgZmFpbGluZyBidWlsZCBwYXNzLgonJycpCnByaW50KGYnRG9jdW1lbnRhdGlvbiBnZW5lcmF0ZWQ6IHtvdXR9L0FHRU5UUy5tZCBhbmQgQlVJTERJTkcubWQnICsgKGYnIChpbnRlZ3JhdGlvbiBpbnN0cnVjdGlvbnMgaW5jbHVkZWQpJyBpZiBpbnMuaXNfZmlsZSgpIGVsc2UgJycpKQo=')

instructions = base64.b64decode('LS0tCm5hbWU6IEhhcEluQVZGb3VuZGF0aW9uIEludGVncmF0aW9uCmRlc2NyaXB0aW9uOiAiVXNlIHdoZW4gaW50ZWdyYXRpbmcsIGVtYmVkZGluZywgZGVidWdnaW5nLCBvciBlbmNvZGluZyB3aXRoIEhhcEluQVZGb3VuZGF0aW9uLmZyYW1ld29yayBpbiBhIG1hY09TIGFwcC4gQ292ZXJzIEFWRm91bmRhdGlvbiBBUElzLCBNZXRhbCBwbGF5YmFjaywgcGFja2FnaW5nLCBzdXBwb3J0ZWQgcGxhdGZvcm0sIGFuZCBkaXN0cmlidXRpb24gbm90aWNlcy4iCi0tLQoKIyBIYXBJbkFWRm91bmRhdGlvbiBJbnRlZ3JhdGlvbgoKVXNlIHRoZSBmcmFtZXdvcmsncyBpbnN0YWxsZWQgcHVibGljIGhlYWRlcnMgYW5kIHRoZSBtYXRjaGluZyB2ZXJzaW9uJ3MgUkVBRE1FIGFzIHRoZSBBUEkgc291cmNlIG9mIHRydXRoLiBUaGUgdXBzdHJlYW0gaW1wbGVtZW50YXRpb24gYW5kIE1ldGFsIHRlc3QgYXBwIGFyZSB1c2VmdWwgZXhhbXBsZXMsIGJ1dCBkbyBub3QgY29weSBwcml2YXRlIGltcGxlbWVudGF0aW9uIGRldGFpbHMgaW50byBhIGNsaWVudCBhcHAuCgojIyBQbGF0Zm9ybSBhbmQgZW1iZWRkaW5nCgotIFRoZSBzdXBwbGllZCBmcmFtZXdvcmsgaXMgYSBkeW5hbWljYWxseSBsaW5rZWQgYGFybTY0YCBtYWNPUyBmcmFtZXdvcmsgd2l0aCBhIG1pbmltdW0gT1MgdmVyc2lvbiBvZiBtYWNPUyAxNS40LiBDaGVjayB0aGUgYWN0dWFsIGZyYW1ld29yaydzIGBJbmZvLnBsaXN0YCBhbmQgYmluYXJ5IGJlZm9yZSBzZXR0aW5nIGRlcGxveW1lbnQgdGFyZ2V0cyBvciBhcmNoaXRlY3R1cmUgYXNzdW1wdGlvbnMuCi0gTGluayBgSGFwSW5BVkZvdW5kYXRpb24uZnJhbWV3b3JrYCBhbmQgZW1iZWQvc2lnbiBpdCBpbiB0aGUgYXBwJ3MgYENvbnRlbnRzL0ZyYW1ld29ya3NgLiBMaW5raW5nIHdpdGhvdXQgZW1iZWRkaW5nIGlzIGluc3VmZmljaWVudCBmb3IgYW4gYXBwIHRoYXQgZG9lcyBub3Qgb3RoZXJ3aXNlIGluc3RhbGwgdGhlIGZyYW1ld29yay4KLSBFbnN1cmUgdGhlIGFwcCdzIHJ1bnBhdGhzIGluY2x1ZGUgYEBleGVjdXRhYmxlX3BhdGgvLi4vRnJhbWV3b3Jrc2A7IHByZXNlcnZlIHRoZSBmcmFtZXdvcmsncyBgQHJwYXRoL0hhcEluQVZGb3VuZGF0aW9uLmZyYW1ld29yay8uLi5gIGluc3RhbGwgbmFtZS4gU2lnbiB0aGUgYXBwIGFmdGVyIGVtYmVkZGluZyB0aGUgZnJhbWV3b3JrLgotIEltcG9ydCB0aGUgdW1icmVsbGEgaGVhZGVyIHdpdGggYCNpbXBvcnQgPEhhcEluQVZGb3VuZGF0aW9uL0hhcEluQVZGb3VuZGF0aW9uLmg+YC4gUHJlZmVyIHB1YmxpYyBmcmFtZXdvcmsgaGVhZGVycyBhbmQgc3ltYm9sczsgZG8gbm90IHJlbHkgb24gcHJpdmF0ZSBoZWFkZXJzIG9yIHN5bWJvbHMuCi0gRG8gbm90IGFkZCBTbmFwcHksIGxpYnNxdWlzaCwgYmM3ZW5jX3Jkbywgb3IgU3BhcmtsZSB0byB0aGUgY2xpZW50IGFwcCBtZXJlbHkgYmVjYXVzZSB0aGUgZnJhbWV3b3JrIHNvdXJjZSBidWlsZCB1c2VzIHRoZW0uIENoZWNrIHRoZSBmcmFtZXdvcmsgYmluYXJ5J3MgZHluYW1pYyBkZXBlbmRlbmNpZXMgZm9yIHRoZSBleGFjdCBzaGlwcGVkIGJ1aWxkLgoKIyMgUGxheWJhY2sgYW5kIHJlbmRlcmluZwoKLSBVc2UgYEFWQXNzZXRgJ3MgSGFwIGhlbHBlcnMgKGBsb2FkSGFwVmlkZW9UcmFja3NXaXRoQ29tcGxldGlvbkhhbmRsZXI6YCAvIGBoYXBWaWRlb1RyYWNrc2ApIG9yIGBBVlBsYXllckl0ZW1gJ3MgYGxvYWRIYXBUcmFja1dpdGhDb21wbGV0aW9uSGFuZGxlcjpgIC8gYGhhcFRyYWNrYCB0byBmaW5kIEhhcCB2aWRlbyB0cmFja3MuIEhhbmRsZSBhc3luY2hyb25vdXMgbG9hZCBlcnJvcnMgYW5kIGFzc2V0cyB3aXRob3V0IGEgSGFwIHRyYWNrLgotIEZvciBBVlBsYXllciBwbGF5YmFjaywgY3JlYXRlIG9uZSBgQVZQbGF5ZXJJdGVtSGFwRFhUT3V0cHV0YCwgYWRkIGl0IHRvIHRoZSBwbGF5ZXIgaXRlbSwgYW5kIHJlcXVlc3QgZnJhbWVzIHdpdGggYGFsbG9jRnJhbWVDbG9zZXN0VG9UaW1lOmAgZnJvbSB0aGUgcGxheWJhY2svcmVuZGVyIGxvb3AuIFRoaXMgaXMgYXN5bmNocm9ub3VzIGFuZCBtYXkgcmV0dXJuIGBuaWxgIHdoaWxlIGEgZnJhbWUgaXMgbm90IHJlYWR5OyBoYW5kbGUgdGhhdCB3aXRob3V0IGJsb2NraW5nIHJlbmRlcmluZy4gQmFsYW5jZSB0aGUgcmV0dXJuZWQgb2JqZWN0J3Mgb3duZXJzaGlwIGFzIHJlcXVpcmVkIGJ5IHRoZSBwcm9qZWN0J3MgQVJDL293bmVyc2hpcCBjb252ZW50aW9ucy4KLSBGb3IgdGltZS1jcml0aWNhbCBzeW5jaHJvbm91cyB3b3JrIHN1Y2ggYXMgdGh1bWJuYWlscyBvciB0cmFuc2NvZGluZywgdXNlIGBhbGxvY0ZyYW1lRm9yVGltZTpgIG9yIGBhbGxvY0ZyYW1lRm9ySGFwU2FtcGxlQnVmZmVyOmAgb2ZmIHRoZSBVSS9yZW5kZXIgdGhyZWFkLgotIEZvciBNZXRhbCByZW5kZXJpbmcsIGxlYXZlIGBvdXRwdXRBc1JHQmAgZGlzYWJsZWQuIEhhcCBmcmFtZXMgY29udGFpbiBjb21wcmVzc2VkIERYVC9CQyBkYXRhIGluIGBkeHREYXRhc2A7IHVwbG9hZC9zYW1wbGUgdGhlIG1hdGNoaW5nIG5hdGl2ZSBjb21wcmVzc2VkIHRleHR1cmUgZm9ybWF0IG9uIGEgc3VwcG9ydGVkIE1ldGFsIGRldmljZS4gRG8gbm90IENQVS1kZWNvbXByZXNzIHRvIFJHQkEgYmVmb3JlIHVwbG9hZGluZyB1bmxlc3MgZXhwbGljaXRseSBpbXBsZW1lbnRpbmcgYSBkaWFnbm9zdGljIGZhbGxiYWNrLgotIEtlZXAgZWFjaCBgSGFwRGVjb2RlckZyYW1lYCBhbGl2ZSB1bnRpbCBhbnkgdXBsb2FkL2NvbW1hbmQgd29yayB0aGF0IHJlYWRzIGl0cyBgZHh0RGF0YXNgIGlzIGNvbXBsZXRlLiBSZXNwZWN0IGBkeHRQbGFuZUNvdW50YDogSGFwIFEgQWxwaGEgY2FuIGhhdmUgYSBzZWNvbmQgYWxwaGEgcGxhbmUuIFVzZSB0aGUgYWN0dWFsIGZyYW1lIGNvZGVjL3RleHR1cmUgZm9ybWF0IGFuZCBkaW1lbnNpb25zOyBEWFQgc3RvcmFnZSBkaW1lbnNpb25zIGNhbiBiZSByb3VuZGVkIHVwIHRvIDQtcGl4ZWwgYmxvY2sgYm91bmRhcmllcyB3aGlsZSBgaW1nU2l6ZWAgaXMgdGhlIHZpc2libGUgaW1hZ2Ugc2l6ZS4KLSBIYXAgUS9ZQ29DZyByZXF1aXJlcyB0aGUgbWF0Y2hpbmcgY29sb3IgcmVjb25zdHJ1Y3Rpb24gc2hhZGVyLiBEbyBub3QgdHJlYXQgaXRzIGNvbXByZXNzZWQgcGxhbmUgYXMgb3JkaW5hcnkgUkdCLiBGb3IgUSBBbHBoYSwgc2FtcGxlIGFuZCBhcHBseSB0aGUgc2VwYXJhdGUgYWxwaGEgcGxhbmUuCi0gYG91dHB1dEFzUkdCID0gWUVTYCByZXF1ZXN0cyBhIHNsb3cgQ1BVIGNvbnZlcnNpb24gcGF0aDsgdXNlIGl0IGZvciBDUFUgZGlzcGxheSwgcmVhZGJhY2ssIG9yIGRpYWdub3N0aWNzLCBub3QgdGhlIG5vcm1hbCBNZXRhbCBwYXRoLiBJZiB3cmFwcGluZyBBVkZvdW5kYXRpb24gcmVhZGVyIG91dHB1dCBhcyBSR0IsIHVzZSBgQVZBc3NldFJlYWRlckhhcFRyYWNrT3V0cHV0YCBhbmQgZXhwbGljaXRseSBjb25maWd1cmUgaXRzIGBvdXRwdXRBc1JHQmAgYmVoYXZpb3IuCi0gVmFsaWRhdGUgdGhlIGV4YWN0IGNvZGVjIHZhcmlhbnRzIGFuZCBIRFIvQkM3IHN1cHBvcnQgYWdhaW5zdCB0aGUgc2hpcHBlZCBmcmFtZXdvcmsncyBjb21wYXRpYmlsaXR5IGRvY3VtZW50YXRpb24gYW5kIGhlYWRlcnMuIERvIG5vdCBpbmZlciBhIGNvZGVjJ3Mgc3VwcG9ydCBzb2xlbHkgZnJvbSBhIHB1YmxpYyBjb25zdGFudCBvciBlbmNvZGVyIG9wdGlvbi4KCiMjIEVuY29kaW5nCgotIFVzZSBgQVZBc3NldFdyaXRlckhhcElucHV0YCBhcyBhbiBgQVZBc3NldFdyaXRlcklucHV0YCwgd2l0aCBvbmUgb2YgaXRzIGRlY2xhcmVkIGBBVlZpZGVvQ29kZWNIYXAuLi5gIGNvZGVjIGlkZW50aWZpZXJzIGFuZCBSR0JBL0JHUkEgOC1iaXQgaW5wdXQgcGl4ZWwgYnVmZmVycy4KLSBUcmVhdCBgYXBwZW5kUGl4ZWxCdWZmZXI6d2l0aFByZXNlbnRhdGlvblRpbWU6YCBhcyBhc3luY2hyb25vdXMuIEZpbmlzaCB0aGUgSGFwIGlucHV0IGFuZCB3YWl0IGZvciBgZmluaXNoZWRFbmNvZGluZ2AgYmVmb3JlIGZpbmlzaGluZyB0aGUgYXNzZXQgd3JpdGVyLCBvciB0cmFpbGluZyBmcmFtZXMgbWF5IGJlIGxvc3QuCi0gU2V0IGNodW5raW5nLCBxdWFsaXR5LCBIRFIsIGFuZCBmYWxsYmFjayBmcmFtZSByYXRlIG9ubHkgdGhyb3VnaCB0aGUgcHVibGljIGtleXMgZGVjbGFyZWQgYnkgdGhlIG1hdGNoaW5nIGZyYW1ld29yayBoZWFkZXJzLiBWYWxpZGF0ZSB0aGUgb3V0cHV0IGJ5IHJlb3BlbmluZyBpdCBhbmQgY2hlY2tpbmcgaXRzIEhhcCB0cmFjay4KCiMjIERpc3RyaWJ1dGlvbiBhbmQgbGljZW5zaW5nCgotIFByZXNlcnZlIHRoZSBgTElDRU5TRWAgYW5kIGBMSUNFTlNFUy9gIHJlc291cmNlcyBzaGlwcGVkIGluIHRoZSBmcmFtZXdvcms7IGluY2x1ZGUgdGhlIGFwcGxpY2FibGUgbm90aWNlcyB3aXRoIHRoZSBhcHAgZGlzdHJpYnV0aW9uLgotIFRoZSBmcmFtZXdvcmsgaW5jbHVkZXMgWUNvQ2cgRFhUIGNvZGUgbWFya2VkIExHUEwtMi4xLW9yLWxhdGVyLiBEbyBub3QgY2xhaW0gdGhhdCBidW5kbGluZyBub3RpY2VzIGFsb25lIGNvbXBsZXRlcyBjb21wbGlhbmNlLiBGb3IgZGlzdHJpYnV0ZWQgYXBwcywgcHJlc2VydmUgZHluYW1pYyBsaW5raW5nIGFuZCB1c2VyIHJlcGxhY2VhYmlsaXR5LCBwcm92aWRlIHRoZSBjb3JyZXNwb25kaW5nIHNvdXJjZS9idWlsZCBtYXRlcmlhbHMgcmVxdWlyZWQgYnkgdGhlIGFwcGxpY2FibGUgTEdQTCB0ZXJtcywgYW5kIGVuc3VyZSB0aGUgYXBwJ3MgdGVybXMgZG8gbm90IHByb2hpYml0IG1vZGlmaWNhdGlvbiBvciByZXZlcnNlIGVuZ2luZWVyaW5nIGZvciBkZWJ1Z2dpbmcgdGhvc2UgbW9kaWZpY2F0aW9ucy4gSGF2ZSBjb3Vuc2VsIHJldmlldyB0aGUgcmVsZWFzZSBhcnJhbmdlbWVudDsgcmVxdWlyZW1lbnRzIGNhbiB2YXJ5IHdpdGggcGFja2FnaW5nIGFuZCBqdXJpc2RpY3Rpb24uCi0gS2VlcCB0aGUgZnJhbWV3b3JrIGJpbmFyeSwgc291cmNlLCBhbmQgZGVwZW5kZW5jeSByZXZpc2lvbnMgbWF0Y2hlZCBmb3IgZWFjaCByZWxlYXNlLiBQcm92aWRlIHJlY2lwaWVudHMgYSBzdGFibGUgc291cmNlIGxvY2F0aW9uIG9yIG9mZmVyIHRpZWQgdG8gdGhhdCBleGFjdCBiaW5hcnksIG5vdCBhIGZsb2F0aW5nIGJyYW5jaCBvciBhbiB1bnJlbGF0ZWQgbmV3ZXIgY2hlY2tvdXQuCgojIyBSZXF1aXJlZCBpbnRlZ3JhdGlvbiBjaGVja3MKCjEuIENvbmZpcm0gdGhlIGFwcCBlbWJlZHMgdGhlIGZyYW1ld29yayBhbmQgaXRzIHJ1bnBhdGhzIHJlc29sdmUgdGhlIGBAcnBhdGhgIGluc3RhbGwgbmFtZS4KMi4gVmVyaWZ5IGNvZGUgc2lnbmluZyBhZnRlciBlbWJlZGRpbmcgYW5kIGxhdW5jaCBvbiB0aGUgbWluaW11bSBzdXBwb3J0ZWQgbWFjT1MvYXJjaGl0ZWN0dXJlLgozLiBUZXN0IEhhcDEsIEhhcCBBbHBoYSwgSGFwIFEsIGFuZCBIYXAgUSBBbHBoYSBwYXRocyBhY3R1YWxseSB1c2VkIGJ5IHRoZSBhcHA7IHRlc3QgYWJzZW50IHRyYWNrcywgZGVsYXllZCBmcmFtZXMsIHNlZWssIGFuZCBlbmQtb2Ytc3RyZWFtLgo0LiBGb3IgTWV0YWwsIGNvbmZpcm0gY29tcHJlc3NlZCB0ZXh0dXJlIGZvcm1hdHMgYW5kIHBsYW5lIGhhbmRsaW5nIG9uIHRoZSB0YXJnZXQgZGV2aWNlOyBkbyBub3Qgc2lsZW50bHkgZmFsbCBiYWNrIHRvIENQVSBjb252ZXJzaW9uLgo1LiBCZWZvcmUgcmVsZWFzZSwgaW5zcGVjdCB0aGUgYnVpbHQgZnJhbWV3b3JrIGJ1bmRsZSBmb3IgYExJQ0VOU0VgLCBgTElDRU5TRVMvYCwgYW5kIHRoZSBMR1BMIHRleHQsIHRoZW4gY29tcGxldGUgYSBzZXBhcmF0ZSBsaWNlbnNlLWNvbXBsaWFuY2UgcmV2aWV3Lgo=')
(out / "HapInAVFoundation.instructions.md").write_bytes(instructions)

sys.argv = ["modframeworks_docs.py",
            "--framework", 'HapInAVFoundation',
            "--out", str(out),
            "--builder", builder]
exec(compile(generator, "embedded_docs.py", "exec"))
EMBEDDED_DOCS
