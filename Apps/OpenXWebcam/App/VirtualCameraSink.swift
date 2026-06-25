import Foundation
import CoreMediaIO
import CoreMedia

final class VirtualCameraSink {
    private var deviceID: CMIODeviceID = 0
    private var sinkStreamID: CMIOStreamID = 0
    private var queue: CMSimpleQueue?
    private var started = false

    var isConnected: Bool {
        queue != nil
    }

    func connect(deviceUID: String = "OpenXWebcam") -> Bool {
        guard let device = Self.findDevice(uid: deviceUID) else { return false }
        let streams = Self.streamIDs(of: device)
        guard streams.count >= 2 else { return false }
        deviceID = device
        sinkStreamID = streams[1]

        var queueOut: Unmanaged<CMSimpleQueue>?
        let status = CMIOStreamCopyBufferQueue(sinkStreamID, { _, _, _ in }, nil, &queueOut)
        guard status == 0, let queueOut else { return false }
        queue = queueOut.takeRetainedValue()

        guard CMIODeviceStartStream(deviceID, sinkStreamID) == 0 else {
            queue = nil
            return false
        }
        started = true
        return true
    }

    func disconnect() {
        if started {
            CMIODeviceStopStream(deviceID, sinkStreamID)
            started = false
        }
        queue = nil
    }

    @discardableResult
    func enqueue(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let queue, CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else { return false }
        let status = CMSimpleQueueEnqueue(queue, element: Unmanaged.passRetained(sampleBuffer).toOpaque())
        if status != 0 {
            Unmanaged<CMSampleBuffer>.fromOpaque(Unmanaged.passUnretained(sampleBuffer).toOpaque()).release()
            return false
        }
        return true
    }

    private static func findDevice(uid: String) -> CMIODeviceID? {
        for device in allDevices() {
            if stringProperty(of: device, selector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID)) == uid {
                return device
            }
        }
        return nil
    }

    private static func allDevices() -> [CMIODeviceID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &dataSize) == 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<CMIODeviceID>.size
        var devices = [CMIODeviceID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, dataSize, &dataUsed, &devices) == 0 else { return [] }
        return devices
    }

    private static func streamIDs(of device: CMIODeviceID) -> [CMIOStreamID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<CMIOStreamID>.size
        var streams = [CMIOStreamID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyData(device, &address, 0, nil, dataSize, &dataUsed, &streams) == 0 else { return [] }
        return streams
    }

    private static func stringProperty(of object: CMIOObjectID, selector: CMIOObjectPropertySelector) -> String? {
        var address = CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        guard CMIOObjectHasProperty(object, &address) else { return nil }
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &dataSize) == 0 else { return nil }
        var value: Unmanaged<CFString>?
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, dataSize, &dataUsed, &value) == 0, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
