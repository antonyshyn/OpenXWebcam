import Foundation
import CoreMediaIO
import CoreVideo
import CoreText
import IOKit.audio

let cameraWidth = 1024
let cameraHeight = 768
let cameraFrameRate = 30

final class ProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: DeviceSource!

    override init() {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: nil)
        deviceSource = DeviceSource(localizedName: "OpenXWebcam")
        try! provider.addDevice(deviceSource.device)
    }

    func connect(to client: CMIOExtensionClient) throws {}

    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = "OpenXWebcam"
        }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

final class DeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var sourceStreamSource: SourceStreamSource!
    private var sinkStreamSource: SinkStreamSource!

    private var formatDescription: CMFormatDescription!
    private var pixelBufferPool: CVPixelBufferPool!

    private let stateQueue = DispatchQueue(label: "com.openxwebcam.app.Extension.state")
    private var splashTimer: DispatchSourceTimer?
    private var lastSinkFrameHostTime: UInt64 = 0
    private var sourceClientCount = 0
    private var sinkClient: CMIOExtensionClient?

    init(localizedName: String) {
        super.init()
        device = CMIOExtensionDevice(localizedName: localizedName,
                                     deviceID: UUID(uuidString: "6E5A9C7B-0001-4F4E-9E5A-9C7B0E4F4E01")!,
                                     legacyDeviceID: "OpenXWebcam",
                                     source: self)

        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                       codecType: kCVPixelFormatType_32BGRA,
                                       width: Int32(cameraWidth), height: Int32(cameraHeight),
                                       extensions: nil,
                                       formatDescriptionOut: &formatDescription)

        let poolAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: cameraWidth,
            kCVPixelBufferHeightKey as String: cameraHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, poolAttributes as CFDictionary, &pixelBufferPool)

        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(cameraFrameRate))
        let streamFormat = CMIOExtensionStreamFormat(formatDescription: formatDescription,
                                                     maxFrameDuration: frameDuration,
                                                     minFrameDuration: frameDuration,
                                                     validFrameDurations: nil)

        sourceStreamSource = SourceStreamSource(localizedName: "OpenXWebcam Video",
                                                streamID: UUID(uuidString: "6E5A9C7B-0002-4F4E-9E5A-9C7B0E4F4E02")!,
                                                format: streamFormat,
                                                device: self)
        sinkStreamSource = SinkStreamSource(localizedName: "OpenXWebcam Sink",
                                            streamID: UUID(uuidString: "6E5A9C7B-0003-4F4E-9E5A-9C7B0E4F4E03")!,
                                            format: streamFormat,
                                            device: self)

        try! device.addStream(sourceStreamSource.stream)
        try! device.addStream(sinkStreamSource.stream)
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = Int(kIOAudioDeviceTransportTypeVirtual)
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = "OpenXWebcam"
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    func sourceStreamStarted() {
        stateQueue.sync {
            sourceClientCount += 1
            if splashTimer == nil { startSplashTimer() }
        }
    }

    func sourceStreamStopped() {
        stateQueue.sync {
            sourceClientCount = max(0, sourceClientCount - 1)
            if sourceClientCount == 0 {
                splashTimer?.cancel()
                splashTimer = nil
            }
        }
    }

    func sinkStreamStarted(client: CMIOExtensionClient) {
        stateQueue.sync { sinkClient = client }
        pullFromSink(client)
    }

    func sinkStreamStopped() {
        stateQueue.sync { sinkClient = nil }
    }

    private func pullFromSink(_ client: CMIOExtensionClient) {
        let stillActive = stateQueue.sync { sinkClient === client }
        guard stillActive else { return }
        sinkStreamSource.stream.consumeSampleBuffer(from: client) { [weak self] sampleBuffer, sequenceNumber, discontinuity, hasMore, error in
            guard let self else { return }
            if let sampleBuffer {
                let hostTime = UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * Double(NSEC_PER_SEC))
                self.stateQueue.sync { self.lastSinkFrameHostTime = hostTime }
                if self.stateQueue.sync(execute: { self.sourceClientCount }) > 0 {
                    self.sourceStreamSource.stream.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: hostTime)
                }
                let output = CMIOExtensionScheduledOutput(sequenceNumber: sequenceNumber, hostTimeInNanoseconds: hostTime)
                self.sinkStreamSource.stream.notifyScheduledOutputChanged(output)
            }
            self.pullFromSink(client)
        }
    }

    private func startSplashTimer() {
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(cameraFrameRate))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * Double(NSEC_PER_SEC))
            let sinkFresh = now < self.lastSinkFrameHostTime + NSEC_PER_SEC
            guard !sinkFresh, self.sourceClientCount > 0 else { return }
            self.sendSplashFrame(hostTime: now)
        }
        timer.resume()
        splashTimer = timer
    }

    private func sendSplashFrame(hostTime: UInt64) {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &pixelBuffer)
        guard let pixelBuffer else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer),
                                   width: cameraWidth, height: cameraHeight,
                                   bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) {
            context.setFillColor(CGColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: cameraWidth, height: cameraHeight))
            drawCenteredText("OpenXWebcam — waiting for camera", in: context)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(cameraFrameRate)),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                           imageBuffer: pixelBuffer,
                                           dataReady: true,
                                           makeDataReadyCallback: nil,
                                           refcon: nil,
                                           formatDescription: formatDescription,
                                           sampleTiming: &timing,
                                           sampleBufferOut: &sampleBuffer)
        if let sampleBuffer {
            sourceStreamSource.stream.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: hostTime)
        }
    }

    private func drawCenteredText(_ text: String, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, 36, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        context.textPosition = CGPoint(x: (CGFloat(cameraWidth) - bounds.width) / 2,
                                       y: (CGFloat(cameraHeight) - bounds.height) / 2)
        CTLineDraw(line, context)
    }
}

final class SourceStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private weak var device: DeviceSource?

    init(localizedName: String, streamID: UUID, format: CMIOExtensionStreamFormat, device: DeviceSource) {
        self.format = format
        self.device = device
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID,
                                     direction: .source, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] {
        [format]
    }

    var activeFormatIndex: Int = 0

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: CMTimeScale(cameraFrameRate))
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        true
    }

    func startStream() throws {
        device?.sourceStreamStarted()
    }

    func stopStream() throws {
        device?.sourceStreamStopped()
    }
}

final class SinkStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private weak var device: DeviceSource?
    private var client: CMIOExtensionClient?

    init(localizedName: String, streamID: UUID, format: CMIOExtensionStreamFormat, device: DeviceSource) {
        self.format = format
        self.device = device
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID,
                                     direction: .sink, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] {
        [format]
    }

    var activeFormatIndex: Int = 0

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: CMTimeScale(cameraFrameRate))
        }
        if properties.contains(.streamSinkBufferQueueSize) {
            streamProperties.sinkBufferQueueSize = 4
        }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            streamProperties.sinkBuffersRequiredForStartup = 1
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        return true
    }

    func startStream() throws {
        if let client {
            device?.sinkStreamStarted(client: client)
        }
    }

    func stopStream() throws {
        device?.sinkStreamStopped()
        client = nil
    }
}
