import Foundation
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
    private let orientation = OSAllocatedUnfairLock(initialState: (mirrored: false, rotation: 0))
    private let framing = OSAllocatedUnfairLock(initialState: (zoom: 1.0, panX: 0.0, panY: 0.0))
    private let previewEnabled = OSAllocatedUnfairLock(initialState: false)
    private let previewInterval: TimeInterval = 1.0 / 15
    private var lastPreviewAt = Date.distantPast
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
            self?.push(jpeg)
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
        sink.disconnect()
    }

    func stopAndWait(timeout: TimeInterval) {
        manager.stop()
        sink.disconnect()
        manager.waitUntilIdle(timeout: timeout)
    }

    private func handle(_ state: CameraState) {
        switch state {
        case .stopped:
            sink.disconnect()
            setState(.idle)
        case .waitingForCamera:
            sink.disconnect()
            setState(.waitingForCamera)
        case .connecting:
            if !sink.isConnected && !sink.connect() {
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
            sink.disconnect()
            setState(.failed(message))
        }
    }

    private func setState(_ state: State) {
        DispatchQueue.main.async { [onStateChange] in
            onStateChange?(state)
        }
    }

    private func push(_ jpeg: Data) {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else {
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

    private func render(_ image: CGImage) -> CVPixelBuffer? {
        let (mirrored, rotation) = orientation.withLock { $0 }
        let (zoom, panX, panY) = framing.withLock { $0 }
        let swapped = rotation == 90 || rotation == 270
        let width = swapped ? image.height : image.width
        let height = swapped ? image.width : image.height
        let cropWidth = Int(Double(width) / zoom) & ~1
        let cropHeight = Int(Double(height) / zoom) & ~1
        let x = (Double(width - cropWidth) / 2 * (1 + panX)).rounded()
        let y = (Double(height - cropHeight) / 2 * (1 + panY)).rounded()
        guard let pixelBuffer = makePixelBuffer(width: cropWidth, height: cropHeight) else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer),
                                      width: cropWidth, height: cropHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }
        context.translateBy(x: CGFloat(width) / 2 - x, y: y + CGFloat(cropHeight) - CGFloat(height) / 2)
        if mirrored {
            context.scaleBy(x: -1, y: 1)
        }
        context.rotate(by: -CGFloat(rotation) * .pi / 180)
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2,
                                       y: -CGFloat(image.height) / 2,
                                       width: CGFloat(image.width),
                                       height: CGFloat(image.height)))
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

    private func cropLetterbox(_ image: CGImage) -> CGImage {
        guard image.height * 4 == image.width * 3 else { return image }
        let contentHeight = (image.width * 2 / 3) & ~1
        let bar = (image.height - contentHeight) / 2
        let content = CGRect(x: 0, y: bar, width: image.width, height: contentHeight)
        return image.cropping(to: content) ?? image
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
