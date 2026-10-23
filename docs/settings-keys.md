# Settings keys

Every setting the app stores, with its key, type and default. The keys are the names a future managed configuration layer (MDM AppConfig, `com.apple.configuration.managed`) would use to override a value; that layer is not implemented yet. Where the Network Survey Android app has a managed configuration key for the same setting, the iOS key uses the same name.

Plain settings live in `UserDefaults` (`SettingsStore`, `Settings` in SurveyCore). Secrets live in the Keychain (generic passwords, service `app.networksurvey.settings`, readable after first unlock on this device only, so a locked phone keeps surveying). Numbers and booleans may also be stored as strings ("8883", "true"), as a managed configuration dictionary may deliver them. A value of the wrong type, or outside the documented range, reads as the default. Keychain items outlive app deletion, so on the first launch of a fresh install the stored credentials (MQTT password, gRPC token, NS Analytics token) are deleted; the install ID is kept.

## What to survey

| Key | Type | Default | Notes |
|---|---|---|---|
| `survey_wifi_ap` | Bool | true | Access point (beacon) records |
| `survey_wifi_client` | Bool | true | Client (station) and probe request records |
| `survey_ble` | Bool | false | Bluetooth LE advertisements |
| `survey_raw_frames` | Bool | false | Raw 802.11 frames for pcapng |

## Where the data goes

| Key | Type | Default | Notes |
|---|---|---|---|
| `destination_log_files` | Bool | true | NS CSV files |
| `destination_mqtt` | Bool | false | |
| `destination_grpc` | Bool | false | |
| `destination_ns_analytics` | Bool | false | |
| `log_wigle_csv` | Bool | true | Also write a WiGLE CSV (with file logging) |

## MQTT

| Key | Type | Default | Notes |
|---|---|---|---|
| `mqtt_connection_host` | String | "" | |
| `mqtt_connection_port` | Int | 8883 | 1 to 65535 |
| `mqtt_tls_enabled` | Bool | true | |
| `mqtt_client_id` | String | "" | Empty: the app picks one |
| `mqtt_username` | String | "" | |
| `mqtt_password` | Secret | none | Keychain |
| `mqtt_topic_prefix` | String | "" | Prepended to every topic |
| `streaming_queue_limit` | Int | 20000 | Records held while MQTT or gRPC is disconnected; 0 means unbounded (MQTT still holds at most 20,000 until the broker is first reached in a survey); not negative |
| `mqtt_stream_client_records` | Bool | false | Experimental: station records on the proposed topic |

## gRPC

| Key | Type | Default | Notes |
|---|---|---|---|
| `grpc_connection_host` | String | "" | |
| `grpc_connection_port` | Int | 2621 | 1 to 65535 |
| `grpc_tls_enabled` | Bool | false | |
| `grpc_auth_token` | Secret | none | Keychain, optional |

## NS Analytics

| Key | Type | Default | Notes |
|---|---|---|---|
| `ns_analytics_api_url` | String | "" | Upload endpoint from the registration QR code or link |
| `ns_analytics_workspace_id` | String | "" | From registration |
| `ns_analytics_workspace_name` | String | "" | From registration, for display |
| `ns_analytics_upload_interval_minutes` | Int | 15 | Upload while surveying every N minutes; 0 means only when the survey stops; at most 1440 |
| `ns_analytics_device_token` | Secret | none | Keychain |
| `ns_analytics_upload_probe_records` | Bool | false | Experimental |
| `ns_analytics_upload_client_records` | Bool | false | Experimental |

## Device

| Key | Type | Default | Notes |
|---|---|---|---|
| `device_name` | String | "" | Empty: "iPhone-" plus the first 4 hex digits of the install ID (for example "iPhone-12FE"). Stamped as `deviceName` on MQTT and gRPC records |
| `device_status_scan_interval_seconds` | Int | 120 | DeviceStatus interval while surveying, 10 to 86400 |
| `install_id` | Secret | generated | Per-install UUID used as `deviceSerialNumber` and in the missionId. Not overridable |

## Location, display, privacy

| Key | Type | Default | Notes |
|---|---|---|---|
| `location_provider` | String | `phone` | `phone`: phone location, board GPS when the phone fix is missing, older than 10 s or worse than 50 m. `board`: board GPS, phone as fallback |
| `display_units` | String | `metric` | `metric` or `imperial` |
| `privacy_zones` | JSON array | [] | `[{"id", "name", "center": {"latitude", "longitude"}, "radiusMeters"}]`. Records and track points that may be inside (distance minus the fix's accuracy within the radius) are never stored. Without a current fix the last fix up to 5 minutes old decides. Stored in UserDefaults, which is included in device backups |
| `ignore_list` | JSON array | [] | `[{"id", "kind", "value", "note"}]`, kind `ssid` (exact, case-sensitive), `bssid`, `mac` or `macPrefix` |

## Advanced

| Key | Type | Default | Notes |
|---|---|---|---|
| `demo_board_enabled` | Bool | false | Show the simulated Demo board |

Protocol and destination settings are read once when a survey starts and stay fixed until it stops. Privacy zone and ignore list changes apply to a running survey right away.
