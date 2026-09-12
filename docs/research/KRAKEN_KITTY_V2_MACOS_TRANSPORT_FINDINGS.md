# Kraken Kitty V2: protocol findings and unresolved macOS transport

## Status and evidence

**Contributor validated on Linux; unsupported in OpenSnek on macOS.** These
findings come from [johnhenry's hardware report in PR #120](https://github.com/gh123man/OpenSnek/pull/120#issuecomment-5625047935)
on 2026-09-10, using a Kraken Kitty V2 White Edition (`1532:0560`). Maintainers
have not reproduced the hardware tests. The contributor's diagnostic scripts and
full logs were not included in the PR; the descriptor and results below preserve
the reported evidence, rather than imply that those artifacts are in this tree.

The successful Linux tests used the [V3 report-`0x40` protocol](../protocol/KRAKEN_V3_PROTOCOL.md).
The initial legacy report-`0x04` implementation and the later report-`0x01`
session-handshake theory were superseded by those results. No Kraken transport,
profile, or probe commands are shipped from this research.

## Interface discovery

The contributor reported one HID interface (USB interface 3):

```text
usagePage=0x0C usage=0x01 maxInput=62 maxOutput=62 maxFeature=1
```

Input Monitoring was already granted to the process performing the macOS tests.
The reported 140-byte HID descriptor was:

```text
05 0C 09 01 A1 01 85 01 15 00 26 FF 00 09 00 75 08 95 3D 91 02 09 00 81 02
85 04 09 00 75 08 95 1A 91 02
85 05 09 00 75 08 95 16 81 02
85 08 09 00 75 08 95 01 81 02
85 0C 09 00 75 08 95 0A 81 02
85 40 09 00 75 08 95 0C 91 02
85 41 09 00 75 08 95 0C 81 02
85 52 15 00 25 01 09 E9 09 EA 75 01 95 02 81 06 09 00 95 06 81 01
85 70 15 00 26 FF 00 09 00 75 08 95 04 91 02
85 71 09 00 75 08 95 04 81 02
C0 05 0B 09 05 A1 01 C0
```

| Report ID | Direction | Payload bytes, excluding report ID |
|---|---|---|
| `0x01` | Output / Input | 61 / 61 |
| `0x04` / `0x05` | Output / Input | 26 / 22 |
| `0x08` | Input | 1 |
| `0x0C` | Input | 10 |
| `0x40` / `0x41` | Output / Input | 12 / 12 |
| `0x52` | Input | 1 (media keys) |
| `0x70` / `0x71` | Output / Input | 4 / 4 |

## Legacy-protocol negative result

Early tests attempted EEPROM/RAM reads with the older 37-byte report-`0x04`
protocol. Explicit report-ID calls to `IOHIDDeviceSetReport` failed with
`0xE0005000`; passing report ID zero with the ID embedded in the full buffer
returned API success. Serial, LED-mode, and color reads all produced the same
23-byte report-`0x05` buffer (ID followed by zeros), and no response callback was
observed. These buffers did not establish meaningful readback.

Device-level legacy control transfers subsequently stalled. The contributor
also reported that Linux rejected legacy commands while V3 lighting worked.
The Kitty V2 must therefore not be assigned the legacy protocol based on its
product name or descriptor alone.

## V3 lighting results

On Linux (NixOS, kernel 6.12), the contributor reported repeatable visual
changes through `hidraw`: static red/green/blue/white, brightness including zero
for fully off, and spectrum cycling. All LEDs mirrored one logical color;
breathing and independent zones were not demonstrated.

The macOS attempts produced these results:

| API and request | Reported result |
|---|---|
| `IOHIDDeviceSetReport(Output, reportID: 0, [0x40, …], 13 bytes)` | API success, but brightness zero left the headset lit |
| `IOHIDDeviceSetReport(Output, reportID: 0x40, 12-byte payload)` | `0xE0005000` |
| `IOUSBDeviceInterface::DeviceRequest`, `SET_REPORT`, `wValue=0x0240`, `wIndex=3` | Mode (`0x01`) acknowledged; color (`0x03`) and brightness (`0x02`) stalled with `0xE000404F` |

An earlier apparent red-color success was retracted after the off test: the
observed red could be the power-on state. API success alone is insufficient
evidence that the device executed a lighting command.

## What remains unresolved

The contributor observed Apple's HID driver owning interface 3 and proposed
that ownership as the cause of the macOS failure. **That causal explanation is
still a hypothesis.** No captured macOS bus trace or successful test after
changing interface ownership is included here. The off test proves the
requested effect did not occur; it does not identify where the report was
dropped or rejected.

The earlier report-`0x01` handshake theory and claim that transport work could
not help are superseded. Linux V3 success did not require the proposed unlock.
A working macOS transport still needs investigation; a DriverKit extension is
one candidate, not a demonstrated requirement or solution.

Start with the [capture guide](KRAKEN_KITTY_V2_CAPTURE_GUIDE.md), then use the
[DriverKit investigation scope](KRAKEN_KITTY_V2_DRIVERKIT_SCOPE.md) if the
evidence supports testing interface ownership. OpenSnek continues to classify
this unregistered device as unsupported through the no-control-interface path.
