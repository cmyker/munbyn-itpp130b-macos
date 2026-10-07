# Hardware acceptance procedure

Current observed results are in [evidence.md](evidence.md). This checklist defines acceptance procedures; it does not claim every test passed. Use synthetic documents. Never generate or purchase real shipping labels for testing. Any private document test needs explicit local approval and must not be captured for diagnostics, uploaded or committed.

Plan a small label budget before each hardware round. Start with dry runs, then one calibration and one QR page; reserve four more labels only when testing two pages with two copies. Failure/phone/lifecycle checks need their own agreed allowance. Count allocations separately from consumed stock, since a failed transfer may produce no paper or partial output. Do not resubmit merely because output is delayed.

Coverage is limited to macOS 15.7.9 / Apple Silicon, one ITPP130B and 100 × 150 mm stock. Tester-confirmed results include calibration, portrait/landscape PDFs, four-label collation, QR decoding, offline retry, interrupted-send recovery and Mac → phone → Mac. Current-policy single-page output also passed, but intermittent stalls and its full multipage/phone/lifecycle matrix remain open. See the validation summary for exact scope; physical 4 × 6 stock, geometry/margins and broader lifecycle behavior remain unverified.

| Test | Procedure / evidence required |
| --- | --- |
| Calibration | Settings → Printer → Print Test Label once; inspect frame/polarity, measure the 200 × 16-dot bar end-to-end and margins. The original one-row ruler was too faint on subsequent labels; thickening the diagnostic does not change print layout. Record physical stock, printed ruler length, native dot pitch and clipping. Do not equate nominal 203 dpi to 8 dots/mm without measurement. |
| System ingress | Open generated PDF in Chrome and Preview; Cmd+P, select display name and media. First dry-run each. Record actual connection/page count and header contract, then physical result. `lp` is a separate integration result. |
| Copies/orientation | Two identifiable source pages, two collated copies, landscape, exactly four labels in A/B/A/B order. Frame/text uncut, QR readable. Portrait single page separately. |
| Media | Repeat geometry with matching 4 × 6 stock only when available; no claim from conversion alone. Verify native width, margins, label feed and gaps. |
| Consecutive jobs | At least three synthetic jobs, sequential labels, no payload interleaving. Release callback after completion. |
| Off/busy | Submit while off; bounded failure before any bytes, no duplicate. Turn on then explicit retry. A phone connection is a possible cause of missing unit, not confirmed by the error. |
| Interrupted send | In a controlled synthetic job interrupt power/link mid-transmission. Unknown outcome blocks new jobs; no replay. Inspect partial paper, clear buffer by power-cycle, confirm recovery; explicit reprint duplicate warning. Record consumed labels separately. |
| Restart | Exit/kill before sending and during sending; restart preserves pending data and converts states conservatively. Never destroy unknown payload without confirmation. |
| Sleep/Bluetooth | Sleep/wake and toggle Bluetooth before/during a synthetic job. Check conservative unknown state, timeouts and no idle reconnect. |
| Phone coexistence | After Mac release, print one synthetic label with phone, disconnect phone, print from Mac again. No routine power-cycle should be needed. Record actual output and whether phone app held its own connection. |
| Login/lifecycle | Installed app permission allow and deny; start/login approval status; login/logout; app absent; duplicate instance; port conflict; admin authorization denial. No system service is promised. |
| Barcode | Scan a physically printed synthetic QR using a phone; decoded text must equal `MUNBYN-BRIDGE-SYNTHETIC-PAGE-1` or `MUNBYN-BRIDGE-SYNTHETIC-PAGE-2`. A rendered QR preview is insufficient. |

Record firmware only through a documented read/status interface or user-observed device label/app; do not probe undocumented write commands. Record BLE service/characteristic properties, selected mode, maximumWriteValueLength and measured pacing without publishing the peripheral identifier.

Before a new physical job after any interrupted command, inspect output and power-cycle: no verified TSPL reset protocol is available. Do not resume at arbitrary byte offsets. Native Print Center cannot cancel a bridge-owned job; bridge cancellation is required after handoff.
