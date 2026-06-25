import Foundation
import CoreMedia
import CoreVideo
import ImageIO
import CameraEngine
import CPTPTransport

final class CameraStreamer {
    enum State: Equatable {
        case idle
        case connecting
        case streaming(model: String, fps: Double)
        case failed(String)
    }

    var onStateChange: ((State) -> Void)?

    private let sink = VirtualCameraSink()
    private var thread: Thread?
    private var shouldRun = false
    private var formatDescription: CMFormatDescription?

    func start(size: FujiLiveViewSize, quality: FujiLiveViewQuality) {
        guard thread == nil else { return }
        shouldRun = true
        let thread = Thread { [weak self] in
            self?.run(size: size, quality: quality)
        }
        thread.name = "camera-streamer"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    func stop() {
        shouldRun = false
    }

    private func setState(_ state: State) {
        DispatchQueue.main.async { [onStateChange] in
            onStateChange?(state)
        }
    }

    private func run(size: FujiLiveViewSize, quality: FujiLiveViewQuality) {
        defer {
            thread = nil
            sink.disconnect()
            setState(.idle)
        }
        setState(.connecting)

        guard let camera = CameraDiscovery.firstFuji() else {
            setState(.failed("No Fujifilm camera found. Check the cable, USB mode and Auto Power Off."))
            return
        }
        guard sink.connect() else {
            setState(.failed("Virtual camera not available. Install the camera extension first."))
            return
        }

        CameraDiscovery.killPtpcamerad()
        let transport = PTPUSBTransport(service: camera.info.service)
        do {
            try transport.openSeizing()
        } catch {
            setState(.failed("USB open failed: \(error.localizedDescription)"))
            return
        }
        defer { transport.close() }

        let session = PTPSession(transport: transport)
        do {
            let rc = try session.open()
            guard rc == PTPRC.ok else {
                setState(.failed(String(format: "Session open failed: 0x%04X", rc)))
                return
            }
            let model = try session.deviceInfo()?.model ?? "camera"
            let fuji = FujiCamera(session: session)
            try fuji.prepare(size: size, quality: quality)
            try fuji.startLiveView()
            setState(.streaming(model: model, fps: 0))

            var frames = 0
            var windowStart = Date()
            while shouldRun {
                guard let jpeg = try fuji.nextFrame() else {
                    usleep(5000)
                    continue
                }
                if let sampleBuffer = makeSampleBuffer(jpeg: jpeg, size: size) {
                    sink.enqueue(sampleBuffer)
                }
                frames += 1
                let elapsed = -windowStart.timeIntervalSinceNow
                if elapsed >= 2 {
                    setState(.streaming(model: model, fps: Double(frames) / elapsed))
                    frames = 0
                    windowStart = Date()
                }
            }
            try fuji.stopLiveView()
            _ = try session.close()
        } catch {
            setState(.failed("Camera error: \(error.localizedDescription)"))
        }
    }

    private func makeSampleBuffer(jpeg: Data, size: FujiLiveViewSize) -> CMSampleBuffer? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }

        let width = size.pixelSize.width
        let height = size.pixelSize.height
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
