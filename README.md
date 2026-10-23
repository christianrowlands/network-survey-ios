<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/img/ns-lockup-dark.svg">
  <img src="docs/img/ns-lockup-light.svg" alt="Network Survey" width="280">
</picture>

# Network Survey for iOS

A Wi-Fi and Bluetooth LE site survey app for iPhone. Walk or drive a site, and
Network Survey records the access points, Wi-Fi clients and Bluetooth devices
it hears, each tagged with location. Log the data to files, stream it to your
own MQTT broker or gRPC server, or upload it to NS Analytics. It is the iPhone
sibling of the Network Survey Android app, with the same file formats and the
same NS Messaging records.

Simple to use, your data your way. No account, no analytics, no tracking.

## Why an external board

iOS has no API for scanning Wi-Fi networks, and it hides the real addresses of
Bluetooth devices from apps. So Network Survey uses a small ESP32 board as its
radio. The board listens passively and sends summaries to the phone over
Bluetooth LE; the phone adds location and does everything else.

The board is receive-only: it never transmits Wi-Fi frames (no probing, no
deauthentication, no injection). Its firmware, the web installer and the board
protocol are in the firmware repository:
[network-survey-esp32](https://github.com/christianrowlands/network-survey-esp32).

No board yet? Turn on the **Demo board** (Survey > Boards) to try every screen
with simulated data.

## Features

- **What it records**
  - Wi-Fi access points from their beacons: SSID, BSSID, channel and width,
    security (including AKM and cipher suites), Wi-Fi generation, signal
  - Wi-Fi clients and their probe requests, with the networks they are
    connected to or looking for
  - Bluetooth LE advertisements (off by default)
  - Raw 802.11 frames into a pcapng file for Wireshark (off by default)
- **Where the data goes** (each optional, chosen before you start)
  - CSV files in the Network Survey formats, plus a WiGLE CSV and pcapng,
    in the Files app
  - MQTT and gRPC streaming in NS Messaging format, as in the Android app
  - Upload to an NS Analytics workspace, registered with a QR code or link
- **On the phone:** a survey screen with live counts per board and
  destination, a map with clustered markers and your track, searchable
  lists, and detail pages with signal history
- **Several boards:** up to four boards at once. The app splits the channels
  between them automatically, or you set each board's role.
- **Privacy controls:** privacy zones where nothing is recorded, an ignore
  list, and a badge and filter for randomized MAC addresses
- **Keeps going in your pocket:** a survey keeps recording with the screen
  locked, with a Live Activity on the Lock Screen and Dynamic Island
- **Location:** from the phone, or from a GPS receiver on the board
- **Board firmware updates** over Bluetooth, with signed releases

Data stays on the iPhone unless you turn on a stream or an upload. The full
walkthrough is in the [user guide](docs/user-guide.md).

## Supported boards

| Board | Bands | Status |
|---|---|---|
| Espressif ESP32-C5-DevKitC-1 | 2.4 and 5 GHz | Tested |
| Seeed Studio XIAO ESP32-C5 | 2.4 and 5 GHz | Supported, not yet tested on hardware |
| Espressif ESP32-C6-DevKitC-1 | 2.4 GHz | Supported, not yet tested on hardware |
| Espressif ESP32-S3-DevKitC-1 | 2.4 GHz | Supported, not yet tested on hardware |
| Espressif ESP32-C3-DevKitM-1 | 2.4 GHz | Supported, not yet tested on hardware |

An ESP32-C5 board is recommended, since it is the only one that hears 5 GHz.
Install the firmware from the browser with the web installer, then pair the
board in the app. See the firmware repository's README and hardware guide.

## Building

Requirements:

- macOS with Xcode 27.1 or later (Swift 6, strict concurrency). The app
  targets iOS 18.0.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
  The Xcode project is generated from `project.yml` and not checked in.

```sh
xcodegen generate
open NetworkSurvey.xcodeproj
```

The simulator needs no setup and has the demo board. To run on an iPhone (a
real board needs one; the simulator has no Bluetooth), copy
`Config/Local.xcconfig.example` to `Config/Local.xcconfig` (gitignored), set
`DEVELOPMENT_TEAM` to your team ID, and set `NS_BUNDLE_ID` to a bundle
identifier of your own.

Swift packages are pinned in each `Package.resolved`. The app has no
analytics, crash reporting or ad SDKs.

## Running tests

```sh
# Swift packages (run on macOS)
for p in Packages/*/; do (cd "$p" && swift test); done

# App unit tests, then UI tests, on an iOS simulator
xcodebuild test -project NetworkSurvey.xcodeproj -scheme NetworkSurvey \
  -destination "$(scripts/sim-destination.sh)" \
  -only-testing:NetworkSurveyTests
xcodebuild test -project NetworkSurvey.xcodeproj -scheme NetworkSurvey \
  -destination "$(scripts/sim-destination.sh)" \
  -only-testing:NetworkSurveyUITests
```

`scripts/sim-destination.sh` picks an iPhone simulator on the newest installed
iOS runtime. Any iPhone simulator works; to choose one, pass
`-destination 'platform=iOS Simulator,name=<simulator name>'` instead.

The MQTT tests in `Packages/Destinations` start a private `mosquitto` broker
(`brew install mosquitto`) and skip themselves without one. CI
([`.github/workflows/ios.yml`](.github/workflows/ios.yml)) runs the package
tests, the app unit tests, `scripts/check-text.sh` and the generated-code
checks.

`scripts/e2e.sh` runs the end-to-end survey test: two simulated boards over the
Bluetooth transport, every destination on, against local servers from
`Tools/E2EHarness` (a mosquitto broker, an NS Messaging gRPC server and an NS
Analytics stub). It checks that the counts on screen, in the database, in the
files and at each server agree, and validates the pcapng with `tshark`. It
needs mosquitto, Wireshark's command line tools and xcodegen;
`E2E_DESTINATION` picks the simulator (by default the one
`scripts/sim-destination.sh` picks).

## Demo board and BoardCLI

The demo board is a simulated board built into the app (Debug and Release). It
produces a synthetic walk with made-up access points, clients and Bluetooth
devices, so every screen and destination can be tried without hardware. Data
from it is never sent to NS Analytics.

`Tools/BoardCLI` is a macOS command line tool that talks to boards with the
same `BoardKit` code the app uses, over the Mac's Bluetooth or the simulator:

```sh
cd Tools/BoardCLI
swift run boardcli scan                         # boards advertising nearby
swift run boardcli pair NS-ABCD                 # pair and remember a board
swift run boardcli stream NS-ABCD --seconds 30  # survey and print rates, gaps, drops
swift run boardcli stream --sim 2 --seconds 5   # two simulated boards
```

`swift run boardcli` with no arguments prints every command.

## Project layout

| Path | Contents |
|---|---|
| `NetworkSurvey/` | The SwiftUI app: `App/` (composition and services), `Screens/`, `DesignSystem/` (every color, font and spacing token), `Resources/` |
| `NetworkSurveyLiveActivity/`, `Shared/` | Live Activity widget extension and the views it shares with the app |
| `Packages/BoardProtocol` | Generated board protocol messages and BLE framing |
| `Packages/BoardKit` | Board transports (CoreBluetooth and simulated), `BoardManager`, channel planning, firmware updates |
| `Packages/SurveyCore` | Survey sessions, the on-device database, privacy filters, settings |
| `Packages/NSMessaging` | NS Messaging records and their JSON form |
| `Packages/Destinations` | CSV, WiGLE, pcapng, MQTT, gRPC and NS Analytics outputs |
| `Tools/BoardCLI` | macOS command line tool for boards |
| `Tools/E2EHarness` | Local servers for the end-to-end test (`scripts/e2e.sh`) |
| `proto/` | Copy of the board protocol (`ns_board.proto`) and the NS Messaging protos |
| `scripts/` | Code generation, proto sync, license and text checks |
| `docs/` | User guide, file formats, settings keys |

## Documentation

- [User guide](docs/user-guide.md): pairing, surveying, destinations, privacy,
  firmware updates, troubleshooting
- [Survey file formats](docs/csv-formats.md): CSV, WiGLE and pcapng
- [Settings keys](docs/settings-keys.md): every stored setting, with defaults
- [Board protocol copy](proto/README.md): how the protocol stays in sync with
  the firmware repository

## Contributing

Bug reports and pull requests are welcome. Read
[`CONTRIBUTING.md`](CONTRIBUTING.md) first. To report a security problem, see
[`SECURITY.md`](SECURITY.md).

## License

Apache License 2.0. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
Third-party licenses are listed in the app under Settings > Open-source
licenses.
