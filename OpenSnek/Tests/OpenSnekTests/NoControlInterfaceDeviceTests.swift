import Foundation
import XCTest
import IOKit
import OpenSnekCore
import OpenSnekHardware
@testable import OpenSnek

/// Exercises handling of Razer USB devices without the 90-byte control interface
/// (e.g. Kraken headsets, which macOS exposes only through a consumer-control HID endpoint).
final class NoControlInterfaceDeviceTests: XCTestCase {
    private func makeHeadsetDevice(id: String = "usb-kraken-kitty-v2") -> MouseDevice {
        MouseDevice(id: id, vendor_id: 0x1532, product_id: 0x0560, product_name: "Razer Kraken Kitty V2 White Ed.", transport: .usb, path_b64: "", serial: nil, firmware: nil)
    }

    func testControlReportSupportRequiresNinetyByteFeatureReports() {
        XCTAssertTrue(USBHIDSupport.supportsControlReports(maxFeatureReportSize: 90))
        XCTAssertTrue(USBHIDSupport.supportsControlReports(maxFeatureReportSize: 91))
        XCTAssertFalse(USBHIDSupport.supportsControlReports(maxFeatureReportSize: 1))
        XCTAssertFalse(USBHIDSupport.supportsControlReports(maxFeatureReportSize: 64))
        XCTAssertFalse(USBHIDSupport.supportsControlReports(maxFeatureReportSize: 0))
    }

    func testNoControlInterfaceAvailabilityBlocksInteraction() {
        XCTAssertTrue(USBControlAvailability.noControlInterface.blocksUSBControlInteraction)
        XCTAssertEqual(USBControlAvailability.noControlInterface.diagnosticsLabel, "No Razer control interface")
    }

    func testNoControlInterfaceErrorClassification() {
        XCTAssertTrue(BridgeClient.isUSBNoControlInterfaceError(BridgeError.usbNoControlInterface))
        // IPC transports deliver errors as plain messages, so text matching must hold too.
        XCTAssertTrue(BridgeClient.isUSBNoControlInterfaceError(BridgeError.commandFailed(BridgeError.usbNoControlInterface.localizedDescription)))
        XCTAssertFalse(BridgeClient.isUSBNoControlInterfaceError(BridgeError.usbMouseUnavailable))
        XCTAssertFalse(BridgeClient.isUSBTelemetryUnavailableError(BridgeError.usbNoControlInterface))
    }

    func testSelectedHeadsetWithoutControlInterfaceShowsUnsupportedNotDisconnected() async {
        let headset = makeHeadsetDevice()
        let backend = DeviceListUpdatingStubBackend(devices: [headset], stateByDeviceID: [:])
        let appState = await MainActor.run { AppState(launchRole: .app, backend: backend, autoStart: false) }
        await backend.setTransientReadFailures([BridgeError.usbNoControlInterface.localizedDescription], for: headset.id)

        await MainActor.run {
            appState.deviceStore.devices = [headset]
            appState.deviceStore.selectedDeviceID = headset.id
        }

        let refreshed = await appState.deviceController.refreshState(for: headset)
        let status = await MainActor.run { appState.deviceStore.currentDeviceStatusIndicator.label }
        let message = await MainActor.run { appState.deviceStore.selectedDeviceInteractionMessage }
        let availability = await MainActor.run { appState.deviceController.usbControlAvailability(for: headset) }
        let fastPollingDeviceIDs = await MainActor.run { appState.runtimeStore.activeFastPollingDeviceIDs(at: Date()) }

        XCTAssertFalse(refreshed)
        XCTAssertEqual(availability, .noControlInterface)
        XCTAssertEqual(status, "Unsupported")
        XCTAssertEqual(message, "This Razer device does not expose the standard Razer USB control interface on macOS, so OpenSnek cannot configure it. Its normal functions (such as audio and media keys) are unaffected.")
        XCTAssertTrue(fastPollingDeviceIDs.isEmpty)
    }
}
