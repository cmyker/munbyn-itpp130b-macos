# Architecture and decision record ADR-001

Decision (2026-10-06): implement one experimental AppSocket ingress, keeping raster/encoder/BLE separate. It is a useful small native proof, **not yet an accepted reliable version-one system printer**. Important acceptance tests remain open.

```
Chrome / Preview / lp
  → Apple's CUPS PDF processing and cgpdftoraster
  → original PPD: application/vnd.cups-raster, no custom filter
  → stock socket backend
  → 127.0.0.1:19100
  → libcups raster API + bounded monochrome conversion
  → validated private durable spool
  → serialized TSPL jobs
  → on-demand selected CoreBluetooth peripheral
```

The running logged-in user's menu app is the only BLE owner. The CLI uses a 0600 AF_UNIX socket within the user's 0700 Application Support directory and checks peer UID. No privileged control channel is exposed on the print TCP port. No launch daemon, system-wide service, printer sharing, or protected-volume installation.

## Actual socket behavior and its limits

The installed Apple socket backend was exercised directly with synthetic cgpdftoraster output. It connects, streams bytes, shuts down its write side, waits for peer EOF, and exits. TCP reads are arbitrary fragments. A write-side EOF at an exact raster page boundary completes one incoming connection/job. One connection may contain many pages. The listener validates all pages and persists payload + queued state before returning/closing. It never interprets idle time as a successful boundary.

Neither EOF nor a successful backend write is a durable application acknowledgement. TCP does not carry a CUPS ID, document title, selected printer identifier, or an authenticated sender. Bridge UUIDs describe only local records. The backend's wait-for-EOF result does not set its transmitted-byte count negative: closing or resetting a stream after a validation error can still produce native CUPS completion. Native Print Center cannot cancel a job already handed to this app. Use the menu's Jobs actions for that stage.

Crash windows:

| Point | Local state / owner | Consequence |
| --- | --- | --- |
| Before connection | CUPS owns job; stock backend retries | Starting the app may allow delivery. No BLE bytes. On this Mac the timeout URI hint did not bound retries; cancel in Print Center if needed. |
| Receiving, before durable queued record | CUPS still has its own spool; bridge has no accepted job | Native completion can still occur if bridge exits/rejects after backend sends all bytes. Potential loss requires user review/resubmission. |
| Durable queued record, before native completion | Bridge owns a valid deferred job; CUPS may still consider its copy pending | A manual/native replay can create a second intentional-looking job. No document-hash deduplication. |
| Connecting, before sending intent | Durable record; no printer writes | Restart converts to failed-before-send; explicit safe retry. |
| Sending intent or any possible BLE write | Printer may hold or print partial data | Restart/error/cancel becomes outcome-unknown. All further BLE jobs stop. No automatic replay. |
| BLE API writes finish | Transmitted, no physical acknowledgement | Completion in the bridge means transmission only. Paper still needs verification. |

`printer-error-policy=abort-job` prevents CUPS scheduler retries after backend failure; it does not make EOF transactional or override the backend's own preconnection retries. The bridge is the sole retry owner after durable handoff. Review/cancel a native pending copy before manually retrying/reprinting in the bridge. Never retry an unknown result in both places.

Actual negative backend tests: a truncated raster was rejected by the bridge while the backend exited **zero**. With no listener on a synthetic unused loopback port, the installed backend kept retrying past **45 seconds** despite `contimeout=5`; the test then terminated it. It reported EINPROGRESS, for which the inspected reference source's retry branch omits the timeout check. Therefore the URI option is a hint, not a promised five-second failure bound. Native cancellation remains available before handoff. These observed limits strengthen the case for maintained IPP before a reliable stable version.

## Is socket sufficient?

It proves a low-dependency pipeline and can support routine successful printing once hardware is calibrated. It cannot meet acknowledged job handoff, reliable validation-error propagation to Print Center, or cancellation after handoff. These limits are material and documented. Therefore this project remains experimental; it does not claim complete reliability acceptance is met. Hardware failure observations may justify replacing this single ingress.

A maintained local IPP printer application was evaluated: PAPPL master at `ccecfceec09ec4323abf091746f59feaa927865d` and stable v1.4.12 at `4f6a8d87dde5ab99d33abe172f767e6db1beb20d`. `pappl/job-ipp.c` implements Print-Job/Send-Document, job-state reporting and cancellation; `pappl/job.c` manages spool files. This supplies native job identity/control. Master requires libcups 3 or CUPS 2.5, but **stable 1.4.12 supports CUPS 2.2+ and therefore the installed 2.3.4**. Its configure script requires a TLS implementation (OpenSSL, LibreSSL or GnuTLS); JPEG, PNG and USB dependencies are optional. Bundling a maintained compatible native dependency set, retaining its licenses, and testing Apple CUPS clients is a feasible next step. No PAPPL binaries or second ingress have been built. The socket proof remains experimental; acknowledged handoff and native cancellation are reasons to replace it with the stable IPP implementation before declaring the full reliability goal achieved.

## Lifecycle

Jobs run serially with pages in raster order; no parallel BLE writes. Each complete job releases the link. Manual Connect releases after ten seconds. Scanning and selection never print. Sleep requests cancellation/release; a possible write remains unknown. Wake only processes safely queued work; failed and unknown work require review. App exit keeps pending/unknown data. A filesystem lock prevents two instances. Port conflicts fail explicitly without killing another process. No idle reconnect loop. Mac → phone → Mac paper output was tester-confirmed without a routine power-cycle. After one controlled transmission crash, unknown-outcome blocking and a post-power-cycle reprint with duplicate-risk confirmation were verified, with tester-confirmed paper count and QR. Installed duplicate-process refusal and login registration/unregistration were tested; actual login/logout and sleep/wake remain acceptance tasks. No protocol reset acknowledgement is implemented.

## Review fixes

Capture/print intent is stored with each accepted job; the capture preference also persists. Restart cannot convert a capture into BLE printing. Capture quota/I/O errors retain source payload in failed-before-send. Local shutdown and durable acceptance use one listener lock so locally induced EOF cannot commit a partial-page sequence. The worker retains listening-descriptor ownership until exit. Queue reads use an explicit local IPP client request (not a new server) and distinguish not-found from inspection failure; all mutations pin the same localhost:631 endpoint. Terminal payload deletion is finished on restart if a crash occurs after the terminal state write.
