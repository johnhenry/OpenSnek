import Foundation
import OpenSnekCore

// PARENT-MERGE: replaced by protocol agent's implementation
//
// This whole file is a minimal, compilable placeholder for the Kraken legacy USB
// protocol module. It exists only so OpenSnekHardware, BridgeClient, and
// OpenSnekProbe can be built and tested against a stable public API while a
// sibling agent implements the real byte-accurate protocol (EEPROM/RAM address
// map, LED-mode encoding, breathing color slots, serial parsing). The parent
// session will replace this file wholesale with that implementation.

/// Defines the legacy Kraken lighting effects (OpenSnekProtocols side of the contract).
public enum KrakenLegacyEffect: Equatable, Sendable {
    case off
    case staticColor(RGBPatch)
    case spectrum
    case breathingSingle(RGBPatch)
    case breathingDual(RGBPatch, RGBPatch)
    case breathingTriple(RGBPatch, RGBPatch, RGBPatch)
}

/// Defines the legacy Kraken lighting effect kinds, independent of color payload.
public enum KrakenLegacyEffectKind: Equatable, Sendable {
    case off
    case staticColor
    case spectrum
    case breathingSingle
    case breathingDual
    case breathingTriple
}

/// Defines the legacy Razer Kraken (headset) USB HID protocol.
///
/// PARENT-MERGE: replaced by protocol agent's implementation. The address map,
/// report layout, and effect byte encoding below are placeholders only.
public enum KrakenLegacyProtocol {
    /// HID report ID used for both requests and input-report responses.
    public static let reportID: UInt8 = 0x04

    /// Full request length in bytes, INCLUDING the leading report-id byte.
    public static let requestLength: Int = 37

    /// Full response length in bytes (input report payload).
    public static let responseLength: Int = 33

    /// RAM address of the current LED mode / effect byte.
    public static let ledModeAddress: UInt16 = 0x172D

    /// RAM address of the custom static color.
    public static let customColorAddress: UInt16 = 0x1189

    /// RAM addresses for the (up to three) breathing-effect colors.
    public static let breathingColorAddresses: [UInt16] = [0x1189, 0x118C, 0x118F]

    /// EEPROM address of the device serial number.
    public static let serialEEPROMAddress: UInt16 = 0x7F00

    /// Length in bytes of the serial number stored in EEPROM.
    public static let serialLength: UInt8 = 22

    /// Rough EEPROM programming/read settle time, in milliseconds per byte requested.
    public static let eepromMillisecondsPerByte: Int = 2

    /// Placeholder command bytes distinguishing an EEPROM read from a RAM read/write.
    private static let eepromReadCommand: UInt8 = 0x81
    private static let ramReadCommand: UInt8 = 0x01
    private static let ramWriteCommand: UInt8 = 0x02

    /// Builds a full `requestLength`-byte report (including the leading report-id
    /// byte) requesting an EEPROM read at `address` of `length` bytes.
    public static func readEEPROMReport(address: UInt16, length: UInt8) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: requestLength)
        report[0] = reportID
        report[1] = eepromReadCommand
        report[2] = UInt8((address >> 8) & 0xFF)
        report[3] = UInt8(address & 0xFF)
        report[4] = length
        return report
    }

    /// Builds a full `requestLength`-byte report (including the leading report-id
    /// byte) requesting a RAM read at `address` of `length` bytes.
    public static func readRAMReport(address: UInt16, length: UInt8) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: requestLength)
        report[0] = reportID
        report[1] = ramReadCommand
        report[2] = UInt8((address >> 8) & 0xFF)
        report[3] = UInt8(address & 0xFF)
        report[4] = length
        return report
    }

    /// Builds a full `requestLength`-byte report (including the leading report-id
    /// byte) writing `payload` to RAM starting at `address`.
    public static func writeRAMReport(address: UInt16, payload: [UInt8]) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: requestLength)
        report[0] = reportID
        report[1] = ramWriteCommand
        report[2] = UInt8((address >> 8) & 0xFF)
        report[3] = UInt8(address & 0xFF)
        report[4] = UInt8(min(255, payload.count))
        let available = requestLength - 5
        for (index, byte) in payload.prefix(available).enumerated() { report[5 + index] = byte }
        return report
    }

    /// Maps an effect to its raw LED-mode byte.
    public static func effectByte(for effect: KrakenLegacyEffect) -> UInt8 {
        switch effect {
        case .off: return 0x00
        case .staticColor: return 0x01
        case .spectrum: return 0x02
        case .breathingSingle: return 0x03
        case .breathingDual: return 0x04
        case .breathingTriple: return 0x05
        }
    }

    /// Maps a raw LED-mode byte back to an effect kind, if recognized.
    public static func effectKind(fromLEDModeByte byte: UInt8) -> KrakenLegacyEffectKind? {
        switch byte {
        case 0x00: return .off
        case 0x01: return .staticColor
        case 0x02: return .spectrum
        case 0x03: return .breathingSingle
        case 0x04: return .breathingDual
        case 0x05: return .breathingTriple
        default: return nil
        }
    }

    /// Builds the ordered write reports needed to apply `effect` (color slot
    /// writes, if any, followed by the LED-mode write).
    public static func setEffectReports(for effect: KrakenLegacyEffect) -> [[UInt8]] {
        var reports: [[UInt8]] = []

        func colorPayload(_ patch: RGBPatch) -> [UInt8] { [UInt8(max(0, min(255, patch.r))), UInt8(max(0, min(255, patch.g))), UInt8(max(0, min(255, patch.b)))] }

        switch effect {
        case .off, .spectrum: break
        case .staticColor(let color): reports.append(writeRAMReport(address: customColorAddress, payload: colorPayload(color)))
        case .breathingSingle(let color): reports.append(writeRAMReport(address: breathingColorAddresses[0], payload: colorPayload(color)))
        case .breathingDual(let first, let second):
            reports.append(writeRAMReport(address: breathingColorAddresses[0], payload: colorPayload(first)))
            reports.append(writeRAMReport(address: breathingColorAddresses[1], payload: colorPayload(second)))
        case .breathingTriple(let first, let second, let third):
            reports.append(writeRAMReport(address: breathingColorAddresses[0], payload: colorPayload(first)))
            reports.append(writeRAMReport(address: breathingColorAddresses[1], payload: colorPayload(second)))
            reports.append(writeRAMReport(address: breathingColorAddresses[2], payload: colorPayload(third)))
        }

        reports.append(writeRAMReport(address: ledModeAddress, payload: [effectByte(for: effect)]))
        return reports
    }

    /// Extracts the payload portion of a response, validating it against the
    /// originating `request` report where possible.
    public static func responsePayload(_ response: [UInt8], request: [UInt8]) -> [UInt8]? {
        guard response.count >= responseLength, !request.isEmpty else { return nil }
        guard response[0] == reportID else { return nil }
        return Array(response.dropFirst(5))
    }

    /// Parses a device serial number from an EEPROM-read payload.
    public static func parseSerial(fromPayload payload: [UInt8]) -> String? {
        guard !payload.isEmpty else { return nil }
        let bytes = Array(payload.prefix(Int(serialLength)))
        let scalars = bytes.filter { $0 != 0 }
        guard !scalars.isEmpty else { return nil }
        guard let raw = String(bytes: scalars, encoding: .ascii) else { return nil }
        let string = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return string.isEmpty ? nil : string
    }
}
