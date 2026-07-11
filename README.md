# BambuCam

BambuCam is a native macOS companion for keeping an eye on a Bambu Lab printer from your menu bar. It shows the camera feed and print status, offers Picture in Picture, and puts the most useful controls close at hand.

BambuCam connects directly to the printer's private network address. It does **not** require the printer to be in LAN Only Mode just to view the camera or status. Some print commands are firmware-dependent; see [Printer commands](#printer-commands).

## Install

```sh
brew install NoahCLR/tap/bambucam
xattr -dr com.apple.quarantine /Applications/BambuCam.app
```

The `xattr` line is needed because BambuCam is signed but not notarized, so
Gatekeeper blocks the first launch of a quarantined copy — including after
every `brew upgrade`. Alternatively, launch it once and approve it under
System Settings → Privacy & Security → **Open Anyway**.

To build from source instead:

```sh
brew install xcodegen
git clone https://github.com/NoahCLR/BambuCam.git && cd BambuCam
scripts/install.sh --open
```

## What it does

- Live printer-camera view in a resizable window and the menu bar
- Native macOS Picture in Picture for the camera feed
- Print status: progress, current layer, time remaining, temperatures, and printer state
- Notifications for completion, failure, milestones, and a lost connection
- Chamber-light control
- Pause, resume, stop, and speed controls when the printer permits them
- One-click launch of a user-selected slicer such as Bambu Studio or OrcaSlicer
- Optional launch at login

## Requirements

- macOS 15 or later
- A Bambu Lab printer reachable from your Mac on the same private network
- The printer's private IPv4 address, access code, and serial number

BambuCam intentionally accepts only RFC 1918 IPv4 addresses such as `192.168.x.x`, `10.x.x.x`, or `172.16.x.x` through `172.31.x.x`. It does not accept printer hostnames, public IP addresses, or IPv6 addresses.

X1-series cameras stream over RTSP; this path is fully implemented and tested against protocol captures, but has not yet been verified against real X1 hardware — treat X1 camera support as experimental and report what you see.

## Set up a printer

1. Open **Settings** from BambuCam.
2. Enter a name, the printer's private IPv4 address, access code, and serial number.
3. Select **Pair Printer**.
4. BambuCam displays separate TLS fingerprints for the printer's MQTT and camera services. Confirm them only while you are connected to a network you trust.
5. Choose **Trust & Test Connection**. On success, the printer is saved and BambuCam starts connecting.

The first pairing is deliberate: it prevents BambuCam from silently trusting an unexpected device on your network. If a printer certificate later changes, BambuCam blocks the connection until you explicitly pair it again.

## Printer commands

The chamber light is available whenever the printer reports it.

Recent Bambu Lab firmware can reject pause, resume, stop, and speed changes from local apps unless **LAN Developer Mode** is enabled on the printer. In BambuCam, enable **LAN Developer Mode** under **Settings → Printer Commands** only after enabling the corresponding setting on the printer. Leave it off if you only want monitoring and light control.

## Menu bar and camera

The menu bar icon shows connection status; during an active print it can show progress. Open the menu to see a compact camera preview, current temperatures, print state, and controls.

In the main window you can:

- Click, scroll, pinch, or drag to zoom and pan the camera.
- Open Picture in Picture from the menu bar.
- Open your preferred slicer from the toolbar or menu bar.
- Reconnect after a printer or network change.

## Notifications

BambuCam asks for notification permission when it starts. Each notification type can be changed independently in **Settings**:

- Print finished
- Print failed
- Progress milestones at 25%, 50%, and 75%
- Printer unreachable for more than one minute

## Privacy and security

BambuCam is designed as a local-only client.

- It has no accounts, cloud sync, analytics, crash reporting, advertising, or update checks.
- Access codes and trusted TLS certificates are stored in the device-local macOS Keychain, not in the preferences file.
- Camera frames are displayed in memory only; BambuCam does not save or upload them.
- Connections are made only to the paired printer's private IPv4 address and must match the certificates accepted during pairing.

For the full policy, see [Privacy](docs/PRIVACY.md).

## Troubleshooting

### Pairing cannot find certificates

Check that the Mac and printer are on the same network, the address is the printer's private IPv4 address, and the printer is awake. BambuCam intentionally does not fall back to hostnames or public addresses.

### The connection is blocked after a printer update or reset

The printer may now present a different TLS certificate. Return to Settings and pair it again while on a trusted network.

### I can monitor the printer, but print controls are unavailable

Enable the matching **LAN Developer Mode** setting on the printer, then enable it in BambuCam's Settings. Monitoring and the chamber light do not depend on that toggle.

### The camera says “Waiting”

Use **Reconnect** and verify that the printer camera is enabled and reachable. BambuCam keeps the camera connection active only while a camera view or Picture in Picture is open.

## Releases and Homebrew

BambuCam releases are signed (not notarized — see [Install](#install)) macOS app bundles distributed through a Homebrew Cask. The release workflow is documented in [Releasing BambuCam](docs/RELEASING.md).

## Support

When reporting an issue, include the macOS version, printer model and firmware version, and a description of the behavior. Do not include your access code, serial number, TLS fingerprints, or camera images.

## License

MIT — see [LICENSE](LICENSE). BambuCam bundles [SwiftNIO](https://github.com/apple/swift-nio) and [SwiftNIO SSL](https://github.com/apple/swift-nio-ssl), both licensed under Apache License 2.0.
