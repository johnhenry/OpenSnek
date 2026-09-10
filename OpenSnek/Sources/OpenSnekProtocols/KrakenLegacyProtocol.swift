import Foundation
import OpenSnekCore

/// Describes a legacy Razer Kraken lighting effect and its color arguments.
///
/// Mirrors the OpenRazer `razerkraken` driver's `matrix_effect_*` sysfs handlers: `off` is
/// `matrix_effect_none`, `staticColor` is `matrix_effect_static`, `spectrum` is
/// `matrix_effect_spectrum`, and the `breathing*` cases are `matrix_effect_breath` with 3, 6, or
/// 9 argument bytes (one, two, or three colors).
public enum KrakenLegacyEffect: Equatable, Sendable {
    case off
    case staticColor(RGBPatch)
    case spectrum
    case breathingSingle(RGBPatch)
    case breathingDual(RGBPatch, RGBPatch)
    case breathingTriple(RGBPatch, RGBPatch, RGBPatch)
}

/// The effect family of a `KrakenLegacyEffect`, independent of its color arguments.
public enum KrakenLegacyEffectKind: Equatable, Sendable { case off, staticColor, spectrum, breathingSingle, breathingDual, breathingTriple }

/// Encodes and decodes the legacy Razer Kraken (Kylie/Kitty V2) HID control protocol.
///
/// This mirrors `drivers/hid/hid-razer/razerkraken_driver.c` from OpenRazer, specifically the
/// Kylie address map used by the Kraken V2/TE/Ultimate/Kitty V2 family
/// (`KYLIE_SET_LED_ADDRESS` and friends). Every request is a 37-byte control-out report built
/// from `struct razer_kraken_request_report` (report id + destination + length + 2-byte
/// big-endian address + 32 bytes of arguments); every response is a 33-byte control-in report
/// (response report id + 32 bytes of arguments), matched to the raw HID input report the device
/// sends back asynchronously (`razer_raw_event` only accepts `size == 33`).
///
/// This module is pure protocol code: no I/O, no device or bridge integration.
public enum KrakenLegacyProtocol {
    /// Output report id used for every memory-access request (`0x04` in the driver).
    public static let reportID: UInt8 = 0x04
    /// Input report id the device echoes on a successful memory-access response (`0x05`).
    public static let responseReportID: UInt8 = 0x05

    /// Full request buffer length, including the leading report-id byte.
    /// `sizeof(struct razer_kraken_request_report)`: 1 (report_id) + 1 (destination) + 1 (length) + 2 (address) + 32 (arguments).
    public static let requestLength = 37
    /// Full response buffer length, including the leading report-id byte.
    /// The driver's `raw_event` handler only accepts raw HID reports of exactly this size.
    public static let responseLength = 33
    /// Number of argument bytes available in a request report.
    public static let requestArgumentsLength = 32
    /// Number of argument bytes available in a response report.
    public static let responseArgumentsLength = 32

    /// Destination byte: read from EEPROM (`0x20`).
    public static let destinationReadEEPROM: UInt8 = 0x20
    /// Destination byte: write to RAM (`0x40`).
    public static let destinationWriteRAM: UInt8 = 0x40
    /// Destination byte: read from RAM (`0x00`).
    public static let destinationReadRAM: UInt8 = 0x00

    /// `KYLIE_SET_LED_ADDRESS`: the RAM address that holds the LED effect bitfield.
    public static let ledModeAddress: UInt16 = 0x172D
    /// `KYLIE_CUSTOM_ADDRESS_START`: the RAM address for the "custom" effect's RGB(+intensity) bytes.
    ///
    /// Exposed for completeness since the driver addresses it separately from the static/breathing
    /// colors below, but `KrakenLegacyEffect` does not model the driver's distinct `matrix_effect_custom`
    /// handler as its own case (see `setEffectReports(for:)`), so nothing in this module writes here yet.
    public static let customColorAddress: UInt16 = 0x1189
    /// `KYLIE_BREATHING1/2/3_ADDRESS_START`: the RAM address of each breathing slot's first color.
    ///
    /// Slot 0 (`0x1741`) is also the address the driver's `matrix_effect_static` handler writes to,
    /// so it doubles as the static-color address. Multi-color slots address their 2nd/3rd colors at
    /// `slot address + 4` and `+ 8` respectively (4 bytes per color: R, G, B, intensity).
    public static let breathingColorAddresses: [UInt16] = [0x1741, 0x1745, 0x174D]
    /// `0x7f00`: the EEPROM address of the device serial number.
    public static let serialEEPROMAddress: UInt16 = 0x7F00
    /// Length in bytes of the serial number stored at `serialEEPROMAddress`.
    public static let serialLength: UInt8 = 22
    /// Milliseconds the driver sleeps per byte of a request's `length` field after sending a
    /// non-skipped control message (`msleep(report->length * 15)`). Reads use the "skip" path and
    /// instead sleep a flat 25ms for the async response to arrive; this constant only applies to
    /// the write-path delay budget.
    public static let eepromMillisecondsPerByte = 15

    // MARK: - Request builders

    /// Builds a 37-byte EEPROM read request (destination `0x20`).
    public static func readEEPROMReport(address: UInt16, length: UInt8) -> [UInt8] { requestReport(destination: destinationReadEEPROM, length: length, address: address, arguments: []) }

    /// Builds a 37-byte RAM read request (destination `0x00`).
    public static func readRAMReport(address: UInt16, length: UInt8) -> [UInt8] { requestReport(destination: destinationReadRAM, length: length, address: address, arguments: []) }

    /// Builds a 37-byte RAM write request (destination `0x40`). `length` is derived from
    /// `payload.count`; the payload is truncated to `requestArgumentsLength` (32) bytes if longer.
    public static func writeRAMReport(address: UInt16, payload: [UInt8]) -> [UInt8] {
        let clamped = Array(payload.prefix(requestArgumentsLength))
        return requestReport(destination: destinationWriteRAM, length: UInt8(clamped.count), address: address, arguments: clamped)
    }

    private static func requestReport(destination: UInt8, length: UInt8, address: UInt16, arguments: [UInt8]) -> [UInt8] {
        var report = [UInt8](repeating: 0x00, count: requestLength)
        report[0] = reportID
        report[1] = destination
        report[2] = length
        report[3] = UInt8((address >> 8) & 0xFF)
        report[4] = UInt8(address & 0xFF)
        for (index, byte) in arguments.prefix(requestArgumentsLength).enumerated() { report[5 + index] = byte }
        return report
    }

    // MARK: - Effect bitfield

    /// Encodes an effect into `union razer_kraken_effect_byte`'s single-byte bitfield value.
    ///
    /// Bit layout (bit 0 is the least significant bit): 0 on/off-static, 1 single-colour breathing,
    /// 2 spectrum cycling, 3 sync, 4 two-colour breathing, 5 three-colour breathing. The driver always
    /// sets bit 0 alongside whichever effect bit is active (it is the master "LED on" bit), and always
    /// sets the sync bit (bit 3) for every breathing variant, matching `matrix_effect_breath`.
    public static func effectByte(for effect: KrakenLegacyEffect) -> UInt8 {
        switch effect {
        case .off: return 0x00
        case .staticColor: return 0x01 // on_off_static
        case .spectrum: return 0x01 | 0x04 // on_off_static | spectrum_cycling
        case .breathingSingle: return 0x01 | 0x02 | 0x08 // on_off_static | single_colour_breathing | sync
        case .breathingDual: return 0x01 | 0x10 | 0x08 // on_off_static | two_colour_breathing | sync
        case .breathingTriple: return 0x01 | 0x20 | 0x08 // on_off_static | three_colour_breathing | sync
        }
    }

    /// Decodes an LED-mode byte back into an effect kind, honoring the same bit priority the
    /// driver's exclusive sysfs handlers imply (three-colour breathing takes precedence over
    /// two-colour, which takes precedence over single-colour, which takes precedence over spectrum).
    /// Returns `nil` for an unrecognized non-zero byte with the on/off bit clear.
    public static func effectKind(fromLEDModeByte byte: UInt8) -> KrakenLegacyEffectKind? {
        if byte == 0x00 { return .off }
        guard byte & 0x01 != 0 else { return nil } // on_off_static must be set for any active effect
        if byte & 0x20 != 0 { return .breathingTriple }
        if byte & 0x10 != 0 { return .breathingDual }
        if byte & 0x02 != 0 { return .breathingSingle }
        if byte & 0x04 != 0 { return .spectrum }
        return .staticColor
    }

    // MARK: - Effect write sequence

    /// Builds the ordered full write sequence for an effect: color report(s) first, then the
    /// led-mode byte write, matching the driver's write order in each `matrix_effect_*` handler.
    ///
    /// The driver's spectrum handler (`matrix_effect_spectrum`) writes only the LED-mode byte, with
    /// no color report — spectrum cycling has no fixed color to send. `off` (`matrix_effect_none`)
    /// likewise writes only the LED-mode byte.
    public static func setEffectReports(for effect: KrakenLegacyEffect) -> [[UInt8]] {
        switch effect {
        case .off:
            return [ledModeReport(effect)]

        case .staticColor(let color):
            return [colorReport(address: breathingColorAddresses[0], color: color), ledModeReport(effect)]

        case .spectrum:
            return [ledModeReport(effect)]

        case .breathingSingle(let color):
            return [colorReport(address: breathingColorAddresses[0], color: color), ledModeReport(effect)]

        case .breathingDual(let first, let second):
            let base = breathingColorAddresses[1]
            return [colorReport(address: base, color: first), colorReport(address: base + 4, color: second), ledModeReport(effect)]

        case .breathingTriple(let first, let second, let third):
            let base = breathingColorAddresses[2]
            return [colorReport(address: base, color: first), colorReport(address: base + 4, color: second), colorReport(address: base + 8, color: third), ledModeReport(effect)]
        }
    }

    private static func ledModeReport(_ effect: KrakenLegacyEffect) -> [UInt8] { writeRAMReport(address: ledModeAddress, payload: [effectByte(for: effect)]) }

    private static func colorReport(address: UInt16, color: RGBPatch) -> [UInt8] {
        writeRAMReport(address: address, payload: [UInt8(max(0, min(255, color.r))), UInt8(max(0, min(255, color.g))), UInt8(max(0, min(255, color.b)))])
    }

    // MARK: - Response handling

    /// Validates a 33-byte response report and returns its argument payload, trimmed to the
    /// requesting report's `length` byte, or `nil` if the response doesn't match.
    ///
    /// The driver's raw HID responses carry no echo of the request's destination, length, or
    /// address (`struct razer_kraken_response_report` is just `report_id + arguments[36]`, and
    /// `razer_raw_event` copies any 33-byte packet verbatim into `device->data`) — matching is done
    /// out-of-band by the driver holding a mutex around one in-flight request at a time. Since this
    /// module has no I/O layer of its own to serialize requests, we validate what we can: the
    /// response report id (`0x05`), the response length, that the request looks like a well-formed
    /// read request (37 bytes, destination `0x00` or `0x20`), and we trim the returned payload to
    /// the request's declared `length` byte so callers get exactly the bytes they asked for.
    public static func responsePayload(_ response: [UInt8], request: [UInt8]) -> [UInt8]? {
        guard response.count == responseLength else { return nil }
        guard response[0] == responseReportID else { return nil }
        guard request.count == requestLength else { return nil }
        guard request[0] == reportID else { return nil }
        let destination = request[1]
        guard destination == destinationReadRAM || destination == destinationReadEEPROM else { return nil }
        let length = Int(request[2])
        guard length > 0, length <= responseArgumentsLength else { return nil }
        return Array(response[1..<(1 + length)])
    }

    /// Parses the 22-byte serial number payload (as returned by `responsePayload` for a
    /// `readEEPROMReport(address: serialEEPROMAddress, length: serialLength)` request) into a string.
    /// Returns `nil` if the payload is too short, empty, or contains non-printable-ASCII bytes.
    public static func parseSerial(fromPayload payload: [UInt8]) -> String? {
        guard payload.count >= Int(serialLength) else { return nil }
        let raw = Array(payload.prefix(Int(serialLength))).prefix { $0 != 0x00 }
        guard !raw.isEmpty else { return nil }
        guard raw.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else { return nil }
        return String(bytes: raw, encoding: .ascii)
    }
}
