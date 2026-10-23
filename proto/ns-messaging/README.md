# NS Messaging protos (copy)

The `.proto` files under `com/craxiom/messaging/` are an unmodified copy of the
protobuf definitions of the NS Messaging API 2.6.0, licensed under the Apache
License 2.0 (`LICENSE` in this folder; credited in the repository `NOTICE`). They are the
gRPC services the app streams to (`WirelessSurvey`, `DeviceStatus`,
`ConnectionHandshake`) and the messages those services import. The JSON
schema in the NS Messaging AsyncAPI document is the official format; the app's
JSON is written by `Packages/NSMessaging`, not from these files.

Regenerate the Swift messages and gRPC stubs in
`Packages/Destinations/Sources/Destinations/GRPC/Generated` with:

```sh
brew install protobuf
scripts/gen-ns-messaging-grpc.sh            # regenerate
scripts/gen-ns-messaging-grpc.sh --check    # fail if the generated code is stale
scripts/gen-ns-messaging-grpc.sh --sync path/to/network-survey-messaging/src/main/proto
```

`--sync` first copies the listed protos from an NS Messaging checkout.
