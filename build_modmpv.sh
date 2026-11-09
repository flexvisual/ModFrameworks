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
    work_dir="$script_root/.modmpv-macos15"
    output_dir="$script_root/output-ModMPV"
    # Fail closed if the workspace/output are symlinks, even if they point inside the root.
    for target in "$work_dir" "$output_dir"; do
        if [[ -L "$target" ]]; then echo "ERROR: refusing symlinked directory: $target" >&2; return 2; fi
        if [[ -e "$target" && ! -d "$target" ]]; then echo "ERROR: expected directory: $target" >&2; return 2; fi
    done
    work_size='not present'; output_size='not present'
    [[ ! -d "$work_dir" ]] || work_size="$(du -sh "$work_dir" 2>/dev/null | awk '{print $1}')"
    [[ ! -d "$output_dir" ]] || output_size="$(du -sh "$output_dir" 2>/dev/null | awk '{print $1}')"
    printf '\n%s — disk-space management\n' 'ModMPV'
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

# ModMPV framework builder (macOS 15.4, arm64; optional ad-hoc signing).
# Builds a self-contained deployment artifact with custom open-source dependencies.
set -Eeuo pipefail
# One canonical log: output-ModMPV/build.log (including failed builds).
# Run the build in a child shell so tee can record all output and preserve status.
if [[ "${MODMPV_LOG_ACTIVE:-0}" != 1 ]]; then
    _modmpv_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _modmpv_out="${OUT:-$_modmpv_root/output-ModMPV}"
    # CLEAN_ALL must happen before opening build.log or it would delete the log.
    if [[ "${CLEAN_ALL:-0}" == 1 ]]; then
        rm -rf "${WORK:-$_modmpv_root/.modmpv-macos15}" "$_modmpv_out"
        export MODMPV_CLEAN_ALREADY_DONE=1
    fi
    mkdir -p "$_modmpv_out"
    export MODMPV_LOG_ACTIVE=1
    bash "${BASH_SOURCE[0]}" "$@" 2>&1 | tee "$_modmpv_out/build.log"
    exit "${PIPESTATUS[0]}"
fi
trap 'status=$?; echo "Build failed near line $LINENO (exit $status); see ${OUT:-output-ModMPV}/build.log" >&2' ERR
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$ROOT/.modmpv-macos15}"
OUT="${OUT:-$ROOT/output-ModMPV}"
modmpv_finalize_reports() {
    local status="$1"
    mkdir -p "$OUT"
    {
      printf 'ModMPV build validation summary\nExit status: %s\n' "$status"
      if [[ "$status" == 0 ]]; then echo 'Build script: COMPLETED'; else echo 'Build script: FAILED (see build.log)'; fi
      echo 'Public symbol audit: see mpv-api-public-symbols.txt and mpv-api-missing-symbols.txt'
      echo 'GPU rendering: NOT VERIFIED by headless smoke test'
      echo 'License distribution compliance: NOT CERTIFIED'
    } > "$OUT/ModMPV-validation.txt"
}
trap 'modmpv_finalize_reports "$?"' EXIT

MIN_MACOS="${MIN_MACOS:-15.4}"
MPV_REF="${MPV_REF:-v0.41.0}"          # Safe stable release anchor layout
FFMPEG_REF="${FFMPEG_REF:-n9.0.2}"     # <- UPDATED: Anchors your media engine to the n9.0.2 release tag
SNAPPY_REF="${SNAPPY_REF:-1.3.1}"
BUNDLE_ID="${BUNDLE_ID:-org.modmpv.framework}"
VERSION="${VERSION:-1.0.0}"
XCFRAMEWORK="${XCFRAMEWORK:-1}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
# Signing modes: auto (default), development, adhoc, none.
SIGN="${SIGN:-1}"
SIGN_MODE="${SIGN_MODE:-auto}"
RELEASE_AUDIT="${RELEASE_AUDIT:-0}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
SIGNING_TEAM="${SIGNING_TEAM:-}"
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

# =====================================================================
# CHOICE FLAGS & CLEAN SLATE CONTROLS (Surgically moved below anchors)
# =====================================================================
CLEAN_ALL="${CLEAN_ALL:-0}"
# PACKAGE_ONLY=1: reuse previously compiled FFmpeg/mpv and dependency archives.
# Only relink, validate, and package the framework/XCFramework.
PACKAGE_ONLY="${PACKAGE_ONLY:-0}"
DEPENDENCIES_ONLY="${DEPENDENCIES_ONLY:-0}"
FFMPEG_ONLY="${FFMPEG_ONLY:-0}"
MPV_ONLY="${MPV_ONLY:-0}" # rebuild mpv only, reuse FFmpeg and dependencies
if (( PACKAGE_ONLY + DEPENDENCIES_ONLY + FFMPEG_ONLY + MPV_ONLY > 1 )); then
    echo "ERROR: PACKAGE_ONLY, DEPENDENCIES_ONLY, FFMPEG_ONLY and MPV_ONLY are mutually exclusive" >&2; exit 2
fi
if [[ "$FFMPEG_ONLY" == 1 && "$CLEAN_ALL" == 1 ]]; then
    echo "ERROR: FFMPEG_ONLY=1 cannot be combined with CLEAN_ALL=1" >&2; exit 2
fi
if [[ "$MPV_ONLY" == 1 && "$CLEAN_ALL" == 1 ]]; then
    echo "ERROR: MPV_ONLY=1 cannot be combined with CLEAN_ALL=1" >&2; exit 2
fi
if [[ "$PACKAGE_ONLY" == 1 && "$CLEAN_ALL" == 1 ]]; then
    echo 'ERROR: PACKAGE_ONLY=1 cannot be combined with CLEAN_ALL=1.' >&2
    exit 2
fi

# Moving upstream branch names are permitted for engineering experiments but
# forbidden in a reproducible release audit. Use immutable commit SHAs or tags.
if [[ "$RELEASE_AUDIT" == 1 ]]; then
    for name in MPV_REF FFMPEG_REF; do
        ref="${!name}"
        case "$ref" in main|master|HEAD) echo "ERROR: $name uses moving ref $ref" >&2; exit 4;; esac
    done
fi

if [[ "$CLEAN_ALL" == 1 && "${MODMPV_CLEAN_ALREADY_DONE:-0}" != 1 ]]; then
    echo "=== Nuclear Option Active: Purging all local sandbox folders... ==="
    rm -rf "$WORK" "$OUT"
fi

PREFIX="$WORK/prefix"
mkdir -p "$WORK" "$OUT" "$PREFIX/bin" "$PREFIX/lib/pkgconfig" "$PREFIX/include"

[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'Requires an Apple Silicon Mac'; exit 1; }

# Dependency discovery initialization
CHECK_ONLY="${CHECK_ONLY:-0}"
LOCAL_PREFIXES="${LOCAL_PREFIXES:-$HOME/.local:/usr/local:/opt/local}"
PREFIX="$WORK/prefix"

export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
export CFLAGS="-arch arm64 -mmacosx-version-min=$MIN_MACOS ${CFLAGS:-}"
export CXXFLAGS="-arch arm64 -mmacosx-version-min=$MIN_MACOS ${CXXFLAGS:-}"
export LDFLAGS="-arch arm64 -mmacosx-version-min=$MIN_MACOS ${LDFLAGS:-}"

BREW=""
if command -v brew >/dev/null 2>&1; then
BREW="$(brew --prefix 2>/dev/null || true)"
elif [[ -x /opt/homebrew/bin/brew ]]; then
BREW="$(/opt/homebrew/bin/brew --prefix 2>/dev/null || true)"
fi

SEARCH_PREFIXES=("$PREFIX")
[[ -z "$BREW" ]] || SEARCH_PREFIXES+=("$BREW")
IFS=: read -r -a EXTRA_PREFIXES <<< "$LOCAL_PREFIXES"
for p in "${EXTRA_PREFIXES[@]}"; do
[[ -d "$p" ]] && SEARCH_PREFIXES+=("$p")
done

# Map paths for environment discovery tools
for p in "${SEARCH_PREFIXES[@]}"; do
[[ -d "$p/bin" ]] && PATH="$p/bin:$PATH"
done
export PATH

report_dependency() {
    local name="$1" cmd="$2" brew_formula="$3" hint="$4"
    if command -v "$cmd" >/dev/null 2>&1; then
    printf '  [FOUND] %-16s %s\n' "$name" "$(command -v "$cmd")"
    else
    printf '  [MISSING] %-16s %s\n' "$name" "$hint"
    [[ -z "$BREW" ]] || printf '            Homebrew: brew install %s\n' "$brew_formula"
    MISSING_TOOLS=1
    fi
}

MISSING_TOOLS=0
printf '\n=== ModMPV macOS 15+ dependency preflight ===\n'
printf 'Homebrew: %s\n' "${BREW:-not installed (optional)}"
printf 'Search prefixes: %s\n' "${SEARCH_PREFIXES[*]}"

if [[ "$PACKAGE_ONLY" != 1 && "$FFMPEG_ONLY" != 1 ]]; then
report_dependency 'git' git git 'Install Git or Xcode Command Line Tools'
report_dependency 'ninja' ninja ninja 'Install Ninja'
report_dependency 'pkg-config' pkg-config pkgconf 'Install pkgconf'
report_dependency 'python3' python3 python 'Install Python 3'
report_dependency 'autoconf' autoconf autoconf 'Required to generate sandbox config files'
report_dependency 'automake' automake automake 'Required to generate custom project makefiles'
report_dependency 'glibtool' glibtoolize libtool 'Required for GNU shared macro processing'
report_dependency 'cargo' cargo rustc 'Install Rust via Homebrew or rustup to compile libdovi'

# ADAPTIVE NASM PREFLIGHT CHECK INJECTED HERE
if command -v nasm >/dev/null 2>&1; then
printf '  [FOUND] %-16s %s (Using system assembler)\n' 'nasm' "$(command -v nasm)"
else
printf '  [INFO]  %-16s %s\n' 'nasm' 'No system assembly fallback; script will build custom sandbox NASM'
fi

fi

# SURGICAL LAYER ADDED HERE: Track host manual generation tools upfront
for t in clang xcrun otool lipo plutil nm meson; do
report_dependency "$t" "$t" "$t" 'Required development system utility'
done
if [[ "$PACKAGE_ONLY" != 1 && "$FFMPEG_ONLY" != 1 ]]; then
    for t in install_name_tool make cmake help2man; do
        report_dependency "$t" "$t" "$t" 'Required development system utility'
    done
fi

if [[ "$XCFRAMEWORK" == 1 ]]; then
report_dependency 'xcodebuild' xcodebuild '' 'Install full Xcode, or set XCFRAMEWORK=0'
fi

if [[ "$CHECK_ONLY" == 1 ]]; then
echo 'Preflight only: no packages installed or builds started.'
[[ "$MISSING_TOOLS" == 0 ]] && exit 0 || exit 2
fi

if [[ "$MISSING_TOOLS" != 0 ]]; then
echo 'Missing tool prerequisites. Install via Homebrew, rerun.' >&2
exit 2
fi

# Set custom compiler environment sandbox constraints once preflight validation clears
SDK_PATH="$(xcrun --show-sdk-path)"
export CFLAGS="-arch arm64 -isysroot $SDK_PATH -mmacosx-version-min=$MIN_MACOS -I$PREFIX/include -O3 ${CFLAGS:-}"
export CXXFLAGS="-arch arm64 -isysroot $SDK_PATH -mmacosx-version-min=$MIN_MACOS -I$PREFIX/include -O3 ${CXXFLAGS:-}"
export LDFLAGS="-arch arm64 -isysroot $SDK_PATH -mmacosx-version-min=$MIN_MACOS -L$PREFIX/lib ${LDFLAGS:-}"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig:$PREFIX/share/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
export PKG_CONFIG="$(command -v pkg-config)"

# macOS SDK supplies zlib, but does not supply a zlib.pc file.
# libpng18.pc requires zlib, so provide SDK-only pkg-config metadata.
# The version below is a compatibility floor, not the SDK's exact version.
if [[ ! -f "$PREFIX/lib/pkgconfig/zlib.pc" ]]; then
    cat > "$PREFIX/lib/pkgconfig/zlib.pc" <<'EOF_ZLIB_PC'
prefix=/usr
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include

Name: zlib
Description: zlib provided by the macOS SDK
Version: 1.2.11
Libs: -lz
Cflags:
EOF_ZLIB_PC
fi

mkdir -p "$WORK" "$OUT" "$PREFIX/bin" "$PREFIX/lib/pkgconfig" "$PREFIX/include"

# Centralized, retryable Git fetch. Existing valid checkouts are preserved.
# GIT_RETRIES and GIT_RETRY_DELAY can be overridden by the caller.
git_retry() {
    local attempt=1 max="${GIT_RETRIES:-3}" delay="${GIT_RETRY_DELAY:-5}"
    while (( attempt <= max )); do
        if git -c http.version=HTTP/1.1 "$@"; then return 0; fi
        if (( attempt == max )); then
            echo "ERROR: Git failed after $max attempts: git $*" >&2
            return 1
        fi
        echo "WARNING: Git command failed (attempt $attempt/$max); retrying in ${delay}s..." >&2
        sleep "$delay"
        attempt=$((attempt + 1))
    done
}

fetch() {
    local url="$1" path="$2" ref="$3" recursive="${4:-0}"
    local -a clone_args=(--depth 1)
    [[ "$recursive" == 1 ]] && clone_args+=(--recursive)

    if [[ -d "$path/.git" ]] && git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        local existing_url
        existing_url="$(git -C "$path" remote get-url origin 2>/dev/null || true)"
        if [[ "$existing_url" == "$url" ]]; then
            echo "Reusing existing checkout: $(basename "$path")"
        else
            echo "WARNING: source URL changed for $path; replacing checkout" >&2
            rm -rf "$path"
        fi
    elif [[ -e "$path" ]]; then
        echo "Removing incomplete checkout: $path"
        rm -rf "$path"
    fi

    if [[ ! -d "$path/.git" ]]; then
        echo "Cloning $(basename "$path")..."
        # Remove partial clones before each attempt, without discarding valid checkouts.
        local attempt=1 max="${GIT_RETRIES:-3}" delay="${GIT_RETRY_DELAY:-5}"
        while :; do
            rm -rf "$path"
            if git -c http.version=HTTP/1.1 clone "${clone_args[@]}" "$url" "$path"; then break; fi
            if (( attempt >= max )); then
                echo "ERROR: Unable to clone $url after $max attempts" >&2
                return 1
            fi
            echo "WARNING: Clone failed ($attempt/$max); retrying in ${delay}s..." >&2
            sleep "$delay"
            attempt=$((attempt + 1))
        done
    fi

    # Reuse local refs without contacting the network; fetch only the requested
    # ref when it is missing. Do not fetch every tag on every invocation.
    if ! git -C "$path" rev-parse --verify -q "refs/tags/$ref^{commit}" >/dev/null && \
       ! git -C "$path" rev-parse --verify -q "refs/remotes/origin/$ref^{commit}" >/dev/null && \
       ! git -C "$path" rev-parse --verify -q "refs/heads/$ref^{commit}" >/dev/null; then
        echo "Fetching requested ref $ref for $(basename "$path")..."
        git_retry -C "$path" fetch --depth 1 origin "$ref"
    fi
    git -C "$path" checkout -f "$ref" 2>/dev/null || \
        git -C "$path" checkout -f FETCH_HEAD
    git -C "$path" reset --hard HEAD
    # Do not git clean -dfx here: retaining build outputs is essential for resuming.
    if [[ "$recursive" == 1 ]]; then
        git_retry -C "$path" submodule update --init --recursive --depth 1
    fi
}

if [[ "$PACKAGE_ONLY" == 1 || "$FFMPEG_ONLY" == 1 || "$MPV_ONLY" == 1 ]]; then
    echo '=== Reusing existing third-party dependencies ==='
else
    echo "=== Building Sandbox Dependencies ==="

# Snappy is required by FFmpeg's HAP encoder and decoder.
if [[ ! -s "$PREFIX/lib/libsnappy.a" || ! -s "$PREFIX/include/snappy-c.h" ]]; then
    echo "Building static Snappy for HAP support..."
    fetch https://github.com/google/snappy.git "$WORK/snappy" "${SNAPPY_REF:-1.3.1}"
    cmake -S "$WORK/snappy" -B "$WORK/snappy-build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
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
fi
[[ -s "$PREFIX/lib/libsnappy.a" && -s "$PREFIX/include/snappy-c.h" ]] || {
    echo "ERROR: static Snappy archive/header missing; HAP support cannot be built" >&2
    exit 1
}

# 1. NasM (For assembly optimizations)
if [[ ! -x "$PREFIX/bin/nasm" ]]; then
echo "Building NASM assembler..."
fetch https://github.com/netwide-assembler/nasm "$WORK/nasm" "master"
pushd "$WORK/nasm" >/dev/null
./autogen.sh || true
./configure --prefix="$PREFIX"
# SURGICAL STANDARD SEQUENCE
make -j "$JOBS"
touch nasm.1 ndisasm.1
make install
popd >/dev/null
fi

# 1b. Libpng (Static Image Rendering Vector Layer)
if [[ ! -f "$PREFIX/lib/libpng.a" ]]; then
echo "Building Libpng for raster graphic overlays..."
fetch https://github.com/pnggroup/libpng.git "$WORK/libpng" "libpng18"
pushd "$WORK/libpng" >/dev/null
./autogen.sh || true
./configure --prefix="$PREFIX" --enable-static --disable-shared
make -j "$JOBS" && make install
popd >/dev/null
fi

# 1c. Brotli (Static, sandbox-local; required by FreeType WOFF2 support)
if [[ ! -s "$PREFIX/lib/libbrotlidec.a" || ! -s "$PREFIX/lib/libbrotlicommon.a" || ! -s "$PREFIX/lib/libbrotlienc.a" ]]; then
    echo "Building Brotli static libraries..."
    if [[ ! -f "$WORK/brotli/CMakeLists.txt" ]]; then
        fetch https://github.com/google/brotli.git "$WORK/brotli" "v1.1.0"
    fi
    cmake -S "$WORK/brotli" -B "$WORK/brotli-build-macos15" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
        -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBROTLI_DISABLE_TESTS=ON
    cmake --build "$WORK/brotli-build-macos15" --config Release --parallel "$JOBS"
    cmake --install "$WORK/brotli-build-macos15" --config Release
fi
for brotli_archive in libbrotlidec.a libbrotlicommon.a libbrotlienc.a; do
    [[ -s "$PREFIX/lib/$brotli_archive" ]] || {
        echo "ERROR: Brotli archive missing: $PREFIX/lib/$brotli_archive" >&2
        exit 1
    }
done

# Verify libpng's transitive zlib dependency before configuring FreeType.
if ! "$PKG_CONFIG" --exists libpng; then
    echo 'ERROR: libpng pkg-config dependency resolution failed:' >&2
    "$PKG_CONFIG" --print-errors --exists libpng || true
    exit 1
fi
printf 'Sandbox libpng version: %s\n' "$("$PKG_CONFIG" --modversion libpng)"

# 2. Freetype (Static)
if [[ ! -f "$PREFIX/lib/libfreetype.a" ]]; then
echo "Building Freetype..."
fetch https://gitlab.freedesktop.org/freetype/freetype.git "$WORK/freetype" "VER-2-15-0"
pushd "$WORK/freetype" >/dev/null
./autogen.sh || true
# SURGICAL PARAMETER UPDATE: Swapped --with-png=no to yes
PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig" ./configure --prefix="$PREFIX" --enable-static --disable-shared --with-harfbuzz=no --with-png=yes --with-brotli=yes
make -j "$JOBS" && make install
popd >/dev/null
fi

# 2b. libjpeg-turbo (static JPEG API used by mpv image writer)
if [[ ! -s "$PREFIX/lib/libjpeg.a" ]]; then
    echo "=== Building libjpeg-turbo (macOS $MIN_MACOS arm64) ==="
    if [[ ! -f "$WORK/libjpeg-turbo/CMakeLists.txt" ]]; then
        fetch https://github.com/libjpeg-turbo/libjpeg-turbo.git "$WORK/libjpeg-turbo" "3.1.1"
    fi
    cmake -S "$WORK/libjpeg-turbo" -B "$WORK/libjpeg-turbo-build-macos15" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_PREFIX_PATH="$PREFIX" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
        -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
        -DENABLE_SHARED=OFF \
        -DENABLE_STATIC=ON \
        -DWITH_TURBOJPEG=OFF \
        -DWITH_TESTS=OFF
    cmake --build "$WORK/libjpeg-turbo-build-macos15" --parallel "$JOBS"
    cmake --install "$WORK/libjpeg-turbo-build-macos15"
fi
[[ -s "$PREFIX/lib/libjpeg.a" ]] || { echo "ERROR: missing local libjpeg.a" >&2; exit 1; }

# 2c. libunibreak (static Unicode line breaking used by libass)
if [[ ! -s "$PREFIX/lib/libunibreak.a" ]]; then
    echo "=== Building libunibreak (macOS $MIN_MACOS arm64) ==="
    if [[ ! -f "$WORK/libunibreak/configure" && ! -f "$WORK/libunibreak/autogen.sh" ]]; then
        fetch https://github.com/adah1972/libunibreak.git "$WORK/libunibreak" "libunibreak_6_1"
    fi
    pushd "$WORK/libunibreak" >/dev/null
    if [[ ! -x ./configure ]]; then
        ./autogen.sh
    fi
    PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig" \
        ./configure --prefix="$PREFIX" --enable-static --disable-shared
    make -j "$JOBS"
    make install
    popd >/dev/null
fi
[[ -s "$PREFIX/lib/libunibreak.a" ]] || { echo "ERROR: missing local libunibreak.a" >&2; exit 1; }

# 3. Fribidi (Static)
if [[ ! -f "$PREFIX/lib/libfribidi.a" ]]; then
echo "Building Fribidi via Meson..."
fetch https://github.com/fribidi/fribidi.git "$WORK/fribidi" "v1.0.18"
pushd "$WORK/fribidi" >/dev/null

# Build cleanly using Meson to match your other successful dependencies
meson setup build \
    --prefix="$PREFIX" \
    --buildtype=release \
    --default-library=static \
    -Ddocs=false \
    -Dtests=false

meson compile -C build && meson install -C build
popd >/dev/null
fi

# 4. Harfbuzz (Static)
if [[ ! -f "$PREFIX/lib/libharfbuzz.a" ]]; then
echo "Building Harfbuzz..."
fetch https://github.com/harfbuzz/harfbuzz.git "$WORK/harfbuzz" "15.0.0"
pushd "$WORK/harfbuzz" >/dev/null
if [[ -f meson.build ]]; then
# The HarfBuzz GPU utility links against FreeType's Brotli decoder without
# libbrotlicommon.a. We need the HarfBuzz library, not its command-line utilities.
meson setup build --prefix="$PREFIX" --buildtype=release --default-library=static \
    -Dglib=disabled -Dtests=disabled -Dutilities=disabled
meson compile -C build
meson install -C build
else
./autogen.sh || ./configure --prefix="$PREFIX" --enable-static --disable-shared --with-glib=no
make -j "$JOBS" && make install
fi
popd >/dev/null
fi
# Stop here if HarfBuzz was not actually installed; don't misdiagnose libass.
[[ -s "$PREFIX/lib/libharfbuzz.a" ]] || { echo "ERROR: HarfBuzz static archive missing after build" >&2; exit 1; }
PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig" \
    pkg-config --exists harfbuzz || { echo "ERROR: HarfBuzz pkg-config metadata missing" >&2; exit 1; }

# 5. Libass (Static Subtitle Engine)
if [[ ! -f "$PREFIX/lib/libass.a" ]]; then
echo "Building Libass..."
rm -rf "$WORK/libass" # Force clean state tracking
fetch https://github.com/libass/libass.git "$WORK/libass" "0.17.5"
pushd "$WORK/libass" >/dev/null
./autogen.sh || true
./configure --prefix="$PREFIX" --enable-static --disable-shared --disable-fontconfig --enable-coretext
make -j "$JOBS" && make install
popd >/dev/null
fi

# 6. Libvpx (Static VP9 Codecs)
if [[ ! -f "$PREFIX/lib/libvpx.a" ]]; then
echo "Building Libvpx..."
fetch https://github.com/webmproject/libvpx.git "$WORK/libvpx" "main"
pushd "$WORK/libvpx" >/dev/null
./configure --prefix="$PREFIX" --enable-static --disable-shared --enable-pic --disable-examples --disable-docs --target=arm64-darwin24-gcc
make -j "$JOBS" && make install
popd >/dev/null
fi

# 7. Dav1d (Static AV1)
if [[ ! -f "$PREFIX/lib/libdav1d.a" ]]; then
echo "Building Dav1d..."
fetch https://github.com/videolan/dav1d.git "$WORK/dav1d" "1.4.3"
pushd "$WORK/dav1d" >/dev/null
# SURGICAL UPDATE: Map option to modern name format
meson setup build --prefix="$PREFIX" --buildtype=release --default-library=static -Denable_tests=false
meson compile -C build && meson install -C build
popd >/dev/null
fi

# 8. Shaderc (Static shader compiler engine)
if [[ ! -f "$PREFIX/lib/libshaderc_combined.a" && ! -f "$PREFIX/lib/libshaderc.a" ]]; then
echo "Building Shaderc (Running git-sync-deps internally)..."
fetch https://github.com/google/shaderc.git "$WORK/shaderc" "main"
pushd "$WORK/shaderc" >/dev/null
./utils/git-sync-deps
mkdir -p build && cd build
cmake -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release -DSHADERC_ENABLE_SPVC=OFF -DSHADERC_SKIP_TESTS=ON ..
make -j "$JOBS" && make install
popd >/dev/null
fi

# 8b. Little CMS (Static ICC Color Management Matrix)
if [[ ! -f "$PREFIX/lib/liblcms2.a" ]]; then
echo "Building Little CMS for professional color grading paths..."
fetch https://github.com/mm2/Little-CMS.git "$WORK/lcms2" "lcms2.20"
pushd "$WORK/lcms2" >/dev/null
./autogen.sh || true
./configure --prefix="$PREFIX" --enable-static --disable-shared
make -j "$JOBS" && make install
popd >/dev/null
fi

# 8c. Uchardet (Static Universal Character Detection Layer)
if [[ ! -f "$PREFIX/lib/libuchardet.a" ]]; then
echo "Building Uchardet text encoding decoder..."
fetch https://gitlab.freedesktop.org/uchardet/uchardet.git "$WORK/uchardet" "v0.0.8"
pushd "$WORK/uchardet" >/dev/null
mkdir -p build && cd build
# SURGICAL UPDATE: Injected CMAKE_POLICY_VERSION_MINIMUM to bypass the modern CMake breaking change
cmake -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release -DBUILD_BINARY=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 ..
make -j "$JOBS" && make install
popd >/dev/null
fi

# 8d. LuaJIT (Static High-Performance Scripting Subsystem)
if [[ ! -f "$PREFIX/lib/libluajit-5.1.a" ]]; then
echo "Building LuaJIT for high-performance scripting pipelines..."
fetch "https://github.com/LuaJIT/LuaJIT.git" "$WORK/luajit" "v2.1"
pushd "$WORK/luajit" >/dev/null

# Force a clean static build targeting your macOS architecture rules
make -j "$JOBS" MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS" CFLAGS="-arch arm64" LDFLAGS="-arch arm64" BUILDMODE=static
make install PREFIX="$PREFIX"

# Surgically create the missing standard symlink if it doesn't map automatically
[[ -f "$PREFIX/lib/libluajit-5.1.a" ]] || ln -s libluajit-5.1.2.1.a "$PREFIX/lib/libluajit-5.1.a" 2>/dev/null || true
popd >/dev/null
fi

# 8e. MoltenVK: preserve the working Xcode/macOS 15 override and extract STATIC archive.
if [[ ! -d "$PREFIX/include/vulkan" || ! -s "$PREFIX/lib/libMoltenVK.a" ]]; then
    echo "=== Building MoltenVK with explicit macOS $MIN_MACOS / arm64 Xcode settings ==="
    fetch "https://github.com/KhronosGroup/MoltenVK.git" "$WORK/moltenvk" "v1.4.2"
    pushd "$WORK/moltenvk" >/dev/null

    # Preserve the proven v5 workaround: fetch using the macOS selection,
    # but intercept upstream before it invokes its own Xcode build loop.
    # The actual external-library build follows with our explicit xcconfig.
    python3 - ./fetchDependencies <<'PY_MVK_FETCH'
from pathlib import Path
import sys
path = Path(sys.argv[1])
source = path.read_text()
marker = '# -------------- Build MoltenVK external library dependencies -----------------'
if source.count(marker) != 1:
    raise SystemExit('ERROR: upstream fetchDependencies build boundary changed; refusing unsafe patch')
source = source.replace(marker,
    'echo "Downloads complete; external Xcode builds deferred to macOS 15 override."\n'
    'exit 0\n' + marker, 1)
path.write_text(source)
PY_MVK_FETCH
    ./fetchDependencies --macos

    ABS_CONFIG="$(pwd)/global_overrides.xcconfig"
    cat > "$ABS_CONFIG" <<EOF_MVK_CONFIG
MACOSX_DEPLOYMENT_TARGET = $MIN_MACOS
CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = NO
ARCHS = arm64
ONLY_ACTIVE_ARCH = YES
EOF_MVK_CONFIG
    export XCODE_XCCONFIG_FILE="$ABS_CONFIG"
    xcodebuild -project ExternalDependencies.xcodeproj \
        -scheme "ExternalDependencies-macOS" \
        -xcconfig "$ABS_CONFIG" \
        -derivedDataPath "External/build" \
        SYMROOT="External/build" OBJROOT="External/build" \
        ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
        MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS" build

    # Xcode may create Latest as a symlink to Release; copying it onto itself
    # exits nonzero on macOS and aborts the build under set -e.
    if [[ ! -e External/build/Latest && ! -L External/build/Latest && -d External/build/Release ]]; then
        ln -s Release External/build/Latest
    fi
    make macos ARCHS=arm64 ONLY_ACTIVE_ARCH=YES MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"

    # Upstream packaging produces XCFrameworks; extract ONLY the static arm64 slice.
    mvk_archives=()
    while IFS= read -r archive; do
        mvk_archives+=("$archive")
    done < <(find Package -type f -name libMoltenVK.a -path '*/static/*' -path '*/macos-arm64/*' -print 2>/dev/null)
    if (( ${#mvk_archives[@]} != 1 )); then
        printf 'ERROR: expected exactly one static macos-arm64 libMoltenVK.a, found %s\n' "${#mvk_archives[@]}" >&2
        printf 'Candidates:\n%s\n' "${mvk_archives[*]:-none}" >&2
        exit 1
    fi
    lipo -verify_arch arm64 "${mvk_archives[0]}"
    mkdir -p "$PREFIX/lib" "$PREFIX/include"
    cp "${mvk_archives[0]}" "$PREFIX/lib/libMoltenVK.a"
    if [[ -d include/vulkan ]]; then
        cp -R include/vulkan "$PREFIX/include/"
    elif [[ -d Package/Latest/MoltenVK/include/vulkan ]]; then
        cp -R Package/Latest/MoltenVK/include/vulkan "$PREFIX/include/"
    else
        echo 'ERROR: MoltenVK Vulkan headers not found' >&2; exit 1
    fi
    unset XCODE_XCCONFIG_FILE
    rm -f "$ABS_CONFIG"
    popd >/dev/null
fi

# 8e-1. Install the complete Vulkan SDK headers, including vk_video/.
# MoltenVK's packaged include/vulkan directory alone is not a complete
# Vulkan-Headers installation; libplacebo includes vulkan_core.h, which
# references the sibling vk_video/vulkan_video_codec_*.h headers.
VULKAN_HEADERS_REF="${VULKAN_HEADERS_REF:-v1.4.304}"
if [[ ! -s "$PREFIX/include/vk_video/vulkan_video_codec_h264std.h" ]]; then
    echo "=== Installing sandbox Vulkan-Headers $VULKAN_HEADERS_REF (vk_video) ==="
    fetch 'https://github.com/KhronosGroup/Vulkan-Headers.git' "$WORK/vulkan-headers" "$VULKAN_HEADERS_REF"
    if [[ ! -s "$WORK/vulkan-headers/include/vulkan/vulkan_core.h" || ! -s "$WORK/vulkan-headers/include/vk_video/vulkan_video_codec_h264std.h" ]]; then
        echo 'ERROR: Vulkan-Headers checkout is incomplete (vulkan/ or vk_video/ missing).' >&2
        exit 1
    fi
    # Keep vulkan/ and vk_video/ from the same SDK release to avoid header
    # version skew. This replaces only headers, not MoltenVK binaries.
    mkdir -p "$PREFIX/include/vulkan" "$PREFIX/include/vk_video"
    cp -R "$WORK/vulkan-headers/include/vulkan/." "$PREFIX/include/vulkan/"
    cp -R "$WORK/vulkan-headers/include/vk_video/." "$PREFIX/include/vk_video/"
fi
[[ -s "$PREFIX/include/vk_video/vulkan_video_codec_h264std.h" ]] || {
    echo 'ERROR: Vulkan video headers still missing after installation.' >&2; exit 1;
}

# 8e-2. Private dynamic Vulkan Loader. Upstream macOS loader produces a dylib,
# not libvulkan.a; use its actual output and keep it within the framework.
VULKAN_LOADER_REF="${VULKAN_LOADER_REF:-v1.4.304}"
if [[ ! -s "$PREFIX/lib/libvulkan.dylib" ]]; then
    echo '=== Building private Vulkan Loader dylib ==='
    fetch 'https://github.com/KhronosGroup/Vulkan-Loader.git' "$WORK/vulkan-loader" "$VULKAN_LOADER_REF"
    cmake -S "$WORK/vulkan-loader" -B "$WORK/vulkan-loader-build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_PREFIX_PATH="$PREFIX" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
        -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
        -DBUILD_TESTS=OFF -DBUILD_WSI_XCB_SUPPORT=OFF \
        -DBUILD_WSI_XLIB_SUPPORT=OFF
    cmake --build "$WORK/vulkan-loader-build" --parallel "$JOBS"
    cmake --install "$WORK/vulkan-loader-build"
fi
[[ -s "$PREFIX/lib/libvulkan.dylib" ]] || { echo 'ERROR: private Vulkan Loader dylib missing' >&2; exit 1; }

# A Vulkan Loader requires a loadable ICD. A static MoltenVK archive cannot
# serve as a Vulkan ICD. Locate a matching dynamic MoltenVK library in the
# already-built MoltenVK package without rerunning its expensive Xcode build.
MOLTENVK_DYLIB="$PREFIX/lib/libMoltenVK.dylib"
if [[ ! -s "$MOLTENVK_DYLIB" ]]; then
    while IFS= read -r candidate; do
        if [[ -s "$candidate" ]] && file "$candidate" | grep -q 'Mach-O' \
            && lipo -archs "$candidate" 2>/dev/null | tr ' ' '\n' | grep -qx arm64; then
            cp -L "$candidate" "$MOLTENVK_DYLIB"
            echo "Using existing macOS arm64 MoltenVK ICD: $candidate"
            break
        fi
    done < <(find "$WORK/moltenvk/Package" -type f -name 'libMoltenVK.dylib' \
        \( -path '*/dynamic/dylib/macOS/*' -o -path '*macos-arm64*' \) -print 2>/dev/null)
fi
if [[ ! -s "$MOLTENVK_DYLIB" ]]; then
    echo 'ERROR: No macOS arm64 dynamic MoltenVK ICD was found in the existing package.' >&2
    echo 'The static MoltenVK archive cannot be loaded by the Vulkan Loader.' >&2
    echo 'Expected Package/Release/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib (arm64).' >&2
    exit 1
fi

# 8f. OpenSSL (Static Cryptography & TLS Layer for Secure Streaming)
if [[ ! -f "$PREFIX/lib/libssl.a" ]]; then
echo "Building OpenSSL for secure streaming layers..."
fetch "https://github.com/openssl/openssl.git" "$WORK/openssl" "openssl-4.1.0"
pushd "$WORK/openssl" >/dev/null
./Configure darwin64-arm64-cc no-shared no-tests --prefix="$PREFIX" --openssldir="$PREFIX/ssl"
make -j "$JOBS"
make install_sw
popd >/dev/null
fi

# 8g. Libdovi (Static Dolby Vision Dynamic RPU Parsing Layer)
if [[ ! -f "$PREFIX/lib/libdovi.a" || "${REBUILD_DOVI:-0}" == 1 ]]; then
echo "Building Libdovi Dolby Vision metadata engine..."
fetch "https://github.com/quietvoid/dovi_tool.git" "$WORK/libdovi" "main"
pushd "$WORK/libdovi/dolby_vision" >/dev/null

# Ensure cargo-c is present to create standard C header / static library outputs
if ! cargo cbuild --version >/dev/null 2>&1; then
    echo "Installing cargo-c helper tool extensions natively..."
    cargo install cargo-c
fi

# Use a rustup-managed compiler, not the Homebrew host compiler.
# A dedicated Cargo target directory prevents reusing macOS 27 objects.
command -v rustup >/dev/null || { echo "ERROR: rustup required for libdovi" >&2; exit 2; }
RUST_TOOLCHAIN="${RUST_TOOLCHAIN:-stable}"
RUSTC_PATH="$(rustup which rustc --toolchain "$RUST_TOOLCHAIN")" || {
  echo "ERROR: rustup toolchain $RUST_TOOLCHAIN unavailable; run rustup toolchain install $RUST_TOOLCHAIN" >&2; exit 2;
}
rustup target list --installed --toolchain "$RUST_TOOLCHAIN" | grep -Fxq aarch64-apple-darwin || {
  echo "ERROR: run rustup target add aarch64-apple-darwin --toolchain $RUST_TOOLCHAIN" >&2; exit 2;
}
CARGO_TARGET_DIR="$WORK/libdovi-target-macos15.4" \
RUSTC="$RUSTC_PATH" \
MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
CARGO_BUILD_TARGET=aarch64-apple-darwin \
CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER="$(xcrun -f clang)" \
CARGO_ENCODED_RUSTFLAGS="-Clink-arg=-mmacosx-version-min=${MIN_MACOS}" \
CARGO_INCREMENTAL=0 \
cargo cinstall --release --target aarch64-apple-darwin --prefix="$PREFIX" --library-type=staticlib

popd >/dev/null
fi

# 9. Libplacebo (Static with Metal GPU & Shaderc mapping)
if [[ ! -f "$PREFIX/lib/libplacebo.a" ]]; then
echo "Building Libplacebo rendering pipeline..."
fetch "https://github.com/haasn/libplacebo" "$WORK/libplacebo" "master" 1
pushd "$WORK/libplacebo" >/dev/null

export CPATH="$PREFIX/include:${CPATH:-}"
export LIBRARY_PATH="$PREFIX/lib:${LIBRARY_PATH:-}"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig:$PREFIX/share/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
export PKG_CONFIG="$(command -v pkg-config)"

meson setup build \
    --prefix="$PREFIX" \
    --buildtype=release \
    --default-library=static \
    -Dshaderc=enabled \
    -Dlcms=enabled \
    -Dvulkan=enabled \
    -Ddovi=enabled \
    -Dpkg_config_path="$PREFIX/lib/pkgconfig"

meson compile -C build && meson install -C build
popd >/dev/null
fi


fi # End third-party dependency build block.

if [[ "$DEPENDENCIES_ONLY" == 1 ]]; then
    echo "SUCCESS: Dependency build completed; existing FFmpeg and mpv untouched."
    exit 0
fi

if [[ "$PACKAGE_ONLY" == 1 ]]; then
    echo '=== PACKAGE_ONLY: reusing installed FFmpeg and mpv static archives ==='
    [[ -d "$WORK/mpv" ]] || { echo "ERROR: missing mpv sources at $WORK/mpv (needed for framework headers/licenses)" >&2; exit 2; }
    [[ -d "$WORK/ffmpeg" ]] || { echo "ERROR: missing FFmpeg sources at $WORK/ffmpeg (needed for license files)" >&2; exit 2; }
    for archive in libavcodec.a libavfilter.a libavformat.a libavutil.a libswresample.a libswscale.a; do
        [[ -s "$PREFIX/lib/$archive" ]] || { echo "ERROR: missing $PREFIX/lib/$archive; run a full build first." >&2; exit 2; }
    done
else
if [[ "$MPV_ONLY" == 1 ]]; then
  echo "=== MPV_ONLY: reusing existing FFmpeg and sandbox dependencies ==="
  for lib in libavcodec.a libavfilter.a libavformat.a libavutil.a libswresample.a libswscale.a libdovi.a libplacebo.a libass.a libfreetype.a libharfbuzz.a; do
    [[ -s "$PREFIX/lib/$lib" ]] || { echo "ERROR: missing $PREFIX/lib/$lib" >&2; exit 2; }
  done
  echo "PASS: required core static archives present"
fi
if [[ "$MPV_ONLY" != 1 ]]; then
    echo "=== Building Isolation-Layer FFmpeg (Pure Static) ==="
if [[ "$FFMPEG_ONLY" == 1 ]]; then
    [[ -f "$WORK/ffmpeg/configure" ]] || { echo "ERROR: existing FFmpeg sources missing" >&2; exit 2; }
    [[ -s "$WORK/mpv-install/lib/libmpv.a" || -s "$WORK/mpv-build/libmpv.a" ]] || { echo "ERROR: existing mpv archive missing" >&2; exit 2; }
    echo "Reconfiguring existing FFmpeg source; mpv and other dependencies will not rebuild."
else
    fetch "https://github.com/FFmpeg/FFmpeg.git" "$WORK/ffmpeg" "$FFMPEG_REF"
fi
# FFmpeg performs executable link checks for optional libraries. Since our
# sandbox libraries are static, request Libs.private/Requires.private too.
# Verify the exact Brotli dependency that previously broke FreeType detection.
echo "=== Checking sandbox FreeType static pkg-config linkage ==="
"$PKG_CONFIG" --exists freetype2 || {
    echo "ERROR: sandbox freetype2.pc not found" >&2; exit 1;
}
FREETYPE_STATIC_LIBS="$("$PKG_CONFIG" --static --libs freetype2)"
printf 'FreeType static flags: %s\n' "$FREETYPE_STATIC_LIBS"
[[ " $FREETYPE_STATIC_LIBS " == *" -lbrotlidec "* ]] || {
    echo "ERROR: freetype2.pc lacks Brotli decoder dependency" >&2; exit 1;
}
[[ " $FREETYPE_STATIC_LIBS " == *" -lbrotlicommon "* ]] || {
    echo "ERROR: freetype2.pc lacks Brotli common dependency" >&2; exit 1;
}
[[ -s "$PREFIX/lib/libbrotlicommon.a" ]] || {
    echo "ERROR: sandbox libbrotlicommon.a missing" >&2; exit 1;
}

pushd "$WORK/ffmpeg" >/dev/null
make distclean >/dev/null 2>&1 || true

# FFmpeg's configure check links Snappy with GNU libstdc++; use Apple's libc++.
python3 - "$WORK/ffmpeg/configure" <<'PY_SNAPPY_CXX_RUNTIME'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
old = "require libsnappy snappy-c.h snappy_compress -lsnappy -lstdc++"
new = "require libsnappy snappy-c.h snappy_compress -lsnappy -lc++"
if source.count(old) != 1:
    raise SystemExit(
        "ERROR: expected exactly one FFmpeg Snappy configure check; "
        "review the upstream configure change before building"
    )
path.write_text(source.replace(old, new))
PY_SNAPPY_CXX_RUNTIME

# Force a pure static archive build footprint
./configure --prefix="$PREFIX" --cc="$(xcrun -f clang)" \
--host-cc="$(xcrun -f clang)" --host-cflags="-isysroot $SDK_PATH" --host-ldflags="-isysroot $SDK_PATH" \
--arch=aarch64 --target-os=darwin --enable-cross-compile \
--sysroot="$SDK_PATH" \
--pkg-config="$PKG_CONFIG" \
--pkg-config-flags="--static" \
--disable-gpl --disable-nonfree --disable-version3 \
--disable-shared --enable-static --enable-pic \
--enable-videotoolbox --enable-audiotoolbox \
--disable-indev=avfoundation \
--enable-libsnappy \
--disable-xlib --disable-libxcb --disable-indev=xcbgrab \
--enable-openssl \
--enable-libass --enable-libfreetype --enable-libfribidi --enable-libvpx --enable-libdav1d \
--disable-doc --disable-programs \
--extra-cflags="$CFLAGS" \
--extra-ldflags="$LDFLAGS"
for feature in GPL VERSION3 NONFREE; do
    if ! grep -Fxq "#define CONFIG_$feature 0" "$WORK/ffmpeg/config.h"; then
        echo "ERROR: FFmpeg enabled forbidden CONFIG_$feature" >&2
        exit 1
    fi
done
for feature in CONFIG_HAP_ENCODER CONFIG_HAP_DECODER; do
    if ! grep -h -Fxq "#define $feature 1" \
        "$WORK/ffmpeg/config_components.h"; then
        echo "ERROR: FFmpeg did not enable $feature" >&2
        exit 1
    fi
done
grep -Fxq '#define CONFIG_LIBSNAPPY 1' "$WORK/ffmpeg/config.h" || {
    echo 'ERROR: FFmpeg did not enable Snappy for HAP support' >&2
    exit 1
}

make -j "$JOBS" && make install
popd >/dev/null

if [[ "$FFMPEG_ONLY" == 1 ]]; then
    if ar -t "$PREFIX/lib/libavdevice.a" | grep -E '(^|/)xcbgrab\.o$' >/dev/null; then
        echo "ERROR: XCB capture object remains in libavdevice.a" >&2; exit 1
    fi
    echo "PASS: FFmpeg rebuilt without XCB capture; mpv preserved."
fi

fi # MPV_ONLY skips FFmpeg rebuild
[[ -s "$PREFIX/lib/libsnappy.a" ]] || {
    echo "ERROR: static Snappy library missing; HAP-enabled FFmpeg cannot be linked" >&2
    exit 2
}
for feature in CONFIG_GPL CONFIG_VERSION3 CONFIG_NONFREE; do
    grep -Fxq "#define $feature 0" "$WORK/ffmpeg/config.h" || {
        echo "ERROR: existing FFmpeg configuration does not prove $feature is disabled" >&2
        exit 2
    }
done
if ! grep -h -Fxq '#define CONFIG_AVFOUNDATION_INDEV 0' "$WORK/ffmpeg/config_components.h"; then
    echo "ERROR: AVFoundation capture input must be disabled to avoid ObjC class collisions" >&2
    exit 1
fi
for feature in CONFIG_HAP_ENCODER CONFIG_HAP_DECODER; do
    grep -Fxq "#define $feature 1" "$WORK/ffmpeg/config_components.h" || {
        echo "ERROR: existing FFmpeg configuration does not include $feature" >&2
        exit 2
    }
done
grep -Fxq '#define CONFIG_LIBSNAPPY 1' "$WORK/ffmpeg/config.h" || {
    echo 'ERROR: existing FFmpeg configuration does not include Snappy for HAP' >&2
    exit 2
}
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig:$PREFIX/share/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
export PKG_CONFIG="$(command -v pkg-config)"

if [[ "$FFMPEG_ONLY" != 1 ]]; then
echo "=== Compiling Customized Modern Libmpv (Pure Static Base) ==="
if [[ "$MPV_ONLY" == 1 ]]; then
  [[ -f "$WORK/mpv/meson.build" ]] || { echo "ERROR: existing mpv sources missing" >&2; exit 2; }
else
  fetch https://github.com/mpv-player/mpv.git "$WORK/mpv" "$MPV_REF"
fi

echo "Checking mpv macOS CAMetalLayer compatibility..."
MPV_MAC_VIEW="$WORK/mpv/video/out/mac/view.swift"
[[ -s "$MPV_MAC_VIEW" ]] || {
    echo "ERROR: expected mpv macOS view source is missing: $MPV_MAC_VIEW" >&2
    exit 1
}
if grep -Fq 'layer as? MetalLayer' "$MPV_MAC_VIEW"; then
    if ! grep -Fxq 'import Metal' "$MPV_MAC_VIEW"; then
        grep -Fxq 'import Cocoa' "$MPV_MAC_VIEW" || {
            echo "ERROR: cannot apply Metal import patch to $MPV_MAC_VIEW" >&2
            exit 1
        }
        sed -i '' '/^import Cocoa$/a\
import Metal
' "$MPV_MAC_VIEW"
    fi
    sed -i '' 's/layer as? MetalLayer/layer as? CAMetalLayer/g' "$MPV_MAC_VIEW"
    grep -Fq 'layer as? CAMetalLayer' "$MPV_MAC_VIEW" || {
        echo "ERROR: CAMetalLayer compatibility patch did not apply to $MPV_MAC_VIEW" >&2
        exit 1
    }
elif [[ -s "$WORK/mpv/video/out/mac/metal_layer.swift" ]] \
    && grep -Fq 'class MetalLayer: CAMetalLayer' "$WORK/mpv/video/out/mac/metal_layer.swift"; then
    echo "mpv already implements MetalLayer as a CAMetalLayer; no patch is needed."
else
    echo "ERROR: unsupported mpv macOS layer implementation; expected a MetalLayer cast or CAMetalLayer subclass" >&2
    exit 1
fi

rm -rf "$WORK/mpv-build" "$WORK/mpv-install"

# Change default library map to static target configuration
ARGS=(--buildtype=release --default-library=static --prefix="$WORK/mpv-install" -Dgpl=false -Dlibmpv=true -Dcplayer=false -Db_lto=false)
opt_exists() { grep -Eq "option\(['\"]$1['\"]" "$WORK/mpv/meson.options" "$WORK/mpv/meson_options.txt" 2>/dev/null; }
add_opt() { local name="$1" value="$2"; if opt_exists "$name"; then ARGS+=("-D$name=$value"); fi; }

add_opt cocoa enabled
add_opt macos-cocoa-cb enabled
add_opt videotoolbox enabled
add_opt libplacebo enabled
add_opt metal enabled
add_opt opengl enabled
add_opt vulkan enabled
add_opt uchardet enabled
add_opt lua luajit
add_opt coreaudio enabled
add_opt dovi enabled

# Meson Swift flags are retained for any normal Swift targets; the mpv custom
# Swift command is corrected separately after Meson setup below.
ARGS+=("-Dswift_args=-target,arm64-apple-macosx${MIN_MACOS}")
echo "Swift deployment target: arm64-apple-macosx${MIN_MACOS}"
meson setup "$WORK/mpv-build" "$WORK/mpv" "${ARGS[@]}" -Dpkg_config_path="$PKG_CONFIG_PATH"

# mpv invokes swiftc through a Meson custom target, bypassing -Dswift_args.
# Patch its generated Ninja command; accept Ninja's actual whitespace/command
# format rather than assuming exactly two leading spaces before COMMAND.
echo "=== Setting mpv custom Swift compiler deployment target to macOS $MIN_MACOS ==="
MPV_NINJA="$WORK/mpv-build/build.ninja" MIN_MACOS="$MIN_MACOS" python3 - <<'PY_SWIFT_TARGET'
import os, pathlib, re, sys
path = pathlib.Path(os.environ['MPV_NINJA'])
s = path.read_text()
target = '-target arm64-apple-macosx' + os.environ['MIN_MACOS']
lines = s.splitlines(keepends=True)
# Find the single generated command that compiles mpv's Swift source files.
# Ninja custom_target commands can be stored as COMMAND = ... with varying
# indentation and may have shell wrappers before the swiftc executable.
candidates = [i for i, line in enumerate(lines)
              if re.match(r'^\s*COMMAND\s*=', line)
              and re.search(r'(?<![\w.-])swiftc(?:\s|$)', line)
              and '-emit-library' in line and '-static' in line
              and 'osdep/mac/' in line]
if len(candidates) != 1:
    sample = [line[:240].strip() for line in lines
              if 'swiftc' in line and ('COMMAND' in line or '-emit-library' in line)]
    sys.exit(f'ERROR: expected one mpv Swift compile command, found {len(candidates)}. Candidates: {sample[:5]}')
i = candidates[0]
line = lines[i]
if re.search(r'(?<!\S)-target(?:\s|=)', line):
    if target not in line:
        sys.exit('ERROR: existing Swift command has a different -target')
else:
    # Insert immediately after swiftc, preserving the remaining command.
    lines[i], count = re.subn(r'(?<![\w.-])(swiftc)(?=\s)',
                              lambda m: m.group(1) + ' ' + target, line, count=1)
    if count != 1:
        sys.exit('ERROR: could not insert Swift target')
    path.write_text(''.join(lines))
print('PASS: mpv Swift command explicitly targets macOS ' + os.environ['MIN_MACOS'])
PY_SWIFT_TARGET
# Confirm Ninja sees the corrected command before compiling.
if ! ninja -C "$WORK/mpv-build" -t commands | grep -F -- "swiftc -target arm64-apple-macosx${MIN_MACOS}" >/dev/null; then
    echo 'ERROR: Ninja Swift compile command does not contain the requested target' >&2
    exit 2
fi
meson compile -C "$WORK/mpv-build" -j "$JOBS"
meson install -C "$WORK/mpv-build"
fi # End mpv build (skipped in FFMPEG_ONLY mode).

fi # End FFmpeg and mpv build block.

[[ -d "$WORK/mpv-build" ]] || {
    echo "ERROR: mpv Meson build metadata missing; cannot verify its GPL setting" >&2
    exit 2
}
python3 - "$WORK/mpv-build" <<'PY_MPV_GPL_CHECK'
import json
import subprocess
import sys

options = json.loads(subprocess.check_output(
    ["meson", "introspect", "--buildoptions", sys.argv[1]], text=True
))
gpl = [option for option in options if option.get("name") == "gpl"]
if len(gpl) != 1 or gpl[0].get("value") is not False:
    raise SystemExit("ERROR: mpv Meson configuration is not verified with gpl=false")
print("PASS: mpv Meson configuration confirms GPL features are disabled")
PY_MPV_GPL_CHECK

# Locate the existing or newly generated static archive.
# Keep this outside both branches so packaging always uses the same source.
# Locate the newly generated static archive library segment
STATIC_LIB="$(find "$WORK/mpv-install" -type f -name 'libmpv.a' | head -n 1)"
[[ -n "$STATIC_LIB" ]] || { echo 'No static libmpv.a produced'; exit 1; }
if [[ "$PACKAGE_ONLY" == 1 || "$FFMPEG_ONLY" == 1 ]]; then
    echo '=== Archive API diagnostics (before relinking) ==='
    if nm -g "$STATIC_LIB" 2>/dev/null | grep -E '[[:space:]]_mpv_create$' >/dev/null; then
        echo 'PASS: static archive contains global _mpv_create'
    else
        echo 'WARNING: static archive does not expose global _mpv_create; final link may fail its API check.'
        echo 'Inspect mpv Meson visibility flags or archive symbols before rebuilding.'
    fi
fi

# Avoid grep -q with pipefail: nm/ar may receive SIGPIPE and falsely fail checks.
# Repair empty mpv static archives using existing compiled object files.
# Meson incorrectly feeds a Swift static archive named swift.o to Apple's ar.
# Apple's libtool can merge the compiled C/ObjC objects and Swift archive.
repair_mpv_archive_if_needed() {
    local built="$WORK/mpv-build/libmpv.a"
    local objects="$WORK/mpv-build/libmpv.a.p"
    local swift="$WORK/mpv-build/osdep/mac/swift.o"
    local count size tmp
    size=$(stat -f %z "$STATIC_LIB" 2>/dev/null || echo 0)
    count=$(ar -t "$STATIC_LIB" 2>/dev/null | grep -Ec '\.(o|obj)$' || true)
    if (( size > 1024 && count > 0 )) && nm -g "$STATIC_LIB" 2>/dev/null | grep -E ' [Tt] _mpv_create$' >/dev/null; then
        echo 'PASS: existing libmpv.a contains object members and _mpv_create'
        return 0
    fi
    echo '=== Repairing empty/invalid libmpv.a from existing mpv build objects ==='
    [[ -d "$objects" ]] || { echo "ERROR: missing compiled objects: $objects" >&2; return 1; }
    [[ -f "$swift" ]] || { echo "ERROR: missing Swift archive: $swift" >&2; return 1; }
    /usr/bin/file "$swift"
    /usr/bin/ar -t "$swift" | grep -E '\.o$' >/dev/null || {
        echo 'ERROR: Swift archive has no object members' >&2; return 1;
    }
    local -a objfiles=()
    while IFS= read -r -d '' item; do objfiles+=("$item"); done < <(find "$objects" -type f -name '*.o' -print0)
    (( ${#objfiles[@]} > 100 )) || { echo 'ERROR: too few compiled mpv objects' >&2; return 1; }
    tmp="$WORK/libmpv-repaired-$$.a"
    rm -f "$tmp"
    xcrun libtool -static -o "$tmp" "${objfiles[@]}" "$swift" || { rm -f "$tmp"; return 1; }
    if ! nm -g "$tmp" 2>/dev/null | grep -E ' T _mpv_create$' >/dev/null; then
        echo 'ERROR: repaired archive does not define _mpv_create' >&2
        rm -f "$tmp"; return 1
    fi
    [[ $(stat -f %z "$tmp") -gt 100000 ]] || { echo 'ERROR: repaired archive is unexpectedly small' >&2; rm -f "$tmp"; return 1; }
    mkdir -p "$(dirname "$STATIC_LIB")"
    cp "$tmp" "$STATIC_LIB"
    cp "$tmp" "$built"
    rm -f "$tmp"
    echo "PASS: repaired mpv archive: $(du -h "$STATIC_LIB")"
}
repair_mpv_archive_if_needed

# =====================================================================
# STEP 1: CORRECTED MONOLITHIC LAYOUT DIRECTORY STRUCTURE
# =====================================================================
FW="$OUT/ModMPV.framework"
if [[ "$PACKAGE_ONLY" == 1 ]]; then
    echo "Using static libmpv: $STATIC_LIB"
fi
rm -rf "$FW"

# Create the explicit, nested Apple structural directories natively
mkdir -p "$FW/Versions/A/Headers"
mkdir -p "$FW/Versions/A/Modules"
mkdir -p "$FW/Versions/A/Resources/Legal"

# Discover all installed upstream public headers, rather than maintaining a
# potentially stale hand-curated list. The umbrella is generated below.
MPV_PUBLIC_HEADERS=()
MPV_HEADER_SOURCE="$WORK/mpv-install/include/mpv"
[[ -d "$MPV_HEADER_SOURCE" ]] || {
    echo "ERROR: mpv public headers were not installed: $MPV_HEADER_SOURCE" >&2
    exit 1
}
mkdir -p "$FW/Versions/A/Headers/mpv"
while IFS= read -r header; do
    MPV_PUBLIC_HEADERS+=("$header")
done < <(find "$MPV_HEADER_SOURCE" -maxdepth 1 -type f -name '*.h' -print | sed 's|.*/||' | LC_ALL=C sort)
(( ${#MPV_PUBLIC_HEADERS[@]} >= 4 )) || {
    echo 'ERROR: unexpectedly small upstream mpv public-header inventory' >&2; exit 1;
}
: > "$OUT/public-headers.txt"
{
    printf '#ifndef MOD_MPV_UMBRELLA_H\n#define MOD_MPV_UMBRELLA_H\n'
    for header in "${MPV_PUBLIC_HEADERS[@]}"; do
        cp "$MPV_HEADER_SOURCE/$header" "$FW/Versions/A/Headers/mpv/$header"
        printf '%s\n' "mpv/$header" >> "$OUT/public-headers.txt"
        printf '#include "mpv/%s"\n' "$header"
    done
    printf '#endif\n'
} > "$FW/Versions/A/Headers/ModMPV.h"

cat > "$FW/Versions/A/Modules/module.modulemap" <<'EOF'
framework module ModMPV {
    umbrella header "ModMPV.h"
    export *
    module * { export * }
}
EOF

# 1. Establish the base version tracker anchor FIRST
ln -sf A "$FW/Versions/Current"

# 2. Draw your clean relative tracking pointers safely underneath it
ln -sf Versions/Current/ModMPV "$FW/ModMPV"
ln -sf Versions/Current/Headers "$FW/Headers"
ln -sf Versions/Current/Modules "$FW/Modules"
ln -sf Versions/Current/Resources "$FW/Resources"

# Preserve all FFmpeg Vulkan objects. Removing vulkan.o breaks references to
# ff_vk_* helpers from FFmpeg encoders and filters. Do not mutate static archives.
# The linker below extracts only the required members from dependency archives.

echo "=== Packaging Unified Monolithic Binary Block via Clang (v17, macOS $MIN_MACOS) ==="
# Detect shaderc filename layout safely
SHADERC_STATIC=""
if [[ -f "$PREFIX/lib/libshaderc_combined.a" ]]; then
    SHADERC_STATIC="$PREFIX/lib/libshaderc_combined.a"
elif [[ -f "$PREFIX/lib/libshaderc.a" ]]; then
    SHADERC_STATIC="$PREFIX/lib/libshaderc.a"
fi

# Only force-load the libmpv archive to retain its exported C API.
# Ordinary static archive linking selects required members without dragging in
# every FFmpeg Vulkan encoder and causing duplicate/unresolved symbols.
DEPENDENCY_LIBS=(
    "$PREFIX/lib/libavcodec.a"
    "$PREFIX/lib/libavfilter.a"
    "$PREFIX/lib/libavformat.a"
    "$PREFIX/lib/libavutil.a"
    "$PREFIX/lib/libswresample.a"
    "$PREFIX/lib/libswscale.a"
    "$PREFIX/lib/libavdevice.a"
    "$PREFIX/lib/libsnappy.a"
    "$PREFIX/lib/libssl.a"
    "$PREFIX/lib/libcrypto.a"
    "$PREFIX/lib/libplacebo.a"
    "${SHADERC_STATIC:-$PREFIX/lib/libshaderc.a}"
    "$PREFIX/lib/libvulkan.dylib"
    "$PREFIX/lib/libass.a"
    "$PREFIX/lib/libunibreak.a"
    "$PREFIX/lib/libfreetype.a"
    "$PREFIX/lib/libjpeg.a"
    "$PREFIX/lib/libbrotlidec.a"
    "$PREFIX/lib/libbrotlicommon.a"
    "$PREFIX/lib/libfribidi.a"
    "$PREFIX/lib/libharfbuzz.a"
    "$PREFIX/lib/libpng.a"
    "$PREFIX/lib/libvpx.a"
    "$PREFIX/lib/libdav1d.a"
    "$PREFIX/lib/liblcms2.a"
    "$PREFIX/lib/libuchardet.a"
    "$PREFIX/lib/libluajit-5.1.a"
    "$PREFIX/lib/libdovi.a"
)

if [[ "$PACKAGE_ONLY" == 1 || "$FFMPEG_ONLY" == 1 ]]; then
    for lib in "${DEPENDENCY_LIBS[@]}"; do
        [[ -s "$lib" ]] || { echo "ERROR: missing dependency archive: $lib" >&2; exit 2; }
    done
fi

# Apple HVF (Hierarchical Variable Fonts) is supplied by the macOS SDK,
# not a sandbox static archive. Weak-link it for the macOS 15.4 deployment
# target; FreeType performs runtime availability checks.
# Two archive passes resolve cross-library dependencies in static FFmpeg.
# Export the public libmpv C API from the final dynamic framework.
# The wildcard is interpreted by Apple's linker, not the shell.
EXPORTS_FILE="$WORK/modmpv-exported-symbols.txt"
printf '%s\n' '_mpv_*' > "$EXPORTS_FILE"

# Stage runtime Vulkan components before linking, and use framework-relative
# paths rather than a dependency on the developer machine's sandbox prefix.
# PACKAGE_ONLY skips the dependency block that normally defines MOLTENVK_DYLIB.
# Resolve the previously built ICD from the private prefix for every mode.
MOLTENVK_DYLIB="${MOLTENVK_DYLIB:-$PREFIX/lib/libMoltenVK.dylib}"
if [[ ! -s "$MOLTENVK_DYLIB" ]]; then
    echo "ERROR: missing private MoltenVK ICD: $MOLTENVK_DYLIB" >&2
    echo 'Run a dependency build first; do not use a Homebrew runtime dylib.' >&2
    exit 2
fi
VULKAN_PRIVATE_DIR="$FW/Versions/A/Frameworks"
VULKAN_MANIFEST_DIR="$FW/Versions/A/Resources/Vulkan"
mkdir -p "$VULKAN_PRIVATE_DIR" "$VULKAN_MANIFEST_DIR"
cp -L "$PREFIX/lib/libvulkan.dylib" "$VULKAN_PRIVATE_DIR/libvulkan.dylib"
ln -sfn libvulkan.dylib "$VULKAN_PRIVATE_DIR/libvulkan.1.dylib"
cp -L "$MOLTENVK_DYLIB" "$VULKAN_PRIVATE_DIR/libMoltenVK.dylib"
for dylib in "$VULKAN_PRIVATE_DIR"/*.dylib; do
    install_name_tool -id "@rpath/$(basename "$dylib")" "$dylib"
done
# Vulkan ICD manifest: the relative library path is resolved relative to this
# JSON file, not the process working directory.
cat > "$VULKAN_MANIFEST_DIR/MoltenVK_icd.json" <<'EOF_VULKAN_ICD'
{
  "file_format_version": "1.0.0",
  "ICD": {
    "library_path": "../../Frameworks/libMoltenVK.dylib",
    "api_version": "1.3.0"
  }
}
EOF_VULKAN_ICD

# Verify Apple SDK exposes HVF before invoking the expensive final linker.
# SDK library may be a .tbd stub rather than a filesystem dylib.
if ! printf 'int main(void) { return 0; }\n' | clang -x c - -arch arm64 \
    -isysroot "$SDK_PATH" -mmacosx-version-min="$MIN_MACOS" \
    -weak-lhvf -o "$WORK/.hvf-sdk-link-check"; then
    echo 'ERROR: Apple HVF library is not linkable with the selected SDK.' >&2
    exit 1
fi
rm -f "$WORK/.hvf-sdk-link-check"

# Capture deployment warnings so release auditing can fail rather than hiding them.
LINK_DIAGNOSTICS="$OUT/linker-diagnostics.log"
# Compile framework binary bundle with private scoping restrictions active
clang -shared -dynamiclib \
    -arch arm64 \
    -isysroot "$SDK_PATH" \
    -mmacosx-version-min="$MIN_MACOS" \
    -install_name "@rpath/ModMPV.framework/Versions/A/ModMPV" \
    -Wl,-rpath,@loader_path/Frameworks \
    -Xlinker -dead_strip \
    -Wl,-no_compact_unwind \
    -Wl,-needed_library,"$PREFIX/lib/libvulkan.dylib" \
    -Wl,-exported_symbols_list,"$EXPORTS_FILE" \
    -Wl,-current_version,"$VERSION" \
    -Wl,-compatibility_version,1.0.0 \
    -Wl,-force_load,"$STATIC_LIB" \
    "${DEPENDENCY_LIBS[@]}" \
    -framework Cocoa -framework OpenGL -framework Metal -framework QuartzCore \
    -framework AudioToolbox -framework VideoToolbox -framework CoreMedia -framework CoreVideo \
    -framework IOKit -framework GameController -framework CoreGraphics \
    -framework CoreFoundation -framework IOSurface -framework ApplicationServices \
    -framework Security \
    -weak-lhvf -lc++ -liconv -lz -lbz2 -o "$FW/Versions/A/ModMPV" \
    2> >(tee "$LINK_DIAGNOSTICS" >&2)

if grep -Eq "was built for newer.*macOS|was built for newer 'macOS' version" "$LINK_DIAGNOSTICS"; then
    echo 'WARNING: Linked archives contain objects targeting a newer macOS release.' >&2
    echo "See $LINK_DIAGNOSTICS" >&2
    if [[ "$RELEASE_AUDIT" == 1 ]]; then
        echo 'ERROR: RELEASE_AUDIT=1 rejects incompatible Swift/Rust objects.' >&2
        exit 4
    fi
fi

# Rewrite the loader dependency to the private bundled copy. Do not leave an
# absolute prefix path in the final Mach-O load commands.
install_name_tool -change "$PREFIX/lib/libvulkan.1.dylib" \
    '@rpath/libvulkan.1.dylib' "$FW/Versions/A/ModMPV" 2>/dev/null || true
install_name_tool -change "$PREFIX/lib/libvulkan.dylib" \
    '@rpath/libvulkan.1.dylib' "$FW/Versions/A/ModMPV" 2>/dev/null || true
# Handle versioned loader install names as installed by CMake.
while IFS= read -r dep; do
    case "$dep" in
        "$PREFIX"/lib/libvulkan*.dylib)
            install_name_tool -change "$dep" '@rpath/libvulkan.1.dylib' "$FW/Versions/A/ModMPV" ;;
    esac
done < <(otool -L "$FW/Versions/A/ModMPV" | awk 'NR>1 {print $1}')
if ! otool -L "$FW/Versions/A/ModMPV" | grep -q '@rpath/libvulkan.1.dylib'; then
    echo 'ERROR: framework does not reference its private Vulkan Loader' >&2; exit 1
fi

# Generate the complete versioned framework Info.plist.
PLIST_PATH="$FW/Versions/A/Resources/Info.plist"
cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>ModMPV</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>ModMPV</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>
    <key>CFBundleSupportedPlatforms</key>
    <array><string>MacOSX</string></array>
    <key>ThirdPartyLicense</key>
    <string>Bundled third-party libraries include LGPL and permissively licensed components. See Resources/Legal and upstream notices for applicable terms.</string>
    <key>mpvLicense</key>
    <string>mpv is built with GPL features disabled; inspect the actual build and license notices to establish applicable terms.</string>
    <key>FFmpegLicense</key>
    <string>FFmpeg is configured with GPL and nonfree features disabled; verify the final linked components and applicable licenses.</string>
    <key>VideoCodecLicense</key>
    <string>VideoToolbox, dav1d, and libvpx support is configured; refer to the bundled notices for licensing details.</string>
</dict>
</plist>
EOF

# A successful plutil -lint alone does not establish that the root is a dictionary.
plutil -lint "$PLIST_PATH"
/usr/bin/python3 - "$PLIST_PATH" "$BUNDLE_ID" "$VERSION" "$MIN_MACOS" <<'PY_VALIDATE_PLIST'
import plistlib
import sys
path, bundle_id, version, minimum = sys.argv[1:]
with open(path, 'rb') as f:
    data = plistlib.load(f)
if not isinstance(data, dict):
    raise SystemExit('ERROR: framework Info.plist root must be a dictionary')
expected = {
    'CFBundleIdentifier': bundle_id,
    'CFBundleShortVersionString': version,
    'LSMinimumSystemVersion': minimum,
    'CFBundleExecutable': 'ModMPV',
    'CFBundlePackageType': 'FMWK',
}
for key, value in expected.items():
    if data.get(key) != value:
        raise SystemExit(f'ERROR: {key}: expected {value!r}, got {data.get(key)!r}')
print('PASS: Complete framework Info.plist dictionary and metadata verified')
PY_VALIDATE_PLIST
plutil -p "$PLIST_PATH"

# Collect available upstream license files and record missing notices.
# Do not silently omit a dependency's notice in a distribution build.
LEGAL="$FW/Versions/A/Resources/Legal"
mkdir -p "$LEGAL"
LICENSE_MANIFEST="$LEGAL/LICENSE_MANIFEST.txt"
: > "$LICENSE_MANIFEST"
copy_notice() {
    local name="$1" dir="$2"; shift 2
    local candidate
    for candidate in "$@"; do
        if [[ -s "$dir/$candidate" ]]; then
            cp "$dir/$candidate" "$LEGAL/LICENSE.$name.txt"
            printf 'FOUND  %-22s %s\n' "$name" "$dir/$candidate" >> "$LICENSE_MANIFEST"
            return 0
        fi
    done
    printf 'MISSING %-22s %s (searched: %s)\n' "$name" "$dir" "$*" >> "$LICENSE_MANIFEST"
    echo "WARNING: missing upstream notice for $name in $dir" >&2
    return 0
}
copy_notice mpv "$WORK/mpv" Copyright LICENSE COPYING
copy_notice ffmpeg "$WORK/ffmpeg" COPYING.LGPLv2.1 COPYING.LGPLv3
copy_notice snappy "$WORK/snappy" COPYING LICENSE LICENSE.txt
copy_notice openssl "$WORK/openssl" LICENSE.txt LICENSE
copy_notice libass "$WORK/libass" COPYING LICENSE
copy_notice brotli "$WORK/brotli" LICENSE
copy_notice libjpeg-turbo "$WORK/libjpeg-turbo" LICENSE.md LICENSE.txt LICENSE
copy_notice libunibreak "$WORK/libunibreak" LICENCE LICENSE COPYING
copy_notice libdovi "$WORK/libdovi" LICENSE LICENSE.md
copy_notice freetype "$WORK/freetype" LICENSE.TXT docs/FTL.TXT docs/GPLv2.TXT
copy_notice harfbuzz "$WORK/harfbuzz" COPYING LICENSE
copy_notice fribidi "$WORK/fribidi" COPYING LICENSE
copy_notice libpng "$WORK/libpng" LICENSE LICENSE.md
copy_notice libvpx "$WORK/libvpx" LICENSE README
copy_notice dav1d "$WORK/dav1d" COPYING LICENSE
copy_notice libplacebo "$WORK/libplacebo" LICENSE COPYING
copy_notice shaderc "$WORK/shaderc" LICENSE
copy_notice lcms2 "$WORK/lcms2" LICENSE LICENSE.txt COPYING
copy_notice uchardet "$WORK/uchardet" COPYING LICENSE
copy_notice luajit "$WORK/luajit" COPYRIGHT LICENSE
copy_notice moltenvk "$WORK/moltenvk" LICENSE LICENSE.md
copy_notice vulkan-loader "$WORK/vulkan-loader" LICENSE.txt LICENSE
copy_notice vulkan-headers "$WORK/vulkan-headers" LICENSE.md LICENSE.txt LICENSE
if grep -q '^MISSING ' "$LICENSE_MANIFEST"; then
    echo "WARNING: incomplete legal notices: $LICENSE_MANIFEST" >&2
    if [[ "$RELEASE_AUDIT" == 1 ]]; then
        echo 'ERROR: RELEASE_AUDIT=1 requires all listed upstream notices.' >&2
        exit 4
    fi
fi
# Reproducibility evidence: exact revisions of locally checked-out sources.
{
    printf 'Minimum macOS: %s\nArchitecture: arm64\n' "$MIN_MACOS"
    for source in mpv ffmpeg snappy openssl libass brotli libjpeg-turbo libunibreak libdovi freetype harfbuzz fribidi libpng libvpx dav1d libplacebo shaderc lcms2 uchardet luajit moltenvk vulkan-loader vulkan-headers; do
        if [[ -d "$WORK/$source/.git" ]]; then
            printf '%-22s %s\n' "$source" "$(git -C "$WORK/$source" rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
        fi
    done
} > "$LEGAL/SOURCE_REVISIONS.txt"
cat > "$LEGAL/DISTRIBUTION_README.txt" <<'EOF_DISTRIBUTION'
Notices here are collected from available source checkouts and are not a legal
compliance certification. Audit each component's actual linked license, its
copyright holders and distribution obligations. Static LGPL components may
require providing corresponding source and a means to relink modified versions.
Include notices/source offers in the shipped application as appropriate.
Do not distribute as macOS 15.4 compatible until all linked objects are built
for macOS 15.4 or earlier and tested on a real macOS 15.4 machine.
EOF_DISTRIBUTION
# Legal notices remain inside Resources; no nonstandard framework-root Legal symlink.
# Extra root entries can invalidate framework bundle sealing.

lipo -verify_arch arm64 "$FW/ModMPV"
{ echo 'STANDALONE MAIN FRAMEWORK LINKAGE:'; otool -L "$FW/ModMPV"; } > "$OUT/linkage-report.txt"

# =====================================================================
# SYSTEM VERIFICATION AND PRODUCTION RELEASE DIAGNOSTICS TEST
# =====================================================================
echo "=== Running Production Release Diagnostic Validation Tests ==="
TEST_FAILED=0
TARGET_FW_BIN="$FW/Versions/A/ModMPV"

# Test A: Check for un-isolated host Homebrew environment path leaks
echo -n "Checking for dynamic Homebrew environment path leaks... "
if otool -L "$TARGET_FW_BIN" | grep -Eq "(/opt/homebrew/|/usr/local/|/opt/local/|$WORK/|$PREFIX/)"; then
    echo "FAILED"
    otool -L "$TARGET_FW_BIN" | grep -E "(/opt/homebrew/|/usr/local/|/opt/local/|$WORK/|$PREFIX/)"
    TEST_FAILED=1
else
    echo "PASSED"
fi

# Test B: Validate the public libmpv API; do not require FFmpeg symbols to be exported.
# FFmpeg is statically linked, and its symbols may be hidden or stripped.
echo -n "Checking exported libmpv API (mpv_create)... "
if nm -gU "$TARGET_FW_BIN" 2>/dev/null | grep -E '[[:space:]]_mpv_create$' >/dev/null; then
    echo "PASSED"
else
    echo "FAILED: mpv_create is not exported by the framework"
    TEST_FAILED=1
fi

# Informational FFmpeg probe only. Symbol visibility cannot prove or disprove
# that FFmpeg code is embedded; actual playback must be tested in a sandboxed app.
echo -n "Checking visible FFmpeg symbols (informational)... "
if nm -a "$TARGET_FW_BIN" 2>/dev/null | grep -Eq '(_avcodec_|_avformat_|_avutil_|_av_frame_)'; then
    echo "Visible FFmpeg symbols found (not a playback test)"
else
    echo "No visible FFmpeg symbols; expected with hidden/stripped static libraries"
fi

# Verify that every public mpv symbol present in the upstream archive survives
# final dynamic linking. This is stronger than checking mpv_create alone.
echo '=== Auditing full exported libmpv symbol surface ==='
python3 - "$STATIC_LIB" "$TARGET_FW_BIN" "$OUT" "$MPV_HEADER_SOURCE" <<'PY_MPV_SYMBOL_AUDIT'
import pathlib, re, subprocess, sys
archive, binary, output, header_dir = sys.argv[1:]
root = pathlib.Path(output)
def symbols(path, defined=False):
    args = ['nm', '-g'] if defined else ['nm', '-gU']
    proc = subprocess.run(args + [path], capture_output=True, text=True)
    if proc.returncode:
        raise SystemExit(f'ERROR: nm failed on {path}: {proc.stderr}')
    result = set()
    for line in proc.stdout.splitlines():
        match = re.search(r'\b([TDS])\s+(_mpv_[A-Za-z0-9_]+)$', line.strip())
        if match:
            result.add(match.group(2))
    return result
upstream = symbols(archive, True)
actual = symbols(binary)
# The public API is defined by installed headers, not every archive-global
# symbol starting with mpv_. Parse function declarations, excluding macros,
# typedefs, callback parameters, and declarations in comments.
headers = sorted(pathlib.Path(header_dir).glob('*.h'))
if len(headers) < 4:
    raise SystemExit('ERROR: installed public headers missing')
public = set()
for header in headers:
    src = header.read_text(errors='replace')
    src = re.sub(r'/\*.*?\*/|//[^\n]*', '', src, flags=re.S)
    # Exported declarations are explicitly marked MPV_EXPORT in mpv headers.
    # Restrict matches to those declarations to avoid typedef/callback confusion.
    for match in re.finditer(r'\bMPV_EXPORT\b(?:(?!;).)*?\b(mpv_[A-Za-z0-9_]+)\s*\(', src, flags=re.S):
        public.add('_' + match.group(1))
# Always write the inventory, even if parsing or linking fails.
(root / 'mpv-api-public-symbols.txt').write_text('\n'.join(sorted(public)) + '\n')
if len(public) < 30 or '_mpv_create' not in public:
    raise SystemExit(f'ERROR: public-header API extraction suspicious ({len(public)} functions); inspect mpv-api-public-symbols.txt')
missing_in_archive = public - upstream
missing_exports = public - actual
internal = upstream - public
(root / 'mpv-api-public-symbols.txt').write_text('\n'.join(sorted(public)) + '\n')
(root / 'mpv-api-symbols.txt').write_text('\n'.join(sorted(public & actual)) + '\n')
(root / 'mpv-api-missing-symbols.txt').write_text('\n'.join(sorted(missing_exports)) + ('\n' if missing_exports else ''))
(root / 'mpv-archive-nonpublic-symbols.txt').write_text('\n'.join(sorted(internal)) + ('\n' if internal else ''))
print(f'Header-declared API: {len(public)}; archive symbols: {len(upstream)}; exported public API: {len(public & actual)}')
if internal:
    print(f'INFO: {len(internal)} archive-global mpv symbols not declared as public API (report saved)')
if missing_in_archive:
    print('WARNING: public header functions absent from archive:', ', '.join(sorted(missing_in_archive)))
if missing_exports:
    raise SystemExit(f'ERROR: {len(missing_exports)} public mpv symbols not exported; see mpv-api-missing-symbols.txt')
print('PASS: all header-declared libmpv functions exported')
PY_MPV_SYMBOL_AUDIT

# An independent Swift client must compile, link, import, and execute.
echo '=== Testing standalone Swift framework consumer ==='
cat > "$WORK/modmpv-swift-smoke.swift" <<'EOF_SWIFT_SMOKE'
import ModMPV
let version = mpv_client_api_version()
precondition(version != 0, "libmpv API version must be nonzero")
print("PASS: Swift imported ModMPV and called mpv_client_api_version: \(version)")
EOF_SWIFT_SMOKE
xcrun swiftc -target "arm64-apple-macosx${MIN_MACOS}" -sdk "$SDK_PATH" \
    -F "$OUT" "$WORK/modmpv-swift-smoke.swift" \
    -o "$WORK/modmpv-swift-smoke"
DYLD_FRAMEWORK_PATH="$OUT" "$WORK/modmpv-swift-smoke"

# Test C: Verify complete plist dictionary and bundle metadata (not a single extracted value)
echo -n "Auditing complete framework Info.plist... "
if /usr/bin/python3 - "$FW/Versions/A/Resources/Info.plist" "$BUNDLE_ID" <<'PY_CHECK_PLIST'
import plistlib, sys
with open(sys.argv[1], 'rb') as f:
    p = plistlib.load(f)
assert isinstance(p, dict), 'plist root is not a dictionary'
assert p.get('CFBundleIdentifier') == sys.argv[2], 'bundle ID mismatch'
assert p.get('CFBundlePackageType') == 'FMWK', 'not a framework'
assert 'ThirdPartyLicense' in p, 'license metadata missing'
PY_CHECK_PLIST
then
    echo "PASSED"
else
    echo "FAILED"
    TEST_FAILED=1
fi

# Test D: Ensure no unresolved symbols are deferred to the host application.
echo -n "Checking unresolved dynamic symbols... "
if nm -m -u "$TARGET_FW_BIN" | grep -q 'dynamically looked up'; then
    echo "FAILED: dynamic_lookup symbols remain"
    nm -m -u "$TARGET_FW_BIN" | grep 'dynamically looked up'
    TEST_FAILED=1
else
    echo "PASSED: no dynamic_lookup symbols"
fi

# Test E: Check deployment target and install name in the actual Mach-O.
echo -n "Checking Mach-O deployment target and install name... "
if ! otool -D "$TARGET_FW_BIN" | grep -Fxq '@rpath/ModMPV.framework/Versions/A/ModMPV'; then
    echo "FAILED: unexpected install name"
    TEST_FAILED=1
elif ! xcrun vtool -show-build "$TARGET_FW_BIN" | grep -Eq 'platform[[:space:]]+MACOS'; then
    echo "FAILED: expected macOS platform metadata"
    TEST_FAILED=1
else
    echo "PASSED"
fi

if [[ "$TEST_FAILED" == 0 ]]; then
    echo "=== Running headless mpv playback smoke test ==="
    python3 - "$WORK/modmpv-smoke.y4m" <<'PY_Y4M'
from pathlib import Path
import sys

width, height, frames = 160, 90, 8
frame = bytes([96]) * (width * height) + bytes([128]) * (width * height // 2)
with Path(sys.argv[1]).open("wb") as video:
    video.write(f"YUV4MPEG2 W{width} H{height} F30:1 Ip A1:1 C420jpeg\n".encode())
    for _ in range(frames):
        video.write(b"FRAME\n")
        video.write(frame)
PY_Y4M
    cat > "$WORK/modmpv-playback-smoke.c" <<'EOF_MPV_SMOKE'
#include <ModMPV/ModMPV.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static int set_option(mpv_handle *ctx, const char *name, const char *value) {
    int status = mpv_set_option_string(ctx, name, value);
    if (status < 0) {
        fprintf(stderr, "mpv option %s failed: %s\n", name, mpv_error_string(status));
        return 0;
    }
    return 1;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "Usage: %s video.y4m\n", argv[0]);
        return 2;
    }
    mpv_handle *ctx = mpv_create();
    if (!ctx) {
        fprintf(stderr, "mpv_create failed\n");
        return 1;
    }
    if (!set_option(ctx, "vo", "null") ||
        !set_option(ctx, "ao", "null") ||
        !set_option(ctx, "hwdec", "no") ||
        !set_option(ctx, "config", "no") ||
        !set_option(ctx, "load-scripts", "no")) {
        mpv_terminate_destroy(ctx);
        return 1;
    }
    int status = mpv_initialize(ctx);
    if (status < 0) {
        fprintf(stderr, "mpv_initialize failed: %s\n", mpv_error_string(status));
        mpv_terminate_destroy(ctx);
        return 1;
    }
    const char *command[] = {"loadfile", argv[1], "replace", NULL};
    status = mpv_command(ctx, command);
    if (status < 0) {
        fprintf(stderr, "loadfile failed: %s\n", mpv_error_string(status));
        mpv_terminate_destroy(ctx);
        return 1;
    }
    int loaded = 0;
    int ended = 0;
    time_t deadline = time(NULL) + 30;
    while (!ended && time(NULL) < deadline) {
        mpv_event *event = mpv_wait_event(ctx, 1.0);
        if (event->event_id == MPV_EVENT_FILE_LOADED)
            loaded = 1;
        if (event->event_id == MPV_EVENT_END_FILE) {
            mpv_event_end_file *end = event->data;
            if (end && end->reason == MPV_END_FILE_REASON_ERROR) {
                fprintf(stderr, "playback ended with error %d\n", end->error);
                mpv_terminate_destroy(ctx);
                return 1;
            }
            ended = 1;
        }
        if (event->event_id == MPV_EVENT_SHUTDOWN)
            break;
    }
    mpv_terminate_destroy(ctx);
    if (!loaded || !ended) {
        fprintf(stderr, "playback timeout (file_loaded=%d, end_file=%d)\n", loaded, ended);
        return 1;
    }
    puts("PASS: synthetic video loaded, decoded, and reached end-of-file");
    return 0;
}
EOF_MPV_SMOKE
    clang -isysroot "$SDK_PATH" -mmacosx-version-min="$MIN_MACOS" \
        -I"$FW/Headers" -F"$OUT" -framework ModMPV \
        "$WORK/modmpv-playback-smoke.c" -o "$WORK/modmpv-playback-smoke"
    DYLD_FRAMEWORK_PATH="$OUT" "$WORK/modmpv-playback-smoke" "$WORK/modmpv-smoke.y4m"
    echo 'NOTE: This headless test verifies demux/decode/playback progression, not app UI, GPU rendering, or audio output.'
fi

# Evaluation Gatekeeper
if [[ "$TEST_FAILED" == 1 ]]; then
    echo "------------------------------------------------------------------------"
    echo "CRITICAL BUILD FAILURE: Framework architecture failed post-link testing." >&2
    echo "------------------------------------------------------------------------"
    exit 3
fi

# Generate accurate agent-facing documentation from the packaged headers,
# actual symbols, build options, source revisions, and test results.
echo '=== Generating agent-readable ModMPV capability documentation ==='
DOC_DIR="$FW/Versions/A/Resources/Documentation"
mkdir -p "$DOC_DIR"
python3 - "$DOC_DIR" "$OUT" "$WORK" "$MIN_MACOS" "$VERSION" "$MPV_REF" "$FFMPEG_REF" <<'PY_GENERATE_DOCS'
import datetime, hashlib, json, pathlib, re, subprocess, sys
folder, out, work, minimum, version, mpv_ref, ffmpeg_ref = sys.argv[1:]
docs = pathlib.Path(folder)
out = pathlib.Path(out)
work = pathlib.Path(work)
headers = (out / 'public-headers.txt').read_text().splitlines()
symbols = (out / 'mpv-api-symbols.txt').read_text().splitlines()
revisions = {}
for name in ('mpv','ffmpeg','snappy','openssl','libass','brotli','libjpeg-turbo',
             'libunibreak','libdovi','freetype','harfbuzz','fribidi','libpng',
             'libvpx','dav1d','libplacebo','shaderc','lcms2','uchardet','luajit',
             'moltenvk','vulkan-loader','vulkan-headers'):
    src = work / name
    if (src / '.git').exists():
        p = subprocess.run(['git','-C',str(src),'rev-parse','HEAD'],capture_output=True,text=True)
        if p.returncode == 0: revisions[name] = p.stdout.strip()
config = (work / 'ffmpeg' / 'config.h').read_text(errors='replace')
flags = {key: bool(re.search(r'^#define CONFIG_'+key+r' 1$', config, re.M))
         for key in ('GPL','VERSION3','NONFREE','LIBSNAPPY')}
if flags['GPL'] or flags['VERSION3'] or flags['NONFREE']:
    raise SystemExit('ERROR: forbidden FFmpeg licensing configuration')
# A configuration claim is not proof that a real GPU renderer initialized.
features = {
    'libmpv_client_api': 'verified_exported_and_swift_callable',
    'headless_video_playback': 'verified_synthetic_test',
    'render_api': 'exported_not_gpu_runtime_tested',
    'metal_vulkan_libplacebo': 'configured_not_gpu_runtime_tested',
    'videotoolbox': 'configured_not_hardware_runtime_tested',
    'hap_snappy': 'configured_not_codec_roundtrip_tested',
    'lua_scripting': 'configured_not_runtime_tested',
    'subtitle_rendering': 'configured_not_runtime_tested',
    'audio_output': 'configured_not_runtime_tested',
    'network_streaming': 'configured_not_runtime_tested',
}
api = {
    'schema_version': 1, 'name':'ModMPV','version':version,
    'description':'macOS arm64 playback, control, events and video rendering via libmpv',
    'minimum_macos':minimum,'architectures':['arm64'],
    'upstream_refs':{'mpv':mpv_ref,'ffmpeg':ffmpeg_ref},
    'source_revisions':revisions,
    'license_configuration':{'mpv_gpl_option':False,'ffmpeg':flags,
        'compliance_certified':False,'distribution_audit_required':True},
    'public_headers':headers,'exported_mpv_symbols':symbols,
    'features':features,
    'routing':{
        'use_for':['media playback','playback control','playback events','video rendering'],
        'do_not_use_for':['metadata editing','transcoding','general media metadata writes'],
        'metadata_writes':'Use ModMKV for supported Matroska-specific edits; ModFFmpeg for other supported metadata writes',
        'media_inspection':'Use ModMediaInfo for broad media inspection',
    },
    'validation':{'headless_playback':'passed','swift_consumer':'passed',
                  'public_symbol_export':'passed','gpu_rendering':'not_tested',
                  'release_compliance':'not_certified'},
}
(docs/'capabilities.json').write_text(json.dumps(api,indent=2,sort_keys=True)+'\n')
(docs/'API_SYMBOLS.txt').write_text('\n'.join(symbols)+'\n')
(docs/'PUBLIC_HEADERS.txt').write_text('\n'.join(headers)+'\n')
header = f'''# ModMPV — Framework Information

Version: {version}  
Platform: macOS {minimum}+ (arm64 only)  
Upstream mpv: {mpv_ref}  
Upstream FFmpeg: {ffmpeg_ref}

ModMPV is an independently embeddable libmpv framework for media playback,
playback controls, events, and video rendering. Its public upstream C API is
available to C, Objective-C and Swift via the framework module.

## Supported integration surface

- {len(headers)} installed upstream public mpv headers.
- {len(symbols)} verified exported mpv symbols (see `API_SYMBOLS.txt`).
- Standalone Swift API invocation and synthetic headless video playback tested.
- Metal/Vulkan/libplacebo, VideoToolbox, Hap/Snappy, subtitle and audio
  functionality is configured but **not validated by real-world runtime tests**.

## Limitations

- This build does not establish real GPU rendering, hardware decode, audio output,
  streaming, or App Store acceptance.
- GPL options are disabled in mpv and FFmpeg; a complete dependency-license
  and LGPL distribution/relinking audit is still required.
- macOS arm64 only; no iOS, tvOS or Intel slice.
- Do not use ModMPV for metadata writing. Use ModMKV for supported Matroska
  metadata edits and ModFFmpeg for other supported metadata writes.

## Import

```swift
import ModMPV
let apiVersion = mpv_client_api_version()
```

See `capabilities.json` for build-derived revisions, symbols, and verification.
'''
(docs/'FRAMEWORK_INFO.md').write_text(header)
(docs/'README.md').write_text(header+'\n## Public headers\n\n'+''.join(f'- `{h}`\n' for h in headers))
(docs/'AGENTS.md').write_text('''# Agent instructions — ModMPV

1. Read `capabilities.json` before choosing APIs or claiming support.
2. Use `PUBLIC_HEADERS.txt` and `API_SYMBOLS.txt` for the actual exposed surface;
   consult bundled `Headers/mpv/*.h` for exact signatures.
3. Use ModMPV for playback, playback control, events and rendering.
4. Use ModMKV for supported Matroska-specific metadata edits and ModFFmpeg
   for all other supported metadata writes. Use ModMediaInfo for inspection.
5. Do not claim Metal, Vulkan, VideoToolbox, audio, streaming, or Hap are
   runtime-verified solely because their build options were enabled.
6. Do not assume GPL-disabled means distribution-compliant. Inspect the Legal
   directory and complete the LGPL/relinking and transitive-license audit.
7. Preserve the public libmpv API. Do not invent wrapper methods or symbols.
8. The build is macOS arm64 only. Never infer iOS/tvOS/x86_64 support.
''')
for name in ('README.md','AGENTS.md','FRAMEWORK_INFO.md','capabilities.json',
             'API_SYMBOLS.txt','PUBLIC_HEADERS.txt'):
    (out/name).write_bytes((docs/name).read_bytes())
print(f'PASS: generated {len(headers)} headers, {len(symbols)} symbols and six documentation artifacts')
PY_GENERATE_DOCS

# =====================================================================
# CODE SIGNING (auto selects development or ad-hoc; explicit modes available)
# Sign nested dylibs first, then seal the enclosing framework bundle.
# This is a development signature, not a Developer ID distribution signature.
# =====================================================================
if [[ "$SIGN_MODE" != none ]]; then
    echo "=== Signing embedded Vulkan libraries and ModMPV.framework ==="
    rm -f "$FW/Legal"
    VULKAN_DIR="$FW/Versions/A/Frameworks"
    for dylib in "$VULKAN_DIR/libvulkan.dylib" "$VULKAN_DIR/libMoltenVK.dylib"; do
        [[ -f "$dylib" ]] || { echo "ERROR: missing nested runtime: $dylib" >&2; exit 1; }
        echo "Signing nested runtime: ${dylib##*/}"
        codesign --force --sign "$CODESIGN_IDENTITY" "$dylib"
        codesign --verify --strict --verbose=2 "$dylib"
    done
    # libvulkan.1.dylib is a symlink to the signed libvulkan.dylib.
    [[ -L "$VULKAN_DIR/libvulkan.1.dylib" ]] || {
        echo 'ERROR: expected Vulkan loader versioned symlink' >&2; exit 1;
    }
    codesign --force --sign "$CODESIGN_IDENTITY" "$FW"
    codesign --verify --deep --strict --verbose=2 "$FW"

    # Ad-hoc signatures are valid, but do not have a Team ID and may not
    # satisfy a hardened host application with library validation enabled.
    # Record the actual team identifiers to make that distinction explicit.
    SIGNING_REPORT="$OUT/ModMPV-signing.txt"
    {
        echo "Requested identity: $CODESIGN_IDENTITY"
        for item in "$FW" "$VULKAN_DIR/libvulkan.dylib" "$VULKAN_DIR/libMoltenVK.dylib"; do
            echo "=== $item ==="
            codesign -dv --verbose=4 "$item" 2>&1 | grep -E '^(Identifier|TeamIdentifier|Authority|Signature)=' || true
            codesign --verify --strict --verbose=2 "$item" 2>&1
        done
    } > "$SIGNING_REPORT"
    EXPECTED_TEAM="$(codesign -dv --verbose=4 "$FW" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1)"
    if [[ "$SIGN_MODE" == development ]]; then
        [[ -n "$EXPECTED_TEAM" && "$EXPECTED_TEAM" != 'not set' ]] || {
            echo 'ERROR: development-signed framework has no Apple Team ID' >&2; exit 3;
        }
    else
        [[ "$EXPECTED_TEAM" == 'not set' ]] || {
            echo "ERROR: ad-hoc framework unexpectedly has Team ID $EXPECTED_TEAM" >&2; exit 3;
        }
    fi
    for item in "$VULKAN_DIR/libvulkan.dylib" "$VULKAN_DIR/libMoltenVK.dylib"; do
        actual_team="$(codesign -dv --verbose=4 "$item" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1)"
        [[ "$actual_team" == "$EXPECTED_TEAM" ]] || {
            echo "ERROR: Team ID mismatch: $item ($actual_team != $EXPECTED_TEAM)" >&2; exit 3;
        }
    done
    if [[ -n "$SIGNING_TEAM" && "$EXPECTED_TEAM" != "$SIGNING_TEAM" ]]; then
        echo "ERROR: signing team $EXPECTED_TEAM does not match requested $SIGNING_TEAM" >&2; exit 3
    fi
    echo "PASS: $SIGN_MODE signatures verified (Team: $EXPECTED_TEAM); details: $SIGNING_REPORT"
else
    echo 'NOTE: signing skipped (SIGN_MODE=none); Xcode must account for nested dylibs'
fi

# =====================================================================
# STEP 4: MANDATORY APPLE XCFRAMEWORK DEPLOYMENT ARTIFACT PACKAGING
# =====================================================================
if [[ "${XCFRAMEWORK:-1}" == 1 ]]; then
    echo "=== Packaging Final Monolithic Standalone XCFRAMEWORK Asset ==="
    rm -rf "$OUT/ModMPV.xcframework"
    
    xcodebuild -create-xcframework \
               -framework "$FW" \
               -output "$OUT/ModMPV.xcframework"
               
    plutil -lint "$OUT/ModMPV.xcframework/Info.plist"
    /usr/bin/python3 - "$OUT/ModMPV.xcframework" "$BUNDLE_ID" "$MIN_MACOS" <<'PY_XCFRAMEWORK'
import os, plistlib, sys
root, bundle_id, minimum = sys.argv[1:]
with open(os.path.join(root, 'Info.plist'), 'rb') as f:
    metadata = plistlib.load(f)
assert isinstance(metadata, dict), 'XCFramework plist must be a dictionary'
slices = metadata.get('AvailableLibraries', [])
assert len(slices) == 1, f'Expected one macOS arm64 slice, got {len(slices)}'
entry = slices[0]
assert entry.get('SupportedPlatform') == 'macos', entry
assert entry.get('SupportedArchitectures') == ['arm64'], entry
relative = entry['LibraryPath']
framework = os.path.join(root, entry['LibraryIdentifier'], relative)
plist = os.path.join(framework, 'Versions', 'A', 'Resources', 'Info.plist')
with open(plist, 'rb') as f:
    info = plistlib.load(f)
assert info['CFBundleIdentifier'] == bundle_id
assert info['LSMinimumSystemVersion'] == minimum
assert os.path.isfile(os.path.join(framework, 'Versions', 'A', 'ModMPV'))
print('PASS: XCFramework macOS arm64 slice, executable and embedded Info.plist')
PY_XCFRAMEWORK
    echo "Note: XCFramework root Info.plist is Xcode-generated slice metadata, not the framework bundle plist."
    if [[ "$SIGN_MODE" != none ]]; then
        # Verify the actual copied framework slice, not just the original input.
        SLICE_FW="$OUT/ModMPV.xcframework/macos-arm64/ModMPV.framework"
        codesign --verify --deep --strict --verbose=2 "$SLICE_FW"
        echo 'PASS: signed XCFramework slice verified'
        for item in "$SLICE_FW" "$SLICE_FW/Versions/A/Frameworks/libvulkan.dylib" "$SLICE_FW/Versions/A/Frameworks/libMoltenVK.dylib"; do
            slice_team="$(codesign -dv --verbose=4 "$item" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1)"
            [[ "$slice_team" == "$EXPECTED_TEAM" ]] || {
                echo "ERROR: XCFramework copied slice has wrong Team ID: $item ($slice_team)" >&2; exit 3;
            }
        done
    fi
fi

cat > "$OUT/APP_STORE_INTEGRATION.txt" <<'EOF'
ModMPV macOS arm64 XCFramework - integration notes

1. Add ModMPV.xcframework to each macOS Xcode app target.
2. Set the framework to Embed & Sign for each app target; do not embed the entire XCFramework.
3. Use a unique app bundle identifier per app; the framework bundle ID stays constant.
4. Archive each app with its own App Store distribution signing and sandbox entitlements.
5. Test playback of sandbox-authorized files and network streams in a sandboxed app.
6. Verify the final app with codesign, spctl and Xcode's archive validation.
7. Review LGPL and other third-party licenses, notices, source/relinking obligations.
8. macOS only: this XCFramework does not contain iOS, iPadOS, or tvOS slices.
9. Vulkan ICD discovery: before initializing mpv/libplacebo, set VK_DRIVER_FILES
   to the absolute path of the embedded
   ModMPV.framework/Versions/A/Resources/Vulkan/MoltenVK_icd.json.
   Do this in your app process startup (before Vulkan initialization); do not
   rely on the user's system Vulkan installation or Homebrew environment.
10. Under host-app library validation, the Vulkan Loader and MoltenVK dylibs
    must satisfy the host signing policy. SIGN_MODE=development (explicit)
    signs with an installed Apple Development identity; SIGN_MODE=adhoc signs
    all nested code ad-hoc for compatible local development hosts. Xcode Embed & Sign
    does not necessarily re-sign nested dylibs; verify the final app.
    Verify @rpath resolution, code signing, and GPU initialization on a clean Mac.
11. Vulkan support is configured but not runtime-verified by this build script.
    Run a real libplacebo Vulkan device initialization/playback test.

This script does not guarantee App Store acceptance or legal compliance.
EOF

# Export reproducible engineering artifacts. Never imply legal approval.
cp -f "$OUT/mpv-api-symbols.txt" "$OUT/ModMPV-exported-symbols.txt"
{
  echo "ModMPV linked binary: $TARGET_FW_BIN"
  otool -L "$TARGET_FW_BIN"
  echo; echo 'Load commands (rpaths):'
  otool -l "$TARGET_FW_BIN" | grep -A3 LC_RPATH || true
} > "$OUT/ModMPV-linkage.txt"
{
  file "$TARGET_FW_BIN"
  xcrun vtool -show-build "$TARGET_FW_BIN" 2>&1 || true
  lipo -archs "$TARGET_FW_BIN"
} > "$OUT/ModMPV-mach-o-build.txt"
python3 - "$FW/Versions/A/Headers" "$OUT/ModMPV-header-inventory.json" <<'PY_HEADER_INVENTORY'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1]); entries=[]
for path in sorted(root.rglob('*.h')):
    data=path.read_bytes()
    entries.append({'path':str(path.relative_to(root)),'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()})
pathlib.Path(sys.argv[2]).write_text(json.dumps({'schema_version':1,'headers':entries},indent=2)+'\n')
print('PASS: inventoried',len(entries),'public headers with SHA-256')
PY_HEADER_INVENTORY
# Capture pinned source trees and provenance, not merely legal notices.
# Git archives preserve committed source content at the exact checked-out revision.
# Nested Git repositories/submodules are captured independently when present.
COMPLIANCE_STAGE="$WORK/modmpv-compliance-stage"
rm -rf "$COMPLIANCE_STAGE"
mkdir -p "$COMPLIANCE_STAGE/Legal" "$COMPLIANCE_STAGE/Sources" "$COMPLIANCE_STAGE/Build"
cp -R "$FW/Versions/A/Resources/Legal/." "$COMPLIANCE_STAGE/Legal/"
cp "${BASH_SOURCE[0]}" "$COMPLIANCE_STAGE/Build/build_modmpv.sh"
[[ ! -f "$OUT/build.log" ]] || cp "$OUT/build.log" "$COMPLIANCE_STAGE/Build/build.log"
python3 - "$WORK" "$COMPLIANCE_STAGE" <<'PY_MPV_SOURCE_MANIFEST'
import json, pathlib, subprocess, sys
work=pathlib.Path(sys.argv[1]).resolve()
stage=pathlib.Path(sys.argv[2]).resolve()
repositories=[]
for path in sorted(work.rglob('.git')):
    repo=path.parent
    # Avoid source discovery within generated compliance material or build outputs.
    if stage == repo or stage in repo.parents:
        continue
    try:
        head=subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'],text=True).strip()
        status=subprocess.check_output(['git','-C',str(repo),'status','--porcelain','--untracked-files=no'],text=True).strip()
        origin=subprocess.run(['git','-C',str(repo),'remote','get-url','origin'],capture_output=True,text=True).stdout.strip()
        relative=repo.relative_to(work).as_posix()
    except (subprocess.CalledProcessError,ValueError):
        continue
    repositories.append({'path':relative,'commit':head,'origin':origin,'tracked_modifications_present':bool(status)})
if not any(x['path']=='mpv' for x in repositories) or not any(x['path']=='ffmpeg' for x in repositories):
    raise SystemExit('ERROR: missing mpv or FFmpeg Git checkout for source-compliance archive')
(stage/'Build'/'source-manifest.json').write_text(json.dumps({'schema_version':1,'repositories':repositories},indent=2)+'\n')
print(f'Source-compliance: discovered {len(repositories)} Git repositories')
PY_MPV_SOURCE_MANIFEST
# Iterate the manifest safely without relying on shell word splitting.
while IFS= read -r repo_rel; do
    [[ -n "$repo_rel" ]] || continue
    repo_path="$WORK/$repo_rel"
    archive_name="${repo_rel//\//__}.tar.gz"
    echo "Archiving source: $repo_rel -> $archive_name"
    git -C "$repo_path" archive --format=tar HEAD | gzip -n > "$COMPLIANCE_STAGE/Sources/$archive_name"
    [[ -s "$COMPLIANCE_STAGE/Sources/$archive_name" ]] || { echo "ERROR: empty source archive: $repo_rel" >&2; exit 1; }
done < <(python3 - "$COMPLIANCE_STAGE/Build/source-manifest.json" <<'PY_MPV_SOURCE_LIST'
import json,sys
for entry in json.load(open(sys.argv[1]))['repositories']:
    print(entry['path'])
PY_MPV_SOURCE_LIST
)
cat > "$COMPLIANCE_STAGE/README.txt" <<'EOF_COMPLIANCE'
ModMPV source and license evidence archive.
Sources/*.tar.gz contains the committed source at the recorded checkout HEAD
for each discovered Git repository. Build/source-manifest.json records the
origin, commit and whether the checkout contains tracked local modifications.
Git archives do NOT contain uncommitted patches, untracked files, Git LFS
objects, or uninitialized submodules. Review the manifest and source tree for
such omissions, generated files, bundled binary dependencies, and source
changes required to reproduce the distributed binary.
This is NOT a certification of complete corresponding source or LGPL
relinking compliance. Legal notices and source archives do not alone satisfy
all distribution obligations. Review every dependency and provide the
required relinking materials and build instructions before release.
EOF_COMPLIANCE
(
    cd "$COMPLIANCE_STAGE"
    find . -type f ! -name SHA256SUMS.txt -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 > SHA256SUMS.txt
)
tar -C "$COMPLIANCE_STAGE" -czf "$OUT/ModMPV-source-compliance.tar.gz" .
echo "PASS: source/compliance evidence packaged: $OUT/ModMPV-source-compliance.tar.gz"
echo "SUCCESS: Reusable macOS arm64 ModMPV XCFramework packaged (SIGN_MODE=$SIGN_MODE; identity=$CODESIGN_IDENTITY)."
echo "Release audit: set RELEASE_AUDIT=1 to reject newer-target objects and missing notices."
echo "Notices: $FW/Versions/A/Resources/Legal/LICENSE_MANIFEST.txt"
echo "Integration notes: $OUT/APP_STORE_INTEGRATION.txt"


# Embedded agent documentation generation
_DOCS_OUT="${OUT:-$(pwd)/output-ModMPV}"
mkdir -p "$_DOCS_OUT"
python3 - "$_DOCS_OUT" "$(basename "${BASH_SOURCE[0]}")" <<'EMBEDDED_DOCS'
import sys, base64, tempfile
from pathlib import Path

out = Path(sys.argv[1])
builder = sys.argv[2]
generator = base64.b64decode('IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJHZW5lcmF0ZSBjb25zaXN0ZW50IGJ1aWxkIGFuZCBhZ2VudCBlbnRyeXBvaW50IGRvY3Mgd2l0aG91dCBjaGFuZ2luZyBidWlsZCBhcnRpZmFjdHMuIiIiCmltcG9ydCBhcmdwYXJzZSwgcGF0aGxpYiwgc2h1dGlsLCBzeXMKcD1hcmdwYXJzZS5Bcmd1bWVudFBhcnNlcigpCnAuYWRkX2FyZ3VtZW50KCctLWZyYW1ld29yaycscmVxdWlyZWQ9VHJ1ZSkKcC5hZGRfYXJndW1lbnQoJy0tb3V0JyxyZXF1aXJlZD1UcnVlKQpwLmFkZF9hcmd1bWVudCgnLS1idWlsZGVyJyxyZXF1aXJlZD1UcnVlKQpwLmFkZF9hcmd1bWVudCgnLS1pbnN0cnVjdGlvbnMnLGRlZmF1bHQ9JycpCmE9cC5wYXJzZV9hcmdzKCk7IG91dD1wYXRobGliLlBhdGgoYS5vdXQpOyBvdXQubWtkaXIocGFyZW50cz1UcnVlLGV4aXN0X29rPVRydWUpCm5hbWU9YS5mcmFtZXdvcmsKYnVpbGRlcj1wYXRobGliLlBhdGgoYS5idWlsZGVyKS5uYW1lCnNvdXJjZT17J0hhcEluQVZGb3VuZGF0aW9uJzonaHR0cHM6Ly9naXRodWIuY29tL2ZsZXh2aXN1YWwvaGFwLWluLWF2Zm91bmRhdGlvbid9LmdldChuYW1lLCdTZWUgdGhlIHBpbm5lZCBzb3VyY2UgcmVmZXJlbmNlcyBhbmQgc291cmNlLWNvbXBsaWFuY2UgYXJjaGl2ZSBzdXBwbGllZCB3aXRoIHRoaXMgcmVsZWFzZS4nKQppbnM9b3V0L2Yne25hbWV9Lmluc3RydWN0aW9ucy5tZCcKaWYgYS5pbnN0cnVjdGlvbnMgYW5kIHBhdGhsaWIuUGF0aChhLmluc3RydWN0aW9ucykuaXNfZmlsZSgpOgogICAgc2h1dGlsLmNvcHkyKGEuaW5zdHJ1Y3Rpb25zLGlucykKZXh0cmE9Zic0LiBSZWFkIGB7aW5zLm5hbWV9YCBmb3IgZnJhbWV3b3JrLXNwZWNpZmljIGludGVncmF0aW9uIGFuZCBNZXRhbC9jb2RlYyBjb25zdHJhaW50cy5cbicgaWYgaW5zLmlzX2ZpbGUoKSBlbHNlICc0LiBDb25zdWx0IHRoZSBmcmFtZXdvcmsgcHVibGljIGhlYWRlcnMgYW5kIGV4aXN0aW5nIGludGVncmF0aW9uIG5vdGVzOyBubyBzZXBhcmF0ZSBpbnRlZ3JhdGlvbiBndWlkZSB3YXMgc3VwcGxpZWQuXG4nCihvdXQvJ0FHRU5UUy5tZCcpLndyaXRlX3RleHQoZicnJyMge25hbWV9IOKAlCBBZ2VudCBpbnN0cnVjdGlvbnMKCkJlZm9yZSBpbnRlZ3JhdGluZywgbW9kaWZ5aW5nLCBkaXN0cmlidXRpbmcgb3IgcmVidWlsZGluZzoKCjEuIFJlYWQgYEJVSUxESU5HLm1kYCBmb3IgcmVwcm9kdWNpYmxlIHNvdXJjZS1idWlsZCBzdGVwcyBhbmQgcHJlcmVxdWlzaXRlcy4KMi4gUmVhZCBgUkVBRE1FLm1kYCBhbmQgYEZSQU1FV09SS19JTkZPLm1kYCB3aGVuIHByZXNlbnQuCjMuIENoZWNrIGBjYXBhYmlsaXRpZXMuanNvbmAgYW5kIHRoZSB2YWxpZGF0aW9uLCBoZWFkZXIsIHN5bWJvbCBhbmQgbGlua2FnZSByZXBvcnRzOyBkbyBub3QgaW5mZXIgdW5zdXBwb3J0ZWQgQVBJcy4Ke2V4dHJhfTUuIFRyZWF0IHRoZSAqKnNoaXBwZWQgcHVibGljIGhlYWRlcnMgYW5kIG1hdGNoaW5nIGJpbmFyeSoqIGFzIGF1dGhvcml0YXRpdmUgZm9yIHRoaXMgcmVsZWFzZS4KNi4gUHJlc2VydmUgZHluYW1pYyBmcmFtZXdvcmsgZW1iZWRkaW5nLCBgQHJwYXRoYCwgcmVwbGFjZWFiaWxpdHkgYW5kIHRoZSBob3N0IGFwcGxpY2F0aW9uJ3Mgc2lnbmluZyByZXF1aXJlbWVudHMuCjcuIFJlYWQgdGhlIGFwcGxpY2FibGUgbGljZW5zZSBub3RpY2VzIGFuZCBleGFjdCBzb3VyY2UgcmV2aXNpb24gcmVjb3JkcyBiZWZvcmUgZGlzdHJpYnV0aW9uLgoKQnVpbGQgc2NyaXB0OiBge2J1aWxkZXJ9YCAoc2hpcHBlZCBhbG9uZ3NpZGUgdGhpcyByZWxlYXNlIGRvY3VtZW50YXRpb24sIG5vdCBuZWNlc3NhcmlseSBpbnNpZGUgdGhlIG91dHB1dCBkaXJlY3RvcnkpLgpTb3VyY2U6IHtzb3VyY2V9CicnJykKKG91dC8nQlVJTERJTkcubWQnKS53cml0ZV90ZXh0KGYnJycjIEJ1aWxkaW5nIHtuYW1lfSBmcm9tIHNvdXJjZQoKIyMgUHJlcmVxdWlzaXRlcwoKLSBBbiBBcHBsZSBTaWxpY29uIE1hYyB3aXRoIFhjb2RlIGFuZCB0aGUgbWFjT1MgU0RLIHN1cHBvcnRlZCBieSB0aGlzIGJ1aWxkZXIuCi0gWGNvZGUgY29tbWFuZC1saW5lIHRvb2xzIHNlbGVjdGVkIChgeGNvZGUtc2VsZWN0IC1wYCksIEdpdCBhbmQgdGhlIGNvbW1hbmQtbGluZSB1dGlsaXRpZXMgdXNlZCBieSB0aGUgYnVpbGRlci4KLSBJbnRlcm5ldCBhY2Nlc3MgdG8gZmV0Y2ggdGhlIGJ1aWxkZXIncyBwaW5uZWQgZGVwZW5kZW5jaWVzLCB1bmxlc3MgYWxyZWFkeSBjYWNoZWQuCgojIyBCdWlsZAoKUGxhY2UgYHtidWlsZGVyfWAgaW4gdGhlIGludGVuZGVkIE1vZEZyYW1ld29ya3Mgd29ya2luZyBkaXJlY3RvcnkgYW5kIHJ1bjoKCmBgYGJhc2gKY2htb2QgK3ggIntidWlsZGVyfSIKLi8ie2J1aWxkZXJ9IgpgYGAKClRoaXMgZG9jdW1lbnRhdGlvbiBpcyBnZW5lcmF0ZWQgZm9yIHRoZSAqKnNwZWNpZmljIHNjcmlwdCB2ZXJzaW9uKiogbmFtZWQgYWJvdmUuIFJldmlldyB0aGF0IHNjcmlwdCdzIGNvbmZpZ3VyYWJsZSBlbnZpcm9ubWVudCB2YXJpYWJsZXMgYW5kIGNsZWFuL3JlYnVpbGQgb3B0aW9ucyBiZWZvcmUgdXNpbmcgdGhlbTsgbm8gY29tbW9uIGZsYWdzIGFyZSBhc3N1bWVkIGFjcm9zcyBidWlsZGVycy4KCiMjIE91dHB1dHMgYW5kIGNoZWNrcwoKLSBJbnNwZWN0IGBidWlsZC5sb2dgIGZvciBhY3R1YWwgY29tcGlsYXRpb24gc3VjY2VzczsgZXhpc3RlbmNlIG9mIGEgZnJhbWV3b3JrIGZvbGRlciBhbG9uZSBpcyBub3QgcHJvb2Ygb2YgYSBmcmVzaCBidWlsZC4KLSBWZXJpZnkgdGhlIGZyYW1ld29yayBhbmQgWENGcmFtZXdvcmsgZGlyZWN0b3JpZXMgaWYgdGhpcyBidWlsZCBlbmFibGVzIGJvdGguCi0gQ2hlY2sgYCotdmFsaWRhdGlvbi50eHRgLCBgKi1saW5rYWdlLnR4dGAsIGAqLW1hY2gtby1idWlsZC50eHRgLCBgKi1oZWFkZXItaW52ZW50b3J5Lmpzb25gLCBgKi1leHBvcnRlZC1zeW1ib2xzLnR4dGAsIGFuZCBgY2FwYWJpbGl0aWVzLmpzb25gIHdoZW4gZ2VuZXJhdGVkLgotIFZlcmlmeSBzaWduYXR1cmVzIHdpdGggYGNvZGVzaWduIC0tdmVyaWZ5IC0tc3RyaWN0IC0tdmVyYm9zZT0yYCBvbiB0aGUgZnJhbWV3b3JrIGFuZCBYQ0ZyYW1ld29yay4gQSBkZXZlbG9wbWVudCBhZC1ob2Mgc2lnbmF0dXJlIGlzICoqbm90KiogYSBEZXZlbG9wZXIgSUQgc2lnbmF0dXJlIG9yIG5vdGFyaXphdGlvbi4KLSBWZXJpZnkgdGhlIGFyY2hpdGVjdHVyZSB3aXRoIGB4Y3J1biBsaXBvIC1pbmZvYCBhbmQgbWluaW11bSBkZXBsb3ltZW50IHZlcnNpb24gd2l0aCBgeGNydW4gdnRvb2wgLXNob3ctYnVpbGRgIG9uIHRoZSBmcmFtZXdvcmsgZXhlY3V0YWJsZS4KLSBVc2UgZXhhY3QgcmV2aXNpb25zIGluIHRoZSBnZW5lcmF0ZWQgZGVwZW5kZW5jeS9zb3VyY2UgbWFuaWZlc3QgZm9yIHJlcHJvZHVjaWJpbGl0eTsgZG8gbm90IHN1YnN0aXR1dGUgY3VycmVudCBicmFuY2ggSEVBRC4KCiMjIERpc3RyaWJ1dGlvbgoKVGhlIHNvdXJjZSByZXBvc2l0b3J5IHJlZmVyZW5jZSBpczoge3NvdXJjZX0KClRoZSBmcmFtZXdvcmsgaXMgaW50ZW5kZWQgdG8gcmVtYWluIGR5bmFtaWNhbGx5IHJlcGxhY2VhYmxlLiBVc2VycyBvZiBhbiBlbWJlZGRlZCBmcmFtZXdvcmsgbWF5IG5lZWQgdG8gcmUtc2lnbiB0aGVpciBhcHBsaWNhdGlvbiBhZnRlciByZXBsYWNlbWVudCwgc3ViamVjdCB0byBpdHMgcnVudGltZSBhbmQgZGlzdHJpYnV0aW9uIHJlc3RyaWN0aW9ucy4gUHVibGlzaGVkIHNvdXJjZSBhbmQgcmVwbGFjZWFiaWxpdHkgYXJlIGltcG9ydGFudCBidXQgZG8gbm90IGJ5IHRoZW1zZWx2ZXMgY2VydGlmeSBsaWNlbnNlIGNvbXBsaWFuY2UuIFJldmlldyB0aGUgZXhhY3Qgbm90aWNlcyBhbmQgY29ycmVzcG9uZGluZyBzb3VyY2UvYnVpbGQgbWF0ZXJpYWxzLgoKIyMgVHJvdWJsZXNob290aW5nCgpJZiBhIGNsZWFuIGJ1aWxkIGZhaWxzLCBrZWVwIGBidWlsZC5sb2dgIGFuZCB0aGUgcmVwb3J0ZWQgdG9vbGNoYWluIHZlcnNpb24sIGluc3BlY3QgdGhlIGZpcnN0IGZhaWx1cmUgKG5vdCBqdXN0IHRoZSBsYXN0IGVycm9yKSwgYW5kIGNoZWNrIHRoZSBwaW5uZWQgZGVwZW5kZW5jeSBjaGVja291dHMuIERvIG5vdCBzaWxlbnRseSBjaGFuZ2UgcGlubmVkIHJldmlzaW9ucyB0byBtYWtlIGEgZmFpbGluZyBidWlsZCBwYXNzLgonJycpCnByaW50KGYnRG9jdW1lbnRhdGlvbiBnZW5lcmF0ZWQ6IHtvdXR9L0FHRU5UUy5tZCBhbmQgQlVJTERJTkcubWQnICsgKGYnIChpbnRlZ3JhdGlvbiBpbnN0cnVjdGlvbnMgaW5jbHVkZWQpJyBpZiBpbnMuaXNfZmlsZSgpIGVsc2UgJycpKQo=')

sys.argv = ["modframeworks_docs.py",
            "--framework", 'ModMPV',
            "--out", str(out),
            "--builder", builder]
exec(compile(generator, "embedded_docs.py", "exec"))
EMBEDDED_DOCS
