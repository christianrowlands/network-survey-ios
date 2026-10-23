# Contributing

Thanks for helping with Network Survey for iOS. Bug reports, fixes, test
results with real boards and ideas are all welcome.

## Before you start

- **Bugs:** open an issue with the iPhone model, iOS version, app version
  (Settings > About), the board and its firmware version if one was involved,
  what you did, what you expected and what happened.
- **Feature ideas and larger changes:** open an issue first so we can agree
  on the approach. Network Survey aims to stay simple to use; not every good
  idea fits.
- **Security problems:** do not open a public issue. See
  [`SECURITY.md`](SECURITY.md).
- **Board firmware and the board protocol** live in the firmware repository
  (`network-survey-esp32`). Changes to `proto/ns_board.proto` start there.

## Ground rules

- **Passive and professional.** The app is a site survey tool. No features
  that make a board transmit Wi-Fi frames, crack or capture handshakes, or
  track people. No gamification.
- **No telemetry.** No analytics, crash reporting, ad or tracking SDKs.
- **Few dependencies.** Each new Swift package needs a good reason, an
  Apache-2.0 compatible license, and an exact version pin. Run
  `scripts/gen-licenses.sh` after changing dependencies so the in-app license
  list stays complete.
- **No real captures in the repository.** Test data must be synthetic. Use
  locally administered MAC addresses (for example `02:00:5E:xx:xx:xx`) and
  made-up network names such as `ExampleNet`.
- **Match the surrounding code.** Swift 6 with strict concurrency, SwiftUI,
  colors and fonts only from the design tokens in `NetworkSurvey/DesignSystem`.
  Production files should stay under about 400 lines.
- **Plain text.** UI copy and docs use short, direct sentences and no em
  dashes (`scripts/check-text.sh` checks this).
- **Formats stay compatible.** CSV files, MQTT topics and NS Messaging JSON
  match the Network Survey Android app. Changes to them need a matching
  change in [`docs/csv-formats.md`](docs/csv-formats.md), and usually in the
  Android app too.

## Building and testing

See the [README](README.md#building) for setup. Before you open a pull
request, run:

```sh
scripts/check-text.sh
for p in Packages/*/; do (cd "$p" && swift test); done
xcodegen generate
xcodebuild test -project NetworkSurvey.xcodeproj -scheme NetworkSurvey \
  -destination "$(scripts/sim-destination.sh)" -only-testing:NetworkSurveyTests
```

Most logic lives in the Swift packages under `Packages/`, which test on macOS
without a simulator. Put new logic there when you can, with tests. UI changes
should keep working with Dynamic Type and VoiceOver, in light and dark mode.

If you touched Bluetooth or board code, say in the pull request whether you
tested with the demo board only or with a real board (which one).

## Generated code

Do not edit generated files by hand:

- `Packages/BoardProtocol` Swift and `proto/ns_board.proto`: run
  `scripts/sync-proto.sh` against the firmware repository
  (see [`proto/README.md`](proto/README.md)).
- NS Messaging gRPC code: `scripts/gen-ns-messaging-grpc.sh`.
- Bundled license texts: `scripts/gen-licenses.sh`.
- Bluetooth SIG assigned numbers: `scripts/update-bluetooth-numbers.sh`.

`sync-proto.sh`, `gen-ns-messaging-grpc.sh` and `gen-licenses.sh` have a
`--check` mode that reports stale output; CI runs the first two.

## Settings

New settings go in `SurveyCore` with a key, type and default, and in
[`docs/settings-keys.md`](docs/settings-keys.md). Reuse the Network Survey
Android app's key name when the same setting exists there.

## Pull requests

- One topic per pull request, with a short description of what and why, and
  screenshots for UI changes.
- CI must pass.
- By contributing you agree that your contribution is licensed under the
  Apache License 2.0, the license of this project.
- Source files carry no per-file license headers; LICENSE and NOTICE cover the
  repository.
