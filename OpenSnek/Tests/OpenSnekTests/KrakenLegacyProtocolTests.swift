import XCTest
import Foundation
import OpenSnekCore
import OpenSnekProtocols

/// Exercises the legacy Razer Kraken protocol encoder/decoder against byte-exact expectations
/// mirrored from OpenRazer's `razerkraken_driver.c`.
final class KrakenLegacyProtocolTests: XCTestCase {
    // MARK: - Request builders

    func testReadEEPROMReportBuildsSerialRequest() {
        var expected = [UInt8](repeating: 0x00, count: 37)
        expected[0] = 0x04
        expected[1] = 0x20
        expected[2] = 0x16
        expected[3] = 0x7F
        expected[4] = 0x00

        let report = KrakenLegacyProtocol.readEEPROMReport(address: KrakenLegacyProtocol.serialEEPROMAddress, length: KrakenLegacyProtocol.serialLength)

        XCTAssertEqual(report, expected)
        XCTAssertEqual(report.count, KrakenLegacyProtocol.requestLength)
    }

    func testReadRAMReportBuildsLEDModeRequest() {
        var expected = [UInt8](repeating: 0x00, count: 37)
        expected[0] = 0x04
        expected[1] = 0x00
        expected[2] = 0x01
        expected[3] = 0x17
        expected[4] = 0x2D

        XCTAssertEqual(KrakenLegacyProtocol.readRAMReport(address: KrakenLegacyProtocol.ledModeAddress, length: 0x01), expected)
    }

    func testWriteRAMReportBuildsLEDModeWrite() {
        var expected = [UInt8](repeating: 0x00, count: 37)
        expected[0] = 0x04
        expected[1] = 0x40
        expected[2] = 0x01
        expected[3] = 0x17
        expected[4] = 0x2D
        expected[5] = 0x05

        XCTAssertEqual(KrakenLegacyProtocol.writeRAMReport(address: KrakenLegacyProtocol.ledModeAddress, payload: [0x05]), expected)
    }

    func testWriteRAMReportBuildsRGBWrite() {
        var expected = [UInt8](repeating: 0x00, count: 37)
        expected[0] = 0x04
        expected[1] = 0x40
        expected[2] = 0x03
        expected[3] = 0x17
        expected[4] = 0x41
        expected[5] = 0x11
        expected[6] = 0x22
        expected[7] = 0x33

        XCTAssertEqual(KrakenLegacyProtocol.writeRAMReport(address: 0x1741, payload: [0x11, 0x22, 0x33]), expected)
    }

    func testWriteRAMReportTruncatesOversizedPayload() {
        let payload = [UInt8](repeating: 0xAB, count: 40)
        let report = KrakenLegacyProtocol.writeRAMReport(address: 0x1741, payload: payload)

        XCTAssertEqual(report.count, KrakenLegacyProtocol.requestLength)
        XCTAssertEqual(report[2], 32) // length clamped to requestArgumentsLength
        XCTAssertEqual(Array(report[5..<37]), [UInt8](repeating: 0xAB, count: 32))
    }

    // MARK: - Effect bitfield

    func testEffectByteMatchesDriverBitLayout() {
        XCTAssertEqual(KrakenLegacyProtocol.effectByte(for: .off), 0x00)
        XCTAssertEqual(KrakenLegacyProtocol.effectByte(for: .staticColor(RGBPatch(r: 1, g: 2, b: 3))), 0x01)
        XCTAssertEqual(KrakenLegacyProtocol.effectByte(for: .spectrum), 0x05) // matches driver comment's worked example
        XCTAssertEqual(KrakenLegacyProtocol.effectByte(for: .breathingSingle(RGBPatch(r: 1, g: 2, b: 3))), 0x0B)
        XCTAssertEqual(KrakenLegacyProtocol.effectByte(for: .breathingDual(RGBPatch(r: 1, g: 2, b: 3), RGBPatch(r: 4, g: 5, b: 6))), 0x19)
        XCTAssertEqual(KrakenLegacyProtocol.effectByte(for: .breathingTriple(RGBPatch(r: 1, g: 2, b: 3), RGBPatch(r: 4, g: 5, b: 6), RGBPatch(r: 7, g: 8, b: 9))), 0x29)
    }

    func testEffectKindDecodesAllEncodedBytes() {
        let color = RGBPatch(r: 1, g: 2, b: 3)
        let effects: [KrakenLegacyEffect] = [.off, .staticColor(color), .spectrum, .breathingSingle(color), .breathingDual(color, color), .breathingTriple(color, color, color)]
        let kinds: [KrakenLegacyEffectKind] = [.off, .staticColor, .spectrum, .breathingSingle, .breathingDual, .breathingTriple]

        for (effect, kind) in zip(effects, kinds) {
            XCTAssertEqual(KrakenLegacyProtocol.effectKind(fromLEDModeByte: KrakenLegacyProtocol.effectByte(for: effect)), kind)
        }
    }

    func testEffectKindRejectsUnrecognizedByteWithOnOffBitClear() {
        XCTAssertNil(KrakenLegacyProtocol.effectKind(fromLEDModeByte: 0x20)) // three-colour bit set but on_off_static clear
        XCTAssertNil(KrakenLegacyProtocol.effectKind(fromLEDModeByte: 0x08)) // sync bit alone, clear on_off_static
    }

    func testEffectKindPrioritizesMoreSpecificBreathingBitsOverSpectrum() {
        // Bitfield with spectrum, single, and three-colour bits all set (not a real device state,
        // but exercises the decode priority documented on effectKind).
        XCTAssertEqual(KrakenLegacyProtocol.effectKind(fromLEDModeByte: 0x01 | 0x04 | 0x02 | 0x20), .breathingTriple)
        XCTAssertEqual(KrakenLegacyProtocol.effectKind(fromLEDModeByte: 0x01 | 0x04 | 0x02 | 0x10), .breathingDual)
        XCTAssertEqual(KrakenLegacyProtocol.effectKind(fromLEDModeByte: 0x01 | 0x04 | 0x02), .breathingSingle)
    }

    // MARK: - setEffectReports

    func testSetEffectReportsForOffIsSingleLEDModeWrite() {
        let reports = KrakenLegacyProtocol.setEffectReports(for: .off)

        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0], KrakenLegacyProtocol.writeRAMReport(address: KrakenLegacyProtocol.ledModeAddress, payload: [0x00]))
    }

    func testSetEffectReportsForSpectrumIsSingleLEDModeWriteWithNoColor() {
        let reports = KrakenLegacyProtocol.setEffectReports(for: .spectrum)

        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0], KrakenLegacyProtocol.writeRAMReport(address: KrakenLegacyProtocol.ledModeAddress, payload: [0x05]))
    }

    func testSetEffectReportsForStaticColorWritesColorThenLEDMode() {
        let color = RGBPatch(r: 0x11, g: 0x22, b: 0x33)
        let reports = KrakenLegacyProtocol.setEffectReports(for: .staticColor(color))

        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports[0], KrakenLegacyProtocol.writeRAMReport(address: KrakenLegacyProtocol.breathingColorAddresses[0], payload: [0x11, 0x22, 0x33]))
        XCTAssertEqual(reports[1], KrakenLegacyProtocol.writeRAMReport(address: KrakenLegacyProtocol.ledModeAddress, payload: [0x01]))
    }

    func testSetEffectReportsForBreathingSingleWritesColorThenLEDMode() {
        let color = RGBPatch(r: 0x44, g: 0x55, b: 0x66)
        let reports = KrakenLegacyProtocol.setEffectReports(for: .breathingSingle(color))

        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports[0], KrakenLegacyProtocol.writeRAMReport(address: KrakenLegacyProtocol.breathingColorAddresses[0], payload: [0x44, 0x55, 0x66]))
        XCTAssertEqual(reports[1], KrakenLegacyProtocol.writeRAMReport(address: KrakenLegacyProtocol.ledModeAddress, payload: [0x0B]))
    }

    func testSetEffectReportsForBreathingDualWritesBothColorsThenLEDMode() {
        let first = RGBPatch(r: 0x01, g: 0x02, b: 0x03)
        let second = RGBPatch(r: 0x04, g: 0x05, b: 0x06)
        let reports = KrakenLegacyProtocol.setEffectReports(for: .breathingDual(first, second))
        let base = KrakenLegacyProtocol.breathingColorAddresses[1]

        XCTAssertEqual(reports.count, 3)
        XCTAssertEqual(reports[0], KrakenLegacyProtocol.writeRAMReport(address: base, payload: [0x01, 0x02, 0x03]))
        XCTAssertEqual(reports[1], KrakenLegacyProtocol.writeRAMReport(address: base + 4, payload: [0x04, 0x05, 0x06]))
        XCTAssertEqual(reports[2], KrakenLegacyProtocol.writeRAMReport(address: KrakenLegacyProtocol.ledModeAddress, payload: [0x19]))
    }

    func testSetEffectReportsForBreathingTripleWritesAllThreeColorsThenLEDMode() {
        let first = RGBPatch(r: 0x01, g: 0x02, b: 0x03)
        let second = RGBPatch(r: 0x04, g: 0x05, b: 0x06)
        let third = RGBPatch(r: 0x07, g: 0x08, b: 0x09)
        let reports = KrakenLegacyProtocol.setEffectReports(for: .breathingTriple(first, second, third))
        let base = KrakenLegacyProtocol.breathingColorAddresses[2]

        XCTAssertEqual(reports.count, 4)
        XCTAssertEqual(reports[0], KrakenLegacyProtocol.writeRAMReport(address: base, payload: [0x01, 0x02, 0x03]))
        XCTAssertEqual(reports[1], KrakenLegacyProtocol.writeRAMReport(address: base + 4, payload: [0x04, 0x05, 0x06]))
        XCTAssertEqual(reports[2], KrakenLegacyProtocol.writeRAMReport(address: base + 8, payload: [0x07, 0x08, 0x09]))
        XCTAssertEqual(reports[3], KrakenLegacyProtocol.writeRAMReport(address: KrakenLegacyProtocol.ledModeAddress, payload: [0x29]))
    }

    func testSetEffectReportsClampsOutOfRangeColorComponents() {
        let color = RGBPatch(r: -10, g: 300, b: 128)
        let reports = KrakenLegacyProtocol.setEffectReports(for: .staticColor(color))

        XCTAssertEqual(reports[0][5], 0x00)
        XCTAssertEqual(reports[0][6], 0xFF)
        XCTAssertEqual(reports[0][7], 0x80)
    }

    // MARK: - Response validation

    private func makeResponse(payload: [UInt8]) -> [UInt8] {
        var response = [UInt8](repeating: 0x00, count: KrakenLegacyProtocol.responseLength)
        response[0] = KrakenLegacyProtocol.responseReportID
        for (index, byte) in payload.prefix(KrakenLegacyProtocol.responseArgumentsLength).enumerated() { response[1 + index] = byte }
        return response
    }

    func testResponsePayloadTrimsToRequestedLength() {
        let request = KrakenLegacyProtocol.readEEPROMReport(address: KrakenLegacyProtocol.serialEEPROMAddress, length: KrakenLegacyProtocol.serialLength)
        let serialBytes: [UInt8] = Array("HN00000000000000000001".utf8).prefix(22).map { $0 }
        let response = makeResponse(payload: serialBytes)

        XCTAssertEqual(KrakenLegacyProtocol.responsePayload(response, request: request), serialBytes)
    }

    func testResponsePayloadRejectsWrongLength() {
        let request = KrakenLegacyProtocol.readRAMReport(address: KrakenLegacyProtocol.ledModeAddress, length: 0x01)
        let shortResponse = [UInt8](repeating: 0x00, count: 20)

        XCTAssertNil(KrakenLegacyProtocol.responsePayload(shortResponse, request: request))
    }

    func testResponsePayloadRejectsWrongResponseReportID() {
        let request = KrakenLegacyProtocol.readRAMReport(address: KrakenLegacyProtocol.ledModeAddress, length: 0x01)
        var response = makeResponse(payload: [0x05])
        response[0] = 0x00

        XCTAssertNil(KrakenLegacyProtocol.responsePayload(response, request: request))
    }

    func testResponsePayloadRejectsMalformedRequest() {
        let response = makeResponse(payload: [0x05])

        XCTAssertNil(KrakenLegacyProtocol.responsePayload(response, request: [0x04, 0x00, 0x01]))
    }

    func testResponsePayloadRejectsWriteRequests() {
        let request = KrakenLegacyProtocol.writeRAMReport(address: KrakenLegacyProtocol.ledModeAddress, payload: [0x01])
        let response = makeResponse(payload: [0x01])

        XCTAssertNil(KrakenLegacyProtocol.responsePayload(response, request: request))
    }

    func testResponsePayloadRejectsZeroLengthRequest() {
        let request = KrakenLegacyProtocol.readRAMReport(address: KrakenLegacyProtocol.ledModeAddress, length: 0x00)
        let response = makeResponse(payload: [0x01])

        XCTAssertNil(KrakenLegacyProtocol.responsePayload(response, request: request))
    }

    func testResponsePayloadReadsCurrentEffectByte() {
        let request = KrakenLegacyProtocol.readRAMReport(address: KrakenLegacyProtocol.ledModeAddress, length: 0x01)
        let response = makeResponse(payload: [0x0B])

        XCTAssertEqual(KrakenLegacyProtocol.responsePayload(response, request: request), [0x0B])
    }

    // MARK: - Serial parsing

    func testParseSerialReturnsTrimmedASCIIString() {
        let serial = "HN000123456789012"
        var payload = Array(serial.utf8)
        payload.append(contentsOf: [UInt8](repeating: 0x00, count: Int(KrakenLegacyProtocol.serialLength) - payload.count))

        XCTAssertEqual(KrakenLegacyProtocol.parseSerial(fromPayload: payload), serial)
    }

    func testParseSerialReturnsFullLengthString() {
        let serial = "RZ01-01234567890123456"
        XCTAssertEqual(serial.count, Int(KrakenLegacyProtocol.serialLength))

        XCTAssertEqual(KrakenLegacyProtocol.parseSerial(fromPayload: Array(serial.utf8)), serial)
    }

    func testParseSerialRejectsTooShortPayload() {
        XCTAssertNil(KrakenLegacyProtocol.parseSerial(fromPayload: [0x48, 0x4E]))
    }

    func testParseSerialRejectsAllZeroPayload() {
        XCTAssertNil(KrakenLegacyProtocol.parseSerial(fromPayload: [UInt8](repeating: 0x00, count: 22)))
    }

    func testParseSerialRejectsNonPrintableBytes() {
        var payload = Array("HN0000000000000000000".utf8)
        payload[3] = 0x01 // non-printable

        XCTAssertNil(KrakenLegacyProtocol.parseSerial(fromPayload: payload))
    }
}
