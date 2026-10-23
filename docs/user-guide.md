# Network Survey for iOS: user guide

Network Survey records the Wi-Fi access points, Wi-Fi clients and Bluetooth LE
devices around you, each tagged with location. Because iOS cannot scan Wi-Fi,
the app uses a small ESP32 survey board as its radio. This guide covers
everything from pairing the board to getting the data out.

Contents:

1. [What you need](#what-you-need)
2. [Pairing a board](#pairing-a-board)
3. [Using several boards](#using-several-boards)
4. [Starting a survey](#starting-a-survey)
5. [While a survey runs](#while-a-survey-runs)
6. [Where the data goes](#where-the-data-goes)
7. [Looking at the data](#looking-at-the-data)
8. [Privacy controls](#privacy-controls)
9. [Updating board firmware](#updating-board-firmware)
10. [Troubleshooting](#troubleshooting)

## What you need

- An iPhone with iOS 18 or later.
- A survey board running the Network Survey firmware. An ESP32-C5 board is
  recommended, because it is the only supported chip that hears 5 GHz. The
  firmware repository lists the supported boards and has a web installer for
  the first install.
- No board yet? Open **Survey > Boards** and turn on **Demo board**. It is a
  simulated board with made-up data, so you can try every screen. Data from
  the demo board is never sent to NS Analytics.

The app asks for two permissions:

- **Bluetooth**, to talk to your board. It is asked the first time you open
  Boards.
- **Location (While Using)**, to place each record on the map. Allow
  **Precise** location; with approximate location the map is not useful. The
  app never asks for "Always": a survey you start keeps location running in
  the background until you stop it.

## Pairing a board

1. Power the board. Its LED gives a short blue blink every 2 seconds while it
   waits for a phone.
2. In the app, open **Survey** and tap **Boards** (or **Find boards** in the
   Still to do list).
3. Hold the board next to your iPhone. It appears under **Nearby** as
   `NS-XXXX`, where `XXXX` is its short ID (also shown by the web installer).
4. Tap the board. When iOS asks, tap **Pair**. The board moves to **Your
   boards** and its LED turns solid blue.

A board that has never been paired is always ready to pair. A board that
already has a phone is shown as **Paired with another phone** or **Not in
pairing mode**. To pair it with this iPhone, hold its **BOOT** button for about
3 seconds until the LED blinks cyan, then tap it within 60 seconds. A board
keeps one pairing: pairing a new phone replaces the old one.

After pairing, the app reconnects to the board on its own whenever it is in
range. You do not need to pair again.

Tap a board under **Your boards** to see its details: model, firmware version,
battery, GPS, what it is doing now, and its role. From there you can
**Connect** or **Disconnect** it, update its firmware, or **Forget this
board**.

**Forgetting a board** deletes the pairing on the board and in the app. iOS
keeps its own copy of the pairing, so to pair the board again later, also open
iOS **Settings > Bluetooth**, tap the info button next to the board and choose
**Forget This Device**.

## Using several boards

You can use up to four boards at once, for example two ESP32-C5 boards to
cover 2.4 and 5 GHz faster, or a third board just for Bluetooth. Pair each one
as above.

By default every board is on **Automatic**: the app splits the channels
between the boards, so each one hops fewer channels and misses less. When you
mix ESP32-C5 boards with 2.4 GHz-only boards, the 2.4 GHz boards take 2.4 GHz
and the ESP32-C5 boards take 5 GHz. With BLE on and two or more boards on
Automatic, one of them listens to Bluetooth full time.

To set a board's role yourself, tap its chip on the Survey screen or open its
details:

| Role | What the board does |
|---|---|
| Automatic | Shares the channels with your other boards. Recommended. |
| 2.4 GHz only | Hops the 2.4 GHz channels. |
| 5 GHz only | Hops the 5 GHz channels (ESP32-C5 boards). |
| One channel | Stays on one channel, so nothing on it is missed. |
| Bluetooth only | Listens to Bluetooth all the time, no Wi-Fi. |

Role changes apply right away, even during a survey.

## Starting a survey

The **Survey** tab is where a survey starts and stops.

**Still to do** lists anything that blocks a survey: Bluetooth off, no board
connected, location not allowed. Each item has a button that fixes it or takes
you to the right place.

**What should it survey?** Turn on what you want to record:

| Tile | Records | Default |
|---|---|---|
| Wi-Fi APs | Access points and their beacons | On |
| Wi-Fi Clients | Devices (stations) and their probe requests | On |
| BLE | Bluetooth Low Energy advertisements | Off |
| Raw frames | Raw 802.11 frames, saved to a pcapng file | Off |

Raw frames are limited by the board's Bluetooth link, so the pcapng file is a
sample of the traffic, not a full capture. They are only saved to files.

**Where should the data go?** Turn on one or more destinations: **Files**,
**MQTT**, **gRPC** and **NS Analytics**. A destination that is not set up yet
shows **Set up** (or **Connect** for NS Analytics). See
[Where the data goes](#where-the-data-goes).

A sentence under the sections says what Start will do, for example "Will save
Wi-Fi access points and clients to files on this iPhone." Then tap **Start
survey**.

What to survey and where the data goes are fixed for the length of a survey.
To change them, stop and start a new one.

## While a survey runs

The Survey screen shows:

- The elapsed time and the **Mission ID**, the survey's ID in every record and
  file (tap copy to copy it).
- A chip per board: its role and channels, the channel it is on now, battery,
  records per second and records lost.
- How many unique access points, clients and Bluetooth devices this survey
  has seen.
- A row per destination: whether files are saving, streams are connected,
  how many records are queued, and when NS Analytics last uploaded. **Upload
  now** sends the NS Analytics queue right away.

You can lock the phone and put it in a pocket. The survey keeps recording,
iOS shows the blue location indicator, and a Live Activity on the Lock Screen
and in the Dynamic Island shows the record count and board state. While the
Survey tab is open and the app is in front, the screen stays on.

If a board goes out of range, its chip shows **Reconnecting** and the app
reconnects when it comes back. The board keeps surveying and buffering in the
meantime, and the survey keeps the same Mission ID.

Tap **Stop**, then **Stop survey** to end it. If the app was closed while a
survey ran (for example the phone restarted), the Survey screen offers to
**Resume** it or **End it** the next time you open the app.

The app stops a survey by itself when the iPhone runs low on storage, and says
so on the Survey screen.

## Where the data goes

All data stays on your iPhone unless you set up a stream or an upload.

### Files

**Settings > Files.** **Save files on this iPhone** is on by default. Each
survey gets its own folder of files:

- Network Survey CSV files for Wi-Fi access points, Bluetooth, clients and
  probe requests (the Wi-Fi and Bluetooth files use the same format as the
  Network Survey Android app).
- A **WiGLE CSV** (on by default) in the WiGLE upload format. Rows without a
  location are left out.
- A pcapng file of raw frames, when **Raw frames** is on.

The **Files** tab lists the surveys with their files. Tap a file to preview
it, share one file or a whole survey, or delete a survey (which also removes
its map and list data). **Open in Files** opens the folder in the iOS Files
app, under **On My iPhone > Network Survey > Surveys**.

The columns of every file are described in [csv-formats.md](csv-formats.md).

### MQTT

**Settings > MQTT** streams records as NS Messaging JSON to an MQTT broker you
run, the same way the Network Survey Android app does.

- **Host** and **Port** (8883 by default), **TLS** (on by default), optional
  **Client ID** (the app picks one if empty), **Username** and **Password**.
- **Topic prefix** goes in front of every topic, for example `site1/`.
- Topics: `80211_beacon_message` (access points), `80211_probe_request_message`
  (probe requests), `bluetooth_message` and `device_status_message`.
- **Stream client records** (experimental) also sends Wi-Fi client records on
  `80211_station_message`, a proposed addition to NS Messaging.
- The queue holds records while the broker is unreachable (20,000 by default,
  0 means no limit) and sends them when the connection comes back. With no
  limit, the queue still holds at most 20,000 records until the broker is first
  reached in a survey, so a wrong host does not fill the phone.

A broker on your local network needs the Local Network permission, which iOS
asks for the first time.

### gRPC

**Settings > gRPC** streams records to a gRPC server that implements the NS
Messaging services (for example one built from the NS Messaging library).

- **Host** and **Port** (2621 by default), and **TLS** (off by default).
- The queue size set under MQTT also applies to gRPC.
- Access points, probe requests, Bluetooth and device status each go on their
  own stream. Client records are not sent over gRPC, because NS Messaging has
  no gRPC method for them yet.

### NS Analytics

NS Analytics is a web platform that puts surveys from every phone in a
workspace on one map. Uploading is optional and needs a workspace.

**To register this iPhone:**

1. In NS Analytics, a workspace admin creates a device registration QR code
   or link.
2. In the app, open **Settings > NS Analytics** (or tap **Connect** next to NS
   Analytics on the Survey screen).
3. Tap **Scan QR code** and point the camera at the code, or copy the link and
   tap **Paste**.
4. Confirm. The screen shows the workspace name and **Registered**.

**Uploading.** With **Upload to NS Analytics** on, records are queued on the
phone and uploaded every 15 minutes during a survey (you can pick another
interval, or **Only when a survey stops**), and again when the survey stops.
Uploads finish in the background. Records without a location are not
uploaded. If the phone is offline, records wait in the queue and go up later.

NS Analytics receives access points, Bluetooth devices and device status.
**Upload probe requests** and **Upload client records** are experimental: NS
Analytics does not store these yet, so leave them off unless you have been
asked to test them.

Surveys that use the demo board are never uploaded.

**Unregister this phone** stops uploads. Records that were not uploaded yet
stay on the phone and go up if you register again.

### Device name

**Settings > Device name** sets the name stamped on MQTT and gRPC records, so
you can tell phones apart on the server. By default it is `iPhone-` and four
characters from this install's ID.

## Looking at the data

- **Map** shows what the current survey (or one you pick from the title menu)
  has seen, at the place each one was strongest. Nearby markers group into
  clusters; tap a cluster to zoom in, or a marker to open its details. The
  options menu filters by type and band, shows your track, and edits privacy
  zones.
- **Lists** has tabs for access points, clients and Bluetooth devices, with
  search, sort (signal, last seen, frame count, name) and filters (band,
  security, hide randomized addresses).
- **Details** show everything known about one access point, client or
  Bluetooth device, a signal chart, and related devices (an access point's
  clients, a client's access points and the networks it probes for).

## Privacy controls

Network Survey records radio metadata such as network names and hardware
addresses. These controls help you keep out what you do not want. All of them
are off or empty until you set them up, and changes apply to a running survey
right away.

### Privacy zones

Nothing is recorded while you are inside a privacy zone, for example your home
or office. Records, your track and device status location are all left out.

- **To add a zone:** on the **Map**, open the options menu and choose **Edit
  privacy zones**, then long-press where the zone should be. Name it and set
  the radius (25 m to 2 km). You can also start from **Settings > Privacy
  zones**.
- Zones are checked against the phone's location fix, allowing for its
  accuracy: a record that might be inside a zone is dropped. Without a
  current fix, the last fix from the past 5 minutes decides.
- Zones apply to new records. They do not delete data recorded earlier.

### Ignore list

Networks and devices on the ignore list are never recorded or sent anywhere,
for example your own access points or phone.

- On a detail screen, tap **Ignore** and choose this access point (BSSID),
  every network with this name (SSID), or this device (MAC).
- Or add entries in **Settings > Ignore list**: an SSID (exact match, case
  sensitive), a BSSID, a MAC address, or a MAC prefix.

### Randomized MAC addresses

Most phones use a random, changing MAC address when they look for networks,
and many Bluetooth devices do the same. The app marks these with a
**Randomized** badge in the lists, and **Hide randomized addresses** in the
Lists filter hides them.

- For **clients**, randomized means a locally administered address.
- For **Bluetooth**, the badge is shown only for private random addresses,
  the kind that change over time.
- **Access points** never get the badge. A locally administered BSSID usually
  means a virtual access point (one radio serving several networks), and the
  details say so.

## Updating board firmware

Board firmware updates go over Bluetooth from the app.

1. Open **Survey > Boards**, tap the board, then **Update firmware**.
2. Tap **Check for update**. The app downloads the latest release and checks
   its signature.
3. If a newer version is available, tap **Install**. Keep the phone next to
   the board and the app open until it finishes (usually a minute or two);
   the screen stays on during the update.
4. The board restarts into the new firmware and the app reconnects.

Updates are not possible during a survey, or for the demo board. If the link
drops during an update, the app resumes where it left off; **Resume update**
continues after a failure. If the new firmware does not start properly, the
board goes back to its previous version by itself.

When the app says a board **Needs a firmware update**, the board speaks an
older protocol version than the app. Update it before surveying.

**Install firmware from file** (on the board's page) installs a firmware image
you have on the phone, for example a build of your own or a board that has no
official image. Choose the `.bin` file and, if you have it, its `.sig`. A file
without a valid signature can still be installed, but the app warns you and
asks you to confirm.

## Troubleshooting

**The board does not show under Nearby.**
- Check that it is powered and its LED blinks blue. Hold it within a few
  meters of the iPhone.
- A board that is connected to another phone does not advertise. Disconnect
  it there, or switch that phone's Bluetooth off.
- Check that Bluetooth is on (Control Center) and that Network Survey is
  allowed to use it (**Settings > Network Survey > Bluetooth**).

**"Paired with another phone" or "Pairing refused".** The board belongs to
another phone, or its pairing window closed. Hold the board's BOOT button for
about 3 seconds until the LED blinks cyan, then connect again within 60
seconds.

**"Forget the board in iOS Settings".** The board no longer has this iPhone's
pairing (it was forgotten, reflashed, or its pairings were deleted), but iOS
still has its half. Open iOS **Settings > Bluetooth**, tap the info button
next to the board, choose **Forget This Device**, then connect again in the
app. Pairing again without this step fails.

**Starting over with a board.** To delete every pairing on the board, power
it up, then within 5 seconds press and hold BOOT for about 10 seconds until
the LED flashes white. (Holding BOOT while the board powers up starts its
download mode instead; just power it up again.) Then forget the board in the
app and in iOS Settings, and pair again.

**Start is disabled.** The text above the button says why: no board
connected, nothing to survey, no destination turned on, or location not
allowed.

**Records are being lost.** A board chip shows records lost when the
Bluetooth link cannot keep up, usually because the phone is too far from the
board or the radio band is very busy. Keep the board close to the phone, turn
off **Raw frames** if you do not need them, or spread the work over more
boards.

**The map is empty or records are in the wrong place.** Check that location is
allowed with **Precise** on, and that the phone has a fix (the Survey screen
shows the location source and accuracy). Records made inside a privacy zone
are left out on purpose.

**MQTT or gRPC shows "Can't connect".** Check the host, port and TLS setting
(MQTT over TLS usually uses port 8883, plain MQTT 1883). For a server on your
local network, allow **Local Network** for Network Survey in iOS Settings.
Records are kept in the queue while the server is unreachable.

**NS Analytics shows "Not uploading" or "Paused".** The registration may have
been removed in NS Analytics (register again), or the workspace has reached
its upload limit (uploads resume at the time shown). Records stay queued on
the phone either way.

**The survey stopped by itself.** The iPhone ran low on storage. Free up space,
share and delete old surveys from the Files tab, and start again.
