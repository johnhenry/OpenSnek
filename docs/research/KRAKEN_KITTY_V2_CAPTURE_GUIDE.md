# Capturing Synapse USB Traffic for the Kraken Kitty V2 (Windows)

The Kraken Kitty V2 (`USB VID 0x1532, PID 0x0560`) does not answer OpenRazer's legacy 37-byte Kraken protocol on macOS (see [KRAKEN_KITTY_V2_MACOS_TRANSPORT_FINDINGS.md](./KRAKEN_KITTY_V2_MACOS_TRANSPORT_FINDINGS.md)). Its HID report descriptor exposes undocumented channels that look like the device's real control protocol:

- **Report ID `0x01`**: 61-byte Output + 61-byte Input, observed returning live, changing data (challenge/handshake-shaped)
- **Report IDs `0x40` / `0x41`**: 12-byte Output / Input pair
- Report IDs `0x04` / `0x05`: the legacy-shaped pair, but descriptor-limited to 26/22 bytes and never populated on macOS

To decode the real protocol, capture what Razer Synapse actually sends on Windows while changing lighting settings, one setting at a time.

## Setup

Use a real Windows PC, or a Windows VM (Parallels/VMware/UTM) with the headset's USB device passed through to the guest. Bluetooth is not involved; this is wired USB.

1. Install [Wireshark](https://www.wireshark.org/) for Windows and enable the **USBPcap** component during installation. Reboot if prompted.
2. Install Razer Synapse (Synapse 3 or newer) and let it detect the Kraken Kitty V2. Note the exact Synapse and firmware versions it reports.
3. In Wireshark, capture on the **USBPcap** interface that shows traffic when you unplug/replug the headset. Apply the display filter after capture starts:

   ```text
   usb.device_address == <addr>
   ```

   Find `<addr>` by replugging the headset with capture running and looking at the `GET DESCRIPTOR` traffic carrying `idVendor 0x1532, idProduct 0x0560`.

## Capture protocol — one change per file

Save each scenario as its own `.pcapng`, named as below. Between scenarios, stop and restart the capture so files stay small and unambiguous. In a notes file, record the wall-clock time of every click.

| File | Scenario |
|---|---|
| `kitty2-00-replug-idle.pcapng` | Start capture, plug the headset in, Synapse **closed**, wait 30 s |
| `kitty2-01-synapse-launch.pcapng` | Start capture, launch Synapse, wait until the device page loads, wait 15 s (captures any handshake/auth on report `0x01`) |
| `kitty2-02-static-red.pcapng` | Synapse already open, set lighting to Static, pure red (`FF0000`) |
| `kitty2-03-static-green.pcapng` | Static, pure green (`00FF00`) |
| `kitty2-04-static-blue.pcapng` | Static, pure blue (`0000FF`) |
| `kitty2-05-brightness-50.pcapng` | Brightness 100% → 50% (if Synapse exposes it) |
| `kitty2-06-brightness-100.pcapng` | Brightness 50% → 100% |
| `kitty2-07-spectrum.pcapng` | Effect → Spectrum cycling |
| `kitty2-08-breathing-single.pcapng` | Effect → Breathing, one color (`FF0000`) |
| `kitty2-09-breathing-dual.pcapng` | Breathing, two colors (`FF0000`, `0000FF`) if available |
| `kitty2-10-off.pcapng` | Lighting off |
| `kitty2-11-synapse-quit.pcapng` | Quit Synapse, wait 15 s (captures any release/handoff) |

Red/green/blue as pure colors matter: the RGB byte positions become obvious when only one channel is nonzero.

## What to look for (and include in notes)

- Which report IDs carry the traffic (`0x01`? `0x40`? interrupt OUT vs control transfers?)
- Whether every session starts with the same exchange on report `0x01` (a handshake the implementation would need to replay)
- Whether color changes are single writes or sequences

## Delivering

Zip the `.pcapng` files plus your notes (Synapse version, firmware version, timestamps) and attach them to an OpenSnek issue referencing this document, or drop them under `captures/` in a PR per [captures/README.md](../../captures/README.md). Decoding and a macOS implementation can proceed from there — the transport side (opening the HID interface, report I/O) is already in-tree as `KrakenLegacyControlSession` and can be repointed at the discovered report IDs.
