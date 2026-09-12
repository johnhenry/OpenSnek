# Razer Kraken V3 report-`0x40` lighting protocol

**Contributor validated on Linux; not supported in OpenSnek on macOS.**
[johnhenry reported these hardware results in PR #120](https://github.com/gh123man/OpenSnek/pull/120#issuecomment-5625047935)
on 2026-09-10 for the Kraken Kitty V2 White Edition (`1532:0560`). Maintainers
have not reproduced them. The contributor identified this as the V3 protocol
used by OpenRGB's `RazerKrakenV3Controller`; it differs from the legacy
report-`0x04` EEPROM/RAM protocol that the tested Kitty V2 rejected.

The upstream [OpenRazer Kitty V2 issue](https://github.com/openrazer/openrazer/issues/2157)
also contains device descriptors and a [Synapse capture for this PID](https://github.com/openrazer/openrazer/issues/2157#issuecomment-1845349483).

## Framing

The HID descriptor declares report `0x40` as a 12-byte Output payload, or
13 bytes including the report ID. The contributor reported working 13- and
15-byte buffers on Linux. Use the 13-byte form for reproducing these findings:
start with the command bytes below and pad the remaining bytes with zeros.

The reported delivery path was Linux `hidraw`, using `SET_REPORT` with
`bmRequestType=0x21`, `bRequest=0x09`, `wValue=0x0240`, and `wIndex=0x0003`
(interface 3). Byte zero is the report ID, byte one is the command, and bytes
two onward are arguments.

## Commands: contributor validated

| Purpose | Command prefix, including report ID | Observed behavior |
|---|---|---|
| Enter direct mode | `40 01 00 0F 08` | Send before writing a static color |
| Set color | `40 03 00 RR GG BB` | All LEDs use the same RGB color |
| Brightness | `40 02 00 00 VV` | `VV` ranges from `00` to `FF`; zero turns lighting off |
| Spectrum cycle | `40 01 00 0F 03` | Full-spectrum color cycling |

Red, green, blue, and white were reported to display correctly. The
contributor observed one mirrored logical zone despite attempts to address
multiple LEDs, and did not reproduce breathing effects. Treat those as limits
of the tested unit and command sequences, not universal Kraken capabilities.

## macOS status

The tested macOS paths returned errors or API success without the expected
visual effect. The cause has not been isolated, and DriverKit is only a
candidate for further investigation. See the [transport findings](../research/KRAKEN_KITTY_V2_MACOS_TRANSPORT_FINDINGS.md)
and [investigation scope](../research/KRAKEN_KITTY_V2_DRIVERKIT_SCOPE.md).
No Kraken profile, protocol implementation, or probe command is registered by
this documentation change.
