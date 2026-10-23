# Survey file formats

A survey session writes its files into its own folder (`Documents/Surveys/<yyyyMMdd-HHmmss>/`,
visible in the Files app). File names carry the session start time in local time. A file is
created when the first record of its kind arrives, so a session without BLE has no Bluetooth file.

| File | Contents | Format |
|---|---|---|
| `craxiom-wifi-<time>.csv` | Wi-Fi access points (one row per AP per channel dwell) | NS CSV Wi-Fi 0.4.0 |
| `craxiom-bluetooth-<time>.csv` | BLE advertisers (one row per address per scan window) | NS CSV Bluetooth 0.3.0 |
| `craxiom-wifi-client-<time>.csv` | Wi-Fi clients (stations) | NS CSV client 0.1.0 |
| `craxiom-wifi-probe-<time>.csv` | Wi-Fi probe requests | NS CSV probe 0.1.0 |
| `craxiom-wigle-<time>.csv` | APs and BLE devices for upload to WiGLE | WigleWifi-1.6 |
| `craxiom-wifi-raw-<time>.pcapng` | Raw 802.11 frames (only with "Raw frames" on) | pcapng, radiotap |

## NS CSV conventions

All NS CSV files follow the Network Survey Android app:

- UTF-8, CRLF line endings, fields quoted only when needed (a field that is empty in the first
  column, starts with a character up to `#` such as a space or `!`, ends with a space, or holds a
  comma, quote or line break). Quotes inside a field are doubled.
- Two comment lines, then the header row:

  ```
  # Created by Network Survey iOS version=1.0.0
  # CSV Version=0.4.0
  deviceTime,latitude,longitude,...
  ```

- Column names are the NS Messaging API field names.
- `deviceTime` is RFC 3339 with the phone's offset, millisecond precision, trailing zeros
  dropped (`2026-10-22T14:03:07.12-05:00`).
- `latitude` and `longitude` have six decimals; `altitude`, `speed` and `accuracy` have up to two
  (rounded up). Without a location they read `0.000000` and `0`.
- `signalStrength`, `snr` and `txPower` are dBm or dB with one decimal (`-48.0`).
- Lists (cipher suites, AKM suites, service UUIDs, frame types) are joined with `;`.
- An empty cell means the value is unknown or was not reported. `locationAge` (milliseconds) is
  empty when unknown.
- Wi-Fi MAC addresses are lowercase, Bluetooth addresses uppercase.

### Wi-Fi 0.4.0 and Bluetooth 0.3.0

Same columns, order and formatting as the Android app's `craxiom-wifi-` and
`craxiom-bluetooth-` files, so existing tools read both. The iOS app also fills Wi-Fi columns the
Android app leaves empty because Android does not expose them: `serviceSetType`, `supportedRates`,
`extendedSupportedRates`, `akmSuites` and `nodeType`.

`encryptionType` uses the NS Messaging values. OWE (Enhanced Open) has no NS value and reads
`UNKNOWN`; enterprise networks read `WPA2` or `WPA3` and are told apart by `akmSuites`
(`IEEE_8021X` and related values). The WiGLE file's `AuthMode` column has the full detail, for
example `[RSN-OWE-CCMP][ESS]`.

### Client 0.1.0

One row per client MAC address per channel dwell. Only frames the client sent are counted, so the
signal describes the client.

| Column | Meaning |
|---|---|
| `deviceTime` ... `recordNumber` | As in the Wi-Fi file (`recordNumber` counts client rows). |
| `sourceAddress` | Client MAC address. |
| `bssid` | The access point the client is associated with or talking to, empty if unknown. |
| `channel`, `frequencyMhz` | Where the frames were received. |
| `signalStrength` | Strongest frame of the dwell, dBm. |
| `snr` | `signalStrength` minus the receiver noise floor, dB, if the board reports it. |
| `frameCount` | Frames received from the client in the dwell. |
| `frameTypes` | Frame types seen: `DATA`, `NULL_DATA`, `PROBE_REQUEST`, `ASSOCIATION_REQUEST`, `REASSOCIATION_REQUEST`, `AUTHENTICATION`, `ACTION`. |
| `locallyAdministered` | `true` when the MAC has the locally administered bit set (usually a randomized MAC). |
| `boardId` | The sensor board that captured the frames. |
| `deviceSerialNumber`, `locationAge` | As in the Wi-Fi file. |

### Probe 0.1.0

One row per client MAC address and requested SSID per channel dwell.

| Column | Meaning |
|---|---|
| `deviceTime` ... `recordNumber` | As in the Wi-Fi file (`recordNumber` counts probe rows). |
| `sourceAddress` | The probing client's MAC address. |
| `destinationAddress`, `bssid` | Address 1 and address 3 of the last request (broadcast or a specific AP). |
| `ssid` | The requested network name, empty for a wildcard probe. |
| `channel`, `frequencyMhz`, `signalStrength`, `snr` | As in the client file. |
| `standard` | Newest 802.11 standard the client advertised (`IEEE80211N`, `IEEE80211AC`, ...), `UNKNOWN` for legacy clients. |
| `probeCount` | Requests received in the dwell. |
| `locallyAdministered` | As in the client file. |
| `boardId`, `deviceSerialNumber`, `locationAge` | As in the client file. |

## WiGLE

`WigleWifi-1.6` with the standard pre-header and the 14 columns `MAC,SSID,AuthMode,FirstSeen,
Channel,Frequency,RSSI,CurrentLatitude,CurrentLongitude,AltitudeMeters,AccuracyMeters,RCOIs,MfgrId,Type`
(LF line endings). `FirstSeen` is UTC. BLE rows use `Misc [LE]` as AuthMode, the advertised name as
SSID and the decimal Bluetooth company ID as `MfgrId`. Latitude and longitude have six decimals.
Rows without a location are left out.
`[MFPR]`/`[MFPC]` are never written because the board does not report the RSN capabilities.

## pcapng

One Section Header Block, one Interface Description Block per board (link type 127, IEEE 802.11
with radiotap, interface name = board ID, microsecond timestamps) and one Enhanced Packet Block per
frame. The radiotap header is made from the board's receive data: Flags (FCS present), Rate (legacy
frames), Channel (frequency and band), antenna signal, antenna noise when known, and MCS for HT
frames. Open the file in Wireshark or read it with `tshark`. Radiotap has no 6 GHz channel flag, so
6 GHz frames carry the 5 GHz flag with their real frequency, and VHT, HE and EHT frames carry no
rate field.
