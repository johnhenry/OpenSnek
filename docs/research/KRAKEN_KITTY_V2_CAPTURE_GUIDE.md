# Capturing Kraken Kitty V2 USB traffic

The Kraken Kitty V2 (`USB VID 0x1532, PID 0x0560`) has a contributor-validated
[V3 report-`0x40` lighting protocol](../protocol/KRAKEN_V3_PROTOCOL.md) on Linux.
The remaining investigation is macOS delivery; the earlier report-`0x01`
handshake theory is superseded. See the [transport findings](KRAKEN_KITTY_V2_MACOS_TRANSPORT_FINDINGS.md).

## Linux: capture a working baseline first

Capture the device's USB bus with `usbmon` from enumeration through a known-working
lighting change. Preserve all transfers in the raw capture, including setup
requests and interrupt reads; apply display filters during analysis.

1. Record the device PID, firmware if available, Linux/kernel version, and the
   exact script or tool revision used to send commands.
2. Start capture before attaching the headset and record an idle baseline.
3. Send direct mode followed by a distinct static color, then brightness zero.
   Record timestamps and what a person actually sees; API success alone is
   insufficient. Restore the original lighting after the test.
4. Save the full capture and correlate each command with its `SET_REPORT`
   setup fields, report length, interface number, and completion status.
5. Compare initialization traffic as well as the lighting writes with the
   macOS attempts. Do not assume interface ownership is the only difference.

## Windows: capture Synapse behavior

Use a Windows capture to investigate additional effects, initialization, or
differences from the working Linux sequence, one setting at a time.

### Setup

Use a real Windows PC, or a Windows VM (Parallels/VMware/UTM) with the headset's USB device passed through to the guest. Bluetooth is not involved; this is wired USB.

1. Install [Wireshark](https://www.wireshark.org/) for Windows and enable the **USBPcap** component during installation. Reboot if prompted.
2. Install Razer Synapse (Synapse 3 or newer) and let it detect the Kraken Kitty V2. Note the exact Synapse and firmware versions it reports.
3. In Wireshark, capture on the **USBPcap** interface that shows traffic when you unplug/replug the headset. Apply the display filter after capture starts:

   ```text
   usb.device_address == <addr>
   ```

   Find `<addr>` by replugging the headset with capture running and looking at the `GET DESCRIPTOR` traffic carrying `idVendor 0x1532, idProduct 0x0560`.

### Capture protocol — one change per file

Save each scenario as its own `.pcapng`, named as below. Between scenarios, stop and restart the capture so files stay small and unambiguous. In a notes file, record the wall-clock time of every click.

| File | Scenario |
|---|---|
| `kitty2-00-replug-idle.pcapng` | Start capture, plug the headset in, Synapse **closed**, wait 30 s |
| `kitty2-01-synapse-launch.pcapng` | Start capture, launch Synapse, wait until the device page loads, wait 15 s to capture initialization |
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

### What to look for (and include in notes)

- Which report IDs carry the traffic (`0x01`? `0x40`? interrupt OUT vs control transfers?)
- Which initialization exchanges precede the first working color or brightness write
- Whether color changes are single writes or sequences

## Delivering

Zip the `.pcapng` files plus your notes (OS/tool versions, firmware version,
timestamps, and visual results) and attach them to an OpenSnek issue referencing
this document, or add them under `captures/` in a PR per
[captures/README.md](../../captures/README.md). OpenSnek does not yet have a
working Kraken macOS transport; a capture informs that work without implying
the legacy protocol scaffolding can control this device.
