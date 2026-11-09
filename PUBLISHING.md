# Publishing this builder repository

This repository contains build scripts and documentation, **not** a verified public binary release. Before making it public:

1. Choose a license for the original scripts and add a `LICENSE` file. Do not assume third-party library licenses cover the scripts.
2. Check `git status --short` and `git ls-files` to ensure no private keys, certificates, developer-specific configuration, output frameworks, hidden build directories, or proprietary media are tracked. `.gitignore` does not untrack already committed files.
3. Verify every source URL and pinned commit is publicly accessible, particularly the HapInAVFoundation fork.
4. Perform a clean build on a second Apple Silicon Mac; verify signing in both auto and ad-hoc modes, runtime dependency closure, and a standalone Swift consumer.
5. Inspect generated license manifests and source-compliance archives before distributing any binary artifacts.

## Basic local checks

```bash
chmod +x *.sh
for script in *.sh; do bash -n "$script" || exit 1; done
./build_modmpv.sh --status
./build_modmpv.sh --clean --dry-run
```

For fresh builds, invoke `./build_modmpv.sh`. For local repackaging after successful compilation, invoke `PACKAGE_ONLY=1 ./build_modmpv.sh`.

## Signing

`SIGN_MODE=auto` uses a single available Apple Development identity or ad-hoc fallback. `SIGN_MODE=development` fails if it cannot select one unambiguously. `SIGN_MODE=adhoc` requires no certificate. `SIGN_MODE=none` skips signing. Set `CODESIGN_IDENTITY` to choose a specific identity. Host applications must still meet macOS library validation requirements.

## HapInAVFoundation fork dependency

The `build_hapinavfoundation.sh` script intentionally fetches `https://github.com/flexvisual/hap-in-avfoundation.git` at commit `ddef0b163bd2781f54d55de30014c4173fce2f10`. This is the Flexvisual framework fork, distinct from the original `https://github.com/Vidvox/hap-in-avfoundation` and from the separate codec repository `https://github.com/Vidvox/hap`. Before publishing, confirm the Flexvisual repository and pinned commit are publicly readable without credentials. Preserve upstream attribution and license notices. Do not change the pinned source to another repository merely to make cloning succeed.
