# MUNBYN ITPP130B Bridge

Experimental, independent macOS menu-bar application exposing **MUNBYN ITPP130B (Bluetooth)** in the normal print dialog. Original code is MIT licensed. This project is not affiliated with MUNBYN.

**Status: alpha development, not a verified reliable printer driver.** See [validation evidence](docs/evidence.md) and [hardware checklist](docs/hardware-validation.md). Compilation, CUPS completion, BLE writes, and physical printing are separate results. Raw socket handoff has material job-control limitations described below. There is no stable v0.1.0 release.

Print label-sized PDFs from the normal macOS print dialog in Chrome, Preview or another application. The bridge converts Apple's raster output to TSPL and sends it to an explicitly selected ITPP130B over Bluetooth LE, releasing the connection after each job so the printer can also be used from a phone.

Physical printing has been tester-confirmed on one ITPP130B with 100 × 150 mm stock, including portrait and landscape PDFs, multiple pages, collated copies and scannable QR codes. The latest four consecutive software transmissions took approximately 9.6–10.2 seconds after a Bluetooth recovery diagnostic. Earlier intermittent stalls remain unexplained, and this is not a latency guarantee. See the [validation summary](docs/evidence.md) for the distinction between software checks, physical observations and outstanding acceptance tests.

## Scope

One explicitly selected ITPP130B, one logged-in macOS user, native printing of label-sized PDFs, separate 100 × 150 mm and 4 × 6 inch (101.6 × 152.4 mm) presets, portrait/landscape content, multiple pages and copies. No USB is needed for the bridge. The existing USB queue and default printer are preserved.

No label editor, automatic A4 extraction/cropping, browser extension, LAN sharing, cloud, accounts, telemetry or automatic updates. The print application controls layout and page ranges; use a PDF sized for the loaded stock.

Deployment target is macOS 13. Builds and local integration have been exercised on **macOS 15.7.9, Apple Silicon, Swift 6.2.4, SDK 26.2, Apple CUPS 2.3.4**. macOS 13/14, Intel and universal packages are not validated. Building needs an Apple Swift 6 compiler and macOS SDK (Xcode or Command Line Tools). Normal use needs no Homebrew, Python, Node or separately installed runtime.

## Download and install

Get the **Apple Silicon alpha DMG** from [GitHub Releases](https://github.com/cmyker/munbyn-itpp130b-macos/releases). A ZIP fallback and SHA256SUMS are provided too. No compilation or developer tools are needed to use the download. Intel Macs and other MUNBYN models are not supported by this release.

1. Quit any existing bridge, open the DMG and drag **MUNBYN ITPP130B Bridge.app** to **Applications**. Eject the DMG and open the installed app. ZIP users can extract and copy the app instead.
2. This alpha is **ad-hoc signed and not notarized**. If macOS blocks first launch, use its individual **System Settings → Privacy & Security → Open Anyway** approval only if you trust the release. See [Apple's instructions](https://support.apple.com/en-us/102445); managed Macs may restrict approval. Do not disable Gatekeeper or SIP globally.
3. Follow **First start** below to allow Bluetooth, select the physical printer and install the separate queue. Downloading/copying the app does not install the queue automatically.

The app must stay running in the owning user's logged-in session. **Start at Login** can register automatic startup when available, but login/logout acceptance remains open. There is currently no hidden service mode or print-triggered launch. The menu icon is the bridge's status/recovery interface, not a per-job application that must reopen documents. See [installation/uninstall notes](docs/INSTALL.txt) and [release verification](docs/releases.md).

## Build and install from source

```sh
git clone https://github.com/cmyker/munbyn-itpp130b-macos.git
cd munbyn-itpp130b-macos
scripts/test.sh
scripts/build-app.sh
scripts/install-app.sh
open "$HOME/Applications/MUNBYN ITPP130B Bridge.app"
```

The build produces `dist/MUNBYN ITPP130B Bridge.app` and installs in `~/Applications` by default. It is **ad-hoc signed, not Developer ID signed or notarized**. Build locally or use macOS's individual app approval controls for an explicitly trusted artifact; do not disable Gatekeeper or SIP globally. Signing is only selected through `MUNBYN_SIGNING_IDENTITY`; downstream builds can set `MUNBYN_BUNDLE_ID` (default `io.github.cmyker.munbyn-itpp130b-bridge`). Changing signing identity/build may prompt for Bluetooth permission again.

First start:

1. Choose **Select Printer**, allow Bluetooth permission, and select your intended physical printer from the unfiltered scan. The app probes writable FFF2 and saves that peripheral identifier and its observed service privately. A common name or UUID alone is insufficient; selection is explicit and never falls back to another device.
2. Enable **Dry Run** for initial synthetic tests. This explicitly writes sensitive local captures; it uses no Bluetooth.
3. Choose **Repair / Install Printer Queue**. The app validates the PPD and starts its loopback listener before requesting the narrowly scoped queue change. macOS may ask for administrator authorization. Canceling leaves other printers untouched. Re-running repairs only the project-owned queue.
4. After a physical calibration on your stock, disable Dry Run. Optionally enable **Start at Login** and check its actual approval state in System Settings. Login/logout launch has not passed acceptance; if registration reports unavailable, launch the app manually after login. The menu app must be running and its user logged in for jobs to arrive.

## Everyday printing

Open a correctly sized label PDF in an application such as Chrome or Preview, press Cmd+P, choose **MUNBYN ITPP130B (Bluetooth)**, select the exact loaded media (100 × 150 mm or 4 × 6 inches), orientation, page range and copies, then Print. Use actual size/100% when the document already matches the stock; examine the application's preview before printing. Chrome may require **See more** in the destination list to find the queue. There is no per-print command and no separate label application. Chrome and Preview have been tested; other applications using the macOS printing system have not yet been individually validated.

For portrait 100 × 150 mm labels, keep portrait at actual size. For landscape, use a 150 × 100 mm document with the matching landscape layout. Forcing a portrait PDF into landscape at 100% can clip it in Apple's raster conversion; this was reproduced in captures and on paper. If you deliberately change layout, explicitly choose the application's fit option and inspect its preview. The bridge preserves the received pixels and cannot recover content already clipped upstream.

Output direction uses TSPL `DIRECTION 0,0`. It preserves the incoming raster and the application's portrait/landscape choice. The latest synthetic QR label's feed-relative direction was tester-confirmed to match normal USB output on the tested unit; an earlier orientation test failed. No additional software rotation is applied.

The queue identifier is `MUNBYN_ITPP130B_Bluetooth`; it is not set as default and sharing is disabled. Printed content is not cropped or label length shortened. Full-page printable area, 203 dpi and 3 mm gap remain calibration assumptions until measured on a unit; see [protocol](docs/protocol.md).

BLE connects on demand and releases after a job. **Release** cancels active bridge work and disconnects; manual Connect releases after ten seconds. A printer missing during connection may be off or busy with a phone; that is a possibility, not a diagnosis. Mac → phone → Mac printing was tester-confirmed on the tested unit; other phone apps and firmware remain untested.

New printer selections prefer **Without Response** for bulk data when both write properties are available, using mode-specific packet limits, CoreBluetooth backpressure and bounded pacing. Each page's last existing data chunk uses **With Response** and is awaited before release; a response-capable characteristic is required. This acknowledges only the final GATT request, not receipt of every earlier command or paper output. Saved explicit choices take precedence; **BLE Write Mode** lets the operator choose either supported mode. Default pacing is a 256-byte cap and 10 ms between writes, further constrained by the selected peripheral's actual limits. On the tested unit, without-response calibration was substantially faster than with-response calibration, but later connections also stalled. [Measured timings and physical results](docs/evidence.md) are limited to that unit and are not a benchmark against another application.

The encoder uses full-width bitmap strips, including white pixels. A compact representation passed offline checks but failed physical acceptance and was removed. Full-width transfers also experienced stalls, so bitmap layout alone does not explain the failure. A response to the last data chunk and the empirical settling interval do not confirm paper output or guarantee earlier best-effort delivery. Reliable delivery remains unresolved.

## Failures and ownership

Jobs are validated and durably stored before the bridge closes the incoming stream. One job/page sequence owns the BLE connection at a time. `transmitted` means CoreBluetooth accepted writes, **not confirmed paper output**. Print Center can therefore show an empty queue while the bridge is still connecting or sending. Check the printer-shaped menu-bar icon → **Jobs** for the bridge-owned state; an empty native queue is not proof that a label printed.

- `failedBeforeSend`: no write intent was recorded; use the menu's Retry after fixing the connection.
- `outcomeUnknown`: a write may have reached the printer. Automatic replay and later BLE jobs stop. Inspect the paper, cancel any native CUPS copy still pending, and power-cycle the printer to clear a potentially partial command buffer. This is an honest user recovery instruction; no protocol reset sequence is verified. Then explicitly confirm recovery. Reprint requires a second duplicate-risk confirmation; identical labels are never deduplicated by hash.
- Cancellation before transmission can discard that bridge job. Cancellation during possible transmission becomes unknown. **Print Center cancellation cannot affect a job already handed to the bridge**; use its Jobs menu.
- Quit/restart preserves pending and uncertain records. Sleep requests cancellation/release; restarting a sending record makes it unknown. App-not-running or port-conflict errors require starting/fixing the app, without killing another listener.

**Architecture limitation:** Apple's socket backend has no transactional application acknowledgement or native job identity. It can report completion after a validation rejection or a crash before durable handoff, and a replay around handoff can duplicate a job. `abort-job` limits scheduler retries but cannot remove these windows. The installed backend continued preconnection retries beyond 45 seconds despite its timeout hint; native cancellation is available before handoff. Check bridge status after failures. The project remains experimental because these limits do not meet fully acknowledged job ownership. [ADR-001](docs/architecture.md) evaluates maintained PAPPL IPP as a replacement, without building two production paths.

## Diagnostics and privacy

Menu Diagnostics and `doctor` show redacted status and aggregate phase timings for the last job in the current app process. Transmission durations and call/byte counts also remain in bounded private job metadata after restart. They do not acknowledge physical printing. Active jobs declare a scoped macOS user activity; any latency improvement remains unverified. No document contents, tracking numbers, raster or TSPL data are logged by default. Data lives in owner-only `~/Library/Application Support/MunbynBridge` (directories 0700, files 0600). Pending/failed/unknown content is retained for explicit review, bounded to 32 unfinished jobs / 128 MiB bitmap accounting. Dry-run preference and each accepted job's capture/print destination persist across restart; changing the setting affects new jobs. A failed capture retains its source for review/retry. Finished content is removed; metadata is bounded to 64 records / 14 days. Dry-run captures are explicitly opt-in, sensitive, local, bounded to 32 folders / 128 MiB, and require ordinary deletion through **Delete Sensitive Captures**. Deletion is not secure SSD erasure. See [security](SECURITY.md) for the unauthenticated loopback boundary.

CLI, communicating with the existing app rather than owning another BLE connection:

```sh
cli="/Applications/MUNBYN ITPP130B Bridge.app/Contents/MacOS/munbyn-bridge"
"$cli" doctor
"$cli" scan
"$cli" status
"$cli" release
"$cli" help
```

`scan` reveals local peripheral identifiers; do not upload its output. Other commands include `select`, `test-print`, `install-queue`, `uninstall-queue --confirm`, `cancel`, `retry`, `confirm-recovery`, `reprint`, `delete`, `dry-run`, `clear-captures`, bounded per-run `pacing CHUNK,DELAY_SECONDS`, saved `write-mode with-response|without-response`, `login` and `quit`. Offline `raster-info PATH` and `capture PATH PRIVATE_OUTPUT` never access Bluetooth. Never commit a real shipping label or a diagnostic capture.

For the source install script's default location, use `$HOME/Applications` instead of `/Applications` in the CLI path. Normal printing needs no CLI command.

## Testing

```sh
scripts/test.sh                   # synthetic, no printer or permission
scripts/integration-dry-run.sh    # Apple raster converter; no queue modification/BLE
```

CI builds/tests/packages on macOS without installing a queue. Integration of actual Chrome/Preview printing and physical hardware is tracked separately. Synthetic fixtures are generated with native frameworks by `scripts/make-fixtures.swift`; no actual shipping labels are included. [Hardware procedures](docs/hardware-validation.md) use a small label budget and require observed paper results before changing verification status.

## Uninstall

Review/cancel native CUPS pending jobs and bridge jobs first. Resolve unknown outcomes before deleting their records. Download users can turn off **Start at Login**, choose **Uninstall Project Queue…**, quit the app and move it to Trash; private data remains until explicit deletion. See [INSTALL.txt](docs/INSTALL.txt). No source checkout is needed for that route.

With a source checkout and the app running:

```sh
scripts/uninstall-app.sh --confirm
# To also delete all private spool/config/captures, explicitly opt in:
scripts/uninstall-app.sh --confirm --delete-data
```

This unregisters login, removes only the owned Bluetooth queue, quits the bridge, and removes the matching installed bundle. Pending jobs cause refusal. The default path is `~/Applications`; use `MUNBYN_APP_PATH` for another installed location. Data is retained unless `--delete-data` is supplied. No USB queue, global CUPS configuration, other app or printer is removed. Menu **Uninstall Project Queue…** is available independently.

For development, start with [CONTRIBUTING](CONTRIBUTING.md) and [AGENTS.md](AGENTS.md), then read the [roadmap](docs/roadmap.md), [architecture](docs/architecture.md), [protocol](docs/protocol.md), and [third-party attribution](THIRD_PARTY_NOTICES.md).
