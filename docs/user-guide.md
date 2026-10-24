# Network Survey for iOS: user guide

Network Survey records the Wi-Fi access points, Wi-Fi clients and Bluetooth LE
devices around you, each tagged with location. Because iOS cannot scan Wi-Fi,
the app uses a small ESP32 sensor called NS Scout as its radio. This guide covers
everything from pairing the Scout to getting the data out.

Contents:

1. [What you need](#what-you-need)
2. [Pairing a Scout](#pairing-a-scout)
3. [Using several Scouts](#using-several-scouts)
4. [Starting a survey](#starting-a-survey)
5. [While a survey runs](#while-a-survey-runs)
6. [Where the data goes](#where-the-data-goes)
7. [Looking at the data](#looking-at-the-data)
8. [Privacy controls](#privacy-controls)
9. [Updating Scout firmware](#updating-scout-firmware)
10. [Troubleshooting](#troubleshooting)

## What you need

- An iPhone with iOS 18 or later.
- An NS Scout: an ESP32 board running the Network Survey firmware. An
  ESP32-C5 board is recommended, because it is the only supported chip that
  hears 5 GHz. [networksurvey.app/scout](https://networksurvey.app/scout)
  says what to buy and how to install the firmware the first time. In the app,
  **Survey > Scouts > New to NS Scout?** walks through the same steps.
- No Scout yet? Open **Survey > Scouts** and turn on **Demo Scout**. It is a
  simulated Scout with made-up data, so you can try every screen. Data from
  the demo Scout is never sent to NS Analytics.

The app asks for two permissions:

- **Bluetooth**, to talk to your Scout. It is asked the first time you open
  Scouts.
- **Location (While Using)**, to place each record on the map. Allow
  **Precise** location; with approximate location the map is not useful. The
  app never asks for "Always": a survey you start keeps location running in
  the background until you stop it.

## Installing the Scout software

A new board needs the Scout software once. On a computer with Chrome or Edge,
go to <https://install.networksurvey.app/>, plug the board in with a USB data
cable, and click **Install** for your board. Later updates install from the app
over Bluetooth. Where to buy a board: <https://networksurvey.app/scout>.

## Pairing a Scout

1. Power the Scout. Its LED gives a short blue blink every 2 seconds while it
   waits for a phone.
2. In the app, open **Survey** and tap **Scouts** (or **Find Scouts** in the
   Still to do list).
3. Hold the Scout next to your iPhone. It appears under **Nearby** as
   `NS-XXXX`, where `XXXX` is its short ID (also shown by the web installer).
4. Tap the Scout. When iOS asks, tap **Pair**. The Scout moves to **Your
   Scouts** and its LED turns solid blue.

A Scout that has never been paired is always ready to pair. A Scout that
already has a phone is shown as **Paired with another phone** or **Not ready
to pair**. To pair it with this iPhone, hold its **BOOT** button for about
3 seconds until the LED blinks cyan, then tap it within 60 seconds. A Scout
keeps one pairing: pairing a new phone replaces the old one.

After pairing, the app reconnects to the Scout on its own whenever it is in
range. You do not need to pair again.

Tap a Scout under **Your Scouts** to see its details: model, firmware version,
battery, GPS, what it is doing now, and its role. From there you can
**Connect** or **Disconnect** it, update its firmware, or **Remove Scout**.

**Removing a Scout** stops the app from connecting to it. Both the Scout and
the iPhone keep their pairing, so it shows under **Nearby** as **Used with this
iPhone before** and you can add it back with one tap, without pairing again.

**Erase pairings on the Scout** (under Advanced, while connected) makes the
Scout forget every phone. You only need it before giving a Scout away for good:
to pair it with another phone, holding BOOT for 3 seconds is enough. iOS keeps
its own copy of the pairing and apps cannot remove it, so after an erase the
app walks you through **Settings > Bluetooth > Forget This Device**.

## Using several Scouts

You can use up to four Scouts at once, for example two ESP32-C5 Scouts to
cover 2.4 and 5 GHz faster, or a third Scout just for Bluetooth. Pair each one
as above.

By default every Scout is on **Automatic**: the app splits the channels
between the Scouts, so each one hops fewer channels and misses less. When you
mix ESP32-C5 Scouts with 2.4 GHz-only Scouts, the 2.4 GHz Scouts take 2.4 GHz
and the ESP32-C5 Scouts take 5 GHz. With BLE on and two or more Scouts on
Automatic, one of them listens to Bluetooth full time.

To set a Scout's role yourself, tap its chip on the Survey screen or open its
details:

| Role | What the Scout does |
|---|---|
| Automatic | Shares the channels with your other Scouts. Recommended. |
| 2.4 GHz only | Hops the 2.4 GHz channels. |
| 5 GHz only | Hops the 5 GHz channels (ESP32-C5 Scouts). |
| One channel | Stays on one channel, so nothing on it is missed. |
| Bluetooth only | Listens to Bluetooth all the time, no Wi-Fi. |

Role changes apply right away, even during a survey.

## Starting a survey

The **Survey** tab is where a survey starts and stops.

**Still to do** lists anything that blocks a survey: Bluetooth off, no Scout
connected, location not allowed. Each item has a button that fixes it or takes
you to the right place.

**What should it survey?** Turn on what you want to record:

| Tile | Records | Default |
|---|---|---|
| Wi-Fi APs | Access points and their beacons | On |
| Wi-Fi Clients | Devices (stations) and their probe requests | On |
| BLE | Bluetooth Low Energy advertisements | Off |
| Raw frames | Raw 802.11 frames, saved to a pcapng file | Off |

Raw frames are limited by the Scout's Bluetooth link, so the pcapng file is a
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

- The elapsed time and the **Mission ID**, the survey's ID in every record, in
  your CSV files and in NS Analytics (tap copy to copy it). It is "NS", this
  iPhone's 8-character ID and the start time, for example
  `NS 12FE3A4B 20261023-140300`.
- A chip per Scout: its role and channels, the channel it is on now, battery,
  records per second and records lost.
- How many unique access points, clients and Bluetooth devices this survey
  has seen.
- A row per destination: whether files are saving, streams are connected,
  how many records are queued, and when NS Analytics last uploaded. **Upload
  now** sends the NS Analytics queue right away.

You can lock the phone and put it in a pocket. The survey keeps recording,
iOS shows the blue location indicator, and a Live Activity on the Lock Screen
and in the Dynamic Island shows the record count and Scout state. While the
Survey tab is open and the app is in front, the screen stays on.

If a Scout goes out of range, its chip shows **Reconnecting** and the app
reconnects when it comes back. The Scout keeps surveying and buffering in the
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

Surveys that use the demo Scout are never uploaded.

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

### Crash reports

App Store builds send a report to the developers when the app crashes or
hangs, so the bug can be fixed. Unlike the controls above, this is on until
you turn it off: **Settings > Send crash reports**.

- A report holds the app version, the iPhone model and iOS version, and what
  the app's code was doing. It never includes survey data, location, network
  names, addresses, screenshots or anything about you.
- Reports go to Sentry, a crash reporting service. Builds made from the
  source code send nothing, and there the switch is not shown.

## Updating Scout firmware

Scout firmware updates go over Bluetooth from the app.

1. Open **Survey > Scouts**, tap the Scout, then **Update firmware**.
2. Tap **Check for update**. The app downloads the latest release and checks
   its signature.
3. If a newer version is available, tap **Install**. Keep the phone next to
   the Scout and the app open until it finishes (usually a minute or two);
   the screen stays on during the update.
4. The Scout restarts into the new firmware and the app reconnects.

Updates are not possible during a survey, or for the demo Scout. If the link
drops during an update, the app resumes where it left off; **Resume update**
continues after a failure. If the new firmware does not start properly, the
Scout goes back to its previous version by itself.

When the app says a Scout **Needs a firmware update**, the Scout speaks an
older protocol version than the app. Update it before surveying.

**Install firmware from file** (on the Scout's page) installs a firmware image
you have on the phone, for example a build of your own or a Scout that has no
official image. Choose the `.bin` file and, if you have it, its `.sig`. A file
without a valid signature can still be installed, but the app warns you and
asks you to confirm.

## Troubleshooting

**The Scout does not show under Nearby.**
- Check that it is powered and its LED blinks blue. Hold it within a few
  meters of the iPhone.
- A Scout that is connected to another phone does not advertise. Disconnect
  it there, or switch that phone's Bluetooth off.
- Check that Bluetooth is on (Control Center) and that Network Survey is
  allowed to use it (**Settings > Network Survey > Bluetooth**).

**"Paired with another phone" or "Pairing refused".** The Scout belongs to
another phone, or its pairing window closed. Hold the Scout's BOOT button for
about 3 seconds until the LED blinks cyan, then connect again within 60
seconds.

**"Pair this Scout again" or "Pairing lost".** The Scout no longer has this
iPhone's pairing (it was reinstalled, its pairings were erased, or it was
paired with another phone), but iOS still has its half. The app notices this
as soon as the Scout is nearby. Tap **Show me how**: it lists the steps
(**Settings > Bluetooth**, the info button next to the Scout, **Forget This
Device**) and connects the Scout again on its own when you come back to the
app. iOS does not let apps remove a pairing themselves.

**Starting over with a Scout.** To delete every pairing on the Scout, power
it up, then within 5 seconds press and hold BOOT for about 10 seconds until
the LED flashes white. (Holding BOOT while the Scout powers up starts its
download mode instead; just power it up again.) Then connect it in the app
and follow **Show me how** to forget it in iOS Settings.

**Start is disabled.** The text above the button says why: no Scout
connected, nothing to survey, no destination turned on, or location not
allowed.

**Records are being lost.** A Scout chip shows records lost when the
Bluetooth link cannot keep up, usually because the phone is too far from the
Scout or the radio band is very busy. Keep the Scout close to the phone, turn
off **Raw frames** if you do not need them, or spread the work over more
Scouts.

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
