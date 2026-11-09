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
    work_dir="$script_root/.modffmpeg-macos15"
    output_dir="$script_root/output-ModFFmpeg"
    # Fail closed if the workspace/output are symlinks, even if they point inside the root.
    for target in "$work_dir" "$output_dir"; do
        if [[ -L "$target" ]]; then echo "ERROR: refusing symlinked directory: $target" >&2; return 2; fi
        if [[ -e "$target" && ! -d "$target" ]]; then echo "ERROR: expected directory: $target" >&2; return 2; fi
    done
    work_size='not present'; output_size='not present'
    [[ ! -d "$work_dir" ]] || work_size="$(du -sh "$work_dir" 2>/dev/null | awk '{print $1}')"
    [[ ! -d "$output_dir" ]] || output_size="$(du -sh "$output_dir" 2>/dev/null | awk '{print $1}')"
    printf '\n%s — disk-space management\n' 'ModFFmpeg'
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

trap 'echo "Build failed near line $LINENO" >&2' ERR
restore_configure() {
    if [[ -n "${SOURCE:-}" && -d "$SOURCE/.git" && -f "$SOURCE/configure" ]]; then
        git -C "$SOURCE" show HEAD:configure > "$SOURCE/configure" || true
        chmod +x "$SOURCE/configure" || true
    fi
}
trap restore_configure EXIT

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$ROOT/.modffmpeg-macos15}"
OUT="${OUT:-$ROOT/output-ModFFmpeg}"
PREFIX="$WORK/prefix"
FFMPEG_REF="${FFMPEG_REF:-n9.0.2}"
SNAPPY_REF="${SNAPPY_REF:-1.3.1}"
MIN_MACOS="${MIN_MACOS:-15.4}"
VERSION="${VERSION:-1.0.0}"
BUNDLE_ID="${BUNDLE_ID:-org.modframeworks.ModFFmpeg}"
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
# CLEAN_BUILD rebuilds FFmpeg and Snappy from source; CLEAN_ALL deletes sources and outputs first.
CLEAN_ALL="${CLEAN_ALL:-0}"
CHECK_ONLY="${CHECK_ONLY:-0}"
CLEAN_BUILD="${CLEAN_BUILD:-0}"
# PACKAGE_ONLY=1 reuses staged archives and headers under the hidden workspace.
PACKAGE_ONLY="${PACKAGE_ONLY:-0}"

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
[[ "$XCFRAMEWORK" == 0 || "$XCFRAMEWORK" == 1 ]] || {
    echo "ERROR: XCFRAMEWORK must be 0 or 1" >&2
    exit 2
}
[[ "$SIGN" == 0 || "$SIGN" == 1 ]] || {
    echo "ERROR: SIGN must be 0 or 1" >&2
    exit 2
}
for flag in CLEAN_ALL CHECK_ONLY CLEAN_BUILD PACKAGE_ONLY; do
    value="${!flag}"
    [[ "$value" == 0 || "$value" == 1 ]] || {
        echo "ERROR: $flag must be 0 or 1" >&2
        exit 2
    }
done
if [[ "$PACKAGE_ONLY" == 1 && ( "$CLEAN_ALL" == 1 || "$CLEAN_BUILD" == 1 ) ]]; then
    echo "ERROR: PACKAGE_ONLY=1 cannot be combined with CLEAN_ALL=1 or CLEAN_BUILD=1" >&2
    exit 2
fi
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
    echo "ERROR: this builder requires an Apple Silicon Mac" >&2
    exit 1
}

TOOLS=(git make cmake xcrun lipo otool nm python3 swiftc plutil install_name_tool shasum)
if [[ "$XCFRAMEWORK" == 1 ]]; then
    TOOLS+=(xcodebuild)
fi
if [[ "$SIGN" == 1 ]]; then
    TOOLS+=(codesign)
fi
for tool in "${TOOLS[@]}"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: required tool not found: $tool" >&2
        exit 2
    fi
done

if [[ "$CHECK_ONLY" == 1 ]]; then
    printf 'Preflight passed for ModFFmpeg (%s, arm64, macOS %s).\n' \
        "$(xcrun --find clang++)" "$MIN_MACOS"
    exit 0
fi

if [[ "$CLEAN_ALL" == 1 ]]; then
    [[ "$WORK" != / && "$OUT" != / && "$WORK" != "$OUT" ]] || {
        echo 'ERROR: unsafe clean paths' >&2; exit 2;
    }
    echo "Removing ModFFmpeg workspace and outputs."
    rm -rf "$WORK" "$OUT"
fi

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun --sdk macosx -f clang)"
CXX="$(xcrun --sdk macosx -f clang++)"
mkdir -p "$WORK" "$OUT" "$PREFIX"
# Persist the complete console output, including failures, for diagnosis.
# Initialize after CLEAN_ALL so cleanup cannot remove the active log.
BUILD_LOG="$OUT/build.log"
exec > >(tee "$BUILD_LOG") 2>&1
printf 'ModFFmpeg build log: %s\n' "$BUILD_LOG"

SNAPPY_SOURCE="$WORK/snappy"
if [[ ! -d "$SNAPPY_SOURCE/.git" ]]; then
    if [[ -e "$SNAPPY_SOURCE" ]]; then
        echo "ERROR: refusing to replace non-Git source path: $SNAPPY_SOURCE" >&2
        exit 2
    fi
    git clone --depth 1 --branch "$SNAPPY_REF" \
        https://github.com/google/snappy.git "$SNAPPY_SOURCE"
else
    [[ -z "$(git -C "$SNAPPY_SOURCE" status --porcelain)" ]] || { echo "ERROR: modified Snappy source checkout" >&2; exit 2; }
    git -C "$SNAPPY_SOURCE" fetch --depth 1 origin "$SNAPPY_REF"
    git -C "$SNAPPY_SOURCE" checkout --force FETCH_HEAD
fi

SOURCE="$WORK/ffmpeg"
if [[ ! -d "$SOURCE/.git" ]]; then
    if [[ -e "$SOURCE" ]]; then
        echo "ERROR: refusing to replace non-Git source path: $SOURCE" >&2
        exit 2
    fi
    git clone --depth 1 --branch "$FFMPEG_REF" \
        https://github.com/FFmpeg/FFmpeg.git "$SOURCE"
else
    [[ -z "$(git -C "$SOURCE" status --porcelain)" ]] || { echo "ERROR: modified FFmpeg source checkout" >&2; exit 2; }
    git -C "$SOURCE" fetch --depth 1 origin "$FFMPEG_REF"
    git -C "$SOURCE" checkout --force FETCH_HEAD
fi

if [[ "$CLEAN_BUILD" == 1 ]]; then
    echo "Removing only generated FFmpeg build and staging directories."
    rm -rf "$WORK/snappy-build" "$WORK/prefix"
    mkdir -p "$PREFIX"
fi

SOURCE_REVISION="$(git -C "$SOURCE" rev-parse HEAD)"
SNAPPY_REVISION="$(git -C "$SNAPPY_SOURCE" rev-parse HEAD)"
echo "Building FFmpeg $FFMPEG_REF ($SOURCE_REVISION) for macOS arm64"
echo "Building Snappy $SNAPPY_REF ($SNAPPY_REVISION) as a static dependency"

export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
export CFLAGS="-arch arm64 -isysroot $SDK_PATH -mmacosx-version-min=$MIN_MACOS -I$PREFIX/include -O2 ${CFLAGS:-}"
export CXXFLAGS="-arch arm64 -isysroot $SDK_PATH -mmacosx-version-min=$MIN_MACOS -I$PREFIX/include -O2 ${CXXFLAGS:-}"
export LDFLAGS="-arch arm64 -isysroot $SDK_PATH -mmacosx-version-min=$MIN_MACOS -L$PREFIX/lib ${LDFLAGS:-}"

if [[ "$PACKAGE_ONLY" != 1 ]]; then
cmake -S "$SNAPPY_SOURCE" -B "$WORK/snappy-build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_C_FLAGS="$CFLAGS" \
    -DCMAKE_CXX_FLAGS="$CXXFLAGS" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
    -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DSNAPPY_BUILD_TESTS=OFF \
    -DSNAPPY_BUILD_BENCHMARKS=OFF \
    -DSNAPPY_INSTALL=ON
cmake --build "$WORK/snappy-build" --config Release --parallel "$JOBS"
cmake --install "$WORK/snappy-build" --config Release
[[ -s "$PREFIX/lib/libsnappy.a" && -s "$PREFIX/include/snappy-c.h" ]] || {
    echo "ERROR: Snappy static archive or C header was not installed" >&2
    exit 1
}

cd "$SOURCE"
make distclean >/dev/null 2>&1 || true
# FFmpeg's configure test hardcodes the GNU C++ runtime. Apple SDKs provide
# libc++ instead, so adapt that single Snappy link check for the target toolchain.
python3 - "$SOURCE/configure" <<'PY_SNAPPY_CXX_RUNTIME'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
old = "require libsnappy snappy-c.h snappy_compress -lsnappy -lstdc++"
new = "require libsnappy snappy-c.h snappy_compress -lsnappy -lc++"
if source.count(old) == 0 and source.count(new) == 1:
    raise SystemExit("ERROR: FFmpeg configure is already patched; restore the pristine checkout")
if source.count(old) != 1:
    raise SystemExit(
        "ERROR: expected exactly one FFmpeg Snappy configure check; "
        "review the upstream configure change before building"
    )
path.write_text(source.replace(old, new))
PY_SNAPPY_CXX_RUNTIME
./configure \
    --prefix="$PREFIX" \
    --cc="$CC" \
    --host-cc="$CC" \
    --host-cflags="-isysroot $SDK_PATH" \
    --host-ldflags="-isysroot $SDK_PATH" \
    --arch=aarch64 \
    --target-os=darwin \
    --sysroot="$SDK_PATH" \
    --disable-autodetect \
    --enable-network \
    --disable-programs \
    --disable-doc \
    --disable-debug \
    --disable-shared \
    --enable-static \
    --enable-pic \
    --disable-gpl \
    --disable-version3 \
    --disable-nonfree \
    --enable-iconv \
    --enable-zlib \
    --enable-bzlib \
    --enable-libsnappy \
    --enable-videotoolbox \
    --enable-audiotoolbox \
    --disable-indev=avfoundation \
    --enable-outdev=audiotoolbox \
    --enable-securetransport \
    --extra-libs=-liconv \
    --extra-cflags="$CFLAGS" \
    --extra-ldflags="$LDFLAGS"
# Restore upstream configure immediately; the generated build configuration retains the probe results.
git -C "$SOURCE" show HEAD:configure > "$SOURCE/configure"
chmod +x "$SOURCE/configure"
for feature in GPL VERSION3 NONFREE; do
    if ! grep -Fxq "#define CONFIG_$feature 0" "$SOURCE/config.h"; then
        echo "ERROR: expected CONFIG_$feature to be disabled in FFmpeg config.h" >&2
        exit 1
    fi
done
for feature in CONFIG_HAP_ENCODER CONFIG_HAP_DECODER \
    CONFIG_AUDIOTOOLBOX_OUTDEV; do
    if ! grep -h -Fxq "#define $feature 1" \
        "$SOURCE/config_components.h"; then
        echo "ERROR: expected $feature to be enabled in FFmpeg config components" >&2
        exit 1
    fi
done
if ! grep -h -Fxq '#define CONFIG_AVFOUNDATION_INDEV 0' "$SOURCE/config_components.h"; then
    echo "ERROR: AVFoundation capture input must be disabled to avoid ObjC class collisions" >&2
    exit 1
fi
for feature in CONFIG_LIBSNAPPY CONFIG_SECURETRANSPORT CONFIG_NETWORK; do
    if ! grep -Fxq "#define $feature 1" "$SOURCE/config.h"; then
        echo "ERROR: expected $feature to be enabled in FFmpeg config.h" >&2
        exit 1
    fi
done
make -j "$JOBS"
make install
fi

FRAMEWORK="$OUT/ModFFmpeg.framework"
XCFRAMEWORK_PATH="$OUT/ModFFmpeg.xcframework"
rm -rf "$FRAMEWORK" "$XCFRAMEWORK_PATH"
# Recreate reports on every packaging run, preventing stale PASS results.
for report in ModFFmpeg-exported-symbols.txt ModFFmpeg-header-inventory.json \
              ModFFmpeg-linkage.txt ModFFmpeg-mach-o-build.txt \
              ModFFmpeg-source-compliance.tar.gz ModFFmpeg-validation.txt; do
    rm -f "$OUT/$report"
done
printf 'INCOMPLETE: validation has not finished. See build.log.\n' > "$OUT/ModFFmpeg-validation.txt"
mkdir -p "$FRAMEWORK/Versions/A/Headers" \
    "$FRAMEWORK/Versions/A/Modules" \
    "$FRAMEWORK/Versions/A/Resources/Legal"
cp -R "$PREFIX/include/." "$FRAMEWORK/Versions/A/Headers/"
# FFmpeg's upstream public headers use <libavutil/...> cross-library includes.
# A standalone Apple framework has no implicit -I Headers search root. Rewrite
# only the *packaged copies* to framework-qualified paths, leaving staged and
# compliance source headers untouched. This enables clean `import ModFFmpeg`.
python3 - "$FRAMEWORK/Versions/A/Headers" <<'PY_FRAMEWORK_HEADERS'
from pathlib import Path
import re, sys
root = Path(sys.argv[1])
pat = re.compile(rb'(#\s*include\s*[<"])(lib(?:avcodec|avdevice|avfilter|avformat|avutil|swresample|swscale)/[^>"\r\n]+)([>"])')
changed = 0
for header in root.rglob('*.h'):
    data = header.read_bytes()
    result, n = pat.subn(lambda m: m.group(1) + b'ModFFmpeg/' + m.group(2) + m.group(3), data)
    if n:
        header.write_bytes(result)
        changed += n
print(f'Framework-qualified {changed} FFmpeg header includes')
if not changed:
    raise SystemExit('ERROR: no cross-library FFmpeg includes were found to qualify')
PY_FRAMEWORK_HEADERS

cat > "$FRAMEWORK/Versions/A/Headers/ModFFmpeg.h" <<'EOF'
#ifndef MOD_FFMPEG_H
#define MOD_FFMPEG_H

#include <ModFFmpeg/libavcodec/avcodec.h>
#include <ModFFmpeg/libavdevice/avdevice.h>
#include <ModFFmpeg/libavfilter/avfilter.h>
#include <ModFFmpeg/libavformat/avformat.h>
#include <ModFFmpeg/libavutil/avutil.h>
#include <ModFFmpeg/libswresample/swresample.h>
#include <ModFFmpeg/libswscale/swscale.h>

#endif
EOF

cat > "$FRAMEWORK/Versions/A/Modules/module.modulemap" <<'EOF'
framework module ModFFmpeg {
    header "ModFFmpeg.h"
    export *
}
EOF

PLIST_PATH="$FRAMEWORK/Versions/A/Resources/Info.plist"
python3 - "$PLIST_PATH" "$BUNDLE_ID" "$VERSION" "$MIN_MACOS" <<'PY_PLIST'
import plistlib
import sys

path, bundle_id, version, minimum = sys.argv[1:]
plist = {
    "CFBundleDevelopmentRegion": "en",
    "CFBundleExecutable": "ModFFmpeg",
    "CFBundleIdentifier": bundle_id,
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": "ModFFmpeg",
    "CFBundlePackageType": "FMWK",
    "CFBundleShortVersionString": version,
    "CFBundleSupportedPlatforms": ["MacOSX"],
    "CFBundleVersion": version,
    "LSMinimumSystemVersion": minimum,
}
with open(path, "wb") as output:
    plistlib.dump(plist, output, sort_keys=True)
PY_PLIST

ln -s A "$FRAMEWORK/Versions/Current"
ln -s Versions/Current/ModFFmpeg "$FRAMEWORK/ModFFmpeg"
ln -s Versions/Current/Headers "$FRAMEWORK/Headers"
ln -s Versions/Current/Modules "$FRAMEWORK/Modules"
ln -s Versions/Current/Resources "$FRAMEWORK/Resources"

LIBRARIES=(
    libavdevice.a
    libavfilter.a
    libswscale.a
    libavformat.a
    libavcodec.a
    libavutil.a
    libswresample.a
)
ARCHIVES=()
for library in "${LIBRARIES[@]}"; do
    archive="$PREFIX/lib/$library"
    [[ -s "$archive" ]] || {
        echo "ERROR: expected FFmpeg archive was not installed: $archive" >&2
        exit 1
    }
    ARCHIVES+=("$archive")
done

# Force-link all public FFmpeg API symbols, but let ld64 select only the
# required archive members. Loading every object duplicates FFmpeg's private
# frame-pool helpers, which are intentionally present in multiple archives.
EXPORTS_FILE="$WORK/modffmpeg-exported-symbols.txt"
: > "$EXPORTS_FILE"
export_pattern() {
    case "$1" in
        libavcodec.a)   printf '%s' '^(av_|avcodec_|avpriv_|avsubtitle_free$)' ;;
        libavdevice.a)  printf '%s' '^(avdevice_|av_)' ;;
        libavfilter.a)  printf '%s' '^(avfilter_|av_)' ;;
        libavformat.a|libavutil.a) printf '%s' '^av' ;;
        libswresample.a) printf '%s' '^(swr_|swresample_)' ;;
        libswscale.a)   printf '%s' '^(sws_|swscale_)' ;;
        *)
            echo "ERROR: no public API export rules for $1" >&2
            return 1
            ;;
    esac
}
for archive in "${ARCHIVES[@]}"; do
    name="${archive##*/}"
    pattern="$(export_pattern "$name")"
    nm -gU "$archive" | awk -v pattern="$pattern" '
        {
            symbol = $NF
            if (NF < 2 || symbol !~ /^_[[:alnum:]_]/ || $2 == "U")
                next
            sub(/^_/, "", symbol)
            if (symbol ~ pattern)
                print "_" symbol
        }
    ' >> "$EXPORTS_FILE"
done
sort -u "$EXPORTS_FILE" -o "$EXPORTS_FILE"
[[ -s "$EXPORTS_FILE" ]] || {
    echo "ERROR: no public FFmpeg API symbols found in static archives" >&2
    exit 1
}
ANCHOR_ASM="$WORK/modffmpeg-symbol-anchors.s"
ANCHOR_OBJECT="$WORK/modffmpeg-symbol-anchors.o"
{
    printf '.section __DATA,__anchors\n'
    printf '.p2align 3\n'
    printf '.globl _modffmpeg_force_anchors\n_modffmpeg_force_anchors:\n'
    while IFS= read -r symbol; do
        printf '    .quad %s\n' "$symbol"
    done < "$EXPORTS_FILE"
} > "$ANCHOR_ASM"
"$CC" -arch arm64 -isysroot "$SDK_PATH" \
    -mmacosx-version-min="$MIN_MACOS" \
    -c "$ANCHOR_ASM" -o "$ANCHOR_OBJECT"

# FFmpeg's configure output records each component's SDK and system-library
# dependencies. Autodetection is disabled above to avoid optional Homebrew
# libraries.
EXTRALIBS="$(sed -n 's/^EXTRALIBS[^=]*=//p' "$SOURCE/ffbuild/config.mak" | tr '\n' ' ')"
[[ -n "$EXTRALIBS" ]] || {
    echo "ERROR: FFmpeg configure did not record its external link dependencies" >&2
    exit 1
}
[[ " $EXTRALIBS " == *" -lsnappy "* && " $EXTRALIBS " == *" -lc++ "* ]] || {
    echo "ERROR: HAP's Snappy and Apple C++ runtime link flags are missing" >&2
    exit 1
}
read -r -a EXTRALIBS_ARGS <<< "$EXTRALIBS"

"$CC" -arch arm64 -isysroot "$SDK_PATH" \
    -mmacosx-version-min="$MIN_MACOS" \
    -dynamiclib \
    -L"$PREFIX/lib" \
    "$ANCHOR_OBJECT" "${ARCHIVES[@]}" "${ARCHIVES[@]}" \
    "${EXTRALIBS_ARGS[@]}" \
    -Wl,-exported_symbols_list,"$EXPORTS_FILE" \
    -Wl,-install_name,@rpath/ModFFmpeg.framework/Versions/A/ModFFmpeg \
    -Wl,-current_version,"$VERSION" \
    -Wl,-compatibility_version,"$VERSION" \
    -o "$FRAMEWORK/Versions/A/ModFFmpeg"

LEGAL="$FRAMEWORK/Versions/A/Resources/Legal"
for notice in COPYING.LGPLv2.1 COPYING.LGPLv3 LICENSE.md; do
    if [[ -s "$SOURCE/$notice" ]]; then
        cp "$SOURCE/$notice" "$LEGAL/"
    fi
done
[[ -s "$SNAPPY_SOURCE/COPYING" ]] || {
    echo "ERROR: Snappy license notice is missing from the source checkout" >&2
    exit 1
}
cp "$SNAPPY_SOURCE/COPYING" "$LEGAL/LICENSE.snappy.txt"
[[ -s "$LEGAL/COPYING.LGPLv2.1" ]] || {
    echo "ERROR: FFmpeg LGPL license text is missing from the source checkout" >&2
    exit 1
}
cat > "$LEGAL/BUILD_INFO.txt" <<EOF
FFmpeg ref: $FFMPEG_REF
FFmpeg commit: $SOURCE_REVISION
Snappy ref: $SNAPPY_REF
Snappy commit: $SNAPPY_REVISION
Architecture: arm64 (macOS)
Minimum macOS: $MIN_MACOS
HAP encoder and decoder: enabled; HAP encoder Snappy compression is included.
GPL, version-3, and nonfree components: disabled at configure time; audit the final build before distribution.
EOF
cat > "$LEGAL/DISTRIBUTION_NOTES.txt" <<'EOF'
FFmpeg is distributed under LGPL terms when built without GPL and nonfree
components. Review the license files and the exact configuration and linked
components before redistribution. Distributing this binary does not require
publishing your application's source code, but does not remove obligations
that may apply to FFmpeg itself, including providing corresponding source and
allowing users to relink a modified LGPL library where required. This note is
not legal advice.
EOF

lipo -verify_arch arm64 "$FRAMEWORK/Versions/A/ModFFmpeg"
plutil -lint "$PLIST_PATH"
if otool -L "$FRAMEWORK/Versions/A/ModFFmpeg" |
    grep -E '(/opt/homebrew/|/usr/local/|/opt/local/|'"$WORK"')'; then
    echo "ERROR: framework has a non-system dynamic dependency" >&2
    exit 1
fi
# Diagnostic reports are produced from the final linked framework image.
BINARY="$FRAMEWORK/Versions/A/ModFFmpeg"
nm -gU "$BINARY" > "$OUT/ModFFmpeg-exported-symbols.txt"
otool -L "$BINARY" > "$OUT/ModFFmpeg-linkage.txt"
otool -l "$BINARY" | awk '/cmd LC_BUILD_VERSION/{show=1; count=0} show {print; count++} show && count>=12 {show=0}' > "$OUT/ModFFmpeg-mach-o-build.txt"
python3 - "$FRAMEWORK/Headers" "$OUT/ModFFmpeg-header-inventory.json" <<'PY_HEADERS'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1]).resolve()
headers = []
for file in sorted(root.rglob('*.h')):
    headers.append({'path': file.relative_to(root).as_posix(),
                    'sha256': hashlib.sha256(file.read_bytes()).hexdigest(),
                    'bytes': file.stat().st_size})
with open(sys.argv[2], 'w') as stream:
    json.dump({'header_count': len(headers), 'headers': headers}, stream, indent=2)
    stream.write('\n')
if not headers:
    raise SystemExit('ERROR: no public headers inventoried')
PY_HEADERS

nm -gU "$FRAMEWORK/Versions/A/ModFFmpeg" | grep -E '[[:space:]]_avcodec_version$' >/dev/null || {
    echo "ERROR: expected FFmpeg API symbol _avcodec_version is not exported" >&2
    exit 1
}

cat > "$WORK/hap-framework-check.c" <<'EOF'
#include <ModFFmpeg/ModFFmpeg.h>

int main(void)
{
    if (!avcodec_find_encoder_by_name("hap"))
        return 1;
    if (!avcodec_find_decoder_by_name("hap"))
        return 2;
    return 0;
}
EOF
"$CC" -arch arm64 -isysroot "$SDK_PATH" \
    -mmacosx-version-min="$MIN_MACOS" \
    -F"$OUT" -framework ModFFmpeg \
    -Wl,-rpath,"$OUT" \
    "$WORK/hap-framework-check.c" -o "$WORK/hap-framework-check"
"$WORK/hap-framework-check" || {
    echo "ERROR: packaged framework failed the HAP encoder/decoder runtime check" >&2
    exit 1
}

# Clean consumer tests intentionally use only -F and -framework; no custom
# HEADER_SEARCH_PATHS or -Xcc -I. This is required for test-app integration.
cat > "$WORK/modffmpeg-c-smoke.c" <<'EOF_C_SMOKE'
#include <ModFFmpeg/ModFFmpeg.h>
#include <stdio.h>
int main(void) {
    unsigned v = avcodec_version();
    if (!v || !avformat_version() || !avutil_version()) return 1;
    printf("PASS: FFmpeg C API version %u\n", v);
    return 0;
}
EOF_C_SMOKE
"$CC" -arch arm64 -isysroot "$SDK_PATH" \
    -mmacosx-version-min="$MIN_MACOS" -F"$OUT" \
    "$WORK/modffmpeg-c-smoke.c" -framework ModFFmpeg \
    -Wl,-rpath,"$OUT" -o "$WORK/modffmpeg-c-smoke"
"$WORK/modffmpeg-c-smoke"

cat > "$WORK/modffmpeg-swift-smoke.swift" <<'EOF_SWIFT_SMOKE'
import ModFFmpeg
let version = avcodec_version()
precondition(version != 0, "FFmpeg version is zero")
print("PASS: Swift imported ModFFmpeg and called avcodec_version")
EOF_SWIFT_SMOKE
swiftc -target "arm64-apple-macosx${MIN_MACOS}" -sdk "$SDK_PATH" \
    -F "$OUT" \
    "$WORK/modffmpeg-swift-smoke.swift" \
    -o "$WORK/modffmpeg-swift-smoke" \
    -Xlinker -rpath -Xlinker "$OUT"
"$WORK/modffmpeg-swift-smoke"

# Every non-system runtime dependency must be absent from the finished image.
python3 - "$FRAMEWORK/Versions/A/ModFFmpeg" <<'PY_DYLIB_AUDIT'
import subprocess, sys
binary = sys.argv[1]
output = subprocess.check_output(["otool", "-L", binary], text=True)
for line in output.splitlines()[1:]:
    dep = line.strip().split(" (")[0]
    if dep.startswith(("/usr/lib/", "/System/Library/")):
        continue
    if dep == "@rpath/ModFFmpeg.framework/Versions/A/ModFFmpeg":
        continue
    raise SystemExit(f"ERROR: unexpected dynamic dependency: {dep}")
print("PASS: no external third-party dynamic library dependencies")
PY_DYLIB_AUDIT

# Machine-readable integration contract and human-readable agent guidance.
DOCS="$FRAMEWORK/Versions/A/Resources/Documentation"
mkdir -p "$DOCS"
python3 - "$DOCS" "$OUT" "$FFMPEG_REF" "$SOURCE_REVISION" \
    "$SNAPPY_REF" "$SNAPPY_REVISION" "$MIN_MACOS" "$VERSION" <<'PY_AGENT_DOCS'
from pathlib import Path
import json, sys
folder, out, ffref, ffrev, snapref, snaprev, minimum, version = sys.argv[1:]
folder, out = Path(folder), Path(out)
cap = {
  'schema_version': 1, 'name': 'ModFFmpeg', 'version': version,
  'platform': 'macOS', 'minimum_os': minimum, 'architectures': ['arm64'],
  'framework_module': 'ModFFmpeg',
  'sources': {'ffmpeg': {'ref': ffref, 'commit': ffrev},
              'snappy': {'ref': snapref, 'commit': snaprev}},
  'components': ['avcodec','avdevice','avfilter','avformat','avutil','swresample','swscale'],
  'features': {'hap_encoder': True, 'hap_decoder': True, 'snappy': True,
               'videotoolbox': True, 'audiotoolbox': True, 'avfoundation_capture_input': False,
               'network': True, 'securetransport': True},
  'notes': ['Codec availability depends on the exact FFmpeg build.',
            'No Swift wrapper; Swift accesses the FFmpeg C API.',
            'GPL, version3, and nonfree disabled at configure time.',
            'LGPL distribution/relinking obligations require legal review.'],
  'artifacts': ['ModFFmpeg.framework','ModFFmpeg.xcframework',
                'ModFFmpeg-source-compliance.tar.gz']
}
(folder/'capabilities.json').write_text(json.dumps(cap, indent=2)+'\n')
(folder/'AGENTS.md').write_text(f'''# ModFFmpeg agent integration

- Platform: macOS {minimum}+ on Apple Silicon arm64.
- Import in Swift: `import ModFFmpeg`.
- Include in C: `#include <ModFFmpeg/ModFFmpeg.h>`.
- Link: `-F/path/to/output-ModFFmpeg -framework ModFFmpeg`.
- The framework-qualified FFmpeg public headers should work without `-I` or `-Xcc -I`.
- APIs are upstream FFmpeg C APIs, not a new ModFFmpeg C wrapper.
- HAP encode/decode, Snappy and VideoToolbox are enabled; FFmpeg AVFoundation capture input is disabled.
- Do not assume a particular codec, format or filter without checking runtime registration.
- See `capabilities.json`, export inventory and validation report.
- Before distribution, review LGPL terms, relinking requirements and source archive.
''')
(folder/'FRAMEWORK_INFO.md').write_text(f'''# ModFFmpeg {version}

FFmpeg `{ffref}` at `{ffrev}`; Snappy `{snapref}` at `{snaprev}`.
macOS {minimum}+ arm64. FFmpeg public C API available to C and Swift.
Framework-qualified headers are packaged for clean framework import.
The full upstream source snapshots and build configuration are in the
`ModFFmpeg-source-compliance.tar.gz` output archive.
''')
(folder/'README.md').write_text('''# ModFFmpeg

Apple Silicon macOS FFmpeg framework and XCFramework with HAP/Snappy support.

Swift: `import ModFFmpeg` then call upstream FFmpeg C functions.
C: `#include <ModFFmpeg/ModFFmpeg.h>`.

Use `capabilities.json` for machine-readable features. Review the source
compliance archive and LGPL obligations before distributing binaries.
''')
for name in ('AGENTS.md','FRAMEWORK_INFO.md','README.md','capabilities.json'):
    (out/name).write_bytes((folder/name).read_bytes())
PY_AGENT_DOCS

FRAMEWORK_NAME=ModFFmpeg
sign_framework_and_report "$FRAMEWORK" "$OUT/ModFFmpeg-signing.txt" "$CODESIGN_IDENTITY" "$SIGN"

if [[ "$XCFRAMEWORK" == 1 ]]; then
    xcodebuild -create-xcframework \
        -framework "$FRAMEWORK" \
        -output "$XCFRAMEWORK_PATH"
fi

if [[ "$XCFRAMEWORK" == 1 ]]; then
    sign_xcframework_and_report "$XCFRAMEWORK_PATH" "$OUT/ModFFmpeg-signing.txt" "$CODESIGN_IDENTITY" "$SIGN"
fi

# Capture exact source revisions and the build configuration for LGPL review.
# Source archives alone do not discharge all LGPL redistribution obligations.
COMPLIANCE_DIR="$WORK/modffmpeg-compliance-stage"
rm -rf "$COMPLIANCE_DIR"
mkdir -p "$COMPLIANCE_DIR/ffmpeg" "$COMPLIANCE_DIR/snappy" "$COMPLIANCE_DIR/build-config"
git -C "$SOURCE" archive HEAD | tar -xf - -C "$COMPLIANCE_DIR/ffmpeg"
git -C "$SNAPPY_SOURCE" archive HEAD | tar -xf - -C "$COMPLIANCE_DIR/snappy"
for config in config.h config_components.h config.asm ffbuild/config.mak ffbuild/config.log; do
    if [[ -f "$SOURCE/$config" ]]; then
        mkdir -p "$COMPLIANCE_DIR/build-config/$(dirname "$config")"
        cp "$SOURCE/$config" "$COMPLIANCE_DIR/build-config/$config"
    fi
done
cp "$LEGAL/BUILD_INFO.txt" "$LEGAL/DISTRIBUTION_NOTES.txt" "$COMPLIANCE_DIR/"
cat > "$COMPLIANCE_DIR/README.txt" <<'EOF_COMPLIANCE'
This archive contains pinned FFmpeg and Snappy source snapshots and FFmpeg's
build configuration. It is a compliance aid, not a legal certification.
Distribution of a combined LGPL library may also require suitable relinkable
objects or other means to replace LGPL components, notices and instructions.
EOF_COMPLIANCE
tar -czf "$OUT/ModFFmpeg-source-compliance.tar.gz" -C "$COMPLIANCE_DIR" .
[[ -s "$OUT/ModFFmpeg-source-compliance.tar.gz" ]] || {
    echo 'ERROR: compliance archive was not generated' >&2
    exit 1
}

echo "Framework: $FRAMEWORK"
if [[ "$XCFRAMEWORK" == 1 ]]; then
    echo "XCFramework: $XCFRAMEWORK_PATH"
fi

cat > "$OUT/ModFFmpeg-validation.txt" <<EOF_VALIDATION
PASS: FFmpeg and Snappy pinned source revisions recorded
PASS: build.log and diagnostic reports generated
PASS: SHA-256 header inventory and exported symbols captured
PASS: linkage and Mach-O build metadata captured
PASS: pinned source/compliance archive generated
PASS: agent documentation and machine-readable capabilities generated
PASS: FFmpeg configured with GPL, version3, and nonfree disabled
PASS: HAP encoder and decoder runtime smoke test
PASS: C standalone framework consumer without custom header search paths
PASS: Swift standalone framework consumer without custom header search paths
PASS: macOS arm64 framework architecture and Info.plist
PASS: no external third-party dynamic dylib dependencies
$(if [[ "$XCFRAMEWORK" == 1 ]]; then echo 'PASS: XCFramework creation'; else echo 'SKIPPED: XCFramework disabled'; fi)
EOF_VALIDATION

printf 'Build log: %s\n' "$BUILD_LOG"
printf 'Output directory: %s\n' "$OUT"


# Embedded agent documentation generation
_DOCS_OUT="${OUT:-$(pwd)/output-ModFFmpeg}"
mkdir -p "$_DOCS_OUT"
python3 - "$_DOCS_OUT" "$(basename "${BASH_SOURCE[0]}")" <<'EMBEDDED_DOCS'
import sys, base64, tempfile
from pathlib import Path

out = Path(sys.argv[1])
builder = sys.argv[2]
generator = base64.b64decode('IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJHZW5lcmF0ZSBjb25zaXN0ZW50IGJ1aWxkIGFuZCBhZ2VudCBlbnRyeXBvaW50IGRvY3Mgd2l0aG91dCBjaGFuZ2luZyBidWlsZCBhcnRpZmFjdHMuIiIiCmltcG9ydCBhcmdwYXJzZSwgcGF0aGxpYiwgc2h1dGlsLCBzeXMKcD1hcmdwYXJzZS5Bcmd1bWVudFBhcnNlcigpCnAuYWRkX2FyZ3VtZW50KCctLWZyYW1ld29yaycscmVxdWlyZWQ9VHJ1ZSkKcC5hZGRfYXJndW1lbnQoJy0tb3V0JyxyZXF1aXJlZD1UcnVlKQpwLmFkZF9hcmd1bWVudCgnLS1idWlsZGVyJyxyZXF1aXJlZD1UcnVlKQpwLmFkZF9hcmd1bWVudCgnLS1pbnN0cnVjdGlvbnMnLGRlZmF1bHQ9JycpCmE9cC5wYXJzZV9hcmdzKCk7IG91dD1wYXRobGliLlBhdGgoYS5vdXQpOyBvdXQubWtkaXIocGFyZW50cz1UcnVlLGV4aXN0X29rPVRydWUpCm5hbWU9YS5mcmFtZXdvcmsKYnVpbGRlcj1wYXRobGliLlBhdGgoYS5idWlsZGVyKS5uYW1lCnNvdXJjZT17J0hhcEluQVZGb3VuZGF0aW9uJzonaHR0cHM6Ly9naXRodWIuY29tL2ZsZXh2aXN1YWwvaGFwLWluLWF2Zm91bmRhdGlvbid9LmdldChuYW1lLCdTZWUgdGhlIHBpbm5lZCBzb3VyY2UgcmVmZXJlbmNlcyBhbmQgc291cmNlLWNvbXBsaWFuY2UgYXJjaGl2ZSBzdXBwbGllZCB3aXRoIHRoaXMgcmVsZWFzZS4nKQppbnM9b3V0L2Yne25hbWV9Lmluc3RydWN0aW9ucy5tZCcKaWYgYS5pbnN0cnVjdGlvbnMgYW5kIHBhdGhsaWIuUGF0aChhLmluc3RydWN0aW9ucykuaXNfZmlsZSgpOgogICAgc2h1dGlsLmNvcHkyKGEuaW5zdHJ1Y3Rpb25zLGlucykKZXh0cmE9Zic0LiBSZWFkIGB7aW5zLm5hbWV9YCBmb3IgZnJhbWV3b3JrLXNwZWNpZmljIGludGVncmF0aW9uIGFuZCBNZXRhbC9jb2RlYyBjb25zdHJhaW50cy5cbicgaWYgaW5zLmlzX2ZpbGUoKSBlbHNlICc0LiBDb25zdWx0IHRoZSBmcmFtZXdvcmsgcHVibGljIGhlYWRlcnMgYW5kIGV4aXN0aW5nIGludGVncmF0aW9uIG5vdGVzOyBubyBzZXBhcmF0ZSBpbnRlZ3JhdGlvbiBndWlkZSB3YXMgc3VwcGxpZWQuXG4nCihvdXQvJ0FHRU5UUy5tZCcpLndyaXRlX3RleHQoZicnJyMge25hbWV9IOKAlCBBZ2VudCBpbnN0cnVjdGlvbnMKCkJlZm9yZSBpbnRlZ3JhdGluZywgbW9kaWZ5aW5nLCBkaXN0cmlidXRpbmcgb3IgcmVidWlsZGluZzoKCjEuIFJlYWQgYEJVSUxESU5HLm1kYCBmb3IgcmVwcm9kdWNpYmxlIHNvdXJjZS1idWlsZCBzdGVwcyBhbmQgcHJlcmVxdWlzaXRlcy4KMi4gUmVhZCBgUkVBRE1FLm1kYCBhbmQgYEZSQU1FV09SS19JTkZPLm1kYCB3aGVuIHByZXNlbnQuCjMuIENoZWNrIGBjYXBhYmlsaXRpZXMuanNvbmAgYW5kIHRoZSB2YWxpZGF0aW9uLCBoZWFkZXIsIHN5bWJvbCBhbmQgbGlua2FnZSByZXBvcnRzOyBkbyBub3QgaW5mZXIgdW5zdXBwb3J0ZWQgQVBJcy4Ke2V4dHJhfTUuIFRyZWF0IHRoZSAqKnNoaXBwZWQgcHVibGljIGhlYWRlcnMgYW5kIG1hdGNoaW5nIGJpbmFyeSoqIGFzIGF1dGhvcml0YXRpdmUgZm9yIHRoaXMgcmVsZWFzZS4KNi4gUHJlc2VydmUgZHluYW1pYyBmcmFtZXdvcmsgZW1iZWRkaW5nLCBgQHJwYXRoYCwgcmVwbGFjZWFiaWxpdHkgYW5kIHRoZSBob3N0IGFwcGxpY2F0aW9uJ3Mgc2lnbmluZyByZXF1aXJlbWVudHMuCjcuIFJlYWQgdGhlIGFwcGxpY2FibGUgbGljZW5zZSBub3RpY2VzIGFuZCBleGFjdCBzb3VyY2UgcmV2aXNpb24gcmVjb3JkcyBiZWZvcmUgZGlzdHJpYnV0aW9uLgoKQnVpbGQgc2NyaXB0OiBge2J1aWxkZXJ9YCAoc2hpcHBlZCBhbG9uZ3NpZGUgdGhpcyByZWxlYXNlIGRvY3VtZW50YXRpb24sIG5vdCBuZWNlc3NhcmlseSBpbnNpZGUgdGhlIG91dHB1dCBkaXJlY3RvcnkpLgpTb3VyY2U6IHtzb3VyY2V9CicnJykKKG91dC8nQlVJTERJTkcubWQnKS53cml0ZV90ZXh0KGYnJycjIEJ1aWxkaW5nIHtuYW1lfSBmcm9tIHNvdXJjZQoKIyMgUHJlcmVxdWlzaXRlcwoKLSBBbiBBcHBsZSBTaWxpY29uIE1hYyB3aXRoIFhjb2RlIGFuZCB0aGUgbWFjT1MgU0RLIHN1cHBvcnRlZCBieSB0aGlzIGJ1aWxkZXIuCi0gWGNvZGUgY29tbWFuZC1saW5lIHRvb2xzIHNlbGVjdGVkIChgeGNvZGUtc2VsZWN0IC1wYCksIEdpdCBhbmQgdGhlIGNvbW1hbmQtbGluZSB1dGlsaXRpZXMgdXNlZCBieSB0aGUgYnVpbGRlci4KLSBJbnRlcm5ldCBhY2Nlc3MgdG8gZmV0Y2ggdGhlIGJ1aWxkZXIncyBwaW5uZWQgZGVwZW5kZW5jaWVzLCB1bmxlc3MgYWxyZWFkeSBjYWNoZWQuCgojIyBCdWlsZAoKUGxhY2UgYHtidWlsZGVyfWAgaW4gdGhlIGludGVuZGVkIE1vZEZyYW1ld29ya3Mgd29ya2luZyBkaXJlY3RvcnkgYW5kIHJ1bjoKCmBgYGJhc2gKY2htb2QgK3ggIntidWlsZGVyfSIKLi8ie2J1aWxkZXJ9IgpgYGAKClRoaXMgZG9jdW1lbnRhdGlvbiBpcyBnZW5lcmF0ZWQgZm9yIHRoZSAqKnNwZWNpZmljIHNjcmlwdCB2ZXJzaW9uKiogbmFtZWQgYWJvdmUuIFJldmlldyB0aGF0IHNjcmlwdCdzIGNvbmZpZ3VyYWJsZSBlbnZpcm9ubWVudCB2YXJpYWJsZXMgYW5kIGNsZWFuL3JlYnVpbGQgb3B0aW9ucyBiZWZvcmUgdXNpbmcgdGhlbTsgbm8gY29tbW9uIGZsYWdzIGFyZSBhc3N1bWVkIGFjcm9zcyBidWlsZGVycy4KCiMjIE91dHB1dHMgYW5kIGNoZWNrcwoKLSBJbnNwZWN0IGBidWlsZC5sb2dgIGZvciBhY3R1YWwgY29tcGlsYXRpb24gc3VjY2VzczsgZXhpc3RlbmNlIG9mIGEgZnJhbWV3b3JrIGZvbGRlciBhbG9uZSBpcyBub3QgcHJvb2Ygb2YgYSBmcmVzaCBidWlsZC4KLSBWZXJpZnkgdGhlIGZyYW1ld29yayBhbmQgWENGcmFtZXdvcmsgZGlyZWN0b3JpZXMgaWYgdGhpcyBidWlsZCBlbmFibGVzIGJvdGguCi0gQ2hlY2sgYCotdmFsaWRhdGlvbi50eHRgLCBgKi1saW5rYWdlLnR4dGAsIGAqLW1hY2gtby1idWlsZC50eHRgLCBgKi1oZWFkZXItaW52ZW50b3J5Lmpzb25gLCBgKi1leHBvcnRlZC1zeW1ib2xzLnR4dGAsIGFuZCBgY2FwYWJpbGl0aWVzLmpzb25gIHdoZW4gZ2VuZXJhdGVkLgotIFZlcmlmeSBzaWduYXR1cmVzIHdpdGggYGNvZGVzaWduIC0tdmVyaWZ5IC0tc3RyaWN0IC0tdmVyYm9zZT0yYCBvbiB0aGUgZnJhbWV3b3JrIGFuZCBYQ0ZyYW1ld29yay4gQSBkZXZlbG9wbWVudCBhZC1ob2Mgc2lnbmF0dXJlIGlzICoqbm90KiogYSBEZXZlbG9wZXIgSUQgc2lnbmF0dXJlIG9yIG5vdGFyaXphdGlvbi4KLSBWZXJpZnkgdGhlIGFyY2hpdGVjdHVyZSB3aXRoIGB4Y3J1biBsaXBvIC1pbmZvYCBhbmQgbWluaW11bSBkZXBsb3ltZW50IHZlcnNpb24gd2l0aCBgeGNydW4gdnRvb2wgLXNob3ctYnVpbGRgIG9uIHRoZSBmcmFtZXdvcmsgZXhlY3V0YWJsZS4KLSBVc2UgZXhhY3QgcmV2aXNpb25zIGluIHRoZSBnZW5lcmF0ZWQgZGVwZW5kZW5jeS9zb3VyY2UgbWFuaWZlc3QgZm9yIHJlcHJvZHVjaWJpbGl0eTsgZG8gbm90IHN1YnN0aXR1dGUgY3VycmVudCBicmFuY2ggSEVBRC4KCiMjIERpc3RyaWJ1dGlvbgoKVGhlIHNvdXJjZSByZXBvc2l0b3J5IHJlZmVyZW5jZSBpczoge3NvdXJjZX0KClRoZSBmcmFtZXdvcmsgaXMgaW50ZW5kZWQgdG8gcmVtYWluIGR5bmFtaWNhbGx5IHJlcGxhY2VhYmxlLiBVc2VycyBvZiBhbiBlbWJlZGRlZCBmcmFtZXdvcmsgbWF5IG5lZWQgdG8gcmUtc2lnbiB0aGVpciBhcHBsaWNhdGlvbiBhZnRlciByZXBsYWNlbWVudCwgc3ViamVjdCB0byBpdHMgcnVudGltZSBhbmQgZGlzdHJpYnV0aW9uIHJlc3RyaWN0aW9ucy4gUHVibGlzaGVkIHNvdXJjZSBhbmQgcmVwbGFjZWFiaWxpdHkgYXJlIGltcG9ydGFudCBidXQgZG8gbm90IGJ5IHRoZW1zZWx2ZXMgY2VydGlmeSBsaWNlbnNlIGNvbXBsaWFuY2UuIFJldmlldyB0aGUgZXhhY3Qgbm90aWNlcyBhbmQgY29ycmVzcG9uZGluZyBzb3VyY2UvYnVpbGQgbWF0ZXJpYWxzLgoKIyMgVHJvdWJsZXNob290aW5nCgpJZiBhIGNsZWFuIGJ1aWxkIGZhaWxzLCBrZWVwIGBidWlsZC5sb2dgIGFuZCB0aGUgcmVwb3J0ZWQgdG9vbGNoYWluIHZlcnNpb24sIGluc3BlY3QgdGhlIGZpcnN0IGZhaWx1cmUgKG5vdCBqdXN0IHRoZSBsYXN0IGVycm9yKSwgYW5kIGNoZWNrIHRoZSBwaW5uZWQgZGVwZW5kZW5jeSBjaGVja291dHMuIERvIG5vdCBzaWxlbnRseSBjaGFuZ2UgcGlubmVkIHJldmlzaW9ucyB0byBtYWtlIGEgZmFpbGluZyBidWlsZCBwYXNzLgonJycpCnByaW50KGYnRG9jdW1lbnRhdGlvbiBnZW5lcmF0ZWQ6IHtvdXR9L0FHRU5UUy5tZCBhbmQgQlVJTERJTkcubWQnICsgKGYnIChpbnRlZ3JhdGlvbiBpbnN0cnVjdGlvbnMgaW5jbHVkZWQpJyBpZiBpbnMuaXNfZmlsZSgpIGVsc2UgJycpKQo=')

sys.argv = ["modframeworks_docs.py",
            "--framework", 'ModFFmpeg',
            "--out", str(out),
            "--builder", builder]
exec(compile(generator, "embedded_docs.py", "exec"))
EMBEDDED_DOCS
