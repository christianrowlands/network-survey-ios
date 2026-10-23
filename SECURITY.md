# Security policy

## Supported versions

Only the latest version of Network Survey for iOS is supported. Fixes go into
the next release; older versions are not patched. Please update to the latest
version before reporting.

## Reporting a vulnerability

If you find a security problem in the app, please report it privately:

- Use GitHub's private vulnerability reporting: the **Report a vulnerability**
  button on this repository's **Security** tab
  (`https://github.com/christianrowlands/network-survey-ios/security/advisories/new`).
- Include a description of the problem, the app and iOS versions, steps to
  reproduce, and any logs or screenshots (with private data removed).
- Do **not** disclose the problem publicly until a fixed version is released.

What to expect:

- Acknowledgment of the report within **96 hours**.
- Updates on the investigation and the plan for a fix.
- A fix in the next available release, and credit in the release notes if
  you want it.

Problems in the board firmware or the board protocol go to the firmware
repository's security policy.

## What the app protects

- **Survey data stays on the phone** unless the user sets up a destination.
  The app has no analytics or tracking, and sends nothing to its developers.
- **Credentials** (MQTT password, NS Analytics device token) are kept in the
  iOS Keychain, readable only on this device after its first unlock. They
  are deleted on the first launch after a reinstall.
- **Board link.** The app talks to boards only over an encrypted, bonded
  Bluetooth LE link, and reconnects on its own only to boards it has paired
  with.
- **Firmware updates.** Official board firmware is signed with Ed25519. The
  app verifies the release manifest and every image against the public keys
  built into it before sending an image to a board, and refuses a release
  below the `min_version` of releases it has already verified. Installing an
  unsigned file needs an explicit confirmation.
- **Streams.** MQTT uses TLS by default. gRPC is plain text by default, as in
  the Network Survey Android app; turn on TLS for servers outside a trusted
  network.

Reports about any of these, or about a way to make the app or a board behave
in a non-passive way, are especially welcome.
