# Contributor guide for coding agents

This guide applies to the whole repository. It is also useful for human contributors. Use it to orient yourself, then check the current source and validation documents before changing behavior.

## Project and current status

MUNBYN ITPP130B Bridge is an independent, experimental macOS menu-bar application. It exposes **MUNBYN ITPP130B (Bluetooth)** in the normal print dialog and sends TSPL over BLE to one explicitly selected ITPP130B. Original code is MIT licensed. It is not affiliated with MUNBYN.

The deployment target is macOS 13. Build and runtime evidence currently covers macOS 15.7.9 on Apple Silicon, Swift 6.2.4, SDK 26.2 and Apple's CUPS 2.3.4. Other OS versions, Intel/universal packages and other printer models are unverified. Normal users must not need a separately installed runtime.

Read these documents first:

1. [README.md](README.md): setup, normal printing and recovery.
2. [docs/architecture.md](docs/architecture.md): ingress, ownership and socket limitations.
3. [docs/protocol.md](docs/protocol.md): raster contract, TSPL, BLE and limits.
4. [docs/evidence.md](docs/evidence.md) and [docs/hardware-validation.md](docs/hardware-validation.md): tested results and remaining acceptance work.
5. [SECURITY.md](SECURITY.md), [CONTRIBUTING.md](CONTRIBUTING.md) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Use [docs/roadmap.md](docs/roadmap.md) for current development priorities; there is no required editor, assistant or plugin.

## Source map

| Location | Responsibility |
| --- | --- |
| `Sources/BridgeCore/Raster.swift`, `Bitmap.swift` | Incremental raster validation, media and monochrome pixels. |
| `Sources/BridgeCore/TSPL.swift`, `Calibration.swift` | Binary-safe encoder and synthetic calibration. |
| `Sources/BridgeCore/Transmission.swift`, `BLEWritePreference.swift` | Transport-independent chunking, deadlines, pacing and write policy. |
| `Sources/BridgeCore/Spool.swift`, `PrivateFiles.swift` | Durable job state, restart recovery and private files. |
| `Sources/BridgeCore/Sockets.swift` | Loopback print ingress and user-restricted control IPC. |
| `Sources/BridgeCore/QueuePlan.swift` | Fixed, ownership-checked queue argument construction. |
| `Sources/CBridge/` | System cupsRaster APIs, local CUPS inspection and authorization interoperability. |
| `Sources/MunbynBridge/` | AppKit menu, coordinator, CoreBluetooth, queue installation and login state. |
| `Sources/MunbynCLI/` | Commands to the owner process; offline raster inspection/capture. |
| `Resources/` | Original PPD and application bundle metadata. |
| `Tests/BridgeCoreTests/`, `scripts/` | Synthetic tests, native conversion and packaging. |

## Development commands

Run from the repository root on macOS:

```sh
scripts/test.sh
scripts/integration-dry-run.sh
scripts/build-app.sh
```

These checks do not install a queue or access Bluetooth. The integration script generates synthetic PDFs and uses Apple's converter. Packaging creates `dist/MUNBYN ITPP130B Bridge.app`, signs ad hoc by default and checks for accidental developer-library dependencies. CI runs the same commands with read-only repository permissions.

For downloadable artifacts, run `scripts/package-release.sh` and follow [docs/releases.md](docs/releases.md). It builds, extracts/verifies the ZIP, mounts/verifies the DMG and writes checksums without launching or installing the app. Keep artifacts in ignored `dist/releases/`; publication requires a reviewed source/tag and accurate prerelease/signing status.

Installation is a separate action: `scripts/install-app.sh`, then launch the installed app and use **Repair Printer Queue**. Quit a running bridge before replacing its bundle. Do not install/uninstall queues, send labels, change Bluetooth settings or register login items merely to run automated tests.

## Printing invariants

- Keep raster decoding, ingress/job ownership, encoding and BLE transport independent. The CLI must not become a competing BLE owner.
- Preserve the existing USB queue and default printer. Modify only an ownership-verified `MUNBYN_ITPP130B_Bluetooth` queue. Use the fixed display name above, loopback `127.0.0.1:19100`, sharing disabled and argument-vector privileged operations.
- Use system cupsRaster APIs. Reject unsupported/truncated/oversized input before print bytes; keep parsing incremental and respect the documented limits. A TCP read is not a job boundary.
- Keep 100 × 150 mm and 101.6 × 152.4 mm media distinct. CUPS owns layout, rotation, scaling, page ranges and collation. Apply a supplied raster copy count once. Preserve bitmap dots and white padding; do not add cropping, smoothing, stretching or a second rotation/copy count.
- TSPL uses full-width strips, explicit `DIRECTION 0,0`, binary-safe framing and `PRINT 1,1` per expanded page. Do not copy Phomemo-specific ESC/POS commands or flow-control assumptions.
- Select the printer explicitly and revalidate its saved service/characteristic. Never silently switch devices or rely on a common name/UUID alone. Firmware behavior is not universal.
- Respect actual characteristic properties, both write capacities, without-response readiness callbacks and bounded pacing. Each page's last existing chunk is sent with response and awaited; preserve the exact concatenated payload. That callback does not acknowledge earlier best-effort delivery or physical printing.
- Serialize jobs/pages, connect on demand and release safely when idle. No aggressive idle reconnect or permanent connection that prevents phone printing.

## Ownership and recovery invariants

- Persist validated content and queued state before bridge acceptance; persist sending intent before the first possible printer write.
- Raw socket handoff is not transactional and carries no native CUPS job ID. Do not invent metadata, describe Print Center completion as paper output or conceal the documented handoff crash windows.
- Failure certainly before printer bytes can be retried explicitly. Possible writes, interruption or restart from sending produce `outcomeUnknown`; block later BLE work and never automatically replay it.
- Reprinting uncertain work needs explicit buffer-recovery and duplicate-risk confirmation. Never resume arbitrary byte offsets or deduplicate by document hash. There is no verified printer-reset command.
- Preserve pending/uncertain records on quit, restart and errors. Keep capture intent persistent so a dry run cannot become a physical print after restart. Warn before deleting sensitive or pending data.

## Verification, privacy and licensing

- Use independent literal expected bytes for encoder tests and mock transports for failure/backpressure tests. Automated tests must not require hardware or Bluetooth permission.
- For source changes, run the three commands above. For documentation-only changes, check links, paths, commands and claims against source; broader tests are optional. Record what ran and any limitations.
- Hardware tests need an explicit small synthetic label budget and operator coordination. Separate unit-test success, native integration, BLE transmission, directly observed paper output and tester-confirmed results. Never infer physical success from a callback or preview.
- Keep real documents, addresses, tracking data, profiles, device identifiers, captures and Bluetooth traces out of Git, issues and CI logs. Document captures require explicit local opt-in. Use ordinary-deletion wording, not secure-erasure promises.
- Preserve third-party licenses/notices and exact upstream provenance. Do not redistribute proprietary drivers. Use signing identities only when explicitly configured; keep credentials out of source and untrusted CI.
- Keep code, docs and UI in English. Update relevant docs when behavior or evidence changes, using generic workflows and anonymous test configurations rather than personal session transcripts.

## Open work

Intermittent BLE stalls remain unexplained. Single-page output with the current final-chunk policy has passed physical checks; its full multipage/phone/lifecycle matrix still needs retesting. Exact vertical geometry/margins, physical 4 × 6 stock, permission denial and login/logout/sleep/wake acceptance remain open.

Socket ingress cannot provide acknowledged native handoff/cancellation. A compatible maintained PAPPL implementation has been evaluated as a replacement; it is not bundled. Keep one production ingress and use [ADR-001](docs/architecture.md) before changing architecture. Do not claim a reliable stable release until its advertised acceptance criteria have actually passed.
