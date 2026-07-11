# Privacy

BambuCam is a local-only printer client.

- It does not include analytics, crash reporting, accounts, cloud sync, advertising, or update checks.
- It sends printer commands, status requests, and camera authentication only to the private IPv4 address that the user enters and pairs.
- Before an access code is ever sent, the user must explicitly accept the displayed MQTT and camera TLS fingerprints. Future connections require the exact pinned certificates.
- Printer access codes and certificate pins are stored only in the macOS Keychain with `AfterFirstUnlockThisDeviceOnly` accessibility. They do not synchronise through iCloud.
- `~/Library/Application Support/BambuCam/config.json` contains non-secret preferences only and is written owner-readable only (`0600`) inside an owner-only directory (`0700`).
- Camera frames are held in memory for display and Picture in Picture; BambuCam does not write or upload them.

Homebrew is separate software. Its optional anonymous installation analytics are governed by Homebrew's own settings and privacy documentation.
