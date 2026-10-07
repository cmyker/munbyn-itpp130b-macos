# Validation evidence and known limitations

Updated 2026-10-07. **Experimental alpha.** Physical output is tester-confirmed on one ITPP130B; complete reliability acceptance remains open. This summary describes anonymous test configurations and reproducible observations. It contains no private documents, device identifiers or personal session transcript.

## Coverage

| Item | Observed configuration |
| --- | --- |
| macOS / architecture | 15.7.9 (24G830), Apple Silicon arm64 |
| Toolchain | Apple Swift 6.2.4, SDK 26.2 |
| Printing system | Apple's shipped CUPS 2.3.4 |
| Deployment target | macOS 13; runtime coverage currently only 15.7.9 |
| Printer / stock | One explicitly selected ITPP130B, 100 × 150 mm stock |
| Firmware | Unknown; no undocumented firmware/status probe used |
| BLE | Service FFF0, writable FFF2, properties 12; observed write capacities 182 bytes without response / 512 with response |
| Package | Apple Silicon, ad-hoc signed, system-only dynamic dependencies; not Developer ID signed or notarized |

Neither cross-compilation nor a deployment target establishes runtime/hardware coverage. Physical 4 × 6 stock, other firmware, macOS 13/14 and Intel/universal builds are unverified.

Exact inspected upstream commits, licenses and relevant source files are recorded in [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md). No reference implementation or proprietary vendor driver is copied into the app. System cupsRasterOpenIO/ReadHeader2/ReadPixels were linked and exercised on the tested SDK/runtime.

## Hardware-independent checks

The current implementation passed **62 tests across nine suites** through `scripts/test.sh`, without a printer, Bluetooth permission or queue changes. Coverage includes:

- Literal independent TSPL expectations: dimensions, polarity, row padding, binary framing, media and final-chunk byte ordering.
- Native raster fixtures: supported monochrome formats, malformed/truncated headers and rows, metadata consistency, limits, page order and copies.
- Durable acceptance, private permissions, restart recovery, capture intent, terminal cleanup and conservative ambiguous outcomes.
- Mock transport chunking, backpressure, bounded deadlines including preparation/settling, disconnects, cancellation and final-request failure/ownership.
- Settings action serialization, actual login-state/pending-approval presentation, failed registration, window creation without owner commands, queue-action window return/user-close handling and visibility of old unresolved jobs.
- Confirmed bulk deletion, preservation without confirmation, whole-spool refusal for active/unrecovered unknown work, restart after clearing and preservation of files outside the job spool. UI tests never construct the owner coordinator or register login.
- Fixed queue arguments and ownership checks; real loopback fragmentation, half-close, port conflict, stalled receive and user-only IPC.

A fresh source clone passed the tests and arm64 ad-hoc packaging. `scripts/build-app.sh` verified the signature and rejected non-system dynamic dependencies. Public CI runs tests, native conversion and packaging without installing a queue. Test-only Testing.framework deployment warnings do not establish macOS 13 coverage.

## Native macOS integration

These are software integration results, separate from paper output:

- `cupstestppd` accepted the original PPD. Apple's converter produced uncompressed v3 K/1-bit raster: 799 × 1199 dots for 100 × 150 mm and 812 × 1218 for 4 × 6 inches, at configured 203 dpi. Two collated copies of two pages expanded to four raster pages with NumCopies=1.
- Installed socket-backend tests observed byte streaming, write-side half-close and waiting for bridge EOF. Dry captures validated complete jobs without BLE. TCP reads were not treated as page/job boundaries.
- Normal Chrome and Preview print dialogs submitted jobs through the separate project queue. Dry runs established actual ingress independently of command-line `lp` tests. Chrome's destination list may require **See more**.
- The installed app's Bluetooth permission approval, explicit selection, service/characteristic validation, profile persistence and renewed permission after ad-hoc updates were exercised. Permission denial remains untested on hardware.
- Queue installation succeeded with narrow administrator authorization, sharing disabled and the selected error policy. The installer did not modify the existing USB queue or request a default-printer change. Actual authorization denial and uninstall acceptance remain open.
- Duplicate app invocation exited while the original owner/control endpoint remained available. SMAppService registration/unregistration was exercised; automatic launch after login/logout remains untested. Unavailable registration is reported rather than presented as enabled.

## Settings UI validation

The alpha.2 UI was inspected on macOS 15.7.9 in an isolated native preview using the production menu/settings source and an in-memory owner stub. General, Printer and Advanced controls were visible without clipped text. A failed login action restored the checkbox from actual service state; cancelling Dry Run and Test Label left their actions unapplied. The preview had no BLE owner, print listener, real spool, queue installer or login registration. A window-loading regression was reproduced and fixed, with a test that presents the window without owner commands.

This validates layout and action presentation, not installed login/logout launch or physical printing. Those acceptance items remain separate below.

For alpha.3, the installed alpha.2 queue repair was exercised with tester-entered administrator authorization: the queue was confirmed owned/installed afterward, the owner remained alive, Settings still existed in the background, and unrelated queue URIs/default-printer fingerprints were unchanged. Queue actions previously had no foreground return. A native controller test reproduced a lost Settings window during a simulated external authorization flow; the added completion return passed it and a user-close safeguard test. This simulation does not run privileged commands. The patched real-password flow still needs operator confirmation; no physical printing was repeated for this UI update.

## Physical results confirmed by a tester

No automated assertion of paper output is made. The following paper observations were reported during controlled testing:

| Test | Confirmed result / scope |
| --- | --- |
| Calibration | White background, full frame and a bold 200-dot bar. An initial wrong-polarity attempt produced an all-black rectangle; corrected encoding passed. |
| Normal app printing | Two-page synthetic PDF from Chrome and a correctly sized landscape PDF from Preview printed. A label-sized PDF also printed correctly through Chrome. Private document contents were not inspected or published. |
| Copies and page order | A separate `lp` queue test produced exactly four labels in 1, 2, 1, 2 order. Both printed QR payloads decoded correctly. This was not a verified two-copy Chrome-dialog test. |
| QR / direction | A current-policy synthetic QR decoded to MUNBYN-BRIDGE-SYNTHETIC-PAGE-1 and emerged in the same direction as normal USB output. Earlier orientation acceptance failed; no second software rotation was added. |
| Phone coexistence | Mac → phone → Mac printing succeeded after normal link release, without a routine power-cycle. Other phone applications/firmware are untested. |
| Printer off | Job failed before sending and remained retained; after power-on, one explicit retry printed exactly once. |
| Interrupted app | Killing during transmission and restarting retained outcome-unknown, blocked subsequent work and did not replay. After power-cycle and explicit duplicate-risk approval, one reprint produced a complete page with the expected QR. |

Copies, landscape, phone handoff and interruption results were obtained before the latest final-chunk response policy. That policy has passed complete single-page calibration, QR and normal Chrome output; its full multipage/phone/lifecycle matrix still needs retesting.

## Dimensions and performance

The 200-dot bold bar measured **25 ± 0.5 mm**. A frame measured approximately **95 × 143 mm** on stock measured 150 mm high. Its programmed line-centre spans are 758 × 1158 dots, predicting 94.84 × 144.89 mm at 203 dpi. Horizontal measurements do not distinguish 203 dpi from 8 dots/mm; the approximately 1.9 mm vertical discrepancy, exact dot pitch, maximum width and edge margins remain unresolved. No compensating stretching was added. Thin one-row marks were faint on later tests; the diagnostic bar was thickened without changing document layout.

At a configured 256-byte cap and 10 ms pacing, an earlier identical full-canvas calibration measured 51.38 seconds with-response and 9.83 seconds without-response (actual streaming chunks 182 bytes). A 2 ms comparison measured 8.00 seconds. Complete faster outputs were tester-confirmed. These are software transmission durations, not paper-ejection times or matched vendor-app benchmarks.

Later transfers stalled or completed software writes with no paper. One stalled attempt spent 107.89 seconds waiting for CoreBluetooth readiness before observation-limit cancellation; it remained outcome-unknown. Compact bitmaps passed offline reconstruction but failed physical acceptance and were removed; restored full-width encoding also stalled. Layout alone does not explain the failure.

After one Mac Bluetooth off/on diagnostic and printer-buffer recovery, four consecutive software transmissions took **10.058, 10.214, 9.636 and 9.891 seconds**, without further reset between them. Calibration, a scanned synthetic QR and normal label output were tester-confirmed. The two final one-page submissions were distinct native jobs; physical count from both was not separately confirmed. This is a recovery observation, not a diagnosed permanent fix or an acceptable requirement to reset Bluetooth before routine printing.

Bounded opt-in local daemon recordings observed slow write/readiness events and a reported ATT MTU of 185. They did not provide radio capture, physical acknowledgements or a verified controller/firmware cause. Raw traces remain private and are not project dependencies. Scoped process activity was added for active work, but App Nap was not established as the cause or its removal as a speed fix.

## Remaining acceptance and architecture limits

- Reproduce and resolve intermittent BLE stalls; repeat current-policy multipage, consecutive-job, phone and interruption checks.
- Verify exact vertical geometry, printable edges/margins and both media on matching physical stock.
- Test sleep/wake, Bluetooth changes during transmission, login/logout launch, installed permission denial, administrator denial and complete uninstall.
- Firmware-specific status, trustworthy physical acknowledgements and printer-buffer reset commands are not implemented or verified.
- Raw socket handoff remains nontransactional. A malformed stream was rejected while the native backend exited zero; a no-listener test retried beyond 45 seconds despite its timeout hint. Print Center cannot cancel a job already owned by the bridge. See [ADR-001](architecture.md) for ownership windows and the maintained IPP implementation evaluated as a replacement.

A successful build, native queue completion, GATT response or rendered preview is not proof of correct paper output. Stable release acceptance has not been met. Future results should update this summary with anonymous configurations and precise verification levels, not private workflow details.
