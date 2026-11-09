# Mod Frameworks — Apple Framework Builders

This workspace aims to distribute reusable, independently versioned Apple media frameworks. Each framework should be consumable by a standalone Xcode target, with its third-party dependencies statically linked where technically and legally appropriate. Some frameworks (notably ModMPV) legitimately require signed, bundled runtime dylibs. Build success is not release approval. See [TODO.md](./TODO.md) for acceptance requirements.

## Contents

- [Quick Start](#public-github-quick-start-macos-apple-silicon)
- [HapInAVFoundation](#hapinavfoundation-source-repository-flexvisual-fork)
- [Build Workflow](#current-build-and-documentation-workflow)
- [ModMPV](#modmpv-apple-framework-builder--verified-november-9-2026)
- [ModFFmpeg](#modffmpegframework--full-featured-gpl-disabled-ffmpeg--static-snappy)
- [ModMKV](#modmkvframework--libebml--libmatroska-metadata-api)
- [ModMediaInfo](#modmediainfoframework--mediainfolib--static-zenlib)
- [Shared Verification Rules](#shared-packaging-and-verification-rules)
- [Build History](#historical-version-notes)
- [Disk Space Management](#disk-space-management-all-five-builders-november-9-2026)

## Public GitHub quick start (macOS Apple Silicon)

These scripts are provided as **source builders**, not precompiled redistribution-ready binaries. They target macOS 15.4+ arm64 where supported; inspect each builder's prerequisites and validation notes. Fresh builds require Xcode/Command Line Tools, host build tools, internet access, and significant free disk space. A successful build on a second Mac is **not yet independently verified**.

```bash
git clone https://github.com/flexvisual/ModFrameworks.git
cd ModFrameworks
chmod +x *.sh
./build_modmpv.sh --status
./build_modmpv.sh
```

No personal signing identity or Team ID is required to use the scripts. **Default `SIGN_MODE=auto`** selects the sole valid Apple Development certificate when exactly one is available; otherwise it uses ad-hoc signing. If multiple certificates exist, it will not guess which team to use. Set `CODESIGN_IDENTITY` explicitly or `SIGN_MODE=development` to require a specific signing configuration.

| Invocation | Signing result |
| --- | --- |
| `./build_modmpv.sh` | Auto: one Apple Development identity or ad-hoc fallback |
| `SIGN_MODE=development ./build_modmpv.sh` | Require one unambiguous Apple Development identity or explicit `CODESIGN_IDENTITY` |
| `CODESIGN_IDENTITY="<identity SHA-1>" ./build_modmpv.sh` | Sign with selected certificate (validate its suitability for your host) |
| `SIGN_MODE=adhoc ./build_modmpv.sh` | Ad-hoc signing; no Team ID |
| `SIGN_MODE=none ./build_modmpv.sh` | Skip signing |
| `PACKAGE_ONLY=1 ./build_modmpv.sh` | Reuse local compiled dependencies; normal signing selection still applies |

The same signing mode interface is now included in the ModFFmpeg, ModMKV, ModMediaInfo, and HapInAVFoundation builders. **Their updated build/signing flows have not been executed on macOS in this revision.** The ModMPV `PACKAGE_ONLY=1` baseline succeeded on November 9 before this portability change.

Ad-hoc signatures are valid for frameworks, but a hardened host app with library validation enabled can reject ad-hoc nested dylibs if its own signing Team ID differs. ModMPV signs its Vulkan Loader and MoltenVK dylibs before sealing the framework. Signing a framework does not automatically make its dependent app compatible with it.

**Disk space:** every builder supports `--status`, `--clean --dry-run`, `--clean`, and `--clean-all`. `--clean` deletes the builder's hidden workspace, preserving its generated output, but removes the cached sources and libraries needed for `PACKAGE_ONLY=1`. Inspect the dry run first. Never commit build workspaces or output artifacts to the public repository.

**Licensing:** The repository's own script license must be chosen by its owner before public publication. This is distinct from the licenses of downloaded third-party source code and linked libraries. Generated frameworks are **not automatically approved for redistribution**; inspect the per-framework license manifests, source/compliance packages, LGPL relinking obligations, and release audit. HapInAVFoundation currently fetches from a `flexvisual/hap-in-avfoundation` fork pinned to a commit; verify that repository is publicly accessible and its redistribution permissions before announcing a reproducible public build.

---

## HapInAVFoundation source repository (Flexvisual fork)

**This builder uses the Flexvisual repository, not the original VIDVOX checkout.** The pinned source is [`flexvisual/hap-in-avfoundation`](https://github.com/flexvisual/hap-in-avfoundation), commit `ddef0b163bd2781f54d55de30014c4173fce2f10`. The original upstream project is [`Vidvox/hap-in-avfoundation`](https://github.com/Vidvox/hap-in-avfoundation); credit and applicable upstream licenses must be preserved.

The script also fetches the separate [`Vidvox/hap`](https://github.com/Vidvox/hap) codec source. This is **not** the same repository as the HapInAVFoundation framework fork. Developers must be able to access the pinned Flexvisual commit for a fresh build; if it is private, deleted, or the commit is unavailable, the build cannot be reproduced publicly. Do not silently substitute upstream HEAD or another fork.

## Framework status

**Status reviewed 2026-11-09.** Portable auto-signing added after the verified baseline; fresh-build validation is pending. The versions below distinguish confirmed build evidence from unverified self-contained documentation updates. Historical sections below describe earlier baselines and are retained for technical reference; use the current script and its generated reports for exact settings.

| Framework | Current status |
| --- | --- |
| ModMPV | **2026-11-09 verified:** `build_modmpv.sh` ran successfully with `PACKAGE_ONLY=1` and Apple Development signing. Nested Vulkan/MoltenVK and XCFramework slice signatures verified for Team `T3UF4F79ND`; standalone Swift consumer and synthetic headless playback passed. User confirmed replacement `ModMPV.framework` works in Framework Bench. GPU rendering, VideoToolbox activation, real-media/HAP tests, and release audit remain open. |
| ModFFmpeg | Current working builder `build_modffmpeg.sh` (v5 lineage); v6 self-contained documentation candidate not yet build-tested. Prior engineering evidence retained; release audit open. |
| ModMKV | Working builder `build_modmkv.sh` (v14 lineage); v15 self-contained documentation candidate not yet build-tested. Earlier v11.1 C/C++/Swift evidence retained; real-media and release audits pending. |
| ModMediaInfo | Working builder `build_modmediainfo.sh` (v4 lineage); v5 self-contained documentation candidate not yet build-tested. Runtime and compliance verification pending. |
| HapInAVFoundation | **v8 verified macOS arm64 build**, framework and XCFramework ad-hoc signatures valid; pinned six-source checkout and source archive produced. v9 self-contained documentation candidate not yet build-tested. Runtime/codec and distribution acceptance remain open. |

## Current build and documentation workflow

The planned root workspace is `~/Desktop/ModFrameworks/`; the **verified November 9 ModMPV build** ran from `~/Desktop/ModFramework-Scripts/` with `build_modmpv.sh`. Do not assume these workspaces or script names are interchangeable. Keep the working `build_modmpv.sh`, `build_modffmpeg.sh`, `build_modmkv.sh`, `build_modmediainfo.sh`, and `build_hap_framework_portable_v8.sh` until replacement builders are individually verified. Versioned self-contained agent-documentation candidates have been prepared (Hap v9, FFmpeg v6, MPV v7, MKV v15, MediaInfo v5), but their execution on macOS is **not yet verified**. Do not assume the ZIP was downloaded successfully or those files exist locally.

Each release output should include `AGENTS.md` and `BUILDING.md` generated **by its builder**. HapInAVFoundation should also include its complete `HapInAVFoundation.instructions.md`. These supplement—not replace—framework binaries, public-header inventories, build logs, Mach-O/linkage reports, validation, pinned source revisions, notices, and source-compliance materials. The final top-level file count is framework-specific; the former nine-item convention is a minimum audit baseline, not an exact count.

HapInAVFoundation v8 evidence: `xcodebuild` reported success for the `HapInAVFoundation` target; the binary is arm64, uses the `@rpath/HapInAVFoundation.framework/...` install name, and both framework and XCFramework passed ad-hoc `codesign` verification. This does not establish successful Hap codec playback/encoding or final license review. No framework ZIPs should be generated by default.

## ModMPV Apple Framework Builder — verified November 9, 2026

**November 9 verified signing baseline:** the earlier `build_modmpv_auto_sign(2).sh`; **updated candidate in this package:** `build_modmpv.sh` in `~/Desktop/ModFramework-Scripts/`. The earlier `build_modmpv.sh` instructions are historical and must not be assumed to describe the verified script. The output is a macOS 15.4+ arm64 `ModMPV.framework` and one-slice `ModMPV.xcframework`, with FFmpeg and mpv statically incorporated where configured, and two **necessary internal runtime dylibs** for Vulkan/MoltenVK.

### Exact working command (local repackaging / offline use)

From Terminal, use the filename that actually exists on disk. The November 9 successful run used the earlier `(2)` variant; the renamed candidate is:

```bash
cd ~/Desktop/ModFramework-Scripts
ls -1 build_modmpv*.sh
# Use the verified filename below if it exists:
env -u SIGN PACKAGE_ONLY=1 bash './build_modmpv.sh'
```

`PACKAGE_ONLY=1` reuses already-installed FFmpeg/mpv static archives and locally available dependencies instead of compiling them again. **It is the verified no-rebuild path**, and should work without internet **provided all required local archives, libraries, sources needed for compliance archiving, and build tools remain present**. It is not a fresh offline source build. The November 9 log shows this mode completed successfully, but does not independently demonstrate a network-disconnected test.

For a normal incremental build with existing source checkouts, omit `PACKAGE_ONLY=1`:

```bash
env -u SIGN bash './build_modmpv.sh'
```

The incremental mode may fetch/update upstream sources and therefore may require internet. A fresh build generally requires internet unless all source dependencies are already cached and the script's fetch logic permits offline reuse. **Do not use `CLEAN_ALL=1` offline**: it removes cached workspace/output needed for reuse. The script is macOS/Apple Silicon specific; consult its preflight for host tools.

### Signing modes: development, ad-hoc, and unsigned staging

The updated `build_modmpv.sh` defaults to **`SIGN_MODE=auto`**, using a valid Apple Development identity and signing the two nested dylibs before the framework. `SIGN_MODE=adhoc` signs **all three binaries** using `codesign -s -` and verifies their signatures; it does not produce a Team ID. `SIGN_MODE=none` skips signing. Legacy `SIGN=0` is accepted as an alias for `none`; `CODESIGN_IDENTITY=-` also selects `adhoc` unless an explicit other mode is requested. Do not set `SIGNING_TEAM` with `adhoc` or `none`.

```bash
# Normal Framework Bench integration: Apple Development signing
PACKAGE_ONLY=1 bash ./build_modmpv.sh

# Ad-hoc local framework for a compatible development/test host
SIGN_MODE=adhoc PACKAGE_ONLY=1 bash ./build_modmpv.sh

# No signing (staging only)
SIGN_MODE=none PACKAGE_ONLY=1 bash ./build_modmpv.sh
```

**Ad-hoc is legitimate macOS code signing.** It failed in the earlier Framework Bench case because the Apple Development-signed host's library-validation policy rejected a nested ad-hoc Vulkan dylib with no matching Team ID. An ad-hoc-signed framework can be used by a host whose signing and library-validation configuration permits it; it is not a universally drop-in replacement for an Apple Development-signed framework in a hardened app. Xcode **Embed & Sign** may sign the outer framework without re-signing every nested dylib.

**Validation status:** The November 9 Apple Development `PACKAGE_ONLY=1` run and Xcode integration were successful with the prior builder. The new explicit ad-hoc mode and renamed script pass static Bash syntax validation in this package but **have not yet been executed on macOS**. Keep the known-good framework until the candidate is tested.

### Packaging and runtime layout

```text
output-ModMPV/
├── ModMPV.framework/
│   └── Versions/A/
│       ├── ModMPV
│       ├── Frameworks/
│       │   ├── libvulkan.dylib
│       │   ├── libvulkan.1.dylib -> libvulkan.dylib
│       │   └── libMoltenVK.dylib
│       └── Resources/
│           ├── Vulkan/MoltenVK_icd.json
│           └── Legal/
├── ModMPV.xcframework/
├── ModMPV-signing.txt
├── AGENTS.md
├── BUILDING.md
└── ModMPV-source-compliance.tar.gz
```

The ModMPV binary references `@rpath/libvulkan.1.dylib` and has `@loader_path/Frameworks` as its runtime search path. The ICD manifest points to `../../Frameworks/libMoltenVK.dylib` relative to `Resources/Vulkan/`. These paths were inspected and are consistent, but **actual Vulkan GPU initialization remains untested**. When using Vulkan/libplacebo, ensure the loader discovers the bundled `MoltenVK_icd.json` (for example, configure `VK_DRIVER_FILES` before Vulkan initialization where appropriate).

### Xcode integration and validation

The November 9 integration test replaced the old working **`ModMPV.framework`** with the newly signed standalone `output-ModMPV/ModMPV.framework` in Framework Bench, with **Embed & Sign** enabled; the user confirmed it worked. This verifies app integration at the reported level, **not** Vulkan rendering, hardware decode, HDR, or HAP codec correctness. Preserve the working version as a rollback artifact.

The successful build log confirmed: 54 public header-declared `mpv_*` functions exported, standalone Swift import and `mpv_client_api_version()` call, synthetic headless playback to EOF, nested signatures and framework signature verification, signed XCFramework slice verification, and generation of source/compliance evidence. The `install_name_tool` warning about invalidating an existing MoltenVK signature was expected because the script re-signed and verified that library afterward. Source/license compliance is **not** yet certified for distribution.

For a quick post-build check:

```bash
FW="$HOME/Desktop/ModFramework-Scripts/output-ModMPV/ModMPV.framework"
codesign --verify --deep --strict --verbose=2 "$FW"
for ITEM in "$FW" "$FW/Versions/A/Frameworks/libvulkan.dylib" "$FW/Versions/A/Frameworks/libMoltenVK.dylib"; do
  echo "=== $ITEM"
  codesign -dv --verbose=4 "$ITEM" 2>&1 | grep -E 'Identifier=|Authority=|TeamIdentifier=|Signature='
done
```

**Remaining acceptance work:** verify real Vulkan/MoltenVK/libplacebo GPU rendering, VideoToolbox hardware decode, HAP/HAP Alpha/HAP Q media, audio, seek/restart, header/API completeness against the exact upstream revision, recursive dependency closure in the final app, and distribution license/relinking obligations. See TODO.md.

## ModFFmpeg.framework — full-featured, GPL-disabled FFmpeg + static Snappy

**Current engineering baseline:** `build_modffmpeg_single_framework_v3.sh` successfully built FFmpeg `n9.0.2` (commit `946fcce07b6dcd0331c8cc609192aeff5e1924f8`) and Snappy `1.3.1` (commit `9c28114a38866f6deeaa826db918293bc28ae410`) on macOS arm64. The supplied `ModFFmpeg-build.log` confirms a C API smoke test, Swift `import ModFFmpeg` and `avcodec_version()` call, absence of external third-party dynamic dylib dependencies, and XCFramework creation. That run produced numerous nonfatal umbrella-header warnings. It does **not** establish full release approval or clean Xcode integration without explicit header search settings.

**Next candidate:** `build_modffmpeg_single_framework_v4.sh`. It retains FFmpeg's broad built-in codecs, formats, filters, network protocols, HAP encoder/decoder, static Snappy, VideoToolbox, AudioToolbox, AVFoundation and SecureTransport. Configuration explicitly disables GPL, version-3, nonfree and autodetected external dependencies. The resulting framework is intended to remain LGPL-compatible, **not** license-obligation-free; audit actual linked components and LGPL replacement/relinking obligations before distribution. The target is macOS 15.4+ Apple Silicon (`arm64`) only. It is a standalone build, independent of ModMPV.

Run the v4 candidate from the ModFrameworks directory (or invoke it by absolute path from elsewhere):

```bash
chmod +x build_modffmpeg_single_framework_v4.sh
CLEAN_ALL=1 ./build_modffmpeg_single_framework_v4.sh  # delete ModFFmpeg workspace/output; fetch and build fresh
```

`CLEAN_ALL=1` deletes only the resolved ModFFmpeg `WORK` and `OUT` paths (defaults: `.modffmpeg-macos15/` and `output-ModFFmpeg/` beside the script). **Back up the successful v3 artifacts and logs first.** `CLEAN_BUILD=1` rebuilds FFmpeg and Snappy from existing source checkouts; `PACKAGE_ONLY=1` repackages previously staged archives and headers. Do not combine `PACKAGE_ONLY` with `CLEAN_ALL` or `CLEAN_BUILD`. Defaults include `SIGN=1` (ad-hoc identity `-`) and `XCFRAMEWORK=1`. A fresh build requires full Xcode/Command Line Tools, Git, CMake, network access and available disk space. `CHECK_ONLY=1` runs preflight without building.

The historical v4 script targeted **these nine core deliverables** (newer builders may also generate agent documentation, revision manifests and signing reports):

```text
output-ModFFmpeg/
├── build.log
├── ModFFmpeg-exported-symbols.txt
├── ModFFmpeg-header-inventory.json
├── ModFFmpeg-linkage.txt
├── ModFFmpeg-mach-o-build.txt
├── ModFFmpeg-source-compliance.tar.gz
├── ModFFmpeg-validation.txt
├── ModFFmpeg.framework/
└── ModFFmpeg.xcframework/
```

The `build.log` is initialized before compilation and must survive failures; the validation file must never claim PASS for incomplete tests. Reports capture symbols, SHA-256 header inventory, `otool` dependencies, Mach-O deployment/SDK metadata, pinned source/compliance inputs, and consumer-test results. A passing log and reports are engineering evidence, not automatic release approval.

**Xcode integration caveat:** FFmpeg's public headers include paths such as `<libavutil/samplefmt.h>`. The v3 and v4 standalone tests explicitly add the packaged `ModFFmpeg.framework/Headers` directory as an include root. Before claiming drop-in `import ModFFmpeg` support, test a fresh Xcode application **without** build-workspace paths or undocumented header-search settings. Verify Clang module/header coverage, clean diagnostics, HAP encoding/decoding on real samples, signing, dependencies, and compliance archive contents. Do not assume the module-map change alone resolves all header warnings. In a macOS app, embed and sign the final framework/XCFramework as appropriate.

## ModMKV.framework — libebml + libmatroska metadata API

**Verified engineering baseline:** `build_modmkv_single_framework_v11_1.sh` (macOS 15.4+ Apple Silicon `arm64`). The November 6, 2026 build log shows successful standalone C, C++, and Swift consumers, indexed metadata tests including attachment extraction, public C++ constructor/destructor exports, signing verification, and `ModMKV.xcframework` generation. The log reports `ninja: no work to do` for upstream libraries, so that particular run reused previously built upstream objects; it does not demonstrate a fresh-from-source rebuild. Keep the successful builder, log, reports, and binaries as the working baseline.

**Pinned upstream versions:** libebml `release-1.4.5` (commit `1878e784321673561039a6a37076b2736f4dc98f`) and libmatroska `release-1.7.1` (commit `f5315fddda2d434e47035c038549a808d8b8eac7`). The builder statically incorporates both libraries into the dynamic framework and packages 60 inventoried public headers under `Headers/ebml/` and `Headers/matroska/`. A standalone C++ consumer links upstream classes. Swift imports the separate C ABI façade through `ModMKV.h`; upstream C++ classes are not directly Swift-importable through that module.

### Build and outputs

```bash
chmod +x build_modmkv_single_framework_v11_1.sh
./build_modmkv_single_framework_v11_1.sh
CLEAN_BUILD=1 ./build_modmkv_single_framework_v11_1.sh # rebuild libraries from existing checkouts
# CLEAN_ALL=1 also removes the ModMKV workspace and output, including source checkouts
```

The script supports `CHECK_ONLY=1`, `SIGN=0`, `XCFRAMEWORK=0`, `MIN_MACOS`, `VERSION`, `BUNDLE_ID`, `WORK`, `OUT`, and `JOBS`. The default output directory is `output-ModMKV/` beside the script. With XCFramework enabled, expected top-level artifacts are `build.log`, `ModMKV-exported-symbols.txt`, `ModMKV-header-inventory.json`, `ModMKV-linkage.txt`, `ModMKV-mach-o-build.txt`, `ModMKV-source-compliance.tar.gz`, `ModMKV-validation.txt`, `ModMKV.framework/`, and `ModMKV.xcframework/`. Use the generated reports for verification; do not infer release approval from file presence alone.

### Metadata API (33 C ABI functions)

The original 12 functions read or edit segment strings and track flags/names, enumerate tracks, count top-level elements, and clear all chapters, attachments, or tags. The additional 21 functions provide indexed access to:

- **Tags:** count tags and simple tags; read/edit existing simple-tag names and values; read tag target UIDs; remove a selected tag.
- **Chapters:** count editions and chapters; read chapter UID, start/end timestamps, display title/language; edit an existing display title; remove a chapter.
- **Attachments:** count attachments; read filename, MIME type, description, UID, and size; extract to a new file without overwriting an existing destination; remove a selected attachment.
- **Tracks:** read existing UID, type, and enabled/default/forced values; edit existing name, legacy language, or IETF language fields.

Indexed access is zero-based and follows file order. String getters require a caller-owned buffer large enough for the terminating NUL. Counts typically return `-1` for failure; most other operations return `1` for success and `0` for missing/unsupported/error. See the generated `Headers/ModMKV.h` for exact signatures and field names. The framework's test fixture checks that fixed-size metadata changes preserve Cluster bytes and file size.

**Important limitations:** The current wrapper uses a bounded EBML walker and intentionally rejects unknown-sized elements, including unknown-sized Segments. String replacements require **exactly the same UTF-8 byte length** as the existing payload; absent elements cannot be inserted. Removal replaces the element with same-length EBML Void. It does not currently recalculate CRC-32, rebuild SeekHead/Cues, grow metadata, or provide crash-safe transactional file replacement. Its in-place rollback attempt is not equivalent to atomic transactions. Use disposable media for editing tests, and verify results with real MKV files and independent parsers before relying on it in production.

**Release still pending:** Compare behavior with the existing `Matroska.framework`; test representative real-world MKV files (including unknown-sized segments and CRC-bearing files); audit all public APIs and dynamic dependencies; validate Xcode app integration and licensing/LGPL relinking obligations. Successful synthetic tests and ad-hoc signatures establish an engineering baseline, not distribution approval.

## ModMediaInfo.framework — MediaInfoLib + static ZenLib

The reported working engineering baseline is `build_modmediainfo_static_zen_v3.sh`, targeting macOS 15.4+ arm64, with MediaInfoLib `v26.10` and ZenLib `v0.4.41`. The intended packaging is **one dynamic ModMediaInfo framework executable** containing ZenLib statically, not a second `libzen` dylib. A one-slice `ModMediaInfo.xcframework` is generated by default. The user reported an approximately 11.3 MB artifact; size alone is not proof of correct linkage.

Keep the v3 script and its successful build log together as an engineering baseline. On an Apple Silicon Mac, from the script's directory:

```bash
chmod +x build_modmediainfo_static_zen_v3.sh
CLEAN_BUILD=1 ./build_modmediainfo_static_zen_v3.sh
```

Inspect the generated framework and XCFramework before adopting them in Xcode:

```bash
otool -L output-ModMediaInfo/ModMediaInfo.framework/ModMediaInfo
lipo -info output-ModMediaInfo/ModMediaInfo.framework/ModMediaInfo
plutil -lint output-ModMediaInfo/ModMediaInfo.framework/Resources/Info.plist
```

`otool -L` must not show `libzen*.dylib` or uncontrolled Homebrew/workspace paths. Confirm C, C++, and Swift standalone consumers, actual media inspection, complete public headers/module coverage, code signing, and licensing/source archives before release. **Static ZenLib incorporation must be reviewed for applicable license obligations**, including any source or relinking requirements. Do not delete or replace a working framework until its candidate passes these checks.

## Shared packaging and verification rules

Each builder should produce at least the core reporting structure illustrated for ModFFmpeg, plus builder-generated agent documentation (using its own framework name), pin and archive upstream sources, build its own dependencies reproducibly, preserve the upstream public API, and produce both a runtime artifact and source/compliance materials. Prefer a single framework binary with statically incorporated support libraries when feasible, but retain necessary signed framework-internal runtime dylibs. Test the actual final Mach-O dependency closure, not merely CMake flags. Verify the resulting framework in a standalone C/C++/Swift consumer as applicable, then test in each application. See [TODO.md](./TODO.md) for the full acceptance checklist.

## Historical version notes

The detailed v3/v4/v11.1 references above document earlier engineering milestones, not instructions to downgrade current working builders. Verify actual options and paths against the script being executed. For current acceptance tasks, see `TODO.md`.

## Disk-space management (all five builders, November 9, 2026)

Each builder keeps its source checkouts, intermediate objects, and compiled dependencies in a **hidden directory beside its script**. These workspaces can grow large and are hidden in Finder by default. The builders now accept the same housekeeping flags, processed **before any build, log initialization, dependency fetch, or network access**:

```bash
./build_modmpv.sh --status
./build_modmpv.sh --clean --dry-run
./build_modmpv.sh --clean
./build_modmpv.sh --clean --yes
./build_modmpv.sh --clean-all --dry-run
./build_modmpv.sh --help
```

Replace `build_modmpv.sh` with any of `build_modffmpeg.sh`, `build_modmkv.sh`, `build_modmediainfo.sh`, or `build_hapinavfoundation.sh` for the same commands.

- `--status` prints hidden-workspace and output sizes plus filesystem free space without changing files.
- `--clean` **deletes the entire hidden workspace** (including cloned sources and compiled static archives) after requiring the user to type `DELETE`. It **preserves the generated output** (`.framework`, `.xcframework`, reports, documentation and compliance archives).
- `--clean --dry-run` previews the targets without deleting anything; `--yes` skips confirmation for intentional noninteractive use.
- `--clean-all` deletes **both** the hidden workspace and that builder's generated output, after confirmation. Use this only if those final artifacts are backed up or no longer needed.
- The cleanup commands reject symlinked workspace/output paths and operate only on the fixed per-builder directories immediately beside the script. They do not honor custom `WORK`/`OUT` environment overrides for deletion.
- After `--clean`, `PACKAGE_ONLY=1` cannot reuse the deleted archives. The next build may require network access, substantial disk space and recompilation. To preserve fast offline repackaging, use `--status` and keep the hidden workspace.

| Builder | Hidden workspace | Generated output |
| --- | --- | --- |
| ModMPV | `.modmpv-macos15/` | `output-ModMPV/` |
| ModFFmpeg | `.modffmpeg-macos15/` | `output-ModFFmpeg/` |
| ModMKV | `.modmkv-macos15/` | `output-ModMKV/` |
| ModMediaInfo | `.modmediainfo-macos15/` | `output-ModMediaInfo/` |
| HapInAVFoundation | `.build-HapInAVFoundation-framework/` | `output-HapInAVFoundation/` |

Normal invocation with **no flags** preserves each builder's existing build behavior. The older `CLEAN_ALL=1` environment mode, where implemented, remains separate from these explicit housekeeping commands.
