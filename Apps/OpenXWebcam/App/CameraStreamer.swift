import Foundation
import CoreMedia
import CoreVideo
import ImageIO
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
    private let framing = OSAllocatedUnfairLock(initialState: (aspect: Double?.none, zoom: 1.0, panX: 0.0, panY: 0.0))
    private let previewInterval: TimeInterval = 1.0 / 15
    private var lastPreviewAt = Date.distantPast
    private var formatDescription: CMFormatDescription?
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

    func setFraming(aspect: Double?, zoom: Double, panX: Double, panY: Double) {
        framing.withLock { $0 = (aspect, zoom, panX, panY) }
    }

    func start(size: FujiLiveViewSize, quality: FujiLiveViewQuality) {
        manager.apply(size: size, quality: quality)
        manager.start()
    }

    func apply(size: FujiLiveViewSize, quality: FujiLiveViewQuality) {
        manager.apply(size: size, quality: quality)
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
        let image = frame(orient(cropLetterbox(decoded)))

        if let sampleBuffer = makeSampleBuffer(image: image) {
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

        if -lastPreviewAt.timeIntervalSinceNow >= previewInterval {
            lastPreviewAt = Date()
            DispatchQueue.main.async { [onPreviewFrame] in
                onPreviewFrame?(image)
            }
        }
    }

    private func orient(_ image: CGImage) -> CGImage {
        let (mirrored, rotation) = orientation.withLock { $0 }
        guard mirrored || rotation != 0 else { return image }
        let swapped = rotation == 90 || rotation == 270
        let width = swapped ? image.height : image.width
        let height = swapped ? image.width : image.height
        guard let context = CGContext(data: nil,
                                      width: width, height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return image }
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        if mirrored {
            context.scaleBy(x: -1, y: 1)
        }
        context.rotate(by: -CGFloat(rotation) * .pi / 180)
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2,
                                       y: -CGFloat(image.height) / 2,
                                       width: CGFloat(image.width),
                                       height: CGFloat(image.height)))
        return context.makeImage() ?? image
    }

    private func frame(_ image: CGImage) -> CGImage {
        let (aspect, zoom, panX, panY) = framing.withLock { $0 }
        let ratio = aspect ?? Double(image.width) / Double(image.height)
        let fitWidth = min(Double(image.width), Double(image.height) * ratio)
        let cropWidth = Int(fitWidth / zoom) & ~1
        let cropHeight = Int(fitWidth / ratio / zoom) & ~1
        guard cropWidth < image.width || cropHeight < image.height else { return image }
        let x = Double(image.width - cropWidth) / 2 * (1 + panX)
        let y = Double(image.height - cropHeight) / 2 * (1 + panY)
        let crop = CGRect(x: x.rounded(), y: y.rounded(), width: Double(cropWidth), height: Double(cropHeight))
        return image.cropping(to: crop) ?? image
    }

    private func cropLetterbox(_ image: CGImage) -> CGImage {
        guard image.height * 4 == image.width * 3 else { return image }
        let contentHeight = (image.width * 2 / 3) & ~1
        let bar = (image.height - contentHeight) / 2
        let content = CGRect(x: 0, y: bar, width: image.width, height: contentHeight)
        return image.cropping(to: content) ?? image
    }

    private func makeSampleBuffer(image: CGImage) -> CMSampleBuffer? {
        let width = image.width
        let height = image.height
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer)
        guard let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer),
                                   width: width, height: height,
                                   bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) {
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

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
