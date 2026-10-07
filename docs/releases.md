# Packaging and publishing releases

Downloadable releases are experimental prereleases until advertised reliability acceptance passes. Keep the model, architecture, OS coverage, signing and remaining limitations explicit. A download does not broaden hardware support.

## Package a reviewed revision

On Apple Silicon macOS, from a clean checkout of the intended source revision:

```sh
scripts/test.sh
scripts/integration-dry-run.sh
scripts/package-release.sh
```

Packaging always invokes the native build, preserves embedded licenses, checks arm64 executables and creates a drag-and-drop DMG plus a ZIP fallback under `dist/releases/`. It extracts the ZIP and mounts the DMG read-only, checks signatures and full app-file equality, verifies installation notes/Applications link and writes SHA256SUMS. It does not launch the app, install a queue or access Bluetooth. `BUILD-INFO.txt` in the DMG records the version, source revision and signature category; a dirty checkout is visibly marked and must not be published.

The version/channel come from the bundled Info.plist. Current packages use `0.1.0-alpha.3`; review all app/CLI/About version strings before changing it. Default signing is ad hoc. Only `MUNBYN_SIGNING_IDENTITY` explicitly selects another identity. This tool does not notarize or staple artifacts; do not describe a signature check as notarization. Never put signing material in source or untrusted CI.

## Publication checks

- Confirm the exact source revision passed CI and the tagged tree is reviewed, generic and free of private documents, identifiers, credentials and developer account details.
- Build from a fresh checkout in a generic temporary path. Inspect bundle contents, embedded string metadata, licenses, architecture and dynamic dependencies before uploading.
- Verify both packaged app copies and checksums. Record local package checks separately from a fresh downloaded-app/Gatekeeper/permission test and physical printing.
- Inspect existing tags/releases first. Create only the reviewed alpha tag and its prerelease; never force an existing tag or replace an unrelated release. Upload only the explicit DMG, ZIP and SHA256SUMS assets. Do not publish every branch/tag or developer folders.
- Describe installation, tested versus target macOS versions, ad-hoc/Developer ID status, notarization status and known limitations in release notes. Link validation evidence and source-build instructions.
- Download the published assets and verify their hashes/signatures again. Confirm release visibility, prerelease status, tag target and asset names.

Release publication is a maintainer action using an explicitly authorized GitHub identity. CI only validates packaging with read-only permissions; it does not publish or receive signing/release secrets from pull requests.

## First launch and uninstall

The DMG includes [INSTALL.txt](INSTALL.txt). Installation means copying the app, opening it and using its explicit printer selection and queue-install actions; downloading the DMG alone does not install the CUPS queue. The background app must remain running in the owning user's session. Other models and a hidden background-service mode are not implemented.

Ad-hoc binaries are not notarized. Document Apple's [individual app approval](https://support.apple.com/en-us/102445) where allowed, and never instruct users to disable Gatekeeper/SIP or remove quarantine globally. A new downloaded-app approval flow is not covered by a local build or mounted-image signature check. Uninstall can use the menu and Finder without cloning or compiling the source; review pending/unknown jobs first.
