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
    work_dir="$script_root/.modmkv-macos15"
    output_dir="$script_root/output-ModMKV"
    # Fail closed if the workspace/output are symlinks, even if they point inside the root.
    for target in "$work_dir" "$output_dir"; do
        if [[ -L "$target" ]]; then echo "ERROR: refusing symlinked directory: $target" >&2; return 2; fi
        if [[ -e "$target" && ! -d "$target" ]]; then echo "ERROR: expected directory: $target" >&2; return 2; fi
    done
    work_size='not present'; output_size='not present'
    [[ ! -d "$work_dir" ]] || work_size="$(du -sh "$work_dir" 2>/dev/null | awk '{print $1}')"
    [[ ! -d "$output_dir" ]] || output_size="$(du -sh "$output_dir" 2>/dev/null | awk '{print $1}')"
    printf '\n%s — disk-space management\n' 'ModMKV'
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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$ROOT/.modmkv-macos15}"
OUT="${OUT:-$ROOT/output-ModMKV}"
PREFIX="$WORK/stage"
EBML_BUILD="$WORK/libebml-build"
MATROSKA_BUILD="$WORK/libmatroska-build"
MIN_MACOS="${MIN_MACOS:-15.4}"
VERSION="${VERSION:-1.0.0}"
BUNDLE_ID="${BUNDLE_ID:-org.modframeworks.ModMKV}"
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
CLEAN_ALL="${CLEAN_ALL:-0}"
CHECK_ONLY="${CHECK_ONLY:-0}"

LIBEBML_SOURCE="${LIBEBML_SOURCE:-$WORK/libebml}"
LIBMATROSKA_SOURCE="${LIBMATROSKA_SOURCE:-$WORK/libmatroska}"
LIBEBML_REF="${LIBEBML_REF:-release-1.4.5}"
LIBMATROSKA_REF="${LIBMATROSKA_REF:-release-1.7.1}"
LIBEBML_URL="${LIBEBML_URL:-https://github.com/Matroska-Org/libebml.git}"
LIBMATROSKA_URL="${LIBMATROSKA_URL:-https://github.com/Matroska-Org/libmatroska.git}"
WRAPPER_SOURCE="$WORK/modmkv_wrapper.cpp"
# C++ wrapper is generated here; no separately maintained .cpp file.
# Full upstream C++ APIs are linked and public headers are packaged.
# Swift sees the C-compatible façade; use Objective-C++/C++ for upstream APIs.

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
for flag in XCFRAMEWORK SIGN CLEAN_BUILD CLEAN_ALL CHECK_ONLY; do
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

TOOLS=(git cmake ninja xcrun clang clang++ swiftc lipo otool nm c++filt python3 shasum)
[[ "$XCFRAMEWORK" != 1 ]] || TOOLS+=(xcodebuild)
[[ "$SIGN" != 1 ]] || TOOLS+=(codesign)
for tool in "${TOOLS[@]}"; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: required tool not found: $tool" >&2
        exit 2
    }
done

if [[ "$CHECK_ONLY" == 1 ]]; then
    printf 'Preflight passed for ModMKV (%s, arm64, macOS %s).\n' \
        "$(xcrun --find clang++)" "$MIN_MACOS"
    exit 0
fi

if [[ "$CLEAN_ALL" == 1 ]]; then
    [[ "$WORK" != / && "$OUT" != / && "$WORK" != "$OUT" ]] || {
        echo "ERROR: unsafe CLEAN_ALL WORK/OUT paths" >&2; exit 2;
    }
    case "$WORK" in "$ROOT"|"$ROOT/") echo "ERROR: WORK cannot be script root" >&2; exit 2;; esac
    case "$OUT" in "$ROOT"|"$ROOT/") echo "ERROR: OUT cannot be script root" >&2; exit 2;; esac
    echo "Removing ModMKV workspace: $WORK"
    echo "Removing ModMKV output: $OUT"
    rm -rf -- "$WORK" "$OUT"
fi

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun --sdk macosx -f clang)"
CXX="$(xcrun --sdk macosx -f clang++)"
mkdir -p "$WORK" "$OUT"
exec > >(tee "$OUT/build.log") 2>&1

fetch_source() {
    local name="$1" url="$2" path="$3" ref="$4"
    if [[ -d "$path/.git" ]]; then
        [[ -f "$path/CMakeLists.txt" ]] || { echo "ERROR: $name checkout missing CMakeLists.txt" >&2; return 2; }
        [[ -z "$(git -C "$path" status --porcelain --untracked-files=no)" ]] || {
            echo "ERROR: $name checkout has local tracked changes" >&2; return 2;
        }
        local expected actual
        expected="$(git -C "$path" rev-parse --verify "${ref}^{commit}" 2>/dev/null)" || {
            echo "ERROR: $name ref $ref not found in existing checkout; use CLEAN_ALL=1" >&2; return 2;
        }
        actual="$(git -C "$path" rev-parse HEAD)"
        [[ "$actual" == "$expected" ]] || {
            echo "ERROR: $name checkout $actual differs from requested $ref ($expected); use CLEAN_ALL=1" >&2; return 2;
        }
        echo "Using verified $name checkout: $actual"
        return 0
    fi
    [[ ! -e "$path" ]] || { echo "ERROR: $name source path exists and is not a Git checkout: $path" >&2; return 2; }
    mkdir -p "$(dirname "$path")"
    echo "Cloning $name ($ref) from $url..."
    git clone --depth 1 --branch "$ref" "$url" "$path"
    [[ -f "$path/CMakeLists.txt" ]] || { echo "ERROR: cloned $name missing CMakeLists.txt" >&2; return 2; }
    [[ -z "$(git -C "$path" status --porcelain --untracked-files=no)" ]] || return 2
}

fetch_source libebml "$LIBEBML_URL" "$LIBEBML_SOURCE" "$LIBEBML_REF"
fetch_source libmatroska "$LIBMATROSKA_URL" "$LIBMATROSKA_SOURCE" "$LIBMATROSKA_REF"

cat > "$WRAPPER_SOURCE" <<'EOF_WRAPPER'
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <limits>
#include <string>
#include <vector>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>

typedef struct ModMKVInspectionElement {
    uint64_t element_id;
    uint64_t offset;
    uint64_t data_offset;
    uint64_t data_size;
    int32_t parent_index;
    uint8_t is_unknown_size;
} ModMKVInspectionElement;

// Bounded EBML walker: never loads Cluster payloads or entire media files.
// All modifications are fixed-length; no segment offsets or media bytes move.
namespace {
struct Node { uint64_t id, start, payload, end; unsigned sizeWidth; };
struct Patch { uint64_t offset; std::vector<unsigned char> bytes; };
struct File {
    int fd=-1; uint64_t size=0;
    explicit File(const char* path, bool write) {
        if (!path) return;
        fd=open(path, write ? O_RDWR : O_RDONLY);
        if (fd>=0) { struct stat st{}; if (fstat(fd,&st)==0 && st.st_size>=0) size=(uint64_t)st.st_size; else {close(fd);fd=-1;} }
    }
    ~File(){if(fd>=0)close(fd);}
    bool read(uint64_t pos, void* buf, size_t len) const {
        if(fd<0 || pos>size || len>size-pos || pos>INT64_MAX)return false;
        auto* p=(unsigned char*)buf; size_t done=0;
        while(done<len){ssize_t n=pread(fd,p+done,len-done,(off_t)(pos+done));if(n<=0)return false;done+=(size_t)n;}return true;
    }
    bool write(uint64_t pos,const std::vector<unsigned char>& data) const {
        if(fd<0 || pos>size || data.size()>size-pos || pos>INT64_MAX)return false;
        size_t done=0;while(done<data.size()){ssize_t n=pwrite(fd,data.data()+done,data.size()-done,(off_t)(pos+done));if(n<=0)return false;done+=(size_t)n;}return true;
    }
};
bool trace(){auto* v=getenv("MODMKV_TRACE");return v && *v && strcmp(v,"0");}
#define TRACE(...) do {if(trace()){fprintf(stderr,"ModMKV TRACE: ");fprintf(stderr,__VA_ARGS__);fprintf(stderr,"\n");}}while(0)
// Returns false for malformed, unknown-size, or out-of-bounds elements.
bool parse(const File& f,uint64_t pos,uint64_t limit,Node& n){
    if(pos>=limit || limit>f.size)return false;
    unsigned char first=0;if(!f.read(pos,&first,1)||first==0)return false;
    unsigned idw=1;while(idw<=4 && !(first & (0x80u>>(idw-1))))++idw;
    if(idw>4 || idw>limit-pos)return false;
    unsigned char hdr[12]{};if(!f.read(pos,hdr,idw+1))return false;
    uint64_t id=0;for(unsigned i=0;i<idw;++i)id=(id<<8)|hdr[i];
    unsigned char s=hdr[idw];if(!s)return false;
    unsigned sw=1;while(sw<=8 && !(s&(0x80u>>(sw-1))))++sw;
    if(sw>8 || idw+sw>limit-pos || !f.read(pos,hdr,idw+sw))return false;
    uint64_t length=hdr[idw]&((1u<<(8-sw))-1u);
    for(unsigned i=1;i<sw;++i)length=(length<<8)|hdr[idw+i];
    if(length==((uint64_t(1)<<(7*sw))-1))return false; // fail closed on unknown size
    uint64_t payload=pos+idw+sw;
    if(length>limit-payload)return false;
    n={id,pos,payload,payload+length,sw};return true;
}
bool children(const File& f,uint64_t from,uint64_t to,std::vector<Node>& out){
    if(to>f.size || from>to)return false;
    for(uint64_t p=from;p<to;){Node n{};if(!parse(f,p,to,n))return false;out.push_back(n);p=n.end;}
    return true;
}
bool root(const File& f,Node& seg){
    Node ebml{};if(!parse(f,0,f.size,ebml)||ebml.id!=0x1A45DFA3)return false;
    for(uint64_t p=ebml.end;p<f.size;){Node n{};if(!parse(f,p,f.size,n))return false;
        if(n.id==0x18538067){seg=n;TRACE("segment pos=%llu payload=%llu end=%llu",(unsigned long long)n.start,(unsigned long long)n.payload,(unsigned long long)n.end);return true;}p=n.end;}
    return false;
}
bool find(const File& f,const Node& parent,uint64_t id,Node& out){
    for(uint64_t p=parent.payload;p<parent.end;){Node n{};if(!parse(f,p,parent.end,n))return false;
        if(n.id==id){out=n;return true;}p=n.end;}
    return false;
}
bool get(const File& f,const Node& n,std::string& s){
    uint64_t len=n.end-n.payload;if(len>1024*1024)return false;
    s.resize((size_t)len);return !len || f.read(n.payload,&s[0],(size_t)len);
}
bool integer(const File& f,const Node& n,uint64_t& value){
    auto len=n.end-n.payload;if(len>8 || !len)return false;
    unsigned char b[8]{};if(!f.read(n.payload,b,(size_t)len))return false;
    value=0;for(unsigned i=0;i<len;++i)value=(value<<8)|b[i];return true;
}
bool voidBytes(uint64_t size,std::vector<unsigned char>& out){
    if(size<2 || size>SIZE_MAX)return false;
    unsigned sw=0;for(unsigned w=1;w<=8;++w){if(size>=1+w && size-1-w < ((uint64_t(1)<<(7*w))-1)){sw=w;break;}}
    if(!sw)return false;
    out.assign((size_t)size,0);out[0]=0xEC;
    uint64_t payload=size-1-sw;for(unsigned i=0;i<sw;++i){out[sw-i]=(unsigned char)(payload&0xFF);payload>>=8;}
    out[1]|=(unsigned char)(0x80u>>(sw-1));return true;
}
bool replacePayload(const File& f,const Node& n,const std::string& value,Patch& patch){
    // Preserve encoded payload length, EBML size width, and all following offsets.
    if(value.size()!=n.end-n.payload)return false;
    patch={n.payload,std::vector<unsigned char>(value.begin(),value.end())};return true;
}
bool commit(File& f,const std::vector<Patch>& patches){
    if(patches.empty())return false;
    for(auto& p:patches)if(p.offset>f.size||p.bytes.size()>f.size-p.offset)return false;
    // Snapshot all target bytes before the first write, allowing rollback on I/O failure.
    std::vector<std::vector<unsigned char>> original;
    for(auto& p:patches){original.emplace_back(p.bytes.size());if(!f.read(p.offset,original.back().data(),original.back().size()))return false;}
    size_t written=0;
    for(;written<patches.size();++written){if(!f.write(patches[written].offset,patches[written].bytes))break;}
    if(written!=patches.size()){
        for(size_t i=0;i<=written && i<patches.size();++i)f.write(patches[i].offset,original[i]);
        fsync(f.fd);return false;
    }
    return fsync(f.fd)==0;
}
bool locateTrack(const File& f,const Node& seg,int number,Node& tracks,Node& entry){
    if(number<=0 || !find(f,seg,0x1654AE6B,tracks))return false;
    for(uint64_t p=tracks.payload;p<tracks.end;){Node n{};if(!parse(f,p,tracks.end,n))return false;
        if(n.id==0xAE){Node num{};uint64_t val=0;if(find(f,n,0xD7,num)&&integer(f,num,val)&&val==(uint64_t)number){entry=n;return true;}}p=n.end;}
    return false;
}
int copy(const std::string& s,char* dst,size_t capacity){if(!dst || s.size()>=capacity)return 0;memcpy(dst,s.c_str(),s.size()+1);return 1;}
uint64_t infoKey(const char* key){if(!key)return 0;if(!strcmp(key,"Title"))return 0x7BA9;if(!strcmp(key,"MuxingApp"))return 0x4D80;if(!strcmp(key,"WritingApp"))return 0x5741;return 0;}
uint64_t trackKey(const char* key){if(!key)return 0;if(!strcmp(key,"Name"))return 0x536E;if(!strcmp(key,"Language"))return 0x22B59C;if(!strcmp(key,"CodecID"))return 0x86;return 0;}

// Indexed metadata access. Indices are zero-based and follow on-disk order.
bool nth(const File& f,const Node& parent,uint64_t id,int index,Node& result){
    if(index<0)return false;
    for(uint64_t p=parent.payload;p<parent.end;){Node n{};if(!parse(f,p,parent.end,n))return false;
        if(n.id==id && index--==0){result=n;return true;}p=n.end;}
    return false;
}
int countChildren(const File& f,const Node& parent,uint64_t id){
    int count=0;for(uint64_t p=parent.payload;p<parent.end;){Node n{};if(!parse(f,p,parent.end,n))return -1;
        if(n.id==id){if(count==INT32_MAX)return -1;++count;}p=n.end;}return count;
}
bool nested(const File& f,uint64_t container,uint64_t child,int index,Node& out){
    Node seg{},outer{};return root(f,seg)&&find(f,seg,container,outer)&&nth(f,outer,child,index,out);
}
int readString(const File& f,const Node& parent,uint64_t id,char* buf,size_t cap){
    Node n{};std::string s;return find(f,parent,id,n)&&get(f,n,s)?copy(s,buf,cap):0;
}
int readNumber(const File& f,const Node& parent,uint64_t id,uint64_t* out){
    if(!out)return 0;Node n{};uint64_t v=0;if(!find(f,parent,id,n)||!integer(f,n,v))return 0;*out=v;return 1;
}
int setString(const char* path,const Node& parent,uint64_t id,const char* value,File& f){
    if(!value)return 0;Node n{};Patch patch{};
    return find(f,parent,id,n)&&replacePayload(f,n,value,patch)&&commit(f,{patch})?1:0;
}
int eraseIndexed(const char* path,uint64_t container,uint64_t child,int index){
    File f(path,true);Node n{};if(f.fd<0||!nested(f,container,child,index,n))return 0;
    std::vector<unsigned char> bytes;if(!voidBytes(n.end-n.start,bytes))return 0;
    return commit(f,{{n.start,std::move(bytes)}})?1:0;
}
bool chapterAt(const File& f,int edition,int chapter,Node& out){
    Node ed{};return nested(f,0x1043A770,0x45B9,edition,ed)&&nth(f,ed,0xB6,chapter,out);
}
bool attachmentAt(const File& f,int index,Node& out){return nested(f,0x1941A469,0x61A7,index,out);}
bool simpleTagAt(const File& f,int tagIndex,int simpleIndex,Node& out){
    Node tag{};return nested(f,0x1254C367,0x7373,tagIndex,tag)&&nth(f,tag,0x67C8,simpleIndex,out);
}

int clearKind(const char* path,uint64_t id){File f(path,true);Node seg{};if(f.fd<0||!root(f,seg))return 0;
    std::vector<Node> nodes;if(!children(f,seg.payload,seg.end,nodes))return 0;
    std::vector<Patch> patches;for(auto& n:nodes)if(n.id==id){std::vector<unsigned char> v;if(!voidBytes(n.end-n.start,v))return 0;patches.push_back({n.start,std::move(v)});}
    TRACE("clear id=%llx matches=%zu",(unsigned long long)id,patches.size());return commit(f,patches)?1:0;
}
}

// v13 compatibility: copy-on-write EBML metadata editor for bounded, self-contained files.
// Files with offset tables (SeekHead/Cues), CRC-32, or unknown-sized elements
// are deliberately rejected rather than silently corrupted.
namespace rewrite13 {
using Bytes=std::vector<unsigned char>;
struct E { uint64_t id; size_t start, payload, end; unsigned width; };
bool parse(const Bytes& b,size_t pos,size_t limit,E& e) {
    if(pos>=limit||limit>b.size()||!b[pos])return false;
    unsigned iw=1;while(iw<=4&&!(b[pos]&(0x80u>>(iw-1))))++iw;
    if(iw>4||iw>limit-pos)return false;
    uint64_t id=0;for(unsigned j=0;j<iw;++j)id=(id<<8)|b[pos+j];
    size_t q=pos+iw;if(q>=limit||!b[q])return false;
    unsigned sw=1;while(sw<=8&&!(b[q]&(0x80u>>(sw-1))))++sw;
    if(sw>8||sw>limit-q)return false;
    uint64_t n=b[q]&((1u<<(8-sw))-1u);
    for(unsigned j=1;j<sw;++j)n=(n<<8)|b[q+j];
    if(n==((uint64_t(1)<<(7*sw))-1)||n>limit-q-sw)return false;
    e={id,pos,q+sw,q+sw+(size_t)n,sw};return true;
}
bool find(const Bytes& b,const E& parent,uint64_t id,E& out){
    for(size_t p=parent.payload;p<parent.end;){E e{};if(!parse(b,p,parent.end,e))return false;
        if(e.id==id){out=e;return true;}p=e.end;}return false;
}
bool segment(const Bytes& b,E& seg){
    E header{};if(!parse(b,0,b.size(),header)||header.id!=0x1A45DFA3)return false;
    for(size_t p=header.end;p<b.size();){E e{};if(!parse(b,p,b.size(),e))return false;
        if(e.id==0x18538067){seg=e;return true;}p=e.end;}return false;
}
bool encodeSize(size_t n,unsigned width,Bytes& out){
    if(width<1||width>8||uint64_t(n)>=(uint64_t(1)<<(7*width))-1)return false;
    out.assign(width,0);uint64_t v=n;
    for(unsigned j=0;j<width;++j){out[width-j-1]=(unsigned char)(v&255);v>>=8;}
    out[0]|=(unsigned char)(0x80u>>(width-1));return true;
}
bool encodeID(uint64_t id,Bytes& out){
    unsigned w=id>0xffffff?4:id>0xffff?3:id>0xff?2:1;
    out.resize(w);for(unsigned j=0;j<w;++j)out[w-j-1]=(unsigned char)(id>>(8*j));return true;
}
bool element(uint64_t id,const Bytes& payload,Bytes& out){
    Bytes idb,sz;encodeID(id,idb);
    unsigned w=1;while(w<=8&&!encodeSize(payload.size(),w,sz))++w;
    if(w>8)return false;out=idb;out.insert(out.end(),sz.begin(),sz.end());
    out.insert(out.end(),payload.begin(),payload.end());return true;
}
bool readFile(const char* path,Bytes& b){
    if(!path)return false;File f(path,false);
    if(f.fd<0||f.size>uint64_t(SIZE_MAX)||f.size>uint64_t(8)*1024*1024*1024)return false;
    b.resize((size_t)f.size);return b.empty()||f.read(0,b.data(),b.size());
}
bool guarded(const Bytes& b,const E& seg){
    // Any explicit position table or CRC anywhere in the segment is unsafe to shift.
    // Inspect container hierarchy only, never interpret Cluster payload as elements.
    const uint64_t containers[]={0x1549A966,0x1654AE6B,0xAE,0x1254C367,0x7373,0x63C0,0x67C8,0x1043A770,0x45B9,0xB6,0x80,0x1941A469,0x61A7};
    std::vector<E> stack{seg};size_t examined=0;
    while(!stack.empty()){
        E p=stack.back();stack.pop_back();
        for(size_t pos=p.payload;pos<p.end;){E e{};if(!parse(b,pos,p.end,e))return false;
            if(++examined>1000000||e.id==0x114D9B74||e.id==0x1C53BB6B||e.id==0xBF)return false;
            for(auto id:containers)if(e.id==id){stack.push_back(e);break;}
            pos=e.end;
        }
    }
    return true;
}
bool writeAtomic(const char* path,const Bytes& b){
    if(!path)return false;struct stat st{};
    if(stat(path,&st)||!S_ISREG(st.st_mode)||st.st_nlink!=1)return false;
    std::string temp=std::string(path)+".modmkv14-XXXXXX";
    std::vector<char> name(temp.begin(),temp.end());name.push_back(0);
    int fd=mkstemp(name.data());if(fd<0)return false;
    bool ok=fchmod(fd,st.st_mode&07777)==0;
    size_t done=0;while(ok&&done<b.size()){
        ssize_t n=::write(fd,b.data()+done,b.size()-done);if(n<=0){ok=false;break;}done+=(size_t)n;
    }
    if(ok)ok=fsync(fd)==0;
    if(close(fd))ok=false;
    if(ok)ok=rename(name.data(),path)==0;
    if(!ok)unlink(name.data());return ok;
}
// Replace a leaf payload; update every ancestor size field up to the Segment.
// The segment is required to be the last top-level element.
bool replace(const char* path,const std::vector<uint64_t>& ids,const Bytes& value,bool insert){
    Bytes b;if(!readFile(path,b))return false;E seg{};
    if(!segment(b,seg)||seg.end!=b.size()||!guarded(b,seg))return false;
    std::vector<E> chain{seg};
    for(size_t i=0;i<ids.size();++i){E child{};
        if(!find(b,chain.back(),ids[i],child)){
            if(!insert||i+1!=ids.size())return false;
            // Append a new element to the final container.
            Bytes elem;if(!element(ids[i],value,elem))return false;
            b.insert(b.begin()+chain.back().end,elem.begin(),elem.end());
            for(size_t k=chain.size();k-->0;){E e=chain[k];Bytes sz;
                size_t old=e.end-e.payload, newSize=old+elem.size();
                if(!encodeSize(newSize,e.width,sz))return false;
                std::copy(sz.begin(),sz.end(),b.begin()+e.payload-e.width);
            }
            return writeAtomic(path,b);
        }
        chain.push_back(child);
    }
    E leaf=chain.back();size_t old=leaf.end-leaf.payload;
    if(value.size()>SIZE_MAX-(b.size()-old))return false;
    Bytes output;b.erase(b.begin()+leaf.payload,b.begin()+leaf.end);
    b.insert(b.begin()+leaf.payload,value.begin(),value.end());
    long long delta=(long long)value.size()-(long long)old;
    for(size_t k=chain.size();k-->0;){E e=chain[k];Bytes sz;
        size_t newSize=k+1==chain.size()?value.size():(size_t)((long long)(e.end-e.payload)+delta);
        if(!encodeSize(newSize,e.width,sz))return false;
        std::copy(sz.begin(),sz.end(),b.begin()+e.payload-e.width);
    }
    return writeAtomic(path,b);
}
}

// v14: read-only, bounded, streaming Matroska element inspection.
// This walker never loads Cluster data and accepts unknown-sized Segment to EOF.
namespace inspect14 {
struct Item { uint64_t id,start,payload,end; int32_t parent; uint8_t unknown; };
struct Scan { std::vector<Item> nodes; int errors=0; };
bool parseNode(const File& f,uint64_t pos,uint64_t limit,Item& out,int32_t parent){
    if(pos>=limit||limit>f.size)return false;
    unsigned char first=0;if(!f.read(pos,&first,1)||!first)return false;
    unsigned iw=1;while(iw<=4 && !(first&(0x80u>>(iw-1))))++iw;
    if(iw>4||iw>limit-pos)return false;
    unsigned char hdr[12]{};if(!f.read(pos,hdr,iw+1))return false;
    uint64_t id=0;for(unsigned i=0;i<iw;++i)id=(id<<8)|hdr[i];
    unsigned sw=1;while(sw<=8 && !(hdr[iw]&(0x80u>>(sw-1))))++sw;
    if(sw>8||iw+sw>limit-pos||!f.read(pos,hdr,iw+sw))return false;
    uint64_t len=hdr[iw]&((1u<<(8-sw))-1u);
    for(unsigned i=1;i<sw;++i)len=(len<<8)|hdr[iw+i];
    bool unknown=len==((uint64_t(1)<<(7*sw))-1);
    uint64_t payload=pos+iw+sw;
    // Unknown-sized Segment is valid; other unknown-sized masters need a
    // schema-aware termination rule, so reject rather than fabricate bounds.
    if(unknown && id!=0x18538067)return false;
    if(!unknown && len>limit-payload)return false;
    out={id,pos,payload,unknown?limit:payload+len,parent,(uint8_t)unknown};return true;
}
bool master(uint64_t id){
    switch(id){
        case 0x1A45DFA3: case 0x18538067: case 0x114D9B74: case 0x4DBB:
        case 0x1549A966: case 0x1654AE6B: case 0xAE: case 0xE0: case 0xE1:
        case 0x55B0: case 0x55D0: case 0x6D80: case 0x6240: case 0x5034:
        case 0x1254C367: case 0x7373: case 0x63C0: case 0x67C8:
        case 0x1043A770: case 0x45B9: case 0xB6: case 0x80:
        case 0x1941A469: case 0x61A7: case 0x1C53BB6B: case 0xBB: case 0xB7:
        case 0x1F43B675: return true;
        default: return false;
    }
}
// Only descend into known metadata/index masters; Cluster is represented as
// an opaque element to avoid walking millions of media blocks.
bool descend(uint64_t id){return master(id)&&id!=0x1F43B675;}
bool scan(const char* path,Scan& scan,size_t maxNodes){
    File f(path,false);if(f.fd<0||f.size==0||maxNodes==0)return false;
    struct Span {uint64_t pos,end;int32_t parent;};
    std::vector<Span> stack{{0,f.size,-1}};
    bool sawHeader=false,sawSegment=false;
    while(!stack.empty()){
        Span& span=stack.back();
        if(span.pos==span.end){stack.pop_back();continue;}
        if(span.pos>span.end||scan.nodes.size()>=maxNodes){++scan.errors;return false;}
        Item item{};
        if(!parseNode(f,span.pos,span.end,item,span.parent)){++scan.errors;return false;}
        if(item.id==0x1A45DFA3&&span.parent==-1)sawHeader=true;
        if(item.id==0x18538067&&span.parent==-1)sawSegment=true;
        int32_t idx=(int32_t)scan.nodes.size();scan.nodes.push_back(item);
        span.pos=item.end;
        if(descend(item.id)&&item.payload<item.end)stack.push_back({item.payload,item.end,idx});
    }
    if(!sawHeader||!sawSegment){++scan.errors;return false;}
    return true;
}
}

extern "C" {
int Matroska_SetSegmentStringTag(const char* path,const char* key,const char* value){
    uint64_t id=infoKey(key);if(!id||!value)return 0;
    File f(path,true);Node seg{},info{},field{};
    if(f.fd<0||!root(f,seg)||!find(f,seg,0x1549A966,info)||!find(f,info,id,field))return 0;
    Patch p{};if(!replacePayload(f,field,value,p)){TRACE("title replacement requires equal payload length: old=%llu new=%zu",(unsigned long long)(field.end-field.payload),strlen(value));return 0;}
    return commit(f,{p})?1:0;
}
int Matroska_SetTrackFlags(const char* path,int number,int def,int forced,const char* language){
    if(def< -1||def>1||forced< -1||forced>1)return 0;
    File f(path,true);Node seg{},tracks{},entry{};if(f.fd<0||!root(f,seg)||!locateTrack(f,seg,number,tracks,entry))return 0;
    std::vector<Patch> patches;
    for(auto choice: {std::pair<uint64_t,int>{0x88,def},{0x55AA,forced}}){
        if(choice.second<0)continue;Node n{};if(!find(f,entry,choice.first,n)||n.end-n.payload!=1)return 0;
        patches.push_back({n.payload,{(unsigned char)choice.second}});
    }
    if(language){Node n{};Patch p{};if(!find(f,entry,0x22B59C,n)||!replacePayload(f,n,language,p))return 0;patches.push_back(std::move(p));}
    return commit(f,patches)?1:0;
}
int Matroska_ClearAllChapters(const char* path){return clearKind(path,0x1043A770);}
int Matroska_ClearAllAttachments(const char* path){return clearKind(path,0x1941A469);}
int ModMKV_GetSegmentString(const char* path,const char* key,char* buf,size_t cap){
    File f(path,false);Node seg{},info{},n{};std::string s;return f.fd>=0&&root(f,seg)&&find(f,seg,0x1549A966,info)&&find(f,info,infoKey(key),n)&&get(f,n,s)?copy(s,buf,cap):0;
}
int ModMKV_GetTrackCount(const char* path){File f(path,false);Node seg{},tracks{};if(f.fd<0||!root(f,seg))return -1;
    if(!find(f,seg,0x1654AE6B,tracks))return 0;std::vector<Node> nodes;if(!children(f,tracks.payload,tracks.end,nodes))return -1;
    int count=0;for(auto& n:nodes)if(n.id==0xAE)++count;return count;
}
int ModMKV_GetTrackNumberAtIndex(const char* path,int index){if(index<0)return -1;
    File f(path,false);Node seg{},tracks{};if(f.fd<0||!root(f,seg)||!find(f,seg,0x1654AE6B,tracks))return -1;
    std::vector<Node> nodes;if(!children(f,tracks.payload,tracks.end,nodes))return -1;
    for(auto& n:nodes)if(n.id==0xAE){if(index--==0){Node num{};uint64_t v=0;return find(f,n,0xD7,num)&&integer(f,num,v)&&v<=INT32_MAX?(int)v:-1;}}return -1;
}
int ModMKV_GetTrackString(const char* path,int number,const char* key,char* buf,size_t cap){
    uint64_t id=trackKey(key);if(!id)return 0;File f(path,false);Node seg{},tracks{},entry{},n{};std::string s;
    return f.fd>=0&&root(f,seg)&&locateTrack(f,seg,number,tracks,entry)&&find(f,entry,id,n)&&get(f,n,s)?copy(s,buf,cap):0;
}
int ModMKV_GetTrackFlag(const char* path,int number,const char* key){
    uint64_t id=key&&!strcmp(key,"Default")?0x88:key&&!strcmp(key,"Forced")?0x55AA:0;
    if(!id)return -1;File f(path,false);Node seg{},tracks{},entry{},n{};uint64_t v=0;
    if(f.fd<0||!root(f,seg)||!locateTrack(f,seg,number,tracks,entry))return -1;
    if(!find(f,entry,id,n))return id==0x88?1:0;
    return integer(f,n,v)?(v?1:0):-1;
}
int ModMKV_SetTrackName(const char* path,int number,const char* name){
    if(!name)return 0;File f(path,true);Node seg{},tracks{},entry{},n{};Patch p{};
    return f.fd>=0&&root(f,seg)&&locateTrack(f,seg,number,tracks,entry)&&find(f,entry,0x536E,n)&&replacePayload(f,n,name,p)&&commit(f,{p})?1:0;
}
int ModMKV_ClearAllTags(const char* path){return clearKind(path,0x1254C367);}
int ModMKV_GetElementCount(const char* path,const char* kind){
    uint64_t id=kind&&!strcmp(kind,"Tags")?0x1254C367:kind&&!strcmp(kind,"Chapters")?0x1043A770:kind&&!strcmp(kind,"Attachments")?0x1941A469:0;
    if(!id)return -1;File f(path,false);Node seg{};if(f.fd<0||!root(f,seg))return -1;
    std::vector<Node> nodes;if(!children(f,seg.payload,seg.end,nodes))return -1;
    int count=0;for(auto& n:nodes)if(n.id==id)++count;return count;
}

// Metadata navigation; missing fields return 0 (or -1 for counts).
int ModMKV_GetTagCount(const char* path){
    File f(path,false);Node seg{},tags{};if(f.fd<0||!root(f,seg))return -1;
    if(!find(f,seg,0x1254C367,tags))return 0;return countChildren(f,tags,0x7373);
}
int ModMKV_GetSimpleTagCount(const char* path,int tagIndex){
    File f(path,false);Node tag{};return f.fd>=0&&nested(f,0x1254C367,0x7373,tagIndex,tag)?countChildren(f,tag,0x67C8):-1;
}
int ModMKV_GetSimpleTagString(const char* path,int tagIndex,int simpleIndex,const char* field,char* buf,size_t cap){
    uint64_t id=field&&!strcmp(field,"Name")?0x45A3:field&&!strcmp(field,"Value")?0x4487:
                field&&!strcmp(field,"Language")?0x447A:field&&!strcmp(field,"LanguageIETF")?0x447B:0;
    if(!id)return 0;File f(path,false);Node n{};
    return f.fd>=0&&simpleTagAt(f,tagIndex,simpleIndex,n)?readString(f,n,id,buf,cap):0;
}
int ModMKV_SetSimpleTagString(const char* path,int tagIndex,int simpleIndex,const char* field,const char* value){
    uint64_t id=field&&!strcmp(field,"Name")?0x45A3:field&&!strcmp(field,"Value")?0x4487:0;
    if(!id)return 0;File f(path,true);Node n{};
    return f.fd>=0&&simpleTagAt(f,tagIndex,simpleIndex,n)?setString(path,n,id,value,f):0;
}
int ModMKV_GetTagTargetUID(const char* path,int tagIndex,const char* kind,uint64_t* uid){
    uint64_t id=kind&&!strcmp(kind,"Track")?0x63C5:kind&&!strcmp(kind,"Edition")?0x63C9:
                kind&&!strcmp(kind,"Chapter")?0x63C4:kind&&!strcmp(kind,"Attachment")?0x63C6:0;
    if(!id)return 0;File f(path,false);Node tag{},target{};
    return f.fd>=0&&nested(f,0x1254C367,0x7373,tagIndex,tag)&&find(f,tag,0x63C0,target)?readNumber(f,target,id,uid):0;
}
int ModMKV_RemoveTag(const char* path,int index){return eraseIndexed(path,0x1254C367,0x7373,index);}
int ModMKV_GetEditionCount(const char* path){
    File f(path,false);Node seg{},chapters{};if(f.fd<0||!root(f,seg))return -1;
    if(!find(f,seg,0x1043A770,chapters))return 0;return countChildren(f,chapters,0x45B9);
}
int ModMKV_GetChapterCount(const char* path,int edition){
    File f(path,false);Node ed{};return f.fd>=0&&nested(f,0x1043A770,0x45B9,edition,ed)?countChildren(f,ed,0xB6):-1;
}
int ModMKV_GetChapterUID(const char* path,int edition,int index,uint64_t* uid){
    File f(path,false);Node n{};return f.fd>=0&&chapterAt(f,edition,index,n)?readNumber(f,n,0x73C4,uid):0;
}
int ModMKV_GetChapterTime(const char* path,int edition,int index,int end,uint64_t* ns){
    File f(path,false);Node n{};return f.fd>=0&&chapterAt(f,edition,index,n)?readNumber(f,n,end?0x92:0x91,ns):0;
}
int ModMKV_GetChapterDisplayString(const char* path,int edition,int index,int displayIndex,const char* field,char* buf,size_t cap){
    uint64_t id=field&&!strcmp(field,"Title")?0x85:field&&!strcmp(field,"Language")?0x437C:0;
    if(!id)return 0;File f(path,false);Node chapter{},display{};
    return f.fd>=0&&chapterAt(f,edition,index,chapter)&&nth(f,chapter,0x80,displayIndex,display)?readString(f,display,id,buf,cap):0;
}
int ModMKV_SetChapterDisplayTitle(const char* path,int edition,int index,int displayIndex,const char* value){
    File f(path,true);Node chapter{},display{};
    return f.fd>=0&&chapterAt(f,edition,index,chapter)&&nth(f,chapter,0x80,displayIndex,display)?setString(path,display,0x85,value,f):0;
}
int ModMKV_RemoveChapter(const char* path,int edition,int index){
    File f(path,true);Node n{};if(f.fd<0||!chapterAt(f,edition,index,n))return 0;
    std::vector<unsigned char> bytes;if(!voidBytes(n.end-n.start,bytes))return 0;
    return commit(f,{{n.start,std::move(bytes)}})?1:0;
}
int ModMKV_GetAttachmentCount(const char* path){
    File f(path,false);Node seg{},attachments{};if(f.fd<0||!root(f,seg))return -1;
    if(!find(f,seg,0x1941A469,attachments))return 0;return countChildren(f,attachments,0x61A7);
}
int ModMKV_GetAttachmentString(const char* path,int index,const char* field,char* buf,size_t cap){
    uint64_t id=field&&!strcmp(field,"Name")?0x466E:field&&!strcmp(field,"MimeType")?0x4660:
                field&&!strcmp(field,"Description")?0x467E:0;
    if(!id)return 0;File f(path,false);Node n{};
    return f.fd>=0&&attachmentAt(f,index,n)?readString(f,n,id,buf,cap):0;
}
int ModMKV_GetAttachmentUID(const char* path,int index,uint64_t* uid){
    File f(path,false);Node n{};return f.fd>=0&&attachmentAt(f,index,n)?readNumber(f,n,0x46AE,uid):0;
}
int ModMKV_GetAttachmentSize(const char* path,int index,uint64_t* size){
    if(!size)return 0;File f(path,false);Node n{},data{};
    if(f.fd<0||!attachmentAt(f,index,n)||!find(f,n,0x465C,data))return 0;
    *size=data.end-data.payload;return 1;
}
int ModMKV_ExtractAttachment(const char* path,int index,const char* output){
    if(!output||!path||!strcmp(path,output))return 0;
    File f(path,false);Node n{},data{};
    if(f.fd<0||!attachmentAt(f,index,n)||!find(f,n,0x465C,data))return 0;
    int dst=open(output,O_WRONLY|O_CREAT|O_EXCL,0600);if(dst<0)return 0;
    unsigned char buf[65536];bool ok=true;
    for(uint64_t pos=data.payload;pos<data.end;){
        size_t chunk=(size_t)std::min<uint64_t>(sizeof(buf),data.end-pos);
        if(!f.read(pos,buf,chunk)){ok=false;break;}
        size_t done=0;while(done<chunk){ssize_t written=write(dst,buf+done,chunk-done);if(written<=0){ok=false;break;}done+=(size_t)written;}
        if(!ok)break;pos+=chunk;
    }
    if(close(dst)!=0)ok=false;if(!ok)unlink(output);return ok?1:0;
}
int ModMKV_RemoveAttachment(const char* path,int index){return eraseIndexed(path,0x1941A469,0x61A7,index);}
int ModMKV_GetTrackUInt(const char* path,int number,const char* field,uint64_t* value){
    uint64_t id=field&&!strcmp(field,"UID")?0x73C5:field&&!strcmp(field,"Type")?0x83:
                field&&!strcmp(field,"Enabled")?0xB9:field&&!strcmp(field,"Default")?0x88:
                field&&!strcmp(field,"Forced")?0x55AA:0;
    if(!id)return 0;File f(path,false);Node seg{},tracks{},entry{};
    return f.fd>=0&&root(f,seg)&&locateTrack(f,seg,number,tracks,entry)?readNumber(f,entry,id,value):0;
}
int ModMKV_SetTrackString(const char* path,int number,const char* field,const char* value){
    uint64_t id=field&&!strcmp(field,"Name")?0x536E:field&&!strcmp(field,"Language")?0x22B59C:
                field&&!strcmp(field,"LanguageIETF")?0x22B59D:0;
    if(!id)return 0;File f(path,true);Node seg{},tracks{},entry{};
    return f.fd>=0&&root(f,seg)&&locateTrack(f,seg,number,tracks,entry)?setString(path,entry,id,value,f):0;
}


// Copy-on-write variable-length title editor. Rejects SeekHead, Cues, CRC and
// unknown-size elements, rather than invalidating Matroska offsets.
// v14 inspector API. Index is zero-based, depth-first on-disk order.
// Returns -1 on scan failure; JSON export never modifies the input.
int ModMKV_GetInspectionCount(const char* path){
    inspect14::Scan s;return inspect14::scan(path,s,1000000)?(int)s.nodes.size():-1;
}
int ModMKV_GetInspectionElement(const char* path,int index,ModMKVInspectionElement* out){
    if(index<0||!out)return 0;inspect14::Scan s;
    if(!inspect14::scan(path,s,1000000)||(size_t)index>=s.nodes.size())return 0;
    const auto& n=s.nodes[(size_t)index];
    *out={n.id,n.start,n.payload,n.end-n.payload,n.parent,n.unknown};return 1;
}
int ModMKV_ValidateStructure(const char* path){
    inspect14::Scan s;return inspect14::scan(path,s,1000000)?1:0;
}
int ModMKV_ExportInspectionJSON(const char* path,const char* outputPath){
    if(!path||!outputPath||!strcmp(path,outputPath))return 0;
    inspect14::Scan s;if(!inspect14::scan(path,s,1000000))return 0;
    // Exclusive creation prevents overwriting arbitrary existing files.
    int fd=open(outputPath,O_WRONLY|O_CREAT|O_EXCL,0644);if(fd<0)return 0;
    FILE* stream=fdopen(fd,"w");if(!stream){close(fd);unlink(outputPath);return 0;}
    bool ok=fputs("{\"schema\":\"modmkv.inspection.v1\",\"elements\":[\n",stream)>=0;
    for(size_t i=0;ok&&i<s.nodes.size();++i){const auto& n=s.nodes[i];
        if(fprintf(stream,"%s{\"id\":%llu,\"offset\":%llu,\"dataOffset\":%llu,\"dataSize\":%llu,\"parentIndex\":%d,\"unknownSize\":%s}",
          i?",\n":"",(unsigned long long)n.id,(unsigned long long)n.start,
          (unsigned long long)n.payload,(unsigned long long)(n.end-n.payload),
          n.parent,n.unknown?"true":"false")<0)ok=false;
    }
    if(ok)ok=fputs("\n]}\n",stream)>=0;
    if(ok)ok=fflush(stream)==0;
    if(ok)ok=fsync(fd)==0;
    if(fclose(stream))ok=false;
    if(!ok)unlink(outputPath);return ok?1:0;
}
int ModMKV_RewriteSegmentTitle(const char* path,const char* title){
    if(!title)return 0;
    rewrite13::Bytes value((const unsigned char*)title,(const unsigned char*)title+strlen(title));
    return rewrite13::replace(path,{0x1549A966,0x7BA9},value,false)?1:0;
}
int ModMKV_RewriteTrackName(const char* path,int number,const char* name){
    if(number<=0||!name)return 0;
    // Resolve track by number first, then rewrite using its on-disk TrackEntry index.
    File f(path,false);Node seg{},tracks{};
    if(f.fd<0||!root(f,seg)||!find(f,seg,0x1654AE6B,tracks))return 0;
    int index=0,found=-1;
    for(uint64_t pos=tracks.payload;pos<tracks.end;){Node e{};
        if(!parse(f,pos,tracks.end,e))return 0;
        if(e.id==0xAE){Node n{};uint64_t v=0;
            if(find(f,e,0xD7,n)&&integer(f,n,v)&&v==(uint64_t)number){found=index;break;}
            ++index;
        }pos=e.end;
    }
    if(found<0)return 0;
    // Current v13 safe rewrite supports the first TrackEntry only; no silent wrong-track edits.
    if(found!=0)return 0;
    rewrite13::Bytes value((const unsigned char*)name,(const unsigned char*)name+strlen(name));
    return rewrite13::replace(path,{0x1654AE6B,0xAE,0x536E},value,false)?1:0;
}

}
EOF_WRAPPER

LIBEBML_REVISION="$(git -C "$LIBEBML_SOURCE" rev-parse HEAD)"
LIBMATROSKA_REVISION="$(git -C "$LIBMATROSKA_SOURCE" rev-parse HEAD)"
echo "libebml commit: $LIBEBML_REVISION"
echo "libmatroska commit: $LIBMATROSKA_REVISION"
echo "Target: macOS $MIN_MACOS arm64; SDK: $SDK_PATH"
echo "Compiler: $("$CXX" --version | head -n 1)"
echo "CMake: $(cmake --version | head -n 1)"

# v9 requires rebuilding archives that may have been compiled with hidden visibility.
# A stamp prevents needlessly rebuilding on subsequent v9 runs.
VISIBILITY_STAMP="$WORK/.modmkv-public-cxx-v10"
if [[ ! -f "$VISIBILITY_STAMP" && "$CLEAN_BUILD" != 1 ]]; then
    echo "Rebuilding upstream archives once for public C++ symbol visibility (v10)."
    rm -rf "$EBML_BUILD" "$MATROSKA_BUILD" "$PREFIX"
fi
if [[ "$CLEAN_BUILD" == 1 ]]; then
    echo "Removing only generated ModMKV build and staging directories."
    rm -rf "$EBML_BUILD" "$MATROSKA_BUILD" "$PREFIX"
fi
mkdir -p "$PREFIX"

# Upstream CMake targets add -fvisibility=hidden after CMake global flags.
# CMAKE_CXX_COMPILER_LAUNCHER executes after target flags have been assembled;
# append -fvisibility=default as the last compiler argument for each object.
# This is generated by this script, not a separately maintained source file.
VISIBILITY_LAUNCHER="$WORK/modmkv-public-visibility-launcher.sh"
cat > "$VISIBILITY_LAUNCHER" <<'EOF_VIS_LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail
exec "$@" -fvisibility=default
EOF_VIS_LAUNCHER
chmod +x "$VISIBILITY_LAUNCHER"

COMMON_CMAKE_ARGS=(
    -G Ninja
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_C_COMPILER="$CC"
    -DCMAKE_CXX_COMPILER="$CXX"
    -DCMAKE_CXX_COMPILER_LAUNCHER="$VISIBILITY_LAUNCHER"
    -DCMAKE_CXX_STANDARD=17
    -DCMAKE_CXX_STANDARD_REQUIRED=ON
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    -DCMAKE_CXX_VISIBILITY_PRESET=default
    -DCMAKE_C_VISIBILITY_PRESET=default
    -DCMAKE_VISIBILITY_INLINES_HIDDEN=OFF
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
    -DCMAKE_OSX_ARCHITECTURES=arm64
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS"
    -DCMAKE_OSX_SYSROOT="$SDK_PATH"
    -DBUILD_SHARED_LIBS=OFF
    -DBUILD_TESTING=OFF
    -DDEV_MODE=OFF
)

EBML_CMAKE_ARGS=("${COMMON_CMAKE_ARGS[@]}" -DCMAKE_INSTALL_PREFIX="$PREFIX")
UTF8CPP_SOURCE="$LIBEBML_SOURCE/build/_deps/utf8cpp-src"
if [[ -f "$UTF8CPP_SOURCE/CMakeLists.txt" ]]; then
    EBML_CMAKE_ARGS+=("-DFETCHCONTENT_SOURCE_DIR_UTF8CPP=$UTF8CPP_SOURCE")
fi
cmake -S "$LIBEBML_SOURCE" -B "$EBML_BUILD" "${EBML_CMAKE_ARGS[@]}"
cmake --build "$EBML_BUILD" --parallel "$JOBS"
cmake --install "$EBML_BUILD"

cmake -S "$LIBMATROSKA_SOURCE" -B "$MATROSKA_BUILD" \
    "${COMMON_CMAKE_ARGS[@]}" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_PREFIX_PATH="$PREFIX" \
    -DEbml_DIR="$PREFIX/lib/cmake/EBML"
cmake --build "$MATROSKA_BUILD" --parallel "$JOBS"
cmake --install "$MATROSKA_BUILD"

# compile_commands.json records upstream flags but not the compiler launcher's
# final appended argument. Verify the launcher is configured for both targets,
# and that it appends -fvisibility=default AFTER the upstream arguments.
python3 - "$EBML_BUILD/CMakeCache.txt" "$MATROSKA_BUILD/CMakeCache.txt" "$VISIBILITY_LAUNCHER" <<'PY_VISIBILITY'
import pathlib, sys
launcher = pathlib.Path(sys.argv[3]).resolve()
body = launcher.read_text()
if 'exec "$@" -fvisibility=default' not in body:
    raise SystemExit('ERROR: visibility launcher does not append default visibility')
for cache_file in sys.argv[1:3]:
    cache = pathlib.Path(cache_file).read_text()
    expected = f'CMAKE_CXX_COMPILER_LAUNCHER:UNINITIALIZED={launcher}'
    if expected not in cache and f'CMAKE_CXX_COMPILER_LAUNCHER:STRING={launcher}' not in cache:
        raise SystemExit(f'ERROR: compiler launcher not configured in {cache_file}')
    print(f'PASS: default-visibility compiler launcher configured: {cache_file}')
PY_VISIBILITY
EBML_LIBRARY="$PREFIX/lib/libebml.a"
MATROSKA_LIBRARY="$PREFIX/lib/libmatroska.a"
[[ -s "$EBML_LIBRARY" && -s "$MATROSKA_LIBRARY" ]] || {
    echo "ERROR: expected installed libebml and libmatroska static archives" >&2
    exit 1
}
[[ -d "$PREFIX/include/ebml" && -d "$PREFIX/include/matroska" ]] || {
    echo "ERROR: expected installed EBML or Matroska public headers are missing" >&2
    exit 1
}

FRAMEWORK="$OUT/ModMKV.framework"
XCFRAMEWORK_PATH="$OUT/ModMKV.xcframework"
rm -rf "$FRAMEWORK" "$XCFRAMEWORK_PATH"
rm -f "$OUT/ModMKV-validation.txt" \
    "$OUT/ModMKV-mach-o-build.txt" \
    "$OUT/ModMKV-source-compliance.tar.gz" \
    "$OUT/ModMKV-header-inventory.json" \
    "$OUT/ModMKV-exported-symbols.txt" \
    "$OUT/ModMKV-linkage.txt" \
    "$OUT/ModMKV-mach-o-build.txt" \
    "$OUT/ModMKV-validation.txt"
mkdir -p "$FRAMEWORK/Versions/A/Headers" \
    "$FRAMEWORK/Versions/A/Modules" \
    "$FRAMEWORK/Versions/A/Frameworks" \
    "$FRAMEWORK/Versions/A/Resources/Legal"
cp -R "$PREFIX/include/ebml" "$PREFIX/include/matroska" \
    "$FRAMEWORK/Versions/A/Headers/"

cat > "$FRAMEWORK/Versions/A/Headers/ModMKV.h" <<'EOF_HEADER'
#ifndef MOD_MKV_H
#define MOD_MKV_H

#ifdef __cplusplus
extern "C" {
#endif

int Matroska_SetSegmentStringTag(const char *file_path, const char *tag_key,
                                 const char *tag_value);
int Matroska_SetTrackFlags(const char *file_path, int track_number,
                           int is_default, int is_forced,
                           const char *language_code);
int Matroska_ClearAllChapters(const char *file_path);
int Matroska_ClearAllAttachments(const char *file_path);

/* UTF-8 reads: return 1 on success, 0 on missing/invalid/insufficient buffer.
   Caller owns buffer. Pass buffer capacity including terminating NUL. */
#include <stddef.h>
int ModMKV_GetSegmentString(const char *path, const char *key, char *buffer, size_t capacity);
int ModMKV_GetTrackCount(const char *path); /* -1 on failure */
int ModMKV_GetTrackNumberAtIndex(const char *path, int index); /* -1 on failure */
int ModMKV_GetTrackString(const char *path, int number, const char *key, char *buffer, size_t capacity);
int ModMKV_GetTrackFlag(const char *path, int number, const char *key); /* -1 on failure */
int ModMKV_SetTrackName(const char *path, int number, const char *name);
int ModMKV_ClearAllTags(const char *path);
int ModMKV_GetElementCount(const char *path, const char *kind); /* -1 on failure */


/* Extended metadata API: indexed, zero-based, on-disk order.
 * All setters are fixed-payload-length only; they fail rather than grow metadata.
 * Removal replaces the selected element with an EBML Void (no media relocation).
 * No insertion or arbitrary-length rewriting is provided.
 * Count functions return -1 on error; other functions return 1 on success.
 * Missing optional values return 0. UTF-8 buffers include space for NUL.
 */
#include <stdint.h>
typedef struct ModMKVInspectionElement {
    uint64_t element_id;
    uint64_t offset;
    uint64_t data_offset;
    uint64_t data_size;
    int32_t parent_index;
    uint8_t is_unknown_size;
} ModMKVInspectionElement;


int ModMKV_GetTagCount(const char *path);
int ModMKV_GetSimpleTagCount(const char *path, int tag_index);
int ModMKV_GetSimpleTagString(const char *path, int tag_index, int simple_index, const char *field, char *buffer, size_t capacity);
int ModMKV_SetSimpleTagString(const char *path, int tag_index, int simple_index, const char *field, const char *value);
int ModMKV_GetTagTargetUID(const char *path, int tag_index, const char *kind, uint64_t *uid);
int ModMKV_RemoveTag(const char *path, int tag_index);
int ModMKV_GetEditionCount(const char *path);
int ModMKV_GetChapterCount(const char *path, int edition_index);
int ModMKV_GetChapterUID(const char *path, int edition_index, int chapter_index, uint64_t *uid);
int ModMKV_GetChapterTime(const char *path, int edition_index, int chapter_index, int end, uint64_t *nanoseconds);
int ModMKV_GetChapterDisplayString(const char *path, int edition_index, int chapter_index, int display_index, const char *field, char *buffer, size_t capacity);
int ModMKV_SetChapterDisplayTitle(const char *path, int edition_index, int chapter_index, int display_index, const char *title);
int ModMKV_RemoveChapter(const char *path, int edition_index, int chapter_index);
int ModMKV_GetAttachmentCount(const char *path);
int ModMKV_GetAttachmentString(const char *path, int index, const char *field, char *buffer, size_t capacity);
int ModMKV_GetAttachmentUID(const char *path, int index, uint64_t *uid);
int ModMKV_GetAttachmentSize(const char *path, int index, uint64_t *size);
int ModMKV_ExtractAttachment(const char *path, int index, const char *output_path);
int ModMKV_RemoveAttachment(const char *path, int index);
int ModMKV_GetTrackUInt(const char *path, int track_number, const char *field, uint64_t *value);
int ModMKV_SetTrackString(const char *path, int track_number, const char *field, const char *value);
/* v14: read-only structural inspection. No input file modification. */
int ModMKV_GetInspectionCount(const char *path);
int ModMKV_GetInspectionElement(const char *path, int index, ModMKVInspectionElement *element);
int ModMKV_ValidateStructure(const char *path); /* basic EBML boundary check, NOT full CRC/Cues validation */
int ModMKV_ExportInspectionJSON(const char *path, const char *output_path); /* O_EXCL: no overwrite */
/* v13 copy-on-write variable-length edits; fail closed on offset tables and CRC. */
int ModMKV_RewriteSegmentTitle(const char *path, const char *title);
int ModMKV_RewriteTrackName(const char *path, int track_number, const char *name);

#ifdef __cplusplus
}
#endif

#endif
EOF_HEADER

cat > "$FRAMEWORK/Versions/A/Modules/module.modulemap" <<'EOF_MODULE'
framework module ModMKV {
    header "ModMKV.h"
    export *
}
EOF_MODULE

BIN="$FRAMEWORK/Versions/A/ModMKV"
"$CXX" -dynamiclib -O3 -std=c++17 \
    -arch arm64 -isysroot "$SDK_PATH" \
    -mmacosx-version-min="$MIN_MACOS" \
    -DEBML_STATIC_DEFINE -DMATROSKA_STATIC_DEFINE \
    -I"$PREFIX/include" \
    "$WRAPPER_SOURCE" \
    -Wl,-force_load,"$MATROSKA_LIBRARY" \
    -Wl,-force_load,"$EBML_LIBRARY" \
    -Wl,-install_name,"@rpath/ModMKV.framework/Versions/A/ModMKV" \
    -o "$BIN"

cp "$LIBEBML_SOURCE/LICENSE.LGPL" \
    "$FRAMEWORK/Versions/A/Resources/Legal/LICENSE.libebml.LGPL"
cp "$LIBMATROSKA_SOURCE/LICENSE.LGPL" \
    "$FRAMEWORK/Versions/A/Resources/Legal/LICENSE.libmatroska.LGPL"

python3 - "$FRAMEWORK/Versions/A/Resources/Info.plist" \
    "$BUNDLE_ID" "$VERSION" "$MIN_MACOS" <<'PY_PLIST'
import plistlib
import sys

path, bundle_id, version, minimum = sys.argv[1:]
plist = {
    "CFBundleDevelopmentRegion": "en",
    "CFBundleExecutable": "ModMKV",
    "CFBundleIdentifier": bundle_id,
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": "ModMKV",
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
ln -s Versions/Current/ModMKV "$FRAMEWORK/ModMKV"
ln -s Versions/Current/Headers "$FRAMEWORK/Headers"
ln -s Versions/Current/Modules "$FRAMEWORK/Modules"
ln -s Versions/Current/Resources "$FRAMEWORK/Resources"

cat > "$FRAMEWORK/Versions/A/Resources/Legal/BUILD_INFO.txt" <<EOF_BUILD
libebml commit: $LIBEBML_REVISION
libmatroska commit: $LIBMATROSKA_REVISION
Architecture: arm64 (macOS)
Minimum macOS: $MIN_MACOS
Version: $VERSION
SDK: $SDK_PATH
Compiler: $("$CXX" --version | head -n 1)
CMake: $(cmake --version | head -n 1)
Build configuration: Release, complete static libebml/libmatroska archives force-loaded into ModMKV.
C++ headers: Headers/ebml and Headers/matroska; Swift module: ModMKV.h only.
EOF_BUILD

python3 - "$FRAMEWORK/Versions/A/Headers" \
    "$OUT/ModMKV-header-inventory.json" <<'PY_HEADERS'
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
print(f"PASS: inventoried {len(headers)} public headers with SHA-256")
PY_HEADERS

EXPORTS="$OUT/ModMKV-exported-symbols.txt"
nm -gU "$BIN" > "$EXPORTS"
for symbol in Matroska_SetSegmentStringTag Matroska_SetTrackFlags \
    Matroska_ClearAllChapters Matroska_ClearAllAttachments \
    ModMKV_GetSegmentString ModMKV_GetTrackCount ModMKV_GetTrackNumberAtIndex \
    ModMKV_GetTrackString ModMKV_GetTrackFlag ModMKV_SetTrackName \
    ModMKV_ClearAllTags ModMKV_GetElementCount \
    ModMKV_GetTagCount ModMKV_GetSimpleTagCount ModMKV_GetSimpleTagString \
    ModMKV_SetSimpleTagString ModMKV_GetTagTargetUID ModMKV_RemoveTag \
    ModMKV_GetEditionCount ModMKV_GetChapterCount ModMKV_GetChapterUID \
    ModMKV_GetChapterTime ModMKV_GetChapterDisplayString ModMKV_SetChapterDisplayTitle \
    ModMKV_RemoveChapter ModMKV_GetAttachmentCount ModMKV_GetAttachmentString \
    ModMKV_GetAttachmentUID ModMKV_GetAttachmentSize ModMKV_ExtractAttachment \
    ModMKV_RemoveAttachment ModMKV_GetTrackUInt ModMKV_SetTrackString \
    ModMKV_RewriteSegmentTitle ModMKV_RewriteTrackName \
    ModMKV_GetInspectionCount ModMKV_GetInspectionElement \
    ModMKV_ValidateStructure ModMKV_ExportInspectionJSON; do
    grep -Eq "[[:space:]]_${symbol}$" "$EXPORTS" || {
        echo "ERROR: expected C API symbol is not exported: $symbol" >&2
        exit 1
    }
done

# Validate actual dynamic exports before attempting the C++ consumer link.
# nm -gU prints mangled names, so use nm -gUm for readable C++ signatures.
CXX_EXPORTS="$OUT/ModMKV-cxx-export-audit.txt"
nm -gU "$BIN" | sed -E 's/([[:space:]])_(_Z)/\1\2/' | c++filt > "$CXX_EXPORTS"
python3 - "$CXX_EXPORTS" <<'PY_CXX_EXPORTS'
import sys
s = open(sys.argv[1], encoding='utf-8').read()
required = (
    'libmatroska::KaxSegment::KaxSegment()',
    'libmatroska::KaxTracks::KaxTracks()',
    'libebml::EbmlHead::EbmlHead()',
    'libebml::EbmlMaster::~EbmlMaster()',
)
missing = [name for name in required if name not in s]
if missing:
    for name in missing:
        print(f'ERROR: upstream C++ symbol not exported: {name}', file=sys.stderr)
    print('ERROR: inspect ModMKV-cxx-export-audit.txt and upstream visibility flags', file=sys.stderr)
    sys.exit(1)
print('PASS: upstream C++ constructors and destructor exported')
PY_CXX_EXPORTS
lipo -verify_arch arm64 "$BIN"
plutil -lint "$FRAMEWORK/Versions/A/Resources/Info.plist"
if ! otool -D "$BIN" |
    grep -Fxq '@rpath/ModMKV.framework/Versions/A/ModMKV'; then
    echo "ERROR: unexpected ModMKV install name" >&2
    otool -L "$BIN" >&2
    exit 1
fi
if otool -L "$BIN" |
    grep -E '(/opt/homebrew/|/usr/local/|/opt/local/|'"$WORK"')'; then
    echo "ERROR: ModMKV has a non-system dynamic dependency" >&2
    exit 1
fi
otool -L "$BIN" > "$OUT/ModMKV-linkage.txt"
xcrun vtool -show-build "$BIN" > "$OUT/ModMKV-mach-o-build.txt"
grep -Eq 'platform[[:space:]]+MACOS' "$OUT/ModMKV-mach-o-build.txt" || {
    echo "ERROR: ModMKV binary does not target macOS" >&2
    exit 1
}

python3 - "$WORK/modmkv-smoke.mkv" <<'PY_MKV_FIXTURE'
import sys

def element(element_id, payload):
    for width in range(1, 9):
        if len(payload) <= (1 << (7 * width)) - 2:
            size = (1 << (7 * width)) | len(payload)
            return element_id + size.to_bytes(width, "big") + payload
    raise ValueError("fixture element is too large")

header = b"".join((
    element(b"\x42\x86", b"\x01"),
    element(b"\x42\xf7", b"\x01"),
    element(b"\x42\xf2", b"\x04"),
    element(b"\x42\xf3", b"\x08"),
    element(b"\x42\x82", b"matroska"),
    element(b"\x42\x87", b"\x04"),
    element(b"\x42\x85", b"\x02"),
))
info = element(b"\x15\x49\xa9\x66", b"".join((
    element(b"\x2a\xd7\xb1", b"\x0f\x42\x40"),
    element(b"\x4d\x80", b"AppA"),
    element(b"\x57\x41", b"AppA"),
    element(b"\x7b\xa9", b"Test"),
)))
track = element(b"\xae", b"".join((
    element(b"\xd7", b"\x01"),
    element(b"\x73\xc5", b"\x01"),
    element(b"\x83", b"\x01"),
    element(b"\x88", b"\x01"),
    element(b"\x55\xaa", b"\x00"),
    element(b"\x22\xb5\x9c", b"eng"),
    element(b"\x86", b"V_VP8"),
)))
tracks = element(b"\x16\x54\xae\x6b", track)
chapters = element(b"\x10\x43\xa7\x70", b"")
attachments = element(b"\x19\x41\xa4\x69", b"")
cluster = element(b"\x1f\x43\xb6\x75", b"".join((
    element(b"\xe7", b"\x00"),
    element(b"\xa3", b"\x81\x00\x00\x80x"),
)))
segment = element(b"\x18\x53\x80\x67", info + tracks + chapters + attachments + cluster)
with open(sys.argv[1], "wb") as output:
    output.write(element(b"\x1a\x45\xdf\xa3", header))
    output.write(segment)
with open(sys.argv[1] + ".cluster", "wb") as output:
    output.write(cluster)
PY_MKV_FIXTURE

cat > "$WORK/modmkv-c-smoke.c" <<'EOF_C'
#include <ModMKV/ModMKV.h>
#include <stddef.h>
#include <stdio.h>

#define CHECK_OK(expr, code) do { \
    int result = (expr); \
    fprintf(stderr, "SMOKE: %s => %d (expected 1)\n", #expr, result); \
    if (result != 1) return (code); \
} while (0)

int main(int argc, char **argv)
{
    if (argc != 2)
        return 2;
    CHECK_OK(Matroska_SetSegmentStringTag(argv[1], "Title", "Mkv!"), 3);
    CHECK_OK(Matroska_SetTrackFlags(argv[1], 1, 0, 1, "fra"), 4);
    CHECK_OK(Matroska_ClearAllChapters(argv[1]), 5);
    CHECK_OK(Matroska_ClearAllAttachments(argv[1]), 8);
    if (Matroska_ClearAllChapters(argv[1]) != 0 ||
        Matroska_ClearAllAttachments(argv[1]) != 0)
        return 6;
    if (Matroska_SetTrackFlags(argv[1], 0, 1, 1, NULL) != 0 ||
        Matroska_SetSegmentStringTag(argv[1], "Unknown", "value") != 0)
        return 7;
    return 0;
}
EOF_C
"$CC" -arch arm64 -isysroot "$SDK_PATH" \
    -mmacosx-version-min="$MIN_MACOS" -F"$OUT" \
    "$WORK/modmkv-c-smoke.c" -framework ModMKV \
    -Wl,-rpath,"$OUT" -o "$WORK/modmkv-c-smoke"
original_size="$(stat -f %z "$WORK/modmkv-smoke.mkv")"
set +e
MODMKV_TRACE=1 DYLD_FRAMEWORK_PATH="$OUT" "$WORK/modmkv-c-smoke" "$WORK/modmkv-smoke.mkv"
smoke_status=$?
set -e
if [[ "$smoke_status" -ne 0 ]]; then
    echo "ERROR: ModMKV C metadata smoke test failed with exit code $smoke_status" >&2
    echo "       3=segment title, 4=track flags, 5=chapters, 8=attachments, 6=repeat removal, 7=invalid-input checks" >&2
    echo "       Trace includes bounded EBML traversal and fixed-size metadata writes." >&2
    exit "$smoke_status"
fi
python3 - "$WORK/modmkv-smoke.mkv" "$WORK/modmkv-smoke.mkv.cluster" \
    "$original_size" <<'PY_VERIFY_MKV'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
cluster = pathlib.Path(sys.argv[2]).read_bytes()
original_size = int(sys.argv[3])
data = path.read_bytes()
assert len(data) == original_size, "in-place edits changed the Matroska file size"
assert data.endswith(cluster), "Matroska Cluster bytes changed during metadata edits"
assert b"\x7b\xa9\x84Mkv!" in data, "Title was not updated"
assert b"\x88\x81\x00" in data, "Track default flag was not updated"
assert b"\x55\xaa\x81\x01" in data, "Track forced flag was not updated"
assert b"\x22\xb5\x9c\x83fra" in data, "Track language was not updated"
assert b"\x10\x43\xa7\x70" not in data, "Chapters were not cleared"
assert b"\x19\x41\xa4\x69" not in data, "Attachments were not cleared"
print("PASS: metadata and track edits preserved file size and Cluster data")
PY_VERIFY_MKV
echo "PASS: standalone C API consumer exercised metadata and track edits"


# Extended metadata fixture and API integration test (separate from the legacy smoke file).
python3 - "$WORK/modmkv-extended.mkv" <<'PY_EXT_FIXTURE'
import sys

def e(i, p):
    for w in range(1, 9):
        if len(p) < (1 << (7*w)) - 1:
            return i + ((1 << (7*w)) | len(p)).to_bytes(w, 'big') + p
    raise ValueError('element too large')

header = e(bytes.fromhex('1a45dfa3'), e(bytes.fromhex('4282'), b'matroska'))
info = e(bytes.fromhex('1549a966'), e(bytes.fromhex('7ba9'), b'Test'))
track = e(bytes.fromhex('ae'), e(bytes.fromhex('d7'), b'\x01') + e(bytes.fromhex('73c5'), b'\x02') + e(bytes.fromhex('83'), b'\x01') + e(bytes.fromhex('536e'), b'Video'))
tracks = e(bytes.fromhex('1654ae6b'), track)
tag = e(bytes.fromhex('7373'), e(bytes.fromhex('63c0'), e(bytes.fromhex('63c5'), b'\x02')) + e(bytes.fromhex('67c8'), e(bytes.fromhex('45a3'), b'ARTIST') + e(bytes.fromhex('4487'), b'Alpha')))
tags = e(bytes.fromhex('1254c367'), tag)
chapter = e(bytes.fromhex('b6'), e(bytes.fromhex('73c4'), b'\x05') + e(bytes.fromhex('91'), (1000000000).to_bytes(8,'big')) + e(bytes.fromhex('80'), e(bytes.fromhex('85'), b'Intro')))
chapters = e(bytes.fromhex('1043a770'), e(bytes.fromhex('45b9'), chapter))
attachment = e(bytes.fromhex('61a7'), e(bytes.fromhex('46ae'), b'\x07') + e(bytes.fromhex('466e'), b'cover.jpg') + e(bytes.fromhex('4660'), b'image/jpeg') + e(bytes.fromhex('465c'), b'FAKEJPEG'))
attachments = e(bytes.fromhex('1941a469'), attachment)
cluster = e(bytes.fromhex('1f43b675'), e(bytes.fromhex('e7'), b'\x00'))
open(sys.argv[1], 'wb').write(header + e(bytes.fromhex('18538067'), info + tracks + tags + chapters + attachments + cluster))
PY_EXT_FIXTURE
cat > "$WORK/modmkv-extended-smoke.c" <<'EOF_EXT_C'
#include <ModMKV/ModMKV.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#define REQUIRE(x) do {if(!(x)){fprintf(stderr,"FAIL extended API line %d: %s\n",__LINE__,#x);return 3;}}while(0)
int main(int argc,char **argv){
    if(argc!=3)return 2;
    char buf[128]={0};uint64_t u=0;
    REQUIRE(ModMKV_GetTagCount(argv[1])==1);
    REQUIRE(ModMKV_GetSimpleTagCount(argv[1],0)==1);
    REQUIRE(ModMKV_GetSimpleTagString(argv[1],0,0,"Name",buf,sizeof buf)==1 && strcmp(buf,"ARTIST")==0);
    REQUIRE(ModMKV_GetSimpleTagString(argv[1],0,0,"Value",buf,sizeof buf)==1 && strcmp(buf,"Alpha")==0);
    REQUIRE(ModMKV_GetTagTargetUID(argv[1],0,"Track",&u)==1 && u==2);
    REQUIRE(ModMKV_SetSimpleTagString(argv[1],0,0,"Value","Bravo")==1);
    REQUIRE(ModMKV_GetEditionCount(argv[1])==1 && ModMKV_GetChapterCount(argv[1],0)==1);
    REQUIRE(ModMKV_GetChapterUID(argv[1],0,0,&u)==1 && u==5);
    REQUIRE(ModMKV_GetChapterTime(argv[1],0,0,0,&u)==1 && u==1000000000ULL);
    REQUIRE(ModMKV_GetChapterDisplayString(argv[1],0,0,0,"Title",buf,sizeof buf)==1 && strcmp(buf,"Intro")==0);
    REQUIRE(ModMKV_SetChapterDisplayTitle(argv[1],0,0,0,"Start")==1);
    REQUIRE(ModMKV_GetAttachmentCount(argv[1])==1);
    REQUIRE(ModMKV_GetAttachmentString(argv[1],0,"Name",buf,sizeof buf)==1 && strcmp(buf,"cover.jpg")==0);
    REQUIRE(ModMKV_GetAttachmentUID(argv[1],0,&u)==1 && u==7);
    REQUIRE(ModMKV_GetAttachmentSize(argv[1],0,&u)==1 && u==8);
    REQUIRE(ModMKV_ExtractAttachment(argv[1],0,argv[2])==1);
    REQUIRE(ModMKV_GetTrackUInt(argv[1],1,"UID",&u)==1 && u==2);
    REQUIRE(ModMKV_SetTrackString(argv[1],1,"Name","Movie")==1);
    REQUIRE(ModMKV_RemoveChapter(argv[1],0,0)==1 && ModMKV_GetChapterCount(argv[1],0)==0);
    REQUIRE(ModMKV_RemoveAttachment(argv[1],0)==1 && ModMKV_GetAttachmentCount(argv[1])==0);
    REQUIRE(ModMKV_RemoveTag(argv[1],0)==1 && ModMKV_GetTagCount(argv[1])==0);
    return 0;
}
EOF_EXT_C
"$CC" -arch arm64 -isysroot "$SDK_PATH" -mmacosx-version-min="$MIN_MACOS" -F"$OUT" \
    "$WORK/modmkv-extended-smoke.c" -framework ModMKV -Wl,-rpath,"$OUT" -o "$WORK/modmkv-extended-smoke"
# Extraction intentionally uses O_EXCL; remove only the previous test artifact.
# This makes repeated builds deterministic without weakening the API's no-overwrite rule.
rm -f -- "$WORK/modmkv-extracted.bin"
DYLD_FRAMEWORK_PATH="$OUT" "$WORK/modmkv-extended-smoke" "$WORK/modmkv-extended.mkv" "$WORK/modmkv-extracted.bin"
python3 - "$WORK/modmkv-extracted.bin" <<'PY_EXT_VERIFY'
import pathlib,sys
assert pathlib.Path(sys.argv[1]).read_bytes()==b'FAKEJPEG', 'attachment extraction mismatch'
print('PASS: indexed tags, chapters, attachments, track fields, and extraction')
PY_EXT_VERIFY


# Validate that the public upstream C++ headers and C++ symbols are consumable.
cat > "$WORK/modmkv-cxx-smoke.cpp" <<'EOF_CXX'
#include <ebml/EbmlHead.h>
#include <matroska/KaxSegment.h>
#include <matroska/KaxTracks.h>
#include <type_traits>
int main() {
    libebml::EbmlHead header;
    libmatroska::KaxSegment segment;
    libmatroska::KaxTracks tracks;
    return (header.GetElementPosition() == 0 &&
            segment.GetElementPosition() == 0 &&
            tracks.GetElementPosition() == 0) ? 0 : 1;
}
EOF_CXX
"$CXX" -std=c++17 -arch arm64 -isysroot "$SDK_PATH" \
    -mmacosx-version-min="$MIN_MACOS" \
    -DEBML_STATIC_DEFINE -DMATROSKA_STATIC_DEFINE \
    -I"$FRAMEWORK/Headers" -F"$OUT" \
    "$WORK/modmkv-cxx-smoke.cpp" -framework ModMKV \
    -Wl,-rpath,"$OUT" -o "$WORK/modmkv-cxx-smoke"
DYLD_FRAMEWORK_PATH="$OUT" "$WORK/modmkv-cxx-smoke"
echo "PASS: standalone C++ consumer imported upstream headers and linked upstream classes"

cat > "$WORK/modmkv-swift-smoke.swift" <<'EOF_SWIFT'
import ModMKV

precondition(Matroska_SetSegmentStringTag(nil, nil, nil) == 0)
precondition(Matroska_SetTrackFlags(nil, 0, -1, -1, nil) == 0)
precondition(Matroska_ClearAllChapters(nil) == 0)
precondition(Matroska_ClearAllAttachments(nil) == 0)
precondition(ModMKV_GetTrackCount(nil) == -1)
precondition(ModMKV_GetElementCount(nil, nil) == -1)
precondition(ModMKV_SetTrackName(nil, 1, nil) == 0)
precondition(ModMKV_GetTagCount(nil) == -1)
precondition(ModMKV_GetEditionCount(nil) == -1)
precondition(ModMKV_GetAttachmentCount(nil) == -1)
precondition(ModMKV_RemoveAttachment(nil, 0) == 0)
precondition(ModMKV_GetTrackUInt(nil, 1, nil, nil) == 0)
EOF_SWIFT
swiftc -F "$OUT" -framework ModMKV \
    "$WORK/modmkv-swift-smoke.swift" -o "$WORK/modmkv-swift-smoke"
DYLD_FRAMEWORK_PATH="$OUT" "$WORK/modmkv-swift-smoke"
echo "PASS: standalone Swift consumer imported ModMKV, linked, and ran (including indexed metadata API)"

# Generate agent documentation before code signing.
DOCS="$FRAMEWORK/Versions/A/Resources/Documentation"
# v13 variable-length rewrite test on the synthetic no-index fixture.
python3 - "$WORK/modmkv-v13-rewrite.mkv" <<'PY_V13_FIXTURE'
import sys
p=sys.argv[1]
def e(i,v):
    assert len(v)<127
    return bytes.fromhex(i)+bytes([0x80|len(v)])+v
head=e('1a45dfa3',e('4282',b'matroska'))
info=e('1549a966',e('7ba9',b'Old'))
track=e('ae',e('d7',b'\x01')+e('536e',b'A'))
tracks=e('1654ae6b',track)
cluster=e('1f43b675',e('e7',b'\x00'))
open(p,'wb').write(head+e('18538067',info+tracks+cluster))
PY_V13_FIXTURE
cat > "$WORK/modmkv-v13-smoke.c" <<'EOF_V13_C'
#include <ModMKV/ModMKV.h>
#include <stdio.h>
#include <string.h>
int main(int argc,char**argv){
 if(argc!=2)return 2;
 if(!ModMKV_RewriteSegmentTitle(argv[1],"A much longer title"))return 3;
 if(!ModMKV_RewriteTrackName(argv[1],1,"Main Video Track"))return 4;
 char s[128];
 if(!ModMKV_GetSegmentString(argv[1],"Title",s,sizeof s))return 5;
 if(strcmp(s,"A much longer title"))return 6;
 if(!ModMKV_GetTrackString(argv[1],1,"Name",s,sizeof s))return 7;
 if(strcmp(s,"Main Video Track"))return 8;
 return 0;
}
EOF_V13_C
# Include string.h explicitly for standalone C consumer.
true # string.h included in source
"$CC" -arch arm64 -isysroot "$SDK_PATH" -mmacosx-version-min="$MIN_MACOS" \
 -F"$OUT" "$WORK/modmkv-v13-smoke.c" -framework ModMKV \
 -Wl,-rpath,"$OUT" -o "$WORK/modmkv-v13-smoke"
DYLD_FRAMEWORK_PATH="$OUT" "$WORK/modmkv-v13-smoke" "$WORK/modmkv-v13-rewrite.mkv"
echo 'PASS: v13 variable-length copy-on-write title and first-track name edits'

# v14: exercise structure inspector and unknown-sized Segment on synthetic fixtures.
python3 - "$WORK/modmkv-v14-unknown.mkv" <<'PY_V14_FIXTURE'
import sys
p=sys.argv[1]
def e(i,v):
    assert len(v)<127
    return bytes.fromhex(i)+bytes([0x80|len(v)])+v
head=e('1a45dfa3',e('4282',b'matroska'))
info=e('1549a966',e('7ba9',b'Inspection'))
cluster=e('1f43b675',e('e7',b'\x00'))
open(p,'wb').write(head+bytes.fromhex('18538067')+b'\xff'+info+cluster)
PY_V14_FIXTURE
cat > "$WORK/modmkv-v14-smoke.c" <<'EOF_V14_C'
#include <ModMKV/ModMKV.h>
#include <stdio.h>
int main(int argc,char**argv){
 if(argc!=3)return 2;
 if(!ModMKV_ValidateStructure(argv[1]))return 3;
 int n=ModMKV_GetInspectionCount(argv[1]);if(n<4)return 4;
 ModMKVInspectionElement item={0};int found=0;
 for(int i=0;i<n;i++){
   if(!ModMKV_GetInspectionElement(argv[1],i,&item))return 5;
   if(item.element_id==0x18538067){if(!item.is_unknown_size)return 6;found++;}
 }
 if(found!=1)return 7;
 if(!ModMKV_ExportInspectionJSON(argv[1],argv[2]))return 8;
 if(ModMKV_ExportInspectionJSON(argv[1],argv[2]))return 9;
 return 0;
}
EOF_V14_C
"$CC" -arch arm64 -isysroot "$SDK_PATH" -mmacosx-version-min="$MIN_MACOS" \
 -F"$OUT" "$WORK/modmkv-v14-smoke.c" -framework ModMKV \
 -Wl,-rpath,"$OUT" -o "$WORK/modmkv-v14-smoke"
rm -f "$WORK/modmkv-v14-inspection.json"
DYLD_FRAMEWORK_PATH="$OUT" "$WORK/modmkv-v14-smoke" \
 "$WORK/modmkv-v14-unknown.mkv" "$WORK/modmkv-v14-inspection.json"
python3 - "$WORK/modmkv-v14-inspection.json" <<'PY_V14_JSON'
import json,sys
x=json.load(open(sys.argv[1]));assert x['schema']=='modmkv.inspection.v1'
assert any(e['id']==0x18538067 and e['unknownSize'] for e in x['elements'])
PY_V14_JSON
echo 'PASS: v14 EBML inspector, unknown-sized Segment and JSON export'

mkdir -p "$DOCS"
python3 - "$FRAMEWORK/Versions/A/Headers/ModMKV.h" "$DOCS" "$OUT" \
  "$LIBEBML_REF" "$LIBEBML_REVISION" "$LIBMATROSKA_REF" "$LIBMATROSKA_REVISION" \
  "$MIN_MACOS" "$VERSION" <<'PY_AGENT_DOCS'
from pathlib import Path
import json, re, sys
header, docs, out, ebml_ref, ebml_rev, mkv_ref, mkv_rev, minimum, version = sys.argv[1:]
docs, out = Path(docs), Path(out)
src = re.sub(r'/\*.*?\*/|//[^\n]*', '', Path(header).read_text(), flags=re.S)
functions = sorted(set(re.findall(r'\b(?:Matroska_|ModMKV_)[A-Za-z0-9_]+(?=\s*\()', src)))
if len(functions) != 39:
    raise SystemExit(f'ERROR: expected 39 C API declarations, found {len(functions)}')
exports = (out / 'ModMKV-exported-symbols.txt').read_text()
missing = [name for name in functions if not re.search(r'(?m)\s_' + re.escape(name) + r'$', exports)]
if missing:
    raise SystemExit('ERROR: missing C API exports: ' + ', '.join(missing))
capabilities = {
    'framework': 'ModMKV', 'version': version, 'platform': 'macOS',
    'minimum_macos': minimum, 'architectures': ['arm64'],
    'upstream': {'libebml': {'ref': ebml_ref, 'commit': ebml_rev},
                 'libmatroska': {'ref': mkv_ref, 'commit': mkv_rev}},
    'api': {'c_function_count': len(functions), 'c_functions': functions,
            'swift': 'C facade', 'cpp': 'upstream libebml and libmatroska headers and linked classes'},
    'capabilities': ['segment and track inspection', 'indexed tag and chapter inspection',
                     'attachment inspection and extraction', 'streaming read-only EBML element inspection and JSON export', 'basic structural boundary validation', 'fixed-byte-length metadata editing',
                     'guarded copy-on-write variable-length segment title and first-track name edits',
                     'track flag edits', 'EBML Void element removal'],
    'limitations': ['no new metadata insertion', 'inspection does not validate CRC or SeekHead/Cues targets', 'variable-length edits limited to existing title and first track name',
                    'no media relocation', 'full metadata insertion and structural rewrite not implemented', 'no SeekHead/Cues/CRC maintenance',
                    'unknown-size Segment unsupported by bounded wrapper',
                    'existing fields required for edits'],
    'licensing': 'LGPL upstream dependencies; corresponding-source and relinking review required'
}
agent = '''# ModMKV agent instructions

Use ModMKV for Matroska-specific metadata reads, EBML structure inspection, and bounded edits.
Use ModMediaInfo for general read-only media inspection and ModFFmpeg for other
supported metadata writes and media processing.

Swift imports the ModMKV C facade; upstream C++ types require C++/Objective-C++.
Legacy setters require identical UTF-8 payload byte length. v13 RewriteSegmentTitle
and RewriteTrackName support variable-length copy-on-write changes on eligible files.
The v13 rewrite rejects SeekHead, Cues, CRC and unknown-size elements. Removal uses EBML Void.
No insertion, remuxing, general variable-size edits, SeekHead/Cues/CRC repair, or unknown-size
Segment support in the wrapper. Back up files before modifying them.
Consult capabilities.json for all declared and verified exported C functions.
'''
readme = f'''# ModMKV {version}

macOS {minimum}+ arm64 Matroska/EBML framework.

## Interfaces

- Swift/C: `import ModMKV` and use the {len(functions)} C functions in `ModMKV.h`.
- C++: include packaged `ebml/` and `matroska/` headers and link ModMKV.

## Capabilities and limitations

Read tags, chapters, tracks, and attachments; inspect EBML structure and export JSON;
extract attachments; edit existing
metadata using legacy equal-byte-length setters or v13 guarded copy-on-write title/name
rewrites; remove selected elements
using EBML Void. Variable-length rewriting rejects SeekHead/Cues/CRC. Does not insert
metadata, remux, repair SeekHead/Cues/CRC, or support
unknown-size Segment elements through the wrapper.

Upstream: libebml {ebml_ref} ({ebml_rev}); libmatroska {mkv_ref} ({mkv_rev}).
See source-compliance archive; LGPL compliance and relinking review remains required.
'''
info = f'''# ModMKV framework information

Version: {version}
Minimum macOS: {minimum}
Architecture: arm64
C API declarations and verified exports: {len(functions)}
libebml: {ebml_ref} ({ebml_rev})
libmatroska: {mkv_ref} ({mkv_rev})
Build validation: output-ModMKV/ModMKV-validation.txt
'''
for name, value in [('AGENTS.md',agent),('README.md',readme),('FRAMEWORK_INFO.md',info),
                    ('capabilities.json',json.dumps(capabilities,indent=2)+'\n')]:
    (docs/name).write_text(value)
    (out/name).write_text(value)
print(f'PASS: agent documentation generated; {len(functions)} C declarations match exports')
PY_AGENT_DOCS

FRAMEWORK_NAME=ModMKV
sign_framework_and_report "$FRAMEWORK" "$OUT/ModMKV-signing.txt" "$CODESIGN_IDENTITY" "$SIGN"

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
assert os.path.isfile(os.path.join(framework, "Versions", "A", "ModMKV"))
print("PASS: XCFramework macOS arm64 slice and framework metadata verified")
PY_XCFRAMEWORK
    if [[ "$SIGN" == 1 ]]; then
        codesign --verify --deep --strict --verbose=2 \
            "$XCFRAMEWORK_PATH/macos-arm64/ModMKV.framework"
    fi
fi

if [[ "$XCFRAMEWORK" == 1 ]]; then
    sign_xcframework_and_report "$XCFRAMEWORK_PATH" "$OUT/ModMKV-signing.txt" "$CODESIGN_IDENTITY" "$SIGN"
fi

{
    git -C "$LIBEBML_SOURCE" archive --format=tar \
        --prefix=libebml/ "$LIBEBML_REVISION" | gzip -n \
        > "$WORK/libebml-source.tar.gz"
    git -C "$LIBMATROSKA_SOURCE" archive --format=tar \
        --prefix=libmatroska/ "$LIBMATROSKA_REVISION" | gzip -n \
        > "$WORK/libmatroska-source.tar.gz"
    mkdir -p "$WORK/source-compliance"
    cat > "$WORK/source-compliance/RELINKING.txt" <<EOF_RELINK
ModMKV is a dynamically linked framework incorporating LGPL libraries.
The framework exposes the upstream C++ interfaces and bundles their public headers.
Corresponding upstream source archives, the generated wrapper source, and the
complete builder are included here. Review LGPL-2.1 requirements before distribution.
The source archive is not a legal opinion or a substitute for compliance review.
libebml: $LIBEBML_REVISION
libmatroska: $LIBMATROSKA_REVISION
EOF_RELINK
    cp "$WORK/libebml-source.tar.gz" "$WORK/libmatroska-source.tar.gz" \
        "$WRAPPER_SOURCE" "${BASH_SOURCE[0]}" \
        "$FRAMEWORK/Versions/A/Resources/Legal/BUILD_INFO.txt" \
        "$FRAMEWORK/Versions/A/Resources/Legal/LICENSE.libebml.LGPL" \
        "$FRAMEWORK/Versions/A/Resources/Legal/LICENSE.libmatroska.LGPL" \
        "$WORK/source-compliance/"
    (
        cd "$WORK/source-compliance"
        shasum -a 256 ./* > SHA256SUMS.txt
    )
    tar -C "$WORK" -czf "$OUT/ModMKV-source-compliance.tar.gz" source-compliance
    rm -rf "$WORK/source-compliance"
}

cat > "$OUT/ModMKV-validation.txt" <<EOF_VALIDATION
PASS: libebml source revision recorded: $LIBEBML_REVISION
PASS: libmatroska source revision recorded: $LIBMATROSKA_REVISION
PASS: upstream EBML and Matroska headers installed in the framework
PASS: 39 Matroska/ModMKV C API symbols declared and exported
PASS: upstream static archives built with a final default-visibility compiler argument and force-loaded into the dynamic framework
PASS: upstream public C++ constructors/destructor verified in dynamic export table
PASS: arm64 macOS framework binary and install name verified
PASS: standalone C API consumer edited a generated Matroska fixture without changing its size or Cluster data
PASS: standalone Swift consumer imported ModMKV, linked, and ran (including indexed metadata API)
PASS: standalone C++ consumer compiled and linked upstream public classes
PASS: guarded copy-on-write variable-length title and first-track name edits tested
PASS: standalone v14 EBML inspector, unknown-size Segment and JSON export tested
PASS: generated agent documentation and capabilities manifest
$(if [[ "$XCFRAMEWORK" == 1 ]]; then echo 'PASS: one-slice macOS arm64 XCFramework metadata verified'; else echo 'SKIPPED: XCFramework creation disabled'; fi)
EOF_VALIDATION

touch "$VISIBILITY_STAMP"
echo "Framework: $FRAMEWORK"
[[ "$XCFRAMEWORK" != 1 ]] || echo "XCFramework: $XCFRAMEWORK_PATH"
echo "Source/compliance archive: $OUT/ModMKV-source-compliance.tar.gz"
echo "Validation report: $OUT/ModMKV-validation.txt"
echo "Linkage report: $OUT/ModMKV-linkage.txt"
echo "Mach-O build report: $OUT/ModMKV-mach-o-build.txt"


# Embedded agent documentation generation
_DOCS_OUT="${OUT:-$(pwd)/output-ModMKV}"
mkdir -p "$_DOCS_OUT"
python3 - "$_DOCS_OUT" "$(basename "${BASH_SOURCE[0]}")" <<'EMBEDDED_DOCS'
import sys, base64, tempfile
from pathlib import Path

out = Path(sys.argv[1])
builder = sys.argv[2]
generator = base64.b64decode('IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJHZW5lcmF0ZSBjb25zaXN0ZW50IGJ1aWxkIGFuZCBhZ2VudCBlbnRyeXBvaW50IGRvY3Mgd2l0aG91dCBjaGFuZ2luZyBidWlsZCBhcnRpZmFjdHMuIiIiCmltcG9ydCBhcmdwYXJzZSwgcGF0aGxpYiwgc2h1dGlsLCBzeXMKcD1hcmdwYXJzZS5Bcmd1bWVudFBhcnNlcigpCnAuYWRkX2FyZ3VtZW50KCctLWZyYW1ld29yaycscmVxdWlyZWQ9VHJ1ZSkKcC5hZGRfYXJndW1lbnQoJy0tb3V0JyxyZXF1aXJlZD1UcnVlKQpwLmFkZF9hcmd1bWVudCgnLS1idWlsZGVyJyxyZXF1aXJlZD1UcnVlKQpwLmFkZF9hcmd1bWVudCgnLS1pbnN0cnVjdGlvbnMnLGRlZmF1bHQ9JycpCmE9cC5wYXJzZV9hcmdzKCk7IG91dD1wYXRobGliLlBhdGgoYS5vdXQpOyBvdXQubWtkaXIocGFyZW50cz1UcnVlLGV4aXN0X29rPVRydWUpCm5hbWU9YS5mcmFtZXdvcmsKYnVpbGRlcj1wYXRobGliLlBhdGgoYS5idWlsZGVyKS5uYW1lCnNvdXJjZT17J0hhcEluQVZGb3VuZGF0aW9uJzonaHR0cHM6Ly9naXRodWIuY29tL2ZsZXh2aXN1YWwvaGFwLWluLWF2Zm91bmRhdGlvbid9LmdldChuYW1lLCdTZWUgdGhlIHBpbm5lZCBzb3VyY2UgcmVmZXJlbmNlcyBhbmQgc291cmNlLWNvbXBsaWFuY2UgYXJjaGl2ZSBzdXBwbGllZCB3aXRoIHRoaXMgcmVsZWFzZS4nKQppbnM9b3V0L2Yne25hbWV9Lmluc3RydWN0aW9ucy5tZCcKaWYgYS5pbnN0cnVjdGlvbnMgYW5kIHBhdGhsaWIuUGF0aChhLmluc3RydWN0aW9ucykuaXNfZmlsZSgpOgogICAgc2h1dGlsLmNvcHkyKGEuaW5zdHJ1Y3Rpb25zLGlucykKZXh0cmE9Zic0LiBSZWFkIGB7aW5zLm5hbWV9YCBmb3IgZnJhbWV3b3JrLXNwZWNpZmljIGludGVncmF0aW9uIGFuZCBNZXRhbC9jb2RlYyBjb25zdHJhaW50cy5cbicgaWYgaW5zLmlzX2ZpbGUoKSBlbHNlICc0LiBDb25zdWx0IHRoZSBmcmFtZXdvcmsgcHVibGljIGhlYWRlcnMgYW5kIGV4aXN0aW5nIGludGVncmF0aW9uIG5vdGVzOyBubyBzZXBhcmF0ZSBpbnRlZ3JhdGlvbiBndWlkZSB3YXMgc3VwcGxpZWQuXG4nCihvdXQvJ0FHRU5UUy5tZCcpLndyaXRlX3RleHQoZicnJyMge25hbWV9IOKAlCBBZ2VudCBpbnN0cnVjdGlvbnMKCkJlZm9yZSBpbnRlZ3JhdGluZywgbW9kaWZ5aW5nLCBkaXN0cmlidXRpbmcgb3IgcmVidWlsZGluZzoKCjEuIFJlYWQgYEJVSUxESU5HLm1kYCBmb3IgcmVwcm9kdWNpYmxlIHNvdXJjZS1idWlsZCBzdGVwcyBhbmQgcHJlcmVxdWlzaXRlcy4KMi4gUmVhZCBgUkVBRE1FLm1kYCBhbmQgYEZSQU1FV09SS19JTkZPLm1kYCB3aGVuIHByZXNlbnQuCjMuIENoZWNrIGBjYXBhYmlsaXRpZXMuanNvbmAgYW5kIHRoZSB2YWxpZGF0aW9uLCBoZWFkZXIsIHN5bWJvbCBhbmQgbGlua2FnZSByZXBvcnRzOyBkbyBub3QgaW5mZXIgdW5zdXBwb3J0ZWQgQVBJcy4Ke2V4dHJhfTUuIFRyZWF0IHRoZSAqKnNoaXBwZWQgcHVibGljIGhlYWRlcnMgYW5kIG1hdGNoaW5nIGJpbmFyeSoqIGFzIGF1dGhvcml0YXRpdmUgZm9yIHRoaXMgcmVsZWFzZS4KNi4gUHJlc2VydmUgZHluYW1pYyBmcmFtZXdvcmsgZW1iZWRkaW5nLCBgQHJwYXRoYCwgcmVwbGFjZWFiaWxpdHkgYW5kIHRoZSBob3N0IGFwcGxpY2F0aW9uJ3Mgc2lnbmluZyByZXF1aXJlbWVudHMuCjcuIFJlYWQgdGhlIGFwcGxpY2FibGUgbGljZW5zZSBub3RpY2VzIGFuZCBleGFjdCBzb3VyY2UgcmV2aXNpb24gcmVjb3JkcyBiZWZvcmUgZGlzdHJpYnV0aW9uLgoKQnVpbGQgc2NyaXB0OiBge2J1aWxkZXJ9YCAoc2hpcHBlZCBhbG9uZ3NpZGUgdGhpcyByZWxlYXNlIGRvY3VtZW50YXRpb24sIG5vdCBuZWNlc3NhcmlseSBpbnNpZGUgdGhlIG91dHB1dCBkaXJlY3RvcnkpLgpTb3VyY2U6IHtzb3VyY2V9CicnJykKKG91dC8nQlVJTERJTkcubWQnKS53cml0ZV90ZXh0KGYnJycjIEJ1aWxkaW5nIHtuYW1lfSBmcm9tIHNvdXJjZQoKIyMgUHJlcmVxdWlzaXRlcwoKLSBBbiBBcHBsZSBTaWxpY29uIE1hYyB3aXRoIFhjb2RlIGFuZCB0aGUgbWFjT1MgU0RLIHN1cHBvcnRlZCBieSB0aGlzIGJ1aWxkZXIuCi0gWGNvZGUgY29tbWFuZC1saW5lIHRvb2xzIHNlbGVjdGVkIChgeGNvZGUtc2VsZWN0IC1wYCksIEdpdCBhbmQgdGhlIGNvbW1hbmQtbGluZSB1dGlsaXRpZXMgdXNlZCBieSB0aGUgYnVpbGRlci4KLSBJbnRlcm5ldCBhY2Nlc3MgdG8gZmV0Y2ggdGhlIGJ1aWxkZXIncyBwaW5uZWQgZGVwZW5kZW5jaWVzLCB1bmxlc3MgYWxyZWFkeSBjYWNoZWQuCgojIyBCdWlsZAoKUGxhY2UgYHtidWlsZGVyfWAgaW4gdGhlIGludGVuZGVkIE1vZEZyYW1ld29ya3Mgd29ya2luZyBkaXJlY3RvcnkgYW5kIHJ1bjoKCmBgYGJhc2gKY2htb2QgK3ggIntidWlsZGVyfSIKLi8ie2J1aWxkZXJ9IgpgYGAKClRoaXMgZG9jdW1lbnRhdGlvbiBpcyBnZW5lcmF0ZWQgZm9yIHRoZSAqKnNwZWNpZmljIHNjcmlwdCB2ZXJzaW9uKiogbmFtZWQgYWJvdmUuIFJldmlldyB0aGF0IHNjcmlwdCdzIGNvbmZpZ3VyYWJsZSBlbnZpcm9ubWVudCB2YXJpYWJsZXMgYW5kIGNsZWFuL3JlYnVpbGQgb3B0aW9ucyBiZWZvcmUgdXNpbmcgdGhlbTsgbm8gY29tbW9uIGZsYWdzIGFyZSBhc3N1bWVkIGFjcm9zcyBidWlsZGVycy4KCiMjIE91dHB1dHMgYW5kIGNoZWNrcwoKLSBJbnNwZWN0IGBidWlsZC5sb2dgIGZvciBhY3R1YWwgY29tcGlsYXRpb24gc3VjY2VzczsgZXhpc3RlbmNlIG9mIGEgZnJhbWV3b3JrIGZvbGRlciBhbG9uZSBpcyBub3QgcHJvb2Ygb2YgYSBmcmVzaCBidWlsZC4KLSBWZXJpZnkgdGhlIGZyYW1ld29yayBhbmQgWENGcmFtZXdvcmsgZGlyZWN0b3JpZXMgaWYgdGhpcyBidWlsZCBlbmFibGVzIGJvdGguCi0gQ2hlY2sgYCotdmFsaWRhdGlvbi50eHRgLCBgKi1saW5rYWdlLnR4dGAsIGAqLW1hY2gtby1idWlsZC50eHRgLCBgKi1oZWFkZXItaW52ZW50b3J5Lmpzb25gLCBgKi1leHBvcnRlZC1zeW1ib2xzLnR4dGAsIGFuZCBgY2FwYWJpbGl0aWVzLmpzb25gIHdoZW4gZ2VuZXJhdGVkLgotIFZlcmlmeSBzaWduYXR1cmVzIHdpdGggYGNvZGVzaWduIC0tdmVyaWZ5IC0tc3RyaWN0IC0tdmVyYm9zZT0yYCBvbiB0aGUgZnJhbWV3b3JrIGFuZCBYQ0ZyYW1ld29yay4gQSBkZXZlbG9wbWVudCBhZC1ob2Mgc2lnbmF0dXJlIGlzICoqbm90KiogYSBEZXZlbG9wZXIgSUQgc2lnbmF0dXJlIG9yIG5vdGFyaXphdGlvbi4KLSBWZXJpZnkgdGhlIGFyY2hpdGVjdHVyZSB3aXRoIGB4Y3J1biBsaXBvIC1pbmZvYCBhbmQgbWluaW11bSBkZXBsb3ltZW50IHZlcnNpb24gd2l0aCBgeGNydW4gdnRvb2wgLXNob3ctYnVpbGRgIG9uIHRoZSBmcmFtZXdvcmsgZXhlY3V0YWJsZS4KLSBVc2UgZXhhY3QgcmV2aXNpb25zIGluIHRoZSBnZW5lcmF0ZWQgZGVwZW5kZW5jeS9zb3VyY2UgbWFuaWZlc3QgZm9yIHJlcHJvZHVjaWJpbGl0eTsgZG8gbm90IHN1YnN0aXR1dGUgY3VycmVudCBicmFuY2ggSEVBRC4KCiMjIERpc3RyaWJ1dGlvbgoKVGhlIHNvdXJjZSByZXBvc2l0b3J5IHJlZmVyZW5jZSBpczoge3NvdXJjZX0KClRoZSBmcmFtZXdvcmsgaXMgaW50ZW5kZWQgdG8gcmVtYWluIGR5bmFtaWNhbGx5IHJlcGxhY2VhYmxlLiBVc2VycyBvZiBhbiBlbWJlZGRlZCBmcmFtZXdvcmsgbWF5IG5lZWQgdG8gcmUtc2lnbiB0aGVpciBhcHBsaWNhdGlvbiBhZnRlciByZXBsYWNlbWVudCwgc3ViamVjdCB0byBpdHMgcnVudGltZSBhbmQgZGlzdHJpYnV0aW9uIHJlc3RyaWN0aW9ucy4gUHVibGlzaGVkIHNvdXJjZSBhbmQgcmVwbGFjZWFiaWxpdHkgYXJlIGltcG9ydGFudCBidXQgZG8gbm90IGJ5IHRoZW1zZWx2ZXMgY2VydGlmeSBsaWNlbnNlIGNvbXBsaWFuY2UuIFJldmlldyB0aGUgZXhhY3Qgbm90aWNlcyBhbmQgY29ycmVzcG9uZGluZyBzb3VyY2UvYnVpbGQgbWF0ZXJpYWxzLgoKIyMgVHJvdWJsZXNob290aW5nCgpJZiBhIGNsZWFuIGJ1aWxkIGZhaWxzLCBrZWVwIGBidWlsZC5sb2dgIGFuZCB0aGUgcmVwb3J0ZWQgdG9vbGNoYWluIHZlcnNpb24sIGluc3BlY3QgdGhlIGZpcnN0IGZhaWx1cmUgKG5vdCBqdXN0IHRoZSBsYXN0IGVycm9yKSwgYW5kIGNoZWNrIHRoZSBwaW5uZWQgZGVwZW5kZW5jeSBjaGVja291dHMuIERvIG5vdCBzaWxlbnRseSBjaGFuZ2UgcGlubmVkIHJldmlzaW9ucyB0byBtYWtlIGEgZmFpbGluZyBidWlsZCBwYXNzLgonJycpCnByaW50KGYnRG9jdW1lbnRhdGlvbiBnZW5lcmF0ZWQ6IHtvdXR9L0FHRU5UUy5tZCBhbmQgQlVJTERJTkcubWQnICsgKGYnIChpbnRlZ3JhdGlvbiBpbnN0cnVjdGlvbnMgaW5jbHVkZWQpJyBpZiBpbnMuaXNfZmlsZSgpIGVsc2UgJycpKQo=')

sys.argv = ["modframeworks_docs.py",
            "--framework", 'ModMKV',
            "--out", str(out),
            "--builder", builder]
exec(compile(generator, "embedded_docs.py", "exec"))
EMBEDDED_DOCS
