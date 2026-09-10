# Kraken Legacy USB Protocol Documentation

This document describes the legacy Razer Kraken headset USB HID protocol used by
`OpenSnekProtocols/KrakenLegacyProtocol.swift` and
`OpenSnekHardware/KrakenLegacyControlSession.swift`. It is a distinct protocol
from [USB_PROTOCOL.md](./USB_PROTOCOL.md): Kraken headsets running this legacy
firmware generation expose only a single consumer-control USB HID interface, not
the 90-byte Razer control interface every other profile in
[PARITY.md](./PARITY.md) relies on, so they cannot speak the shared class/cmd
protocol at all.

> **Status**: this document, and the protocol module it describes, are a
> best-effort placeholder pending hardware validation. The byte layout below is
> derived from public reverse-engineering references (see
> [References](#references)), not a capture against real hardware. Anywhere the
> implementation diverges from a spike's findings, look for a
> `PARENT-MERGE` comment in the source.

## Table of Contents

- [Overview](#overview)
- [Report Structure](#report-structure)
- [Address Map](#address-map)
- [LED Mode / Effect Encoding](#led-mode--effect-encoding)
- [Serial Number](#serial-number)
- [Transport Notes](#transport-notes)
- [Device-Specific Notes](#device-specific-notes)
- [References](#references)

---

## Overview

Unlike the class/cmd command protocol used by Razer mice and keyboards, this
generation of Kraken firmware exposes a flat, addressable EEPROM/RAM space.
Requests read or write a run of bytes at a 16-bit address; there is no
class/cmd/transaction-ID envelope. `KrakenLegacyProtocol` (in `OpenSnekCore`'s
sibling package `OpenSnekProtocols`) builds and parses these reports; it has no
IOKit dependency, so it is unit-testable without hardware.

| Connection | Vendor ID | Product ID | Protocol Support |
|------------|-----------|------------|------------------|
| USB Cable | `0x1532` | `0x0560` (Kraken Kitty V2) | Lighting only |

## Report Structure

Both requests and the input-report responses use HID report ID `0x04`
(`KrakenLegacyProtocol.reportID`). A full request is **37 bytes including the
leading report-id byte** (`KrakenLegacyProtocol.requestLength`); responses are
**33 bytes** (`KrakenLegacyProtocol.responseLength`).

```
Offset  Size  Field              Description
------  ----  -----              -----------
0       1     Report ID          0x04 (dropped before IOHIDDeviceSetReport; see Transport Notes)
1       1     Command            0x81 = EEPROM read, 0x01 = RAM read, 0x02 = RAM write
2-3     2     Address            Big-endian 16-bit EEPROM/RAM address
4       1     Length             Requested/written byte count
5-36    32    Payload            Write payload (RAM writes only); zero-padded otherwise
```

Responses echo the report ID at offset 0; the payload occupies the bytes after
a fixed 5-byte header (`KrakenLegacyProtocol.responsePayload(_:request:)`).

## Address Map

| Constant | Address | Purpose |
|---|---|---|
| `ledModeAddress` | `0x172D` | Current LED mode / effect byte (RAM) |
| `customColorAddress` | `0x1189` | Static-color RGB (also breathing color slot 0) |
| `breathingColorAddresses[1]` | `0x118C` | Breathing color slot 1 (dual/triple breathing) |
| `breathingColorAddresses[2]` | `0x118F` | Breathing color slot 2 (triple breathing) |
| `serialEEPROMAddress` | `0x7F00` | Device serial number (EEPROM) |

`serialLength` (`22` bytes) bounds the EEPROM serial read.
`eepromMillisecondsPerByte` estimates EEPROM programming/settle time per byte
requested, for callers that want to pace multi-byte EEPROM writes; the current
protocol module only performs EEPROM reads.

## LED Mode / Effect Encoding

`KrakenLegacyProtocol.effectByte(for:)` / `effectKind(fromLEDModeByte:)` map
between the `KrakenLegacyEffect` enum and the raw LED-mode byte:

| Byte | Effect |
|---|---|
| `0x00` | Off |
| `0x01` | Static color |
| `0x02` | Spectrum |
| `0x03` | Breathing, single color |
| `0x04` | Breathing, dual color |
| `0x05` | Breathing, triple color |

`setEffectReports(for:)` builds the ordered write sequence for an effect: a RAM
write to the relevant color address(es) (skipped for `off`/`spectrum`, which
carry no color payload), followed by a RAM write of the LED-mode byte to
`ledModeAddress`.

`KrakenKittyV2USB` (see [DeviceSupport.swift](../../OpenSnek/Sources/OpenSnekCore/DeviceSupport.swift))
only advertises the subset of `KrakenLegacyEffect` cases that have a
corresponding `LightingEffectKind` in OpenSnek's shared UI model: `off`,
`staticColor`, `spectrum`, `breathingSingle` (`pulseSingle`), and
`breathingDual` (`pulseDual`). `breathingTriple` exists in the protocol module
for completeness but has no UI-facing equivalent yet.

## Serial Number

`parseSerial(fromPayload:)` reads up to `serialLength` bytes from an EEPROM
read at `serialEEPROMAddress`, strips trailing zero padding, decodes as ASCII,
and trims whitespace/control characters. Returns `nil` for an empty or
undecodable payload.

## Transport Notes

`KrakenLegacyControlSession` sends requests via `IOHIDDeviceSetReport` with
`kIOHIDReportTypeOutput`, **without the leading report-id byte** (the report ID
is passed as `IOHIDDeviceSetReport`'s separate `reportID` argument instead).
Responses are expected as asynchronous HID input reports, registered via
`IOHIDDeviceRegisterInputReportCallback` on a dedicated dispatch queue; a
`GetReport(kIOHIDReportTypeInput)` poll is used as a fallback when no callback
report arrives in time.

These are both spike-provided assumptions, not confirmed hardware behavior.
Both are collected in one place —
`KrakenLegacyTransportAssumptions` in `KrakenLegacyControlSession.swift` — so
they can be flipped without touching call sites once the hardware-transport
spike reports its findings. Look for the `PARENT-MERGE: confirm with spike
findings` comment.

## Device-Specific Notes

- Kraken Kitty V2 (`0x0560`): lighting-only. No DPI, poll-rate, power-management,
  or button-remap hardware; `DeviceProfile.usesKrakenLegacyProtocol = true`
  routes it around the standard 90-byte-feature-report control-interface
  requirement in `BridgeClient` (see `readState`, `usbControlAvailability`, and
  `apply` in `BridgeClient.swift` / `BridgeClient+USB.swift` /
  `BridgeClient+Apply.swift`).

## References

- [OpenRazer](https://github.com/openrazer/openrazer) `razerkraken_driver.c` and
  related Kraken-family driver sources (legacy Kraken protocol reverse
  engineering).
- [USB_PROTOCOL.md](./USB_PROTOCOL.md) — the shared class/cmd protocol this
  device does **not** use.
- [PARITY.md](./PARITY.md) — scope and status across all shipped profiles.
