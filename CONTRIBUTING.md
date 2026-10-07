# Contributing

Contributions from people and coding agents are welcome. Start with [README.md](README.md) for setup and [AGENTS.md](AGENTS.md) for the source map, commands and printing invariants. Review the [validation summary](docs/evidence.md) before choosing work; this project remains experimental.

Build with an Apple Swift 6 compiler on Apple Silicon macOS. For source changes, run `scripts/test.sh`, `scripts/integration-dry-run.sh` and `scripts/build-app.sh` before proposing a pull request. For documentation changes, verify links, commands, paths and claims against the current source. Tests use synthetic data and must not access BLE, request permission, install queues or change the default printer. CI must remain hardware independent.

Keep each pull request focused. Explain the problem, resulting behavior, checks actually run and remaining limitations. Link any relevant issue and update the affected architecture/protocol/validation documents. Describe public workflows generically and use anonymous test configurations.

Release packaging and publication checks are documented in [docs/releases.md](docs/releases.md). Packaging checks are safe for CI; installing/running the downloaded app and physical acceptance are separate tests. Downloads must remain prereleases while reliability acceptance is open.

Keep raster decoding, TSPL encoding, BLE transport and ingress/job management separate. State transitions must persist write intent before the first possible printer write. Never auto-replay uncertain work or infer device status from a generic successful write. Do not add characteristic/device fallback, retries after a possible write, Phomemo flow control, content cropping or unmeasured maximum-throughput pacing.

Provide independent expected-byte encoder fixtures and useful failure tests, rather than testing an encoder solely with a matching decoder. For hardware changes record OS/firmware where obtainable, procedure, label budget and observed paper result. Mark tester-confirmed and directly observed results separately. A BLE write/preview is not physical evidence. Do not broaden support to another model without an explicit decision and unit-specific protocol evidence.

Use English for source/docs/UI and MIT for original work. Keep dependency licenses and notices. Never redistribute vendor driver code. Keep upstream checkouts, real shipping labels, captures, device profiles and private test evidence outside this repository. Review all outgoing commits for secrets and personal data. Distribution is alpha until advertised acceptance tests pass; only explicitly configured signing identities may be used.
