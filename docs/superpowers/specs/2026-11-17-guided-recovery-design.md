# Guided printing recovery

The existing recovery actions do not provide a clear self-service route out of a retained unknown outcome. Restart intentionally preserves that uncertainty; clearing history cannot bypass it. Implement the already-required conservative recovery rules as one guided action.

## Approach

Use **Recover Printing…** in the menu when work needs attention, and always in Settings → Printer. It combines existing cancellation, recovery and clearing responsibilities in the single owner process. Keeping scattered per-job controls leaves the current usability problem. Automatically discarding uncertain work on restart violates duplicate protection. A guided, explicitly confirmed reset is the suitable approach.

## Flow and boundaries

1. Opening the action does nothing. A warning explains that pending bridge jobs and this user's jobs in the project CUPS queue will be cancelled/discarded; earlier output may exist.
2. Starting persists a recovery pause before stopping ingress/transmission, releases the BLE link, and cancels only current-user jobs in the ownership-verified project queue on localhost:631. Wait for in-flight work to stop. Failure leaves a visible, durable recovery pause and any remaining records; deletion can partially complete.
3. If any interrupted transmission has an unrecovered unknown outcome, clearly ask the operator to inspect the paper and turn the printer off and on. Closing the prompt leaves the pause and records intact; reopening resumes the flow.
4. Explicit completion acknowledges the physical reset when required, checks native pending work again, recreates the app's BLE client without connecting, deletes bridge job records through existing spool protections, restores loopback ingress, and finally clears the durable pause. No old job is replayed. Starting again is safe after a partial failure or app restart.

Preserve the selected printer, media/write preferences, capture intent, login registration, USB/default printer and unrelated queues. No system Bluetooth toggle, daemon restart, privileged reset, automatic test print or unverified TSPL reset command. Ordinary file deletion is not secure erasure. A raw socket handoff still has the documented native handoff/cancellation windows; recovery does not make it transactional or fix the underlying BLE stall.

## Validation

Use real temporary spools/state files and injected external operations to cover pause-before-stop, restart, interruption, unrecovered outcomes, explicit clearing, failures and idempotency. Test fixed queue/user-scoped cancellation argv and bounded child execution without touching real printer queues. Test Settings entry/action and menu visibility without an owner or BLE. Run all project checks. Inspect the installed recovery flow; separately verify one fresh synthetic print after recovery with an explicit additional one-label allocation.
