# Board protocol (copy)

`ns_board.proto` is a copy of the board protocol definition from the firmware
repository (`network-survey-esp32`, `proto/ns_board.proto`), which is the
source of truth. Its `docs/protocol.md` describes the GATT layout, framing and
flows. Do not edit the copy here.

To update the copy, the test fixtures, and the generated Swift in
`Packages/BoardProtocol`:

```sh
brew install protobuf
scripts/sync-proto.sh [path/to/network-survey-esp32]   # default: ../network-survey-esp32
scripts/sync-proto.sh --check                          # fails if anything is stale
```
