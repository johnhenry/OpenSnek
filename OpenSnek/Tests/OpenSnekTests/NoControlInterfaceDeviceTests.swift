import Foundation
import XCTest
import IOKit
import OpenSnekCore
import OpenSnekHardware
@testable import OpenSnek

/// Exercises handling of Razer USB devices without the 90-byte control interface
/// (e.g. Kraken headsets, which macOS exposes only through a consumer-control HID endpoint).
final class NoControlInterfaceDeviceTests: XCTestCase {
    private func makeHeadsetDevice(id: String = "usb-kraken-kitty-v2") -> MouseDevice { MouseDevice(id: id, vendor_id: 0x1532, product_id: 0x0560, product_name: "Razer Kraken Kitty V2 White Ed.", transport: .usb, path_b64: "", serial: nil, firmware: nil) }

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

        _ = await appState.deviceController.refreshState(for: headset)
        let readsWhileUnsupported = await backend.readCount(for: headset.id)
        XCTAssertEqual(readsWhileUnsupported, 1)
        await MainActor.run {
            XCTAssertNil(appState.deviceStore.errorMessage)
            appState.deviceController.applyDeviceList([], source: "test.unplug")
            XCTAssertTrue(appState.deviceStore.devices.isEmpty)
            XCTAssertNil(appState.deviceStore.selectedDevice)
            XCTAssertEqual(appState.deviceController.usbControlAvailability(for: headset), .unknown)
        }
        await backend.setTransientReadFailures([BridgeError.usbNoControlInterface.localizedDescription], for: headset.id)
        await appState.deviceStore.refreshDevices()
        let readsAfterReplug = await backend.readCount(for: headset.id)
        XCTAssertEqual(readsAfterReplug, 2)
        await MainActor.run { XCTAssertEqual(appState.deviceStore.currentDeviceStatusIndicator.label, "Unsupported") }
    }

    func testDiscoveryResetCanRecoverADeviceAfterControlInterfaceAppears() async throws {
        let device = makeHeadsetDevice(id: "usb-control-interface-appears")
        let state = makeRefactorTestState(device: device, telemetry: RefactorTestStateTelemetry(connection: "usb", batteryPercent: 80, dpiValues: [800, 1600], activeStage: 0))
        let backend = DeviceListUpdatingStubBackend(devices: [device], stateByDeviceID: [device.id: state])
        let appState = await MainActor.run { AppState(launchRole: .app, backend: backend, autoStart: false) }
        await backend.setTransientReadFailures([BridgeError.usbNoControlInterface.localizedDescription], for: device.id)
        await appState.deviceStore.refreshDevices()
        await MainActor.run {
            XCTAssertEqual(appState.deviceStore.currentDeviceStatusIndicator.label, "Unsupported")
            appState.deviceController.applyBackendUSBControlAvailabilityUpdate(deviceID: device.id, availability: .unknown, updatedAt: Date())
        }
        try await waitForAppStateCondition { await MainActor.run { appState.deviceStore.currentDeviceStatusIndicator.label == "Connected" } }
        let reads = await backend.readCount(for: device.id)
        XCTAssertEqual(reads, 2)
        await MainActor.run { XCTAssertTrue(appState.deviceStore.selectedDeviceControlsEnabled) }
    }

    func testUnsupportedAvailabilitySurvivesIPCAndRemoteUnplugReplug() async throws {
        let device = makeHeadsetDevice(id: "remote-no-control-interface")
        let snapshot = SharedServiceSnapshot(devices: [device], stateByDeviceID: [:], lastUpdatedByDeviceID: [:], usbControlAvailabilityByDeviceID: [device.id: .noControlInterface])
        let decoded = try JSONDecoder().decode(SharedServiceSnapshot.self, from: JSONEncoder().encode(snapshot))
        let appState = await MainActor.run { AppState(launchRole: .app, backend: SnapshotTestRemoteBackend(), autoStart: false) }
        await MainActor.run {
            appState.deviceStore.applyRemoteServiceSnapshot(decoded)
            XCTAssertEqual(appState.deviceStore.currentDeviceStatusIndicator.label, "Unsupported")
            XCTAssertFalse(appState.deviceStore.selectedDeviceControlsEnabled)
            appState.deviceStore.applyRemoteServiceSnapshot(SharedServiceSnapshot(devices: [], stateByDeviceID: [:], lastUpdatedByDeviceID: [:]))
            XCTAssertNil(appState.deviceStore.selectedDevice)
            XCTAssertEqual(appState.deviceController.usbControlAvailability(for: device), .unknown)
            appState.deviceStore.applyRemoteServiceSnapshot(decoded)
            XCTAssertEqual(appState.deviceStore.currentDeviceStatusIndicator.label, "Unsupported")
            XCTAssertFalse(appState.deviceStore.selectedDeviceControlsEnabled)
            XCTAssertTrue(appState.runtimeStore.activeFastPollingDeviceIDs(at: Date()).isEmpty)
        }
    }
}
