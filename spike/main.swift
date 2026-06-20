// OpenXWebcam — Phase 0 feasibility spike
//
// Goal: prove we can pull Fujifilm X-T30 live-view frames over USB WITHOUT a
// capture card and WITHOUT disabling SIP, by relaying PTP commands through
// Apple's ImageCaptureCore (`requestSendPTPCommand`) instead of claiming the
// USB interface ourselves.
//
// Flow:
//   1. ICDeviceBrowser -> find the camera (prefer X-T30 / Fujifilm)
//   2. open an ICCameraDevice session
//   3. send the Fuji live-view PTP sequence:
//        InitiateOpenCapture(0x101C) -> [GetObjectInfo / GetObject / DeleteObject
//        on handle 0x80000001] loop -> TerminateOpenCapture(0x1018)
//   4. save ~30 JPEG frames, report achievable fps.
//
// PTP opcode sequence is a protocol fact taken from libgphoto2's ptp2 driver
// (camlibs/ptp2/library.c). No third-party source is reused here.

import Foundation
@preconcurrency import ImageCaptureCore
import AppKit

// MARK: - Little-endian byte helpers

extension Data {
    mutating func appendLE(_ v: UInt16) { var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) } }
    mutating func appendLE(_ v: UInt32) { var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) } }
    func readLE16(_ off: Int) -> UInt16 {
        guard off + 2 <= count else { return 0 }
        return UInt16(self[startIndex + off]) | (UInt16(self[startIndex + off + 1]) << 8)
    }
    func readLE32(_ off: Int) -> UInt32 {
        guard off + 4 <= count else { return 0 }
        return UInt32(self[startIndex + off]) | (UInt32(self[startIndex + off + 1]) << 8)
             | (UInt32(self[startIndex + off + 2]) << 16) | (UInt32(self[startIndex + off + 3]) << 24)
    }
}

// MARK: - PTP constants

enum PTP {
    // Container type: we build the USB PTP command container ourselves.
    static let typeCommand: UInt16 = 0x0001

    // Standard opcodes
    static let GetDeviceInfo: UInt16        = 0x1001
    static let GetObjectInfo: UInt16        = 0x1008
    static let GetObject: UInt16            = 0x1009
    static let DeleteObject: UInt16         = 0x100B
    static let InitiateOpenCapture: UInt16  = 0x101C
    static let TerminateOpenCapture: UInt16 = 0x1018
    static let SetDevicePropValue: UInt16   = 0x1016
    static let GetDevicePropDesc: UInt16    = 0x1014
    static let GetDevicePropValue: UInt16   = 0x1015
    // Fuji vendor opcodes
    static let FujiGetDeviceInfo: UInt16        = 0x902B
    static let FujiCancelInitiateCapture: UInt16 = 0x9030

    // Fuji live-view object handle (synthetic)
    static let liveViewHandle: UInt32 = 0x80000001

    // Response codes
    static let RC_OK: UInt16                 = 0x2001
    static let RC_InvalidObjectHandle: UInt16 = 0x2009
    static let RC_AccessDenied: UInt16       = 0x200F
    static let RC_DeviceBusy: UInt16         = 0x2019

    /// Build a USB PTP command container: length | type(0x0001) | opcode | transactionID | params...
    static func command(_ op: UInt16, tid: UInt32, params: [UInt32] = []) -> Data {
        var d = Data()
        d.appendLE(UInt32(12 + params.count * 4))
        d.appendLE(typeCommand)
        d.appendLE(op)
        d.appendLE(tid)
        for p in params { d.appendLE(p) }
        return d
    }
}

struct PTPResponse {
    let code: UInt16
    let transactionID: UInt32
    let params: [UInt32]
    var ok: Bool { code == PTP.RC_OK }
}

/// Parse a PTP response container: length(4) | type(2) | code(2) | transactionID(4) | params...
func parseResponse(_ data: Data?) -> PTPResponse? {
    guard let d = data, d.count >= 12 else { return nil }
    let code = d.readLE16(6)
    let tid = d.readLE32(8)
    var params: [UInt32] = []
    var off = 12
    while off + 4 <= d.count { params.append(d.readLE32(off)); off += 4 }
    return PTPResponse(code: code, transactionID: tid, params: params)
}

func hex16(_ v: UInt16?) -> String { v.map { String(format: "0x%04X", $0) } ?? "nil" }

/// Parse a PTP DeviceInfo dataset far enough to extract VendorExtensionID and the
/// OperationsSupported opcode list. This tells us exactly which opcodes the camera
/// advertises — the list ImageCaptureCore appears to filter against.
func parseDeviceInfo(_ d: Data) -> (vendorExtID: UInt32, operations: [UInt16], events: [UInt16], deviceProps: [UInt16], manufacturer: String, model: String, version: String, serial: String) {
    var off = 0
    func u16() -> UInt16 { let v = d.readLE16(off); off += 2; return v }
    func u32() -> UInt32 { let v = d.readLE32(off); off += 4; return v }
    func readString() -> String {
        guard off < d.count else { return "" }
        let nChars = Int(d[d.startIndex + off]); off += 1   // count of UTF-16LE code units, incl. trailing null
        if nChars == 0 { return "" }
        var units: [UInt16] = []
        var i = 0
        while i < nChars && off + i * 2 + 2 <= d.count {
            let c = d.readLE16(off + i * 2)
            if c != 0 { units.append(c) }
            i += 1
        }
        off += nChars * 2
        return String(decoding: units, as: UTF16.self)
    }
    func u16Array() -> [UInt16] {
        let n = Int(u32()); var a: [UInt16] = []; var i = 0
        while i < n && off + 2 <= d.count { a.append(u16()); i += 1 }
        return a
    }
    _ = u16()                       // StandardVersion
    let vendorExtID = u32()         // VendorExtensionID
    _ = u16()                       // VendorExtensionVersion
    _ = readString()                // VendorExtensionDesc
    _ = u16()                       // FunctionalMode
    let ops = u16Array()            // OperationsSupported
    let events = u16Array()         // EventsSupported
    let props = u16Array()          // DevicePropertiesSupported
    _ = u16Array()                  // CaptureFormats
    _ = u16Array()                  // ImageFormats
    let manufacturer = readString() // Manufacturer
    let model = readString()        // Model
    let version = readString()      // DeviceVersion
    let serial = readString()       // SerialNumber
    return (vendorExtID, ops, events, props, manufacturer, model, version, serial)
}

// MARK: - PTP DevicePropDesc parsing

/// A parsed PTP device-property descriptor (GetDevicePropDesc / 0x1014).
/// Layout: propCode(u16) | dataType(u16) | getSet(u8) | factoryDefault<DTS> |
///         currentValue<DTS> | formFlag(u8) | [range: min/max/step | enum: count(u16)+values]
struct PropDesc {
    let code: UInt16
    let dataType: UInt16
    let getSet: UInt8            // 0 = read-only, 1 = read/write
    let factoryDefault: UInt64?
    let current: UInt64?
    let formFlag: UInt8          // 0 none, 1 range, 2 enum
    let range: (min: UInt64, max: UInt64, step: UInt64)?
    let enumValues: [UInt64]
}

/// Byte width of a PTP integer datatype; 0 for string/unknown.
func ptpTypeSize(_ t: UInt16) -> Int {
    switch t {
    case 0x0001, 0x0002: return 1   // INT8 / UINT8
    case 0x0003, 0x0004: return 2   // INT16 / UINT16
    case 0x0005, 0x0006: return 4   // INT32 / UINT32
    case 0x0007, 0x0008: return 8   // INT64 / UINT64
    default: return 0
    }
}

func ptpTypeName(_ t: UInt16) -> String {
    switch t {
    case 0x0001: return "INT8"
    case 0x0002: return "UINT8"
    case 0x0003: return "INT16"
    case 0x0004: return "UINT16"
    case 0x0005: return "INT32"
    case 0x0006: return "UINT32"
    case 0x0007: return "INT64"
    case 0x0008: return "UINT64"
    case 0xFFFF: return "STR"
    default:     return String(format: "T0x%04X", t)
    }
}

func parsePropDesc(_ d: Data) -> PropDesc? {
    guard d.count >= 5 else { return nil }
    var off = 0
    func u8() -> UInt8 { let v = d[d.startIndex + off]; off += 1; return v }
    func u16() -> UInt16 { let v = d.readLE16(off); off += 2; return v }
    // Read one value of the property's datatype; advances past strings but returns nil for them.
    func readVal(_ t: UInt16) -> UInt64? {
        if t == 0xFFFF {                       // PTP string: len byte + UTF-16 units
            guard off < d.count else { return nil }
            let n = Int(d[d.startIndex + off]); off += 1
            off += n * 2
            return nil
        }
        let n = ptpTypeSize(t)
        guard n > 0, off + n <= d.count else { return nil }
        var v: UInt64 = 0
        for i in 0..<n { v |= UInt64(d[d.startIndex + off + i]) << (8 * i) }
        off += n
        return v
    }
    let code = u16()
    let dataType = u16()
    guard off < d.count else { return nil }
    let getSet = u8()
    let factory = readVal(dataType)
    let current = readVal(dataType)
    var formFlag: UInt8 = 0
    var range: (min: UInt64, max: UInt64, step: UInt64)? = nil
    var enumVals: [UInt64] = []
    if off < d.count {
        formFlag = u8()
        if formFlag == 0x01 {
            let mn = readVal(dataType) ?? 0
            let mx = readVal(dataType) ?? 0
            let st = readVal(dataType) ?? 0
            range = (mn, mx, st)
        } else if formFlag == 0x02 && off + 2 <= d.count {
            let cnt = Int(u16()); var i = 0
            while i < cnt, let v = readVal(dataType) { enumVals.append(v); i += 1 }
        }
    }
    return PropDesc(code: code, dataType: dataType, getSet: getSet,
                    factoryDefault: factory, current: current,
                    formFlag: formFlag, range: range, enumValues: enumVals)
}

func fmtPropDesc(_ p: PropDesc) -> String {
    let rw = p.getSet == 1 ? "rw" : "ro"
    let cur = p.current.map { String($0) } ?? "?"
    let def = p.factoryDefault.map { String($0) } ?? "?"
    var form = ""
    if p.formFlag == 0x01, let r = p.range {
        form = "  range=[\(r.min)…\(r.max) step \(r.step)]"
    } else if p.formFlag == 0x02 {
        form = "  enum=\(p.enumValues)"
    }
    return String(format: "0x%04X %-7@ %@ cur=%@ def=%@%@",
                  p.code, ptpTypeName(p.dataType) as NSString, rw, cur, def, form)
}

/// Hex preview of a Data blob (for raw wire debugging).
func hexPreview(_ d: Data?, _ maxBytes: Int = 24) -> String {
    guard let d = d else { return "nil" }
    let shown = d.prefix(maxBytes).map { String(format: "%02X", $0) }.joined(separator: " ")
    return "\(d.count)B [\(shown)\(d.count > maxBytes ? " …" : "")]"
}

// MARK: - Logging

func log(_ s: String) {
    let line = s + "\n"
    FileHandle.standardOutput.write(line.data(using: .utf8)!)
}

// MARK: - Spike coordinator

final class Spike: NSObject, ICDeviceBrowserDelegate, ICDeviceDelegate {
    let browser = ICDeviceBrowser()
    var camera: ICCameraDevice?
    private var tid: UInt32 = 0
    var verbose = true   // dump raw PTP bytes while debugging

    // continuations (all set/resumed on the main thread)
    private var deviceCont: CheckedContinuation<ICCameraDevice, Never>?
    private var openCont: CheckedContinuation<Error?, Never>?
    private var readyCont: CheckedContinuation<Void, Never>?
    private var ptpCont: CheckedContinuation<(data: Data?, resp: PTPResponse?, err: Error?), Never>?

    // where frames are written
    let framesDir: URL

    init(framesDir: URL) { self.framesDir = framesDir }

    // MARK: browser / session bring-up

    func findCamera() async -> ICCameraDevice {
        await withCheckedContinuation { c in
            DispatchQueue.main.async {
                self.deviceCont = c
                self.browser.delegate = self
                let maskRaw = ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
                self.browser.browsedDeviceTypeMask = unsafeBitCast(maskRaw, to: ICDeviceTypeMask.self)
                self.browser.start()
                log("ICDeviceBrowser started; waiting for a camera…")
            }
        }
    }

    func openSession(_ cam: ICCameraDevice) async -> Error? {
        await withCheckedContinuation { c in
            DispatchQueue.main.async {
                self.openCont = c
                cam.delegate = self
                cam.requestOpenSession()
                log("requestOpenSession sent…")
            }
        }
    }

    /// Wait for the device to report ready, but don't block forever — Fuji may
    /// only fire the camera-specific ready callback (which we don't observe here),
    /// so we cap the wait and let PTP retries handle not-quite-ready cameras.
    func waitForReady(timeout: TimeInterval) async {
        let waited: Void? = await withTaskGroup(of: Void?.self) { group in
            group.addTask { await withCheckedContinuation { c in DispatchQueue.main.async { self.readyCont = c } } }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)); return () }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
        _ = waited
        // clear any dangling continuation without resuming twice
        if let c = readyCont { readyCont = nil; c.resume() }
    }

    // MARK: PTP send

    @discardableResult
    func send(_ op: UInt16, params: [UInt32] = [], outData: Data? = nil) async -> (data: Data?, resp: PTPResponse?, err: Error?) {
        return await withCheckedContinuation { c in
            DispatchQueue.main.async {
                self.tid &+= 1
                let cmd = PTP.command(op, tid: self.tid, params: params)
                self.ptpCont = c
                self.camera!.requestSendPTPCommand(
                    cmd,
                    outData: outData,
                    sendCommandDelegate: self,
                    didSendCommand: #selector(self.didSendPTPCommand(_:inData:response:error:contextInfo:)),
                    contextInfo: nil)
            }
        }
    }

    /// SetDevicePropValue with a UInt16 value (data-out phase). Returns the response code.
    func setPropU16(_ prop: UInt32, _ value: UInt16) async -> UInt16? {
        var out = Data(); out.appendLE(value)
        let r = await send(PTP.SetDevicePropValue, params: [prop], outData: out)
        return r.resp?.code
    }

    /// GetDevicePropDesc (0x1014) for one property, parsed. Read-only and safe.
    func getPropDesc(_ prop: UInt16) async -> (desc: PropDesc?, rc: UInt16?, bytes: Int) {
        let r = await send(PTP.GetDevicePropDesc, params: [UInt32(prop)])
        return (r.data.flatMap(parsePropDesc), r.resp?.code, r.data?.count ?? 0)
    }

    @objc func didSendPTPCommand(_ command: NSData?, inData: NSData?, response: NSData?, error: NSError?, contextInfo: UnsafeMutableRawPointer?) {
        let cmdD = command as Data?, respD = response as Data?, dataD = inData as Data?
        if verbose {
            log("    <- callback: cmd=\(hexPreview(cmdD, 12)) resp=\(hexPreview(respD)) data=\(hexPreview(dataD, 8)) err=\(error?.localizedDescription ?? "nil")")
        }
        let c = ptpCont; ptpCont = nil
        c?.resume(returning: (dataD, parseResponse(respD), error))
    }

    // MARK: main flow

    func run() async {
        let cam = await findCamera()
        camera = cam
        log("→ Using camera: \"\(cam.name ?? "?")\"  transport=\(cam.transportType ?? "?")  usbLocationID=\(String(format: "0x%08X", cam.usbLocationID))")
        log("  capabilities: \(cam.capabilities)")

        if let err = await openSession(cam) {
            log("✗ Open session FAILED: \(err.localizedDescription)")
            finish(success: false)
            return
        }
        log("✓ Session opened. Waiting up to 6s for ready…")
        await waitForReady(timeout: 6)
        log("Proceeding to Fuji live-view sequence.")

        // CANARY: the simplest standard PTP read. Every PTP camera supports it and
        // it returns a big data blob. If THIS comes back all-nil, no command is
        // reaching the camera (session/relay problem), not a Fuji-opcode problem.
        log("— canary: standard GetDeviceInfo(0x1001) —")
        let di = await send(PTP.GetDeviceInfo)
        log("GetDeviceInfo(0x1001): rc=\(hex16(di.resp?.code)) respTID=\(di.resp?.transactionID ?? 0) dataBytes=\(di.data?.count ?? 0) err=\(di.err?.localizedDescription ?? "none")")
        if let d = di.data, d.count > 0 {
            log("  ✓ canary returned data — the relay works. Parsing OperationsSupported…")
            let info = parseDeviceInfo(d)
            log("  identity: manufacturer=\"\(info.manufacturer)\" model=\"\(info.model)\" version=\"\(info.version)\" serial=\"\(info.serial)\"")
            log("  VendorExtensionID: 0x\(String(format: "%04X", info.vendorExtID))  (Fuji=0x000E, MTP/PTP=0x0006)")
            log("  camera advertises \(info.operations.count) operations:")
            log("    " + info.operations.map { String(format: "0x%04X", $0) }.joined(separator: " "))
            log("  events (\(info.events.count)): " + info.events.map { String(format: "0x%04X", $0) }.joined(separator: " "))
            log("  device properties (\(info.deviceProps.count)): " + info.deviceProps.map { String(format: "0x%04X", $0) }.joined(separator: " "))
            let need: [(UInt16, String)] = [
                (0x1001, "GetDeviceInfo (canary, worked)"),
                (0x101C, "InitiateOpenCapture (live-view start)"),
                (0x1018, "TerminateOpenCapture (live-view stop)"),
                (0x1008, "GetObjectInfo"),
                (0x1009, "GetObject (fetch frame)"),
                (0x100B, "DeleteObject"),
                (0x902B, "Fuji GetDeviceInfo"),
            ]
            log("  --- do we get what live view needs? ---")
            for (op, name) in need {
                log("    \(hex16(op)) \(name): \(info.operations.contains(op) ? "ADVERTISED ✓" : "NOT advertised ✗")")
            }

            // Introspect every advertised device property (GetDevicePropDesc, read-only).
            // This tells us the datatype, current value, factory default, and the allowed
            // range/enum for each — crucially, the *correct* values for the priority props
            // (0xD207/0xD230) instead of blindly writing 1, and whether any prop looks like a
            // "movie / record / PC-connect" mode we could flip to escape DeviceBusy.
            log("  --- advertised device-property descriptors ---")
            for prop in info.deviceProps {
                let pd = await getPropDesc(prop)
                if let desc = pd.desc {
                    log("    " + fmtPropDesc(desc))
                } else {
                    log(String(format: "    0x%04X GetDevicePropDesc rc=%@ (%dB, unparsed)", prop, hex16(pd.rc), pd.bytes))
                }
            }
        } else {
            log("  ✗ canary returned no data — commands are not reaching the camera at all.")
        }

        // Wire up the PTP event handler. If InitiateOpenCapture really starts the
        // stream, Fuji emits events (PreviewAvailable 0xC001 / ObjectAdded 0xC004) even
        // when ICC never surfaces the (no-data) command response.
        await MainActor.run {
            self.camera?.ptpEventHandler = { eventData in
                log("  <PTP event> \(hexPreview(eventData as Data?, 20))")
            }
        }

        // Let ICC finish its post-ready housekeeping before we ask the camera to stream.
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        // PREP: Fuji won't start an open-capture stream until it's put into remote/live
        // priority. libgphoto2 sets PriorityMode; Fujifilm's X-webcam app sets ForceMode=1.
        // These vendor props aren't advertised (camera reports as generic MTP), but Fuji
        // bodies still respond to them (libgphoto2 relies on exactly this).
        log("Prep: nudging camera into remote/live priority…")
        for (name, prop) in [("PriorityMode 0xD207", UInt32(0xD207)),
                             ("ForceMode 0xD230",   UInt32(0xD230)),
                             ("PC-Mode 0xD38C",     UInt32(0xD38C))] {
            let rc = await setPropU16(prop, 1)
            log("  SetDeviceProp \(name)=1 -> rc=\(hex16(rc))")
        }

        // START live view. InitiateOpenCapture often returns DeviceBusy(0x2019) at first;
        // libgphoto2 retries through it. Retry patiently and only poll once it's OK.
        var openCaptureTID: UInt32 = 0
        var started = false
        var lastRC: UInt16?
        let openCaptureAttempts = 8
        for attempt in 1...openCaptureAttempts {
            let r = await send(PTP.InitiateOpenCapture, params: [0x00000000, 0x00000000])
            lastRC = r.resp?.code
            if r.resp?.code == PTP.RC_OK {
                openCaptureTID = r.resp?.transactionID ?? 0
                started = true
                log("InitiateOpenCapture(0x101C) #\(attempt): rc=0x2001 OK ✓")
                break
            }
            log("InitiateOpenCapture(0x101C) #\(attempt): rc=\(hex16(r.resp?.code)) — retrying through busy")
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
        if !started { log("→ InitiateOpenCapture never returned OK (last rc=\(hex16(lastRC))) after \(openCaptureAttempts) tries.") }

        // Poll for frames (libgphoto2 order: GetObjectInfo to check readiness, then GetObject).
        log("Polling live-view handle 0x80000001…")
        verbose = false
        var saved = 0
        var firstFrameAt: Date?
        var notReady = 0
        for _ in 1...300 {
            let oi = await send(PTP.GetObjectInfo, params: [PTP.liveViewHandle])
            if oi.resp?.code == PTP.RC_InvalidObjectHandle {
                notReady += 1
                if notReady == 1 { log("  frame not ready yet (InvalidObjectHandle) — waiting…") }
                if notReady > 150 { log("  → no frame ever became available."); break }
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            let go = await send(PTP.GetObject, params: [PTP.liveViewHandle])
            if let jpeg = go.data, jpeg.count > 3, jpeg[jpeg.startIndex] == 0xFF, jpeg[jpeg.startIndex + 1] == 0xD8 {
                if firstFrameAt == nil { firstFrameAt = Date(); log("  ✓✓✓ FIRST JPEG FRAME: \(jpeg.count) bytes!") }
                try? jpeg.write(to: framesDir.appendingPathComponent(String(format: "frame_%03d.jpg", saved)))
                saved += 1
                _ = await send(PTP.DeleteObject, params: [PTP.liveViewHandle, 0])
                if saved >= 30 { break }
            } else if go.resp?.code == PTP.RC_DeviceBusy || go.resp?.code == PTP.RC_AccessDenied {
                try? await Task.sleep(nanoseconds: 5_000_000)
                _ = await send(PTP.DeleteObject, params: [PTP.liveViewHandle, 0])
            } else {
                _ = await send(PTP.DeleteObject, params: [PTP.liveViewHandle, 0])
            }
        }

        let elapsed = firstFrameAt.map { Date().timeIntervalSince($0) } ?? 0
        let fps = (elapsed > 0 && saved > 1) ? Double(saved - 1) / elapsed : 0
        log("")
        log("──────── RESULT ────────")
        log("frames saved : \(saved)")
        log(String(format: "frame rate   : %.1f fps", fps))
        log("frames dir   : \(framesDir.path)")
        if saved >= 2 { log("VERDICT      : ✅ ImageCaptureCore CAN drive Fuji live view!") }
        else if started { log("VERDICT      : ⚠️  capture started but no frame surfaced — investigate.") }
        else            { log("VERDICT      : ❌ InitiateOpenCapture stayed busy the whole time.") }
        log("────────────────────────")

        // STOP (best effort)
        let stop = await send(PTP.TerminateOpenCapture, params: [openCaptureTID])
        log("TerminateOpenCapture(0x1018) rc=\(hex16(stop.resp?.code))")

        await MainActor.run { self.camera?.requestCloseSession() }
        try? await Task.sleep(nanoseconds: 300_000_000)
        finish(success: saved >= 2)
    }

    func finish(success: Bool) {
        DispatchQueue.main.async {
            self.browser.stop()
            exit(success ? 0 : 1)
        }
    }

    // MARK: ICDeviceBrowserDelegate (required)

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        log("browser didAdd: \"\(device.name ?? "?")\" (\(device.transportType ?? "?"))")
        guard let cam = device as? ICCameraDevice, camera == nil, deviceCont != nil else { return }
        let name = (device.name ?? "").lowercased()
        let looksFuji = name.contains("x-t30") || name.contains("fujifilm") || name.contains("fuji") || name.contains("x-t")
        // Prefer an obvious Fuji match; otherwise, if no more devices are coming, take the first camera.
        if looksFuji || !moreComing {
            camera = cam
            let c = deviceCont; deviceCont = nil
            c?.resume(returning: cam)
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        log("browser didRemove: \"\(device.name ?? "?")\"")
    }

    // MARK: ICDeviceDelegate (required + a couple of useful optionals)

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        let c = openCont; openCont = nil
        c?.resume(returning: error)
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        log("didCloseSession err=\(error?.localizedDescription ?? "none")")
    }

    func didRemove(_ device: ICDevice) {
        log("didRemoveDevice: \"\(device.name ?? "?")\"")
    }

    func deviceDidBecomeReady(_ device: ICDevice) {
        log("deviceDidBecomeReady")
        let c = readyCont; readyCont = nil
        c?.resume()
    }

    func device(_ device: ICDevice, didEncounterError error: Error?) {
        log("device didEncounterError: \(error?.localizedDescription ?? "unknown")")
    }
}

// MARK: - Entry point

let framesDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("frames")
try? FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)
// clear any old frames
if let old = try? FileManager.default.contentsOfDirectory(at: framesDir, includingPropertiesForKeys: nil) {
    for f in old where f.pathExtension == "jpg" { try? FileManager.default.removeItem(at: f) }
}

log("OpenXWebcam Phase 0 spike — ImageCaptureCore PTP live-view feasibility")
log("frames will be written to: \(framesDir.path)")
log("")

let spike = Spike(framesDir: framesDir)

// Accessory app: gives us a proper bundle identity for TCC without a Dock icon/window.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Safety net: if nothing happens (e.g. camera never enumerated), bail after 60s.
Task {
    try? await Task.sleep(nanoseconds: 60_000_000_000)
    log("✗ Timed out after 60s with no result. Is the X-T30 connected, awake (Auto Power Off OFF), and in an enumerating USB mode?")
    exit(2)
}

Task { await spike.run() }

app.run()
