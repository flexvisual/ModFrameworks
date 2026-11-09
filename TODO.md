# Mod Frameworks — Global TODO

> Scope: **ModFrameworks is shared Apple media infrastructure for multiple software products**, including Dopey Meta-Edit. This is a roadmap, not a claim of successful validation. Preserve existing working artifacts until replacements are proven.

## Public HapInAVFoundation fork prerequisite

- [ ] Confirm `https://github.com/flexvisual/hap-in-avfoundation.git` is publicly accessible and contains pinned commit `ddef0b163bd2781f54d55de30014c4173fce2f10`. This is the intentional framework source, not `Vidvox/hap-in-avfoundation`; preserve VIDVOX attribution and upstream licensing.

## Platform-wide architecture and reuse requirements (all Mod frameworks)

**Principle:** Build once, validate thoroughly, and reuse across applications. No framework may depend on Dopey Meta-Edit-specific code, paths, entitlements, resources, or assumptions.

- [ ] Define each framework as an independently versioned, independently distributable product with its own source pin, build script, README, changelog, and test artifacts.
- [ ] Preserve the **complete upstream public API** (headers, exported C symbols, supported features) rather than exposing only what one current application uses. Audit against the exact pinned upstream revision.
- [ ] Ensure each Mod framework can be compiled, linked, loaded, and exercised by a **standalone test consumer** without other Mod frameworks or application-specific dependencies.
- [ ] Verify public headers and module maps in standalone C and Swift consumers; use stable, documented module names and preserve upstream ABI. Do not add application-specific wrappers or option whitelists.
- [ ] Maintain compatibility tests for every consuming application, with sample media and repeatable smoke tests; separate framework acceptance from any one app's integration status.
- [ ] Version frameworks independently and document ABI/API changes, minimum OS/SDK, architectures, and dependency changes. An update to one Mod framework must not automatically require rebuilding another.
- [ ] Establish shared packaging/audit conventions while keeping each framework's build configuration and dependency closure independent.
- [ ] Archive distributable artifacts and compliance/source materials per framework and version, so one application's release does not depend on a developer's original build workspace.
- [ ] Keep `HapInAVFoundation.framework` identifiable as an unmodified third-party upstream framework unless an explicitly approved dependency modernization creates a separately documented derivative; do not use the Mod prefix for it.

**Directory root:** `~/Desktop/ModFrameworks/`. Current `mpv/` contains the v20 baseline script and files; preserve it. Organize future `ffmpeg/`, `mkv/`, `mediainfo/`, and `hap/` work as separate projects, with a root `TODO.md` and `AGENTS.md` for common policy. Do not assume relocated v20 script paths work without checking.

## November 9, 2026 status reconciliation

The original roadmap below contains historical v3/v4/v11.1/v20/v21 references. Preserve these as engineering history, but **do not treat them as the current builder versions or pending first builds**. Historical working script lineages observed in the earlier workspace (the verified November 9 ModMPV builder is separately documented below): `build_modffmpeg.sh` (v5), `build_modmpv.sh` (v6), `build_modmkv.sh` (v14), `build_modmediainfo.sh` (v4), and `build_hap_framework_portable_v8.sh`. Proposed self-contained documentation versions are FFmpeg v6, MPV v7, MKV v15, MediaInfo v5, and Hap v9; they have **not** been demonstrated as successfully executed on macOS.

- [x] **VERIFIED — HapInAVFoundation v8 packaging:** Six pinned repositories fetched, framework target built successfully, arm64 binary and `@rpath` linkage inspected, ad-hoc framework/XCFramework signatures verified, source-compliance archive and reports generated. This is engineering build evidence, **not** a verified playback/encoding or release approval.
- [x] **VERIFIED — Hap agent documentation (manual generation):** `AGENTS.md`, `BUILDING.md`, and `HapInAVFoundation.instructions.md` were generated and inspected. Automatic generation from a self-contained v9 script remains untested.
- [ ] **TODO — self-contained documentation builders:** Confirm all five updated scripts exist locally, run `bash -n`, and test each builder's documentation stage; ensure each script embeds its own generator and does not require `modframeworks_docs.py` at runtime. Preserve existing binaries and outputs until the candidate is verified.
- [ ] **TODO — agent documentation checks:** Ensure every release includes `AGENTS.md`, `BUILDING.md`, and applicable framework-specific instructions. Verify instructions describe the exact built API, dynamic dependencies, minimum macOS, code signing, source revision, and licenses.
- [ ] **TODO — Hap functional validation:** Test Hap, Hap Alpha, Hap Q, Hap Q Alpha, Metal compressed-texture and alpha-plane handling, seeking, delayed frames, encoding completion, and real-app integration. Treat HDR/BC7 as unverified until demonstrated.
- [ ] **TODO — license presence:** Verify the actual embedded framework bundles contain applicable LICENSE/notice files; a separate source-compliance archive does not by itself prove bundle contents. Review replacement/relinking obligations where LGPL applies.
- [ ] **TODO — Dopey Meta-Edit:** Compile and test the updated About view; check that source links and attribution wording match the shipped five frameworks and their actual notice locations.

## November 9, 2026 — ModMPV verified signing and Framework Bench integration

- [x] **VERIFIED — local package-only build:** From `~/Desktop/ModFramework-Scripts/`, `env -u SIGN PACKAGE_ONLY=1 bash './build_modmpv.sh'` succeeded, reusing existing FFmpeg/mpv archives. This was not a clean rebuild and was not explicitly tested with the network disconnected.
- [x] **VERIFIED — Apple Development signatures:** The build selected Apple Development identity `8A012C79BCDF130469B477CE9AA63EB0FAEE0617`; `ModMPV.framework`, nested `libvulkan.dylib`, nested `libMoltenVK.dylib`, and the XCFramework slice passed verification with Team `T3UF4F79ND`.
- [x] **VERIFIED — API/consumer/headless checks:** 54 header-declared public mpv functions exported, standalone Swift import and API call passed, synthetic video decoded to EOF. Do not mistake headless success for GPU, audio, VideoToolbox, or real-media acceptance.
- [x] **REPORTED — Framework Bench integration:** The user replaced the old standalone `ModMPV.framework` with the new Apple Development–signed framework in Xcode (**Embed & Sign**) and confirmed that it worked. Preserve the old known-good artifact until rollback is no longer necessary.
- [x] **DIAGNOSED — earlier ad-hoc failure:** Prior XCFramework and nested Vulkan/MoltenVK dylibs were ad-hoc signed (`TeamIdentifier=not set`) after `SIGN=0`; macOS rejected the nested Vulkan library in the Apple Development–signed host process due to a Team ID mismatch. Ad-hoc signatures are not categorically invalid, but are unsuitable for that mismatched library-validation context.
- [x] **VERIFIED — Vulkan packaging paths:** `Versions/A/Frameworks/` contains the two dylibs and `libvulkan.1.dylib` symlink; `@loader_path/Frameworks` and the manifest's `../../Frameworks/libMoltenVK.dylib` resolve consistently. This does not prove runtime Vulkan driver discovery or GPU rendering.
- [ ] **TODO — true offline verification:** Disconnect networking and repeat `PACKAGE_ONLY=1` using intact local archives and source/compliance inputs; ensure the script makes no fetch attempts. Document any missing-cache failures without modifying the known-good framework.
- [ ] **TODO — GPU and codec validation:** Verify Vulkan/MoltenVK/libplacebo initialization and actual rendering, VideoToolbox hardware decode, real-media/HAP variants, audio, seek, and frame/CPU/GPU performance in Framework Bench.
- [ ] **TODO — release compliance:** Independently audit licenses, LGPL relinking obligations, pinned sources, source archive contents, full runtime dependency closure, and public header/API completeness before distribution approval.

**Offline repackaging command for the renamed candidate (not yet re-tested on macOS):**

```bash
cd ~/Desktop/ModFramework-Scripts
env -u SIGN PACKAGE_ONLY=1 bash './build_modmpv.sh'
```

Use `SIGN_MODE=development` for the known-good Framework Bench signing policy; `SIGN_MODE=adhoc` is available for compatible local test hosts, and do not use `CLEAN_ALL=1` when relying on local caches offline. For an incremental build with existing source checkouts, omit `PACKAGE_ONLY=1`; network access may still be needed. See README.md for signing rationale and verification commands.

## November 9 candidate builder update — explicit ad-hoc mode

- [x] **STATIC VALIDATION — renamed script:** The supplied `build_modmpv.sh` has been updated and passes `bash -n` in the packaging environment. Other four supplied builder scripts are preserved unchanged.
- [ ] **MACOS TEST — development signing:** Run `PACKAGE_ONLY=1 bash ./build_modmpv.sh`; verify outer and nested Team IDs, XCFramework slice and Framework Bench integration. The previous builder passed; this renamed candidate has not yet been run on macOS.
- [ ] **MACOS TEST — ad-hoc signing:** Run `SIGN_MODE=adhoc PACKAGE_ONLY=1 bash ./build_modmpv.sh`; verify the framework and both nested dylibs are valid ad-hoc signatures and all report `TeamIdentifier=not set`. Test loading in a compatible host without restrictive library validation; do not replace the known-good Framework Bench build for this test.
- [ ] **OFFLINE TEST:** Repeat `PACKAGE_ONLY=1` with networking disconnected; ensure all required cached artifacts and compliance sources exist.
- [ ] **INTEGRATION:** Test actual Vulkan ICD discovery and rendering separately from signing; retain the known-good signed Framework Bench artifact.

## Public GitHub release checklist (2026-11-09)

- [x] Add portable signing selection (`SIGN_MODE=auto|development|adhoc|none`) to all five builders; remove hardcoded personal certificate selection.
- [x] Add Git ignore rules for hidden build workspaces, generated frameworks, logs, and signing artifacts.
- [ ] Test a full fresh build on a separate Apple Silicon Mac with no Apple Development certificate (ad-hoc fallback).
- [ ] Test all five builders with exactly one identity, multiple identities, an explicitly selected identity, and no identity.
- [ ] Confirm the pinned HapInAVFoundation fork is publicly accessible and appropriately licensed.
- [ ] Choose and add a repository-level license for the original build scripts (third-party licenses remain separate).
- [ ] Review all source URLs, submodules, local patches, credentials, and license compliance before publication.
- [ ] Publish release notes stating supported host architectures and that binaries are not yet release-certified.

## Framework ownership and responsibilities

| Framework (planned distribution name) | Responsibility | Status |
| --- | --- | --- |
| `ModMPV.framework` | Playback and rendering | ModMPV builder and output exist; legacy libmpv integration tasks below remain historical acceptance work |
| `ModFFmpeg.framework` | Encoding/export and general metadata edits | v5 builder lineage in workspace; prior v3 C/Swift evidence; release audits pending |
| `ModMKV.framework` | Matroska metadata editing | v14 builder lineage in workspace; prior v11.1 C/C++/Swift tests verified; real-media audits pending |
| `ModMediaInfo.framework` | Stream retrieval and inspection | v4 builder lineage in workspace; independent runtime verification and release audit pending |
| `HapInAVFoundation.framework` | Third-party Hap fallback | v8 build and signed XCFramework verified; functional testing and release audit pending |

The application must not package obsolete standalone playback dylibs. Framework-internal dylibs (including the Vulkan Loader and MoltenVK) remain permitted and must resolve within their bundles. Prefer statically linked third-party dependencies inside a single framework binary when upstream build behavior, ABI, licensing, and functionality permit; this is not a blanket ban on necessary internal dylibs. Do not remove dependencies needed by retained frameworks without an explicit audit.

## Status legend

- **VERIFIED** — Supported by an inspectable artifact and reproducible test result.
- **REPORTED** — Agent reported a result; retain evidence and independently reproduce when practical.
- **TODO** — Not yet tested or implemented.
- **BLOCKED FOR RELEASE** — Distribution cannot be approved until resolved; does not automatically block local engineering tests.

## P0 — Current application validation (before renaming or rebuilding)

- [ ] **TODO:** Build Dopey Meta-Edit with the current `libmpv.framework` directly, not the XCFramework.
- [ ] **TODO:** Show an actual decoded video frame in the existing preview renderer; capture logs and media sample details.
- [ ] **TODO:** Exercise pause, seek, playback restart, audio, and representative codecs after first-frame success.
- [ ] **TODO:** Test Hap fallback through unchanged `HapInAVFoundation.framework`.
- [ ] **TODO:** Test metadata edits through Matroska and FFmpeg, stream inspection through MediaInfo, and encoding/export through FFmpeg.
- [ ] **REPORTED:** `libmpv` resolves `@rpath/libvulkan.1.dylib` using `@loader_path/Resources/Vulkan`; Vulkan ICD uses bundled MoltenVK; nested signatures verify. Capture actual commands/output in the test report.
- [ ] **TODO:** Inspect final `.app` dependency closure, embed phases, signatures, and search paths. Reject obsolete standalone third-party playback dylibs outside designated frameworks.
- [ ] **TODO:** Record failures precisely; do not change rendering code or restore old libraries without diagnosis and authorization.

## P1 — ModMPV v21: public headers and complete native API

**Release-blocking requirement:** Header/API completeness must be verified against the **exact pinned upstream mpv revision**, not a guessed list or a different tag.

- [ ] Identify upstream revision, installed public header list, and the authoritative upstream install/build rules.
- [ ] Enumerate every public libmpv header installed by that revision. Expected for the current mpv 0.41 line: `client.h`, `render.h`, `render_gl.h`, `stream_cb.h`; verify the list rather than assuming it is exhaustive.
- [ ] Compare packaged headers byte-for-byte (or record justified generated transformations) with the exact upstream sources; capture SHA-256 checksums and report extra/missing/stale files.
- [ ] Ensure all public headers, umbrella header, and `Modules/module.modulemap` are included and nonempty. Remove any `|| true` that masks missing required headers.
- [ ] Validate header include paths for the **actual chosen framework layout**. Do not promise `<mpv/client.h>` or `import mpv` unless those exact forms compile without undocumented workarounds.
- [ ] Compile and link a minimal C consumer against only the packaged framework and Apple SDK; include each public header independently and in combination.
- [ ] Compile and link a minimal Swift consumer with the intended module name, using only packaged artifacts. Test with `swiftc`/Xcode, not a textual module-map inspection alone.
- [ ] Verify `mpv_*` exports against public declarations, accounting for macros, inline helpers, version guards, and non-exported declarations.
- [ ] Verify option/property/command/event APIs are exposed without a wrapper or artificial whitelist. Document that compiled features determine which options actually work.
- [ ] Confirm framework executable name, bundle metadata, module name, install names, and actual Swift import agree for `ModMPV.framework`.
- [ ] Save machine-readable header inventory, compile-test logs, `nm` results, and a human-readable PASS/FAIL report. Packaging must fail on incomplete public API.
- [ ] Preserve original upstream `mpv_*` ABI; no Swift/Objective-C wrapper and no symbol renaming.

## P2 — Reproducible, controlled builds (all Mod frameworks)

- [ ] Pin upstream source commits/tags and all third-party dependencies; archive sources and checksums.
- [ ] Save patches, exact configuration commands, build scripts, compiler/SDK versions, environment and deployment targets.
- [ ] Use Apple toolchains and target SDKs. Permit Homebrew as an optional **host-tool provider only**, never as an uncontrolled source of linked target dependencies.
- [ ] Reject unexpected `/opt/homebrew`, `/usr/local`, and build-machine-specific include/library paths in target artifacts; allow explicitly documented exceptions only after review.
- [ ] Audit all Mach-O linked libraries and `@rpath` resolution recursively, including framework-internal dylibs and plugins.
- [ ] Preserve required resource files, runtime loaders, notices, and code-signature validity; sign nested binaries before signing the framework.
- [ ] Add optional post-success cleanup with dry-run, clearly separating source archives, rebuild caches, temporary objects, and final release/compliance artifacts. Never silently delete compliance inputs.
- [ ] Provide incremental builds and a reproducible clean-build path; avoid rebuilding working dependencies without cause.
- [ ] Validate macOS arm64 first, then macOS x86_64, iOS/iPadOS device/simulator, tvOS device/simulator as separately built targets. No cross-platform slice reuse.

## P3 — Strict GPL/AGPL-free distribution and LGPL compliance

- [ ] **REPORTED:** mpv Meson config embeds `-Dgpl=false`; ModFFmpeg v3 was configured with GPL/version-3/nonfree disabled and passed its dynamic dependency check. Confirm exact enabled components and source-level licensing evidence; binary-symbol and dynamic-dependency scans alone are not conclusive.
- [ ] Verify FFmpeg `--disable-nonfree` or equivalent demonstrated effective configuration, and audit all enabled external libraries and their licenses.
- [ ] Audit **every** Mod framework, its statically linked code, nested dylibs, and relevant third-party assets for GPL/AGPL-only components and license incompatibilities.
- [ ] Preserve unmodified upstream notices. Do not delete GPL references merely to pass a scan; determine applicable licensing from exact sources and build configuration.
- [ ] **BLOCKED FOR RELEASE:** Recover or recreate exact source archives, patches, build commands, dependency manifests, and applicable LGPL relinking/replacement materials for statically incorporated LGPL components.
- [ ] **BLOCKED FOR RELEASE:** Supply complete required notices and license texts for FFmpeg and HapInAVFoundation, and any other bundled components.
- [ ] Document LGPL obligations, including replacement/relinking where applicable; obtain qualified legal review before external distribution if uncertain.
- [ ] Distinguish local development/testing from release approval. Log warnings during internal tests; fail release packaging/distribution approval on unresolved compliance evidence.
- [ ] Produce a separately archived **runtime artifact** and **source/compliance artifact** from the same pinned build inputs.

## P4 — Remaining framework migrations

- [x] **REPORTED — ModFFmpeg v3:** FFmpeg n9.0.2 + static Snappy 1.3.1 built on macOS arm64; standalone C and Swift API tests passed; XCFramework created; no external third-party dynamic dylibs reported. Retain v3 script, successful log, and binaries as an engineering baseline.
- [ ] **ModFFmpeg v4:** Back up v3, then run `CLEAN_ALL=1 ./build_modffmpeg_single_framework_v4.sh` and verify a fresh-source build and all nine output artifacts.
- [ ] **ModFFmpeg module:** Verify umbrella-header warnings are eliminated without suppressing diagnostics; validate public header/module coverage and fresh Xcode C/Swift consumption without undocumented header search paths.
- [ ] **ModFFmpeg functionality:** Test real HAP encode/decode, representative media formats, metadata edits, networking and Apple hardware acceleration where enabled; compare with the legacy `FFmpeg.framework` functionality.
- [ ] **ModFFmpeg release audit:** Inspect source-compliance archive, actual configuration, export inventory, Mach-O dependencies, signatures, LGPL replacement/relinking requirements, and independently reproducible results.
- [x] **VERIFIED — ModMKV v11.1 engineering baseline:** macOS 15.4+ arm64 framework and XCFramework built; standalone C, C++, and Swift consumers passed; indexed tags/chapters/attachments/track tests and extraction passed; public C++ exports and signing verified in the 2026-11-06 log. The latest log reused compiled upstream libraries (`ninja: no work to do`); preserve the build evidence.
- [ ] **ModMKV clean-source reproducibility:** Run `CLEAN_ALL=1` (after backing up working outputs), confirm fresh upstream compilation and successful tests, and archive complete reports.
- [ ] **ModMKV real-media validation:** Compare existing `Matroska.framework` functionality; exercise real-world MKVs, unknown-sized Segments, multiple metadata layouts, CRC-bearing files, and independent parser verification.
- [ ] **ModMKV v12 transactional editing:** Support metadata growth and insertion, safe temporary-file/atomic replacement, SeekHead/Cues maintenance, CRC-32 updates, and failure recovery; preserve media bytes.
- [ ] **ModMKV release audit:** Confirm upstream API/header completeness, dependency closure, real Xcode integration, licensing notices, LGPL replacement/relinking materials, and independent reproducibility.
- [ ] **ModMediaInfo:** Retain the reported successful `build_modmediainfo_static_zen_v3.sh` engineering baseline (MediaInfoLib v26.10, ZenLib v0.4.41; macOS 15.4+ arm64). ZenLib is intended to be statically incorporated into the dynamic ModMediaInfo binary, with no separate ZenLib dylib shipped. Archive the actual script, output and build log; independently confirm `otool -L`, exported API, header/module coverage, C/C++/Swift consumers, code signing, runtime media inspection, and source/license compliance before marking VERIFIED. Preserve stream retrieval functionality.
- [ ] **HapInAVFoundation:** Preserve the current working binary as the baseline; evaluate a separately built, updated version with pinned Squish/Snappy. Do not rename to a Mod framework or replace the baseline until validation passes.
- [ ] Apply the same header, C/C++/Swift consumer (where supported), dependency, signing, reproducibility, and license audits to every newly built Mod framework. Do not infer static dependency linkage solely from build flags or output size: inspect the final Mach-O and build artifacts.

## P4A — HapInAVFoundation: updated Squish and Snappy (planned, not authorized to rebuild yet)

**Scope:** Third-party `HapInAVFoundation.framework` remains under its upstream name. Modernize its dependencies only after a documented compatibility and licensing review; preserve the current framework as a known-good reference.

- [ ] Clone `https://github.com/Vidvox/hap-in-avfoundation.git`; record the exact commit SHA, submodules, original license files, and any local changes. Do not assume repository HEAD matches the existing framework binary.
- [ ] Inventory the precise Snappy and Squish source trees, revisions, forks, patches, APIs, and build settings currently used by VIDVOX and by the existing packaged binary (where verifiable).
- [ ] Obtain and pin an appropriate stable upstream Snappy release from `https://github.com/google/snappy`; record archive/hash, license, and source provenance.
- [ ] Identify the *specific* Squish implementation compatible with HapInAVFoundation and assess maintained forks/updates. Do not replace it with a similarly named but incompatible library.
- [ ] Compare old/new APIs, pixel formats, compressed block behavior, compiler requirements, macOS deployment compatibility, and ABI; document required source patches before approval.
- [ ] Audit all bundled code, including YCoCg/DXT compression routines and transitive components, for GPL/AGPL exclusions, LGPL obligations, and permissive-license notice requirements. Keep original license texts intact.
- [ ] Prepare a controlled Apple Clang build plan for updated Snappy/Squish without Homebrew target dependencies or new standalone third-party dylibs.
- [ ] Produce a *separate candidate* `HapInAVFoundation.framework`; do not overwrite or silently replace the current known-good framework.
- [ ] Validate Hap, Hap Alpha, Hap Q and any other supported variants using representative files; test encode/decode, visual correctness, alpha, seek/restart, performance, and compatibility with existing media.
- [ ] Verify actual rendering/texture interop (including Metal if used by the application); do not assume the upstream library itself provides a Metal renderer.
- [ ] Audit the candidate's headers, Clang module, exports, runtime dependency closure, signatures, and licensing/source/relinking package.
- [ ] Document the exact dependency versions, patches, build steps, test results, and rollback procedure; authorize replacement only after explicit review.

## Common single-framework packaging plan

- [ ] For each Mod framework, fetch and pin all required upstream repositories; record exact commit IDs and source checksums. Separate source checkout from generated build products.
- [ ] Build the main library as the framework executable. Prefer statically linking eligible supporting libraries into that executable rather than shipping loose dylibs; explicitly configure and verify static linkage for each dependency. Upstream CMake options can be overridden by project logic, so confirm the actual library types and final link commands.
- [ ] Allow framework-internal runtime dylibs only where required (for example, ModMPV's Vulkan/MoltenVK stack), with correct `@loader_path`/`@rpath`, embedding, signing, and recursive dependency closure checks.
- [ ] Deliver a versioned `.framework` and optional one-platform `.xcframework`, with exact public headers, valid module map, Info.plist, install name, licensing notices, and a standalone validation report.
- [ ] Test C, C++ (when relevant), and Swift consumers against the packaged artifact; run a real functional smoke test, not just a symbol check. Verify no unintended external Homebrew/build-workspace libraries are required.
- [ ] Treat successful compilation, an 11.3 MB reported artifact, and a passing script log as engineering evidence, not release approval. Validate actual Xcode app integration and LGPL/static-linking obligations separately.

## Standardized builder output and evidence (all Mod frameworks)

- [ ] Emit at least these nine core deliverables where both framework forms are enabled, plus generated agent docs and any framework-specific reports: `build.log`, `<Name>-exported-symbols.txt`, `<Name>-header-inventory.json`, `<Name>-linkage.txt`, `<Name>-mach-o-build.txt`, `<Name>-source-compliance.tar.gz`, `<Name>-validation.txt`, `<Name>.framework/`, and `<Name>.xcframework/`. Adapt intentionally for upstream HapInAVFoundation or disabled XCFramework output; document any exceptions.
- [ ] Initialize `build.log` before build operations and retain it after failure. Mark validation INCOMPLETE/FAIL until checks genuinely pass; never fabricate a successful report.
- [ ] Include SHA-256 public-header inventory, exported symbols, Mach-O minimum OS/SDK, actual `otool -L` dependencies, pinned sources and patches, applicable notices, and C/C++/Swift smoke-test results where supported.
- [ ] Maintain both a clean-from-source path and a faster package-only/incremental path, preserving previous successful artifacts until the candidate is validated.

## Shared-framework acceptance criteria

- [ ] Validate standalone framework consumption in addition to Dopey Meta-Edit integration.
- [ ] Test each published version against a documented compatibility matrix of consuming applications, supported OS versions, and architectures.
- [ ] Publish per-framework API/header inventories, version information, change notes, and release/compliance artifacts.

## Release acceptance criteria

A Mod framework is release-ready only when all of the following are documented with reproducible evidence: (1) actual runtime functionality, (2) exact upstream public-header coverage, (3) C and Swift consumer compilation, (4) complete runtime dependency closure, (5) correct module/bundle/install names, (6) valid signatures, (7) pinned reproducible build inputs, and (8) approved license and compliance artifacts. A successful build alone does not satisfy release acceptance.

## Immediate next action

**Updated November 9:** ModMPV package-only Apple Development signing and Framework Bench integration now work. Do not repeat the previous first-integration task or replace the working framework unnecessarily. Next prioritize actual Vulkan/MoltenVK/libplacebo rendering, VideoToolbox activation, HAP/real-media playback and a true offline repackaging test.

Preserve the successful ModMKV v11.1 engineering baseline and log; plan real-media validation and transactional editing without overwriting it. Preserve the successful ModFFmpeg v3 artifacts and logs; run the v4 `CLEAN_ALL=1` candidate and inspect its nine reports, module warnings, and fresh Xcode consumer tests. In parallel, finish local video playback testing with the existing `libmpv.framework`, then run the upstream-matched header audit for ModMPV v21 **without altering its working baseline**. Preserve the successful ModMediaInfo v3 engineering artifacts and audit them independently. Hap v8 is now built and packaged; preserve the working baseline and complete functional and compliance validation before release or application replacement.

## Roadmap maintenance note

The P0–P4 sections above preserve earlier milestones and version references for traceability. A checked item represents only the evidence explicitly described; do not infer current functional or release acceptance from a successful build. The self-contained documentation update is pending local execution and validation.

## November 9, 2026 — builder disk-space housekeeping

- [x] Added `--status`, `--clean`, `--clean-all`, `--dry-run`, `--yes`, and `--help` to all five builders; commands execute before build side effects.
- [x] Normal `--clean` preserves generated frameworks, XCFrameworks, reports and compliance archives while deleting each builder's hidden source/build workspace; explicit warning that `PACKAGE_ONLY=1` will stop working until archives are rebuilt.
- [x] Restricted deletion to the builder's fixed sibling directories, rejected symlink targets, required typed confirmation or explicit `--yes`.
- [x] All five modified scripts passed `bash -n` syntax validation in the packaging environment.
- [ ] Verify `--status` sizes, interactive confirmation, `--clean`, and `--clean-all` on macOS with disposable test directories before using cleanup on production workspaces.
- [ ] Decide whether a separate cache-preserving cleanup mode is needed; the current `--clean` intentionally reclaims the entire hidden workspace.
