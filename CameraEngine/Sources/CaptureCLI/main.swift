import Foundation
import CameraEngine
import CPTPTransport

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

let arguments = CommandLine.arguments

if arguments.count > 1 && arguments[1] == "watch" {
    let seconds = arguments.count > 2 ? Int(arguments[2]) ?? 60 : 60
    let manager = CameraManager()
    manager.onState = { state in
        print("state: \(state)")
    }
    manager.onFPS = { fps in
        print(String(format: "fps: %.1f", fps))
    }
    manager.start()
    print("watching for \(seconds)s — plug, unplug, power the camera off and on")
    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) {
        manager.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1)) { exit(0) }
    }
    RunLoop.main.run()
}

let frameCount = arguments.count > 1 ? Int(arguments[1]) ?? 30 : 30
let size = arguments.count > 2 ? FujiLiveViewSize(rawValue: UInt16(arguments[2]) ?? 0) : .xga
let quality = arguments.count > 3 ? FujiLiveViewQuality(rawValue: UInt16(arguments[3]) ?? 0) : .normal

guard let camera = CameraDiscovery.firstFuji() else {
    fail("no fuji camera found; check cable, usb mode and auto power off")
}
print("found camera: vid=0x\(String(camera.info.vendorID, radix: 16)) pid=0x\(String(camera.info.productID, radix: 16))")

CameraDiscovery.killPtpcamerad()

let transport = PTPUSBTransport(service: camera.info.service)
do {
    try transport.openSeizing()
} catch {
    fail("usb open failed: \(error.localizedDescription)")
}
defer { transport.close() }

let session = PTPSession(transport: transport)
let openRC = try session.open()
guard openRC == PTPRC.ok else { fail("open session failed: 0x\(String(openRC, radix: 16))") }

guard let info = try session.deviceInfo() else { fail("device info failed") }
print("model: \(info.manufacturer) \(info.model) \(info.deviceVersion)")
print("vendor ext: 0x\(String(info.vendorExtensionID, radix: 16)) \"\(info.vendorExtensionDesc)\"")

let fuji = FujiCamera(session: session)
try fuji.prepare(size: size, quality: quality)
try fuji.startLiveView()
print("live view started")

let framesDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("frames")
try FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)

var saved = 0
var firstFrameAt: Date?
var polls = 0
while saved < frameCount && polls < frameCount * 50 {
    polls += 1
    guard let jpeg = try fuji.nextFrame() else {
        usleep(5000)
        continue
    }
    if firstFrameAt == nil {
        firstFrameAt = Date()
        print("first frame: \(jpeg.count) bytes")
    }
    try jpeg.write(to: framesDir.appendingPathComponent(String(format: "frame_%03d.jpg", saved)))
    saved += 1
}

try fuji.stopLiveView()
_ = try session.close()

let elapsed = firstFrameAt.map { -$0.timeIntervalSinceNow } ?? 0
let fps = elapsed > 0 && saved > 1 ? Double(saved - 1) / elapsed : 0
print("frames: \(saved), fps: \(String(format: "%.1f", fps))")
exit(saved >= 2 ? 0 : 1)
