# Third-party notices and provenance

Original bridge source is MIT licensed. It is independent and not affiliated with MUNBYN.

No source or binary implementation from these reference projects is copied into the application. Protocol/integration ideas and source observations informed the original implementation. Their complete MIT licenses are retained for attribution and any future reuse:

| Reference | Exact inspected commit | Relevant files | License / reuse |
| --- | --- | --- | --- |
| [sebadel/itpp130b-ble](https://github.com/sebadel/itpp130b-ble/tree/2da3089a2d01b9486b93ae2716118c75ef63042e) | `2da3089a2d01b9486b93ae2716118c75ef63042e` | `backend/ble`, `filter/ble_tspl`, `tests/test_tspl.py`, `ppd/Printer_ITPP130.ppd`, `setup.sh` | MIT; TSPL/FFF2 starting evidence, no code copied. [License](docs/third-party/itpp130b-ble-LICENSE) |
| [danielgormly/phomo](https://github.com/danielgormly/phomo/tree/96058e2f240824b526ba85245251bd479617c228) | `96058e2f240824b526ba85245251bd479617c228` | `Sources/phomo/JobServer.swift`, `CUPSRaster.swift`, `QueueInstaller.swift`, `BLE.swift`, `ppd/phomemo-m02-pro.ppd`, `HANDOFF.md` | MIT; raster-consuming PPD/loopback design reference, no code copied. [License](docs/third-party/phomo-LICENSE) |
| [Apple CUPS](https://github.com/apple-oss-distributions/cups/tree/2716564fcd1f5bf4cd4082279e97625a8f98204e) | `2716564fcd1f5bf4cd4082279e97625a8f98204e` | `cups/backend/socket.c`, `cups/cups/raster-stream.c` | Apache-2.0 with CUPS exceptions in NOTICE; license/notice retained under docs/third-party. Source inspection only. System libcups is dynamically linked, not redistributed or relicensed. This source snapshot is not asserted identical to the installed binary. |
| [PAPPL](https://github.com/michaelrsweet/pappl) | master `ccecfceec09ec4323abf091746f59feaa927865d`; stable v1.4.12 `4f6a8d87dde5ab99d33abe172f767e6db1beb20d` | `configure.ac`, `pappl/job.c`, `pappl/job-ipp.c`, README | Apache-2.0 with optional linking exceptions in NOTICE; stable license/notice retained under docs/third-party; evaluated, not bundled or implemented. Stable supports the installed CUPS version. |

Apple AppKit, CoreBluetooth, Security, ServiceManagement and Swift runtime are system dependencies. The app does not bundle Homebrew libraries, Python, Node, Linux BLE components, or proprietary vendor filters. The original C bridge uses public system header declarations; no CUPS parser code was copied.

The [TSC TSPL/TSPL2 programming manual](https://fs.tscprinters.com/system/files/31-0000001-00_tspl_tspl2_programming_3_0.pdf), BITMAP section (printed pages 67–69), supplies independent binary command framing evidence. It is not included or relicensed and does not prove the behavior of MUNBYN firmware.

The locally installed proprietary USB filter was used for a stdout-only synthetic diagnostic comparing its normal and 180-degree TSPL direction commands. No print backend was invoked. Its code, binaries and captured payloads are not copied, bundled or redistributed, and the bridge's build or normal printing does not require that driver.
