import Foundation
import CoreImage
import CoreMedia
import CoreVideo
import ImageIO
import VideoToolbox
import os
import CameraEngine

final class CameraStreamer {
    enum State: Equatable {
        case idle
        case waitingForCamera
        case connecting
        case streaming(model: String, fps: Double)
        case failed(String)
    }

    var onStateChange: ((State) -> Void)?
    var onPropertiesChange: (([CameraProperty]) -> Void)?
    var onPreviewFrame: ((CGImage) -> Void)?

    private let manager = CameraManager()
    private let sink = VirtualCameraSink()
    private let frameQueue = DispatchQueue(label: "com.openxwebcam.frames", qos: .userInteractive, autoreleaseFrequency: .workItem)
    private let pendingFrame = OSAllocatedUnfairLock<Data?>(initialState: nil)
    private let orientation = OSAllocatedUnfairLock(initialState: (mirrored: false, rotation: 0))
    private let framing = OSAllocatedUnfairLock(initialState: (zoom: 1.0, panX: 0.0, panY: 0.0))
    private let previewEnabled = OSAllocatedUnfairLock(initialState: false)
    private let previewInterval: TimeInterval = 1.0 / 15
    private var lastPreviewAt = Date.distantPast
    private let ciContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
    private var decoder: VTDecompressionSession?
    private var jpegFormat: CMVideoFormatDescription?
    private var formatDescription: CMFormatDescription?
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    private var model = ""
    private var sinkStalledFrames = 0
    private var decodeFailures = 0

    init() {
        manager.onState = { [weak self] state in
            self?.handle(state)
        }
        manager.onFPS = { [weak self] fps in
            guard let self else { return }
            self.setState(.streaming(model: self.model, fps: fps))
        }
        manager.onFrame = { [weak self] jpeg in
            self?.submit(jpeg)
        }
        manager.onProperties = { [weak self] properties in
            DispatchQueue.main.async {
                self?.onPropertiesChange?(properties)
            }
        }
    }

    var deviceInfo: PTPDeviceInfo? {
        manager.deviceInfo
    }

    func set(property: CameraProperty, to value: PTPPropValue) {
        manager.set(property: property, to: value)
    }

    func setOrientation(mirrored: Bool, rotation: Int) {
        orientation.withLock { $0 = (mirrored, rotation) }
    }

    func setFraming(zoom: Double, panX: Double, panY: Double) {
        framing.withLock { $0 = (zoom, panX, panY) }
    }

    func setPreviewEnabled(_ enabled: Bool) {
        previewEnabled.withLock { $0 = enabled }
    }

    func start(size: FujiLiveViewSize, quality: FujiLiveViewQuality) {
        manager.apply(size: size, quality: quality)
        manager.start()
    }

    func apply(size: FujiLiveViewSize, quality: FujiLiveViewQuality) {
        manager.apply(size: size, quality: quality)
    }

    func setMaxFrameRate(_ fps: Int) {
        manager.setMaxFrameRate(fps)
    }

    func stop() {
        manager.stop()
        disconnectSink()
    }

    func stopAndWait(timeout: TimeInterval) {
        manager.stop()
        frameQueue.sync { sink.disconnect() }
        manager.waitUntilIdle(timeout: timeout)
    }

    private func disconnectSink() {
        frameQueue.async { [sink] in
            sink.disconnect()
        }
    }

    private func handle(_ state: CameraState) {
        switch state {
        case .stopped:
            disconnectSink()
            setState(.idle)
        case .waitingForCamera:
            disconnectSink()
            setState(.waitingForCamera)
        case .connecting:
            if !frameQueue.sync(execute: { sink.isConnected || sink.connect() }) {
                EngineLog.add("sink connect failed")
                manager.stop()
                setState(.failed("Virtual camera not available. Install the camera extension first."))
                return
            }
            setState(.connecting)
        case .streaming(let model):
            self.model = model
            setState(.streaming(model: model, fps: 0))
        case .cameraError(let message):
            disconnectSink()
            setState(.failed(message))
        }
    }

    private func setState(_ state: State) {
        DispatchQueue.main.async { [onStateChange] in
            onStateChange?(state)
        }
    }

    private func submit(_ jpeg: Data) {
        let queued = pendingFrame.withLock { pending in
            defer { pending = jpeg }
            return pending != nil
        }
        guard !queued else { return }
        frameQueue.async { [weak self] in
            guard let self, let jpeg = pendingFrame.withLock({ $0.take() }) else { return }
            push(jpeg)
        }
    }

    private func push(_ jpeg: Data) {
        guard let decoded = decode(jpeg) else {
            decodeFailures += 1
            if decodeFailures == 1 {
                EngineLog.add("frame decode failed")
            }
            return
        }
        guard let pixelBuffer = render(cropLetterbox(decoded)) else { return }

        if let sampleBuffer = makeSampleBuffer(pixelBuffer) {
            if sink.enqueue(sampleBuffer) {
                sinkStalledFrames = 0
            } else {
                sinkStalledFrames += 1
                if sinkStalledFrames == 60 {
                    EngineLog.add("sink not draining, reconnecting")
                    sink.disconnect()
                    if !sink.connect() {
                        EngineLog.add("sink reconnect failed")
                    }
                    sinkStalledFrames = 0
                }
            }
        }

        if previewEnabled.withLock({ $0 }), -lastPreviewAt.timeIntervalSinceNow >= previewInterval {
            lastPreviewAt = Date()
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
            if let image {
                DispatchQueue.main.async { [onPreviewFrame] in
                    onPreviewFrame?(image)
                }
            }
        }
    }

    private func decode(_ jpeg: Data) -> CIImage? {
        if let decoder, let pixelBuffer = decode(jpeg, with: decoder) {
            return CIImage(cvPixelBuffer: pixelBuffer)
        }
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        makeDecoder(width: image.width, height: image.height)
        return CIImage(cgImage: image)
    }

    private func decode(_ jpeg: Data, with decoder: VTDecompressionSession) -> CVPixelBuffer? {
        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: jpeg.count,
                                           blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                           dataLength: jpeg.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &blockBuffer)
        guard let blockBuffer else { return nil }
        jpeg.withUnsafeBytes {
            _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: jpeg.count)
        }
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = jpeg.count
        CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: jpegFormat,
                                  sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                  sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer)
        guard let sampleBuffer else { return nil }
        var pixelBuffer: CVPixelBuffer?
        VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil) { status, _, imageBuffer, _, _ in
            if status == noErr {
                pixelBuffer = imageBuffer
            }
        }
        return pixelBuffer
    }

    private func makeDecoder(width: Int, height: Int) {
        let dimensions = jpegFormat.map(CMVideoFormatDescriptionGetDimensions)
        guard dimensions?.width != Int32(width) || dimensions?.height != Int32(height) else { return }
        if let decoder {
            VTDecompressionSessionInvalidate(decoder)
        }
        decoder = nil
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_JPEG,
                                       width: Int32(width), height: Int32(height), extensions: nil, formatDescriptionOut: &jpegFormat)
        guard let jpegFormat else { return }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr8,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: jpegFormat, decoderSpecification: nil,
                                     imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &decoder)
    }

    private func render(_ image: CIImage) -> CVPixelBuffer? {
        let (mirrored, rotation) = orientation.withLock { $0 }
        let (zoom, panX, panY) = framing.withLock { $0 }
        let extent = image.extent
        let swapped = rotation == 90 || rotation == 270
        let width = Int(swapped ? extent.height : extent.width)
        let height = Int(swapped ? extent.width : extent.height)
        let cropWidth = Int(Double(width) / zoom) & ~1
        let cropHeight = Int(Double(height) / zoom) & ~1
        let x = (Double(width - cropWidth) / 2 * (1 + panX)).rounded()
        let y = (Double(height - cropHeight) / 2 * (1 + panY)).rounded()
        guard let pixelBuffer = makePixelBuffer(width: cropWidth, height: cropHeight) else { return nil }

        var transform = CGAffineTransform(translationX: CGFloat(width) / 2 - x, y: y + CGFloat(cropHeight) - CGFloat(height) / 2)
        if mirrored {
            transform = transform.scaledBy(x: -1, y: 1)
        }
        transform = transform
            .rotated(by: -CGFloat(rotation) * .pi / 180)
            .translatedBy(x: -extent.midX, y: -extent.midY)
        ciContext.render(image.transformed(by: transform), to: pixelBuffer,
                         bounds: CGRect(x: 0, y: 0, width: cropWidth, height: cropHeight), colorSpace: nil)
        return pixelBuffer
    }

    private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolSize != (width, height) {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
            pool = nil
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
            poolSize = (width, height)
        }
        guard let pool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        return pixelBuffer
    }

    private func cropLetterbox(_ image: CIImage) -> CIImage {
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)
        guard height * 4 == width * 3 else { return image }
        let contentHeight = (width * 2 / 3) & ~1
        let bar = (height - contentHeight) / 2
        return image.cropped(to: CGRect(x: 0, y: bar, width: width, height: contentHeight))
    }

    private func makeSampleBuffer(_ pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let dimensions = formatDescription.map(CMVideoFormatDescriptionGetDimensions)
        if dimensions?.width != Int32(width) || dimensions?.height != Int32(height) {
            var description: CMFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &description)
            formatDescription = description
        }
        guard let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                           imageBuffer: pixelBuffer,
                                           dataReady: true,
                                           makeDataReadyCallback: nil,
                                           refcon: nil,
                                           formatDescription: formatDescription,
                                           sampleTiming: &timing,
                                           sampleBufferOut: &sampleBuffer)
        return sampleBuffer
    }
}
