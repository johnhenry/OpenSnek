import Foundation
import Darwin
import IOKit
import IOKit.hid
import OpenSnekProtocols

/// Groups transport-level assumptions for the legacy Kraken protocol that the
/// hardware-spike agent is still validating against real devices.
///
/// PARENT-MERGE: confirm with spike findings. If the spike finds requests must
/// include the leading report-id byte, or that responses never arrive as input
/// reports (GetReport-only), flip these two knobs.
public enum KrakenLegacyTransportAssumptions {
    /// When true, `IOHIDDeviceSetReport` is called with the report bytes WITHOUT
    /// the leading report-id byte (the report ID is passed as the `reportID`
    /// argument instead). When false, the full buffer (report-id byte included)
    /// is sent as-is.
    public static let stripsLeadingReportIDOnSend = true

    /// When true, the session registers an input-report callback and treats
    /// unsolicited/async input reports as command responses. When false, only
    /// the `GetReport` poll fallback is used.
    public static let usesInputReportCallback = true
}

/// Coordinates a control session with a legacy-protocol Razer Kraken headset over
/// its single consumer-control USB HID interface. Modeled on
/// `USBHIDControlSession`: per-device recursive lock plus a matching flock-based
/// interprocess lock, so a Kraken headset and a Razer mouse never race for the
/// same physical device concurrently from different processes.
public final class KrakenLegacyControlSession: @unchecked Sendable {
    /// Stores interprocess device lock data.
    private struct InterprocessDeviceLock {
        let fd: Int32

        func release() {
            _ = flock(fd, LOCK_UN)
            _ = close(fd)
        }
    }

    /// Coordinates device lock registry behavior, shared by deviceID with
    /// `USBHIDControlSession` so a headset and a mouse sharing a device ID
    /// (never expected in practice, but kept consistent) still serialize.
    private final class DeviceLockRegistry: @unchecked Sendable {
        private let registryLock = NSLock()
        private var deviceLocks: [String: NSRecursiveLock] = [:]

        func lock(for deviceID: String) -> NSRecursiveLock {
            registryLock.lock()
            defer { registryLock.unlock() }
            if let lock = deviceLocks[deviceID] { return lock }
            let lock = NSRecursiveLock()
            lock.name = "open.snek.usb.kraken.device.\(deviceID)"
            deviceLocks[deviceID] = lock
            return lock
        }
    }

    public let device: IOHIDDevice
    public let deviceID: String

    private static let deviceLockRegistry = DeviceLockRegistry()

    private let callbackQueue = DispatchQueue(label: "open.snek.usb.kraken.callback")
    private var isScheduledOnCallbackQueue = false
    private var pendingInputReports: [[UInt8]] = []
    private let pendingReportsLock = NSLock()

    public init(device: IOHIDDevice, deviceID: String) {
        self.device = device
        self.deviceID = deviceID
    }

    public func withExclusiveDeviceAccess<T>(_ body: () throws -> T) throws -> T {
        let lock = Self.deviceLock(for: deviceID)
        lock.lock()
        defer { lock.unlock() }

        let depth = Self.currentThreadLockDepth(for: deviceID)
        if depth > 0 {
            Self.setCurrentThreadLockDepth(depth + 1, for: deviceID)
            defer { Self.setCurrentThreadLockDepth(depth, for: deviceID) }
            return try body()
        }

        let fileLock = try Self.acquireInterprocessDeviceLock(for: deviceID)
        Self.setCurrentThreadLockDepth(1, for: deviceID)
        defer {
            Self.setCurrentThreadLockDepth(0, for: deviceID)
            fileLock.release()
        }
        return try body()
    }

    /// Sends `request` (a full `KrakenLegacyProtocol.requestLength`-byte report,
    /// report-id byte included) and waits for a matching response, retrying the
    /// read up to `responseAttempts` times within `responseTimeout` seconds.
    ///
    /// Prefers an input-report callback (registered on a dedicated dispatch
    /// queue, per `KrakenLegacyTransportAssumptions.usesInputReportCallback`)
    /// and falls back to a `GetReport(input)` poll when no callback report
    /// arrives in time.
    public func exchange(request: [UInt8], responseAttempts: Int = 6, responseTimeout: TimeInterval = 0.5) throws -> [UInt8] {
        try withExclusiveDeviceAccess {
            let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            guard openResult == kIOReturnSuccess else {
                if openResult == kIOReturnNotPermitted { throw BridgeError.commandFailed("USB HID access denied. Grant Input Monitoring and relaunch.") }
                if USBHIDSupport.isDeviceUnavailableOpenResult(openResult) { throw BridgeError.commandFailed("Device not available") }
                throw BridgeError.commandFailed("Failed to open Kraken HID device (\(openResult))")
            }
            defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

            if KrakenLegacyTransportAssumptions.usesInputReportCallback { scheduleInputReportCallbackIfNeeded() }
            clearPendingInputReports()

            try sendRequest(request)

            let deadline = Date().addingTimeInterval(responseTimeout)
            let perAttemptTimeout = responseTimeout / Double(max(1, responseAttempts))
            for _ in 0..<max(1, responseAttempts) {
                if KrakenLegacyTransportAssumptions.usesInputReportCallback, let callbackReport = waitForCallbackReport(timeout: min(perAttemptTimeout, max(0, deadline.timeIntervalSinceNow))) { return callbackReport }
                if let polled = try? pollGetReport() { return polled }
                if Date() >= deadline { break }
            }
            throw BridgeError.commandFailed("Kraken device did not respond")
        }
    }

    /// Sends an ordered sequence of write reports (e.g. from
    /// `KrakenLegacyProtocol.setEffectReports(for:)`), waiting for and
    /// discarding a response after each write, with `interRequestDelayUs`
    /// between writes to give firmware time to settle.
    public func perform(requests: [[UInt8]], interRequestDelayUs: useconds_t = 5_000) throws -> Bool {
        for request in requests {
            _ = try exchange(request: request)
            if interRequestDelayUs > 0 { usleep(interRequestDelayUs) }
        }
        return true
    }

    private func sendRequest(_ request: [UInt8]) throws {
        let payload: [UInt8]
        let reportID: CFIndex
        if KrakenLegacyTransportAssumptions.stripsLeadingReportIDOnSend, request.first == KrakenLegacyProtocol.reportID {
            payload = Array(request.dropFirst())
            reportID = CFIndex(KrakenLegacyProtocol.reportID)
        } else {
            payload = request
            reportID = CFIndex(KrakenLegacyProtocol.reportID)
        }

        let setResult = payload.withUnsafeBufferPointer { ptr -> IOReturn in
            guard let base = ptr.baseAddress else { return kIOReturnError }
            return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, reportID, base, ptr.count)
        }
        guard setResult == kIOReturnSuccess else {
            if setResult == kIOReturnNotPermitted { throw BridgeError.commandFailed("USB HID access denied. Grant Input Monitoring and relaunch.") }
            throw BridgeError.commandFailed("Failed to write Kraken HID report (\(setResult))")
        }
    }

    private func pollGetReport() throws -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: KrakenLegacyProtocol.responseLength)
        var length = out.count
        let getResult = out.withUnsafeMutableBufferPointer { ptr -> IOReturn in
            guard let base = ptr.baseAddress else { return kIOReturnError }
            return IOHIDDeviceGetReport(device, kIOHIDReportTypeInput, CFIndex(KrakenLegacyProtocol.reportID), base, &length)
        }
        guard getResult == kIOReturnSuccess, length > 0 else { return nil }
        return Array(out.prefix(length))
    }

    private func scheduleInputReportCallbackIfNeeded() {
        guard !isScheduledOnCallbackQueue else { return }
        isScheduledOnCallbackQueue = true

        let context = Unmanaged.passUnretained(self).toOpaque()
        let bufferSize = max(KrakenLegacyProtocol.responseLength, 64)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)

        IOHIDDeviceRegisterInputReportCallback(
            device, buffer, bufferSize,
            { context, _, _, _, _, report, reportLength in
                guard let context else { return }
                let session = Unmanaged<KrakenLegacyControlSession>.fromOpaque(context).takeUnretainedValue()
                let bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
                session.appendPendingInputReport(bytes)
            }, context)

        IOHIDDeviceSetDispatchQueue(device, callbackQueue)
        IOHIDDeviceActivate(device)
    }

    private func appendPendingInputReport(_ report: [UInt8]) {
        pendingReportsLock.lock()
        pendingInputReports.append(report)
        pendingReportsLock.unlock()
    }

    private func clearPendingInputReports() {
        pendingReportsLock.lock()
        pendingInputReports.removeAll()
        pendingReportsLock.unlock()
    }

    private func takePendingInputReport() -> [UInt8]? {
        pendingReportsLock.lock()
        defer { pendingReportsLock.unlock() }
        guard !pendingInputReports.isEmpty else { return nil }
        return pendingInputReports.removeFirst()
    }

    private func waitForCallbackReport(timeout: TimeInterval) -> [UInt8]? {
        guard timeout > 0 else { return takePendingInputReport() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let report = takePendingInputReport() { return report }
            usleep(2_000)
        }
        return takePendingInputReport()
    }

    private static func deviceLock(for deviceID: String) -> NSRecursiveLock { deviceLockRegistry.lock(for: deviceID) }

    private static func interprocessLockURL(for deviceID: String) throws -> URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/OpenSnek/HIDLocks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(USBHIDControlSession.interprocessLockFileName(for: deviceID))
    }

    private static func acquireInterprocessDeviceLock(for deviceID: String) throws -> InterprocessDeviceLock {
        let url = try interprocessLockURL(for: deviceID)
        let fd = url.path.withCString { path in open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR) }
        guard fd >= 0 else { throw BridgeError.commandFailed("Kraken HID lock open failed for \(deviceID): errno \(errno)") }

        while true {
            if flock(fd, LOCK_EX) == 0 { return InterprocessDeviceLock(fd: fd) }
            if errno == EINTR { continue }
            let lockErrno = errno
            _ = close(fd)
            throw BridgeError.commandFailed("Kraken HID lock failed for \(deviceID): errno \(lockErrno)")
        }
    }

    private static func currentThreadLockDepth(for deviceID: String) -> Int { Thread.current.threadDictionary[threadLockDepthKey(for: deviceID)] as? Int ?? 0 }

    private static func setCurrentThreadLockDepth(_ depth: Int, for deviceID: String) {
        let key = threadLockDepthKey(for: deviceID)
        if depth <= 0 { Thread.current.threadDictionary.removeObject(forKey: key) } else { Thread.current.threadDictionary[key] = depth }
    }

    private static func threadLockDepthKey(for deviceID: String) -> String { "open.snek.usb.kraken.device.lock.depth.\(deviceID)" }
}
