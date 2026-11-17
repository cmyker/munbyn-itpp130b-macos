# Guided Recovery Implementation Plan

> For agentic workers: use superpowers:executing-plans inline, with one independent review before integration. Tasks use TDD and sensible commits.

**Goal:** Make a stuck bridge safely repairable through one guided in-app recovery action.
**Architecture:** Durable recovery pause and real spool policy in BridgeCore; native queue and BLE/ingress operations remain in the single app owner; presentation reuses Settings actions and confirmations.
**Tech Stack:** SwiftPM, Swift/AppKit, system CUPS tools and CoreBluetooth; no new runtime.
**Spec:** ../specs/2026-11-17-guided-recovery-design.md

## Global constraints

- macOS 13 target; one explicitly selected ITPP130B and logged-in user.
- Preserve USB/default/unrelated queues, profile and settings. Only ownership-verified MUNBYN_ITPP130B_Bluetooth on localhost:631 may be cancelled, scoped to the current user's jobs.
- Unknown work is never automatically replayed or deleted before explicit buffer-recovery confirmation. Persist pause before stopping; retain pause on failure/restart.
- No Bluetooth access, queue mutations or login registration in automated tests. Keep captures/identifiers/private documents out of Git.

## Review focus

- Closing or restarting midway must not resume pending jobs.
- Failure to stop an active sender must not allow clearing or a competing BLE owner.
- Native CUPS environment overrides/unowned queues/other users must not broaden cancellation.
- Active TCP input must not commit a stale job across recovery.
- Final listener/connection reset failure must remain retryable and visibly paused.

### Task 1: Durable recovery policy

**Files:** Sources/BridgeCore/PrintingRecovery.swift; Tests/BridgeCoreTests/RecoveryTests.swift.
**Consumes:** real Spool and PrivateFiles; a private state URL.
**Produces:** @MainActor PrintingRecovery(spool:stateURL:), isPaused, needsPrinterRestart() throws -> Bool; begin(stop:cancelNative:) async throws; finish(printerRestarted:prepare:resume:) async throws. Hooks are nonescaping async throwing Void closures.

- [ ] Write failing tests for pause-before-stop, reopen-after-cancel/restart, unknown acknowledgement, failure retention and idempotent completion.
- [ ] Run scripts/test.sh --filter RecoveryTests. Expected: missing recovery behavior.
- [ ] Implement persist-first begin and guarded finish; never invoke external operations in init.
- [ ] Run scripts/test.sh. Expected: all tests pass. Commit policy and tests.

### Task 2: Safe owner and native operations

**Files:** QueuePlan.swift; Sockets.swift; BoundedCommand.swift; QueueRecovery.swift; Coordinator.swift; BLE.swift; QueueTests.swift; SocketTests.swift; native command tests.
**Consumes:** Task 1 recovery policy and hooks.
**Produces:** QueuePlan.cancelPending(existing:user:) and pendingQuery(user:) argv; BoundedCommand.run(executable:arguments:timeout:); QueueRecovery.cancelPending() throws; SocketListener.isStopped; BLEPrinter.resetConnection() async throws; Coordinator recovery-begin/recovery-finish commands and persistent process/ingress pause.

- [ ] Write failing argv, process timeout/output and stop/rebind tests. Verify no real queue/BLE use.
- [ ] Run focused tests. Expected: missing behavior.
- [ ] Implement fixed localhost:631/current-user/project-queue commands; ownership preflight, bounded execution; await sender/listener stop, fresh BLE client without connect, guarded ingress restore.
- [ ] Run scripts/test.sh. Expected: all tests pass. Commit operations and tests.

### Task 3: Guided recovery presentation

**Files:** RecoveryModel.swift; RecoveryWindow.swift; Menu.swift; SettingsModel.swift; SettingsWindow.swift; CLI help; UI tests.
**Consumes:** recovery-begin returns paused/needsPrinterRestart; recovery-finish requires confirmation and explicit restart acknowledgement when needed.
**Produces:** Recover Printing action in issue menu and Settings, with warning/start/physical-reset/finish/completed stages; closing retains safe pause and reopening continues.

- [ ] Write failing model and entry-point tests with injected command responses; opening/refreshing must issue no commands.
- [ ] Run focused tests. Expected: missing flow/actions.
- [ ] Implement guided flow; leave errors resumable and never auto-reprint or erase profile/preferences.
- [ ] Run scripts/test.sh. Expected: all tests pass. Commit UI and tests.

### Task 4: Verification, installed check and publication

**Files:** README.md, AGENTS.md, docs/evidence.md, docs/protocol.md, docs/releases.md and release version fields.
**Consumes:** complete recovery flow and reviewed source.
**Produces:** accurately labelled alpha source/artifacts and evidence, preserving known BLE/socket limitations.

- [ ] Run all three project checks. Expected: success, with no hardware/queue mutation.
- [ ] Independent whole-branch review and address findings.
- [ ] Inspect installed recovery flow; allocate one additional synthetic label to verify fresh print after recovery. Do not infer paper from callbacks.
- [ ] Audit outgoing source/history and publish only reviewed source and accurately labelled alpha artifacts; verify downloads/CI. Do not claim the radio stall fixed by this workflow.
