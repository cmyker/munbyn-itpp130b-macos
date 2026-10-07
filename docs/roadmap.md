# Development roadmap

The project is an experimental alpha. This roadmap describes current capabilities and acceptance work; it does not replace [validation evidence](evidence.md) or promise release dates.

## Implemented foundation

- Native SwiftPM menu-bar app and a CLI communicating with one owner process.
- Apple CUPS raster conversion, loopback socket ingress and a bounded system cupsRaster bridge.
- Separate 100 × 150 mm and 4 × 6 inch media, monochrome conversion and binary-safe full-width TSPL.
- Explicit BLE selection, mode-specific chunk limits, backpressure, pacing, final-chunk response and on-demand release.
- Private durable spool, serialized jobs, cancellation, restart recovery and conservative unknown outcomes.
- Compact status/recovery menu and native General/Printer/Advanced Settings window, including an explicit Start at Login checkbox with actual macOS approval state.
- Queue ownership checks, repair/removal actions, dry-run capture and diagnostics.
- Hardware-independent tests, native conversion checks, source-build packaging and CI.

Physical output has been tester-confirmed on one unit. The current implementation does not yet meet complete reliability acceptance.

## Priorities before a stable release

1. **Reliable BLE delivery.** Reproduce intermittent readiness stalls, distinguish host-stack and device behavior with bounded opt-in diagnostics, and validate any change using synthetic labels. A final GATT response alone cannot prove earlier best-effort delivery or paper output. Preserve conservative unknown-outcome handling.
2. **Acknowledged print ingress.** Replace the experimental socket path if native handoff/cancellation requirements cannot be satisfied. [ADR-001](architecture.md) evaluates compatible maintained PAPPL rather than a custom IPP server. Bundle only validated native dependencies with their licenses; keep one production ingress.
3. **Current-policy hardware matrix.** Repeat portrait/landscape, two pages with two copies, consecutive jobs, offline retry, interrupted transmission and Mac → phone → Mac. Verify margins and geometry on both media with matching stock and scan printed barcodes/QR codes.
4. **Lifecycle and packaging.** Exercise sleep/wake, Bluetooth changes, login/logout, installed permission denial, administrator denial and full uninstall. Validate minimum-version runtime coverage before claiming it. Consider Intel/universal packages only after build/dependency validation.
5. **Distribution.** Continue providing source-build instructions. Publish alpha artifacts only with accurate signing and test status. Developer ID signing/notarization requires explicit project configuration; stable releases require their advertised acceptance criteria to pass.

Use [AGENTS.md](../AGENTS.md) and [CONTRIBUTING.md](../CONTRIBUTING.md) when preparing a focused change. Update this roadmap and the validation summary as acceptance work is completed; keep examples and test reports generic and anonymous.
