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
    private let previewEnabled = OSAllocatedUnfairLock(initialState: false)
    private let previewInterval: TimeInterval = 1.0 / 15
    private var lastPreviewAt = Date.distantPast
    private var formatDescription: CMFormatDescription?
    private var model = ""
    private var frameSize = FujiLiveViewSize.xga.pixelSize

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

    func setPreviewEnabled(_ enabled: Bool) {
        previewEnabled.withLock { $0 = enabled }
    }

    func start(size: FujiLiveViewSize, quality: FujiLiveViewQuality) {
        frameSize = size.pixelSize
        manager.apply(size: size, quality: quality)
        manager.start()
    }

    func stop() {
        manager.stop()
        sink.disconnect()
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
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return }

        if let sampleBuffer = makeSampleBuffer(image: image) {
            sink.enqueue(sampleBuffer)
        }

        let wantsPreview = previewEnabled.withLock { $0 }
        if wantsPreview && -lastPreviewAt.timeIntervalSinceNow >= previewInterval {
            lastPreviewAt = Date()
            DispatchQueue.main.async { [onPreviewFrame] in
                onPreviewFrame?(image)
            }
        }
    }

    private func makeSampleBuffer(image: CGImage) -> CMSampleBuffer? {
        let width = frameSize.width
        let height = frameSize.height
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

        if formatDescription == nil || CMVideoFormatDescriptionGetDimensions(formatDescription!).width != Int32(width) {
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
