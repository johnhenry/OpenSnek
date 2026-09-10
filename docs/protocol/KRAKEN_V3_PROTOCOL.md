# Razer Kraken V3 (`0x40`) Lighting Protocol — validated on Kraken Kitty V2 (`0x0560`)

This documents the lighting protocol the **Razer Kraken Kitty V2 White Edition** (USB `1532:0560`) actually speaks, established by hardware validation (2026-09) on Linux. It is **not** the legacy 37-byte Kraken memory-poke protocol (see [KRAKEN_LEGACY_PROTOCOL.md](./KRAKEN_LEGACY_PROTOCOL.md)); this unit ignores that entirely. It is the newer "V3" single-command protocol OpenRGB implements in `RazerKrakenV3Controller`, and it matches a Synapse USB capture of this exact PID posted in [openrazer/openrazer#2157](https://github.com/openrazer/openrazer/issues/2157).

## Report framing

- **HID Output report, report ID `0x40`.** The device declares report `0x40` as a 12-byte Output report (13 bytes including the report-ID byte). OpenRGB pads to a 15-byte buffer (`report_id + command_id + arguments[13]`); both 13- and 15-byte buffers were accepted.
- Delivered as a USB `SET_REPORT` (`bmRequestType 0x21`, `bRequest 0x09`, `wValue 0x0240`, `wIndex 0x0003` = interface 3). On Linux this is what a `write()` to the device's `hidraw` node produces (interface 3 has only an interrupt-IN endpoint, no OUT, so the kernel uses a control `SET_REPORT`).
- Byte layout: `[0]=0x40 (report id)`, `[1]=command_id`, `[2]=arguments[0]`, `[3..]=arguments[1..]`.

## Commands (validated)

| Purpose | Bytes (report id + command + args) | Notes |
|---|---|---|
| Enter direct mode | `40 01 00 0F 08` | `command_id 0x01` (SET_MODE), `arguments[1]=0x0F`, `arguments[2]=0x08` (mode-id DIRECT). **Must precede a color write.** |
| Set color (all LEDs) | `40 03 00 RR GG BB` | `command_id 0x03` (SET_COLOR), `arguments[0]=0x00`, then R,G,B at `arguments[1..3]`. |
| Brightness | `40 02 00 00 VV` | `command_id 0x02` (SET_BRIGHTNESS), `arguments[2]=VV` (0x00–0xFF). `VV=0x00` is fully off. |
| Spectrum / color-cycle | `40 01 00 0F 03` | SET_MODE with mode-id `0x03` (OpenRGB calls this "wave"; on this headset it renders as a full-spectrum cycle). |

RGB order is R,G,B (validated: red, green, blue, white all correct).

## Behaviors observed on the Kitty V2 White Edition

- **Single logical zone.** OpenRGB's device model lists 4 LEDs / 3 zones ("Headset Left", "Headset Right", "Cat ears"), but on this unit every ring LED mirrors one color: multi-LED `SET_COLOR` frames (13- and 15-byte) and a legacy 4-LED custom frame all lit the whole device with the first color. Treat it as one zone.
- **Breathing not reachable.** OpenRGB's V3 `SetModeBreathing` frame produced no breathing on this unit; only static/spectrum/brightness/off were reproducible.
- Direct-mode color must be preceded by the mode-direct command in the same session.

## Validated capability set (for an implementation)

Off, static color, brightness (0–255), and spectrum/color-cycle. Everything here was confirmed repeatably on Linux with unambiguous visual changes (including brightness 0 → fully dark).

## Transport requirement — critical for macOS

This protocol was validated over Linux's `hidraw` path. **It does not currently work on macOS through OpenSnek's HID APIs** — see [../research/KRAKEN_KITTY_V2_MACOS_TRANSPORT_FINDINGS.md](../research/KRAKEN_KITTY_V2_MACOS_TRANSPORT_FINDINGS.md). Apple's `IOHIDFamily` owns interface 3; `IOHIDDeviceSetReport` returns success but the reports never reach the device, and device-level `IOUSBDeviceInterface` control transfers stall on the color/brightness commands. A macOS implementation needs a driver that claims interface 3 (see [KRAKEN_KITTY_V2_DRIVERKIT_SCOPE.md](../research/KRAKEN_KITTY_V2_DRIVERKIT_SCOPE.md)).
