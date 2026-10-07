# Raster and TSPL contract

## macOS ingress observed on 15.7.9, arm64, Apple CUPS 2.3.4

The original PPD advertises a no-op `application/vnd.cups-raster` filter. Apple supplies `cgpdftopdf`/`cgpdftoraster`; no proprietary or bundled custom filter is required. Real generated output starts with little-endian uncompressed CUPS raster v3 `3SaR`, followed by `cups_page_header2_t` headers and the declared pixel rows. The API, not custom binary offsets, decodes the header and rows. A synthetic system-library writer is also used for tests.

Supported: uncompressed v3 (`3SaR` or byte-swapped `RaS3`), chunky single-channel W (0), K (3), or SW (18), 1 or 8 bits per pixel/color, one color, 203 × 203 resolution. Compressed v2, v1, PWG, Apple/URF, RGB/CMYK, planar/banded, 16-bit and other variants are explicitly rejected. The preamble check rejects compressed variants before libcups can allocate row buffers from untrusted headers. Native APIs are available in SDK 26.2 and successfully used on runtime 15.7.9.

Each row must have exactly ceil(width × bits / 8) bytes. Read incrementally and require the full row. Reject truncated headers/pixels/trailing bytes, unsupported metadata, excessive copies, nonfinite or mismatched physical dimensions. Clean EOF is required exactly between pages, not after a delay. No empty jobs.

| Preset | Physical dimensions | PPD points | Observed raster dots |
| --- | --- | --- | --- |
| 100 × 150 mm | 100 × 150 mm | 283.464567 × 425.196850 | 799 × 1199 |
| 4 × 6 inches | 101.6 × 152.4 mm | 288 × 432 | 812 × 1218 |

Reported calibration measurements were **25 mm** for the original 200-dot horizontal ruler and **95 mm wide × 143 mm high** for the frame. The programmed frame borders span 758 × 1158 dots between line centres. At 203 dpi these predict 94.84 × 144.89 mm; at 8 dots/mm they predict 94.75 × 144.75 mm. The whole-millimetre horizontal reports are consistent with both values and cannot establish exact native dot pitch. The reported frame height is about 1.9 mm (1.3%) shorter than the configured prediction; this vertical discrepancy remains unresolved. Ruler error was not quantified, and physical stock height was reported as 150 mm. Maximum head width and edge margins remain unverified. No bridge-side stretching or DPI adjustment was made from these measurements. 203 dpi remains a configured value supported by the existing USB PPD and these approximate horizontal checks. The bridge accepts one-dot raster rounding tolerance, preserves the actual pixels and leaves any unused area white; it never stretches to force dimensions. Full imageable area in this experimental PPD is provisional until an edge calibration verifies it.

The synthetic calibration uses a 200 × 16-dot black bar for easier physical measurement, at x=40...239 and y=80...95. Its original one-row version was extremely faint or invisible on later prints with both BLE write modes. The changed diagnostic has independent packed-row tests, installed-app dry-capture evidence and tester confirmation that its full length is physically visible on one label, measured as 25 ± 0.5 mm. The cause of the original faint marks remains unknown. This does not change incoming raster content, media, encoder polarity, density or pacing.

## Responsibility

CUPS and the originating application own scaling, placement, selected page ranges, landscape/content rotation, page order and collation. In the actual queue, `orientation-requested=4` changed pixels while physical dimensions and Orientation=0 remained portrait. Direct `cupsfilter` does not reproduce all queue PDF preprocessing; its orientation argument alone did not rotate the synthetic PDF. The bridge does **no second rotation, cropping, scaling, trim or automatic A4 extraction**. Select the correct physical stock and app scaling in the print dialog; A4 document content requires the user's explicit layout choice.

Actual queue captures and paper showed clipping when a portrait-sized PDF was forced into landscape without scaling. A correctly sized 150 × 100 mm landscape PDF produced an uncut rotated frame in a queue capture. An explicit `fit-to-page=true` conversion also preserves the frame, but the application/CUPS owns that requested layout change. Never add bridge-side scaling to compensate for already clipped input. Synthetic fixtures include both portrait and landscape document sizes.

Apple conversion expands requested copies into raster pages in tested `-n 2` collated output (four pages, NumCopies=1). A tester confirmed four physical labels in 1/2/1/2 order through the installed queue. The bridge applies a non-one raster NumCopies once if it is actually supplied; collation repeats whole page sequences, uncollated copies repeat each page. Reject mixed collation/counts. TSPL always uses PRINT 1,1 for each resulting page, never the original UI count again. Chrome/Preview ingress was separately tested through their dialogs; copies were verified with `lp`, not a confirmed two-copy dialog submission.

K 1-bit black data passes through unchanged except unused padding bits cleared white. W/SW 1-bit is inverted. 8-bit gray uses threshold 128 with no dithering; conversion is row-local. MSB is leftmost. Packed bridge/PBM bitmap uses one=black. TSPL output inverts those bytes, including padding, so zero=black and one=white. The first physical test without inversion produced a black rectangle (tester observation); a corrected calibration is tracked in the evidence file. This correction is model-specific evidence, not a claim about every firmware.

The encoder sets feed-relative output direction with `DIRECTION 0,0`, including an explicit non-mirrored mode. A development-only stdout diagnostic of an existing USB filter emitted the same command for normal rotation and `DIRECTION 1,0` for 180 degrees. An earlier BLE orientation test failed; the latest synthetic QR label was tester-confirmed to match normal USB direction. This is separate from the application's portrait/landscape content rotation: bitmap rows and bits are preserved, with no second software rotation or mirroring. The earlier discrepancy remains unexplained. The proprietary filter is neither bundled nor required by the bridge.

## Candidate TSPL

Binary-safe ASCII CRLF commands: exact SIZE in mm, provisional GAP 3 mm,0 mm, DIRECTION 0,0, REFERENCE 0,0, CLS; full-width BITMAP 0,y,widthBytes,rows,0 strips of at most 100 rows; exact binary payload (including null/newline bytes) followed by CRLF; PRINT 1,1 CRLF. Mode 0 overwrites each disjoint rectangle. Physical media dimensions remain fixed on every page. No ESC/POS, Phomemo substitutions, feed hacks or buffer-credit protocol. Density/speed are left to printer settings rather than unverified sweep ranges.

A compact representation was evaluated using disjoint sparse rectangles on a full-size CLS canvas. Independent offline checks reconstructed all pixels, but the physical calibration did not print. Production encoding has therefore returned to full-width strips, including white rows and columns. The restored full-width app also later stalled in BLE readiness, so firmware rejection of sparse rectangles has not been established as the cause. Neither format has a verified device acknowledgement.

The [TSC programming manual](https://fs.tscprinters.com/system/files/31-0000001-00_tspl_tspl2_programming_3_0.pdf), BITMAP section, supplies independent coordinate, byte-width, row-height and overwrite-mode syntax; MUNBYN source supplies model-specific starting evidence. Neither substitutes for physical verification of polarity, direction, gap, bitmap padding or additional-feed behavior on this unit.

## BLE

Explicitly selected CoreBluetooth identifier and probed parent service/FFF2 are saved in a 0600 local file. Discovery has no service filter. Connection verifies that profile again; no name fallback, other-characteristic fallback, arbitrary MAC address, or silent switch. Actual properties choose without-response bulk streaming when both write properties are available, otherwise writes with response. A response-capable characteristic is required for the last existing data chunk of each page; write-without-response-only characteristics are rejected before print bytes. A saved explicit preference takes precedence and is never silently replaced. Chunk limit is the smaller of maximumWriteValueLength for the selected bulk mode and for with-response, capped at 256 bytes by default. The actual tested unit reports 182/512, leaving its 182-byte streaming segmentation unchanged. If a different unit reports a smaller response capacity, chunks are shortened without changing the concatenated bytes. Without-response writes wait for canSendWriteWithoutResponse and the ready callback. GATT write response is not a print-complete acknowledgement.

Default pacing is a 256-byte cap, 10 ms between writes and one second between pages. The selected device's actual limits can shorten each chunk. `pacing CHUNK,SECONDS` allows bounded per-run calibration (20–512 bytes, 1–200 ms). Measurements and failed physical attempts are summarized in [evidence.md](evidence.md); do not infer a latency guarantee from a faster test.

Operation timeouts: 10 seconds Bluetooth availability, 15 seconds connect/discovery/write/readiness; whole transmission 600 seconds on a monotonic clock, including preparation and final pacing/settling. No retry after a possible write. Saved `write-mode` is explicit per selected printer, with no unsupported-mode fallback. Without-response bulk uses readiness callbacks and bounded pacing.

For every page, the last existing chunk is sent with-response and its delegate result awaited before proceeding; it is not appended, duplicated or re-encoded. The connection remains owned through this callback, one-second final settling and final readiness check. Callback failure, timeout or cancellation after write intent remains outcome-unknown. A GATT response acknowledges the final request only; it cannot establish earlier best-effort delivery or paper output. Single-page physical results have passed, but reliable mixed-mode multipage operation still requires hardware verification. Printer-specific flow control, status, firmware identity and physical acknowledgements are not implemented/verified.

## Limits

- One receiving print connection at a time; listen backlog 2; loopback only.
- 64 MiB incoming bytes and 60 seconds to clean receive EOF.
- 32 raster source pages, at most 16 header copies, at most 64 final labels.
- Bitmap safety bound 832 × 1300; supported media dimensions must also match.
- 32 unfinished jobs, 128 MiB packed pending storage, 128 total metadata records.
- Control requests ≤4 KiB; wire lines ≤16 KiB; intended UID only.
- Opt-in captures: at most 32 jobs / 128 MiB; explicit deletion, never upload.
- Completed/cancelled job content deleted; terminal metadata retained up to 14 days / 64 records. Pending, failed and uncertain contents remain until explicit review/deletion.

## Timing diagnostics and background work

Each active job declares a scoped user-initiated process activity while allowing idle system sleep. This classifies requested printing work for macOS; it is not an idle BLE connection or a system-wide power setting. The activity ends when the task exits, including failure/cancellation. Sleep notifications still cancel and release; actual sleep/wake acceptance remains open. The absence of activity in earlier code made background scheduling a candidate for investigation, but it is not proof of the observed delay's cause.

`doctor`/`status` report aggregate metrics for the last attempt in the current app process: preparation, readiness, write calls, actual pacing sleeps, inter-page waits, sending-intent persistence and final settling. `submittedBytes` counts only calls that returned successfully; a failing call may still have affected the device. No count acknowledges physical printing. Transmission metrics also persist in each terminal job record, using the existing private bounded retention. Load/encoding, queue wait (wall-clock estimate), connecting and terminal persistence timings are process-local. These diagnostics record durations/counts, never raster/TSPL/document contents. Synchronous persistence and cooperative cancellation can delay the return past a deadline; the sender checks the remaining budget before new work and after awaits and cannot then report success. It does not return early while a child might still write.

## Final-chunk request policy

Apple's [cancelPeripheralConnection contract](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/cancelperipheralconnection(_:)) says that pending commands may or may not complete when the nonblocking cancellation is requested. A fixed delay alone cannot establish completion of the last data chunk. The bridge now waits for that chunk's GATT response before normal release; this removes the specific policy of releasing without that response. It does not claim to fix the observed mid-transfer readiness stalls, establish an atomic job protocol, or confirm physical printing. The [central-role guide](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/PerformingCommonCentralRoleTasks/PerformingCommonCentralRoleTasks.html) describes without-response delivery as best-effort. No undocumented reset, status probe, extra TSPL command or Phomemo flow-control assumption is added.

The current policy has passed single-page calibration, a scanned synthetic QR and normal Chrome output on the tested unit. Intermittent mid-transfer stalls also occurred before recovery. See the anonymous [validation summary](evidence.md) for software durations, physical confirmation and the remaining acceptance matrix.
