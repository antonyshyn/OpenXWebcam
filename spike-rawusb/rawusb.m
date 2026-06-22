// OpenXWebcam — Phase 1 raw-USB feasibility spike (MIT)
//
// Goal: prove we can pull Fujifilm X-T30 live-view JPEG frames over USB by
// SEIZING interface 0 from Apple's `ptpcamerad` and driving the PTP live-view
// sequence ourselves — the exact thing ImageCaptureCore refused to do
// (InitiateOpenCapture -> DeviceBusy, forever, because ICC/ptpcamerad co-owns
// and polls the session).
//
// Mechanism (all public API; PTP is a published protocol, IOKit/IOUSBLib is
// Apple's own USB API):
//   * Match the PTP Still-Imaging interface (bInterfaceClass 6 / subclass 1).
//   * Open the parent IOUSBDevice + the interface with the *seize* variants of
//     the classic IOUSBLib user client (IOUSBInterfaceInterface300). The classic
//     stack is not gated by the DriverKit/IOUSBHost entitlement, and as root the
//     seize evicts the prior owner. If a sticky ptpcamerad refuses, we SIGKILL it
//     (root) and retry once.
//   * PTP-over-bulk: command container out, optional data-out, read data-in +
//     response in from bulk-IN. Container = len|type|code|txnID|params.
//   * Fuji live view (from libgphoto2 ptp2, a protocol fact):
//       InitiateOpenCapture(0x101C, 0, 0)
//       loop: GetObjectInfo(0x1008,0x80000001) / GetObject(0x1009,0x80000001)->JPEG
//             / DeleteObject(0x100B,0x80000001)
//       TerminateOpenCapture(0x1018)
//
// MUST be run as root (sudo) so the interface seize succeeds. Frames -> ./frames.

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/usb/IOUSBLib.h>
#import <IOUSBHost/IOUSBHost.h>   // used only to build the interface matching dict
#import <mach/mach.h>

// ─── Target ────────────────────────────────────────────────────────────────
static const uint16_t kVID = 0x04cb;   // FUJIFILM
static const uint16_t kPID = 0x02e3;   // X-T30

// ─── PTP container types ─────────────────────────────────────────────────────
enum { PTP_CMD = 0x0001, PTP_DATA = 0x0002, PTP_RESP = 0x0003 };

// ─── PTP opcodes ──────────────────────────────────────────────────────────────
enum {
    OP_GetDeviceInfo        = 0x1001,
    OP_GetObjectInfo        = 0x1008,
    OP_GetObject            = 0x1009,
    OP_DeleteObject         = 0x100B,
    OP_GetDevicePropValue   = 0x1015,
    OP_SetDevicePropValue   = 0x1016,
    OP_TerminateOpenCapture = 0x1018,
    OP_InitiateOpenCapture  = 0x101C,
};
static const uint32_t LV_HANDLE = 0x80000001;   // Fuji synthetic live-view object

// Fuji vendor device-property codes (libgphoto2 camlibs/ptp2/ptp.h)
enum {
    DPC_FUJI_PriorityMode = 0xD207,   // 1=camera priority, 2=USB control (gphoto sets 2)
    DPC_FUJI_CurrentState = 0xD212,   // opaque state blob (5 bytes on this cam)
    DPC_FUJI_ForceMode    = 0xD230,   // "set by webcam app" = 1 (only legal value)
    DPC_FUJI_PCMode       = 0xD38C,   // timelapse traffic sets 1 ("PC Mode"); unadvertised here
};

// ─── PTP response codes ───────────────────────────────────────────────────────
enum {
    RC_OK                 = 0x2001,
    RC_InvalidObjectHandle= 0x2009,
    RC_AccessDenied       = 0x200F,
    RC_DeviceBusy         = 0x2019,
};

// ─── Little-endian byte helpers ──────────────────────────────────────────────
static inline void put16(uint8_t *p, uint16_t v){ p[0]=v; p[1]=v>>8; }
static inline void put32(uint8_t *p, uint32_t v){ p[0]=v; p[1]=v>>8; p[2]=v>>16; p[3]=v>>24; }
static inline uint16_t get16(const uint8_t *p){ return (uint16_t)p[0] | ((uint16_t)p[1]<<8); }
static inline uint32_t get32(const uint8_t *p){ return (uint32_t)p[0] | ((uint32_t)p[1]<<8) | ((uint32_t)p[2]<<16) | ((uint32_t)p[3]<<24); }

// ─── Opened-interface state (single-threaded, so file-scope is fine) ─────────
static IOUSBInterfaceInterface300 **gIface  = NULL;
static IOUSBDeviceInterface300    **gDevice = NULL;
static uint8_t  gPipeOut = 0, gPipeIn = 0, gPipeIntr = 0;
static uint32_t gTxn = 0;

// Shared 8 MB bulk-IN scratch (a live-view JPEG is ~0.1–2 MB).
static uint8_t gBuf[8 * 1024 * 1024];

static void logln(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(stdout, "%s\n", s.UTF8String);
    fflush(stdout);
}

// ─── Parse a PTP response container: len|type(0x0003)|rc|txnID|params ─────────
static uint16_t parseResponse(NSData *resp, uint32_t *outParams, int *outNParams) {
    if (outNParams) *outNParams = 0;
    if (resp.length < 8) return 0;
    const uint8_t *p = resp.bytes;
    uint16_t rc = get16(p + 6);
    if (outParams && outNParams) {
        int n = 0, off = 12;
        while (off + 4 <= (int)resp.length && n < 5) { outParams[n++] = get32(p + off); off += 4; }
        *outNParams = n;
    }
    return rc;
}

// ─── One synchronous PTP transaction ──────────────────────────────────────────
// Writes the command (and optional data-out), reads the data-in phase (if any)
// and the response. Returns the response code; *inData (payload without the
// 12-byte container header) is set when a data-in phase is present.
static uint16_t ptp(uint16_t op, const uint32_t *params, int nParams,
                    const void *dataOut, uint32_t dataOutLen,
                    NSData **inData, uint32_t *respParams, int *nRespParams) {
    if (inData) *inData = nil;
    gTxn++;

    // 1. command container
    uint8_t cmd[12 + 5 * 4];
    uint32_t clen = 12 + (uint32_t)nParams * 4;
    put32(cmd, clen); put16(cmd + 4, PTP_CMD); put16(cmd + 6, op); put32(cmd + 8, gTxn);
    for (int i = 0; i < nParams; i++) put32(cmd + 12 + i * 4, params[i]);
    IOReturn kr = (*gIface)->WritePipeTO(gIface, gPipeOut, cmd, clen, 0, 5000);
    if (kr != kIOReturnSuccess) { logln(@"    ! WritePipe(cmd 0x%04X) failed 0x%08x", op, kr); return 0; }

    // 2. optional data-out phase
    if (dataOut && dataOutLen) {
        uint32_t dlen = 12 + dataOutLen;
        uint8_t *dc = malloc(dlen);
        put32(dc, dlen); put16(dc + 4, PTP_DATA); put16(dc + 6, op); put32(dc + 8, gTxn);
        memcpy(dc + 12, dataOut, dataOutLen);
        kr = (*gIface)->WritePipeTO(gIface, gPipeOut, dc, dlen, 0, 5000);
        free(dc);
        if (kr != kIOReturnSuccess) { logln(@"    ! WritePipe(data 0x%04X) failed 0x%08x", op, kr); return 0; }
    }

    // 3. read first bulk-IN packet
    UInt32 rsize = sizeof(gBuf);
    kr = (*gIface)->ReadPipeTO(gIface, gPipeIn, gBuf, &rsize, 0, 5000);
    if (kr != kIOReturnSuccess) { logln(@"    ! ReadPipe(0x%04X) failed 0x%08x", op, kr); return 0; }
    if (rsize < 12) return 0;

    uint16_t ctype = get16(gBuf + 4);
    if (ctype == PTP_DATA) {
        uint32_t declared = get32(gBuf);
        NSMutableData *acc = [NSMutableData dataWithBytes:gBuf length:rsize];
        while (acc.length < declared) {
            UInt32 r2 = sizeof(gBuf);
            kr = (*gIface)->ReadPipeTO(gIface, gPipeIn, gBuf, &r2, 0, 5000);
            if (kr != kIOReturnSuccess || r2 == 0) break;
            [acc appendBytes:gBuf length:r2];
        }
        uint32_t dataEnd = MIN((uint32_t)acc.length, declared);
        if (inData) {
            *inData = dataEnd > 12 ? [acc subdataWithRange:NSMakeRange(12, dataEnd - 12)] : [NSData data];
        }
        // response is either appended to this transfer or a separate read
        NSData *resp;
        if (acc.length > declared) {
            resp = [acc subdataWithRange:NSMakeRange(declared, acc.length - declared)];
        } else {
            UInt32 r3 = sizeof(gBuf);
            kr = (*gIface)->ReadPipeTO(gIface, gPipeIn, gBuf, &r3, 0, 5000);
            if (kr != kIOReturnSuccess || r3 < 12) return 0;
            resp = [NSData dataWithBytes:gBuf length:r3];
        }
        return parseResponse(resp, respParams, nRespParams);
    } else if (ctype == PTP_RESP) {
        NSData *resp = [NSData dataWithBytes:gBuf length:rsize];
        return parseResponse(resp, respParams, nRespParams);
    }
    logln(@"    ! unexpected container type 0x%04X for op 0x%04X", ctype, op);
    return 0;
}

// ─── A no-data-phase op sent with TransactionID 0 (OpenSession/CloseSession) ──
// OpenSession(0x1002, sessionID) MUST precede session-scoped ops like
// InitiateOpenCapture. Per PTP, session-setup ops carry TransactionID 0.
static uint16_t sessionOp(uint16_t op, uint32_t param, BOOL hasParam) {
    uint8_t cmd[16];
    uint32_t clen = hasParam ? 16 : 12;
    put32(cmd, clen); put16(cmd + 4, PTP_CMD); put16(cmd + 6, op); put32(cmd + 8, 0);
    if (hasParam) put32(cmd + 12, param);
    if ((*gIface)->WritePipeTO(gIface, gPipeOut, cmd, clen, 0, 5000) != kIOReturnSuccess) return 0;
    UInt32 rs = sizeof(gBuf);
    if ((*gIface)->ReadPipeTO(gIface, gPipeIn, gBuf, &rs, 0, 5000) != kIOReturnSuccess || rs < 12) return 0;
    return get16(gBuf + 6);
}

// ─── VID/PID of an interface service (from its parent IOUSBDevice) ────────────
static void serviceVidPid(io_service_t svc, uint16_t *vid, uint16_t *pid) {
    *vid = *pid = 0;
    io_service_t dev = IO_OBJECT_NULL;
    if (IORegistryEntryGetParentEntry(svc, kIOServicePlane, &dev) != KERN_SUCCESS) return;
    CFTypeRef v = IORegistryEntryCreateCFProperty(dev, CFSTR("idVendor"),  kCFAllocatorDefault, 0);
    CFTypeRef p = IORegistryEntryCreateCFProperty(dev, CFSTR("idProduct"), kCFAllocatorDefault, 0);
    if (v) { *vid = (uint16_t)[(__bridge NSNumber *)v unsignedShortValue]; CFRelease(v); }
    if (p) { *pid = (uint16_t)[(__bridge NSNumber *)p unsignedShortValue]; CFRelease(p); }
    IOObjectRelease(dev);
}

// ─── Open one IOUSBLib COM interface for a service ────────────────────────────
// pluginType is a CFUUIDRef (kIO…UserClientTypeID); iid is CFUUIDBytes for QI.
static void *openPlugin(io_service_t svc, CFUUIDRef pluginType, CFUUIDBytes iid) {
    IOCFPlugInInterface **plugin = NULL; SInt32 score = 0;
    if (IOCreatePlugInInterfaceForService(svc, pluginType, kIOCFPlugInInterfaceID, &plugin, &score) != KERN_SUCCESS || !plugin)
        return NULL;
    void *result = NULL;
    (*plugin)->QueryInterface(plugin, iid, &result);
    (*plugin)->Release(plugin);
    return result;
}

// ─── Seize interface 0 of the X-T30 (root) ────────────────────────────────────
static BOOL openCamera(void) {
    // Match ALL PTP still-image interfaces (bInterfaceClass 6 / subclass 1) and
    // filter to the X-T30 by parent-device VID/PID in code. Constraining VID/PID/
    // interface# in the dictionary itself is unreliable — those properties live on
    // the parent IOUSBDevice node, not the interface nub.
    // IOServiceGetMatchingServices consumes (releases) this dictionary reference.
    CFMutableDictionaryRef match =
        [IOUSBHostInterface createMatchingDictionaryWithVendorID:nil
                                                       productID:nil
                                                       bcdDevice:nil
                                                 interfaceNumber:nil
                                              configurationValue:nil
                                                  interfaceClass:@6
                                               interfaceSubclass:@1
                                               interfaceProtocol:nil
                                                           speed:nil
                                                  productIDArray:nil];
    if (!match) { logln(@"✗ could not build matching dictionary"); return NO; }

    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) != KERN_SUCCESS) {
        logln(@"✗ IOServiceGetMatchingServices failed"); return NO;
    }
    io_service_t ifaceSvc = IO_OBJECT_NULL, svc;
    int seen = 0;
    while ((svc = IOIteratorNext(iter)) != IO_OBJECT_NULL) {
        uint16_t v, p; serviceVidPid(svc, &v, &p);
        seen++;
        logln(@"  PTP interface candidate #%d: VID=0x%04X PID=0x%04X", seen, v, p);
        if (v == kVID && p == kPID && ifaceSvc == IO_OBJECT_NULL) ifaceSvc = svc;
        else IOObjectRelease(svc);
    }
    IOObjectRelease(iter);
    if (ifaceSvc == IO_OBJECT_NULL) {
        logln(@"✗ X-T30 not found (%d class-6/1 PTP interface(s) present). Is it connected, awake (Auto Power Off OFF), in X WEBCAM mode?", seen);
        return NO;
    }
    logln(@"✓ found X-T30 PTP interface service");

    // Parent device: seize it first and hold it open so ptpcamerad can't re-grab.
    io_service_t devSvc = IO_OBJECT_NULL;
    if (IORegistryEntryGetParentEntry(ifaceSvc, kIOServicePlane, &devSvc) == KERN_SUCCESS && devSvc) {
        gDevice = openPlugin(devSvc,
                             kIOUSBDeviceUserClientTypeID,
                             CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID300));
        IOObjectRelease(devSvc);
    }
    if (gDevice) {
        IOReturn dk = (*gDevice)->USBDeviceOpenSeize(gDevice);
        logln(@"  USBDeviceOpenSeize -> 0x%08x%@", dk, dk == kIOReturnSuccess ? @" (owned)" : @"");
        if (dk != kIOReturnSuccess) { (*gDevice)->Release(gDevice); gDevice = NULL; }
    }

    // Interface: seize. If a sticky ptpcamerad still holds it, SIGKILL it (root) and retry once.
    gIface = openPlugin(ifaceSvc,
                        kIOUSBInterfaceUserClientTypeID,
                        CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID300));
    IOObjectRelease(ifaceSvc);
    if (!gIface) { logln(@"✗ could not create IOUSBInterface COM object"); return NO; }

    IOReturn ik = (*gIface)->USBInterfaceOpenSeize(gIface);
    logln(@"  USBInterfaceOpenSeize -> 0x%08x", ik);
    if (ik == kIOReturnExclusiveAccess) {
        logln(@"  interface still held — SIGKILL ptpcamerad and retry…");
        system("/usr/bin/killall -9 ptpcamerad >/dev/null 2>&1");
        usleep(300 * 1000);
        ik = (*gIface)->USBInterfaceOpenSeize(gIface);
        logln(@"  USBInterfaceOpenSeize retry -> 0x%08x", ik);
    }
    if (ik != kIOReturnSuccess) {
        logln(@"✗ interface seize failed 0x%08x (are you root? `sudo ./run.sh`)", ik);
        return NO;
    }
    logln(@"✓ SEIZED interface 0 — we own the PTP pipe now");

    // Activate endpoints, then discover bulk-OUT / bulk-IN / interrupt-IN.
    (*gIface)->SetAlternateInterface(gIface, 0);
    UInt8 nep = 0; (*gIface)->GetNumEndpoints(gIface, &nep);
    for (UInt8 i = 1; i <= nep; i++) {
        UInt8 dir = 0, num = 0, tt = 0, interval = 0; UInt16 mps = 0;
        if ((*gIface)->GetPipeProperties(gIface, i, &dir, &num, &tt, &mps, &interval) != kIOReturnSuccess) continue;
        const char *ds = (dir == kUSBIn) ? "IN " : "OUT";
        const char *ts = (tt == kUSBBulk) ? "bulk" : (tt == kUSBInterrupt) ? "intr" : "?";
        logln(@"  pipe %u: %s %s ep%u maxPacket=%u", i, ds, ts, num, mps);
        if (tt == kUSBBulk && dir == kUSBOut && !gPipeOut) gPipeOut = i;
        else if (tt == kUSBBulk && dir == kUSBIn && !gPipeIn) gPipeIn = i;
        else if (tt == kUSBInterrupt && dir == kUSBIn && !gPipeIntr) gPipeIntr = i;
    }
    if (!gPipeOut || !gPipeIn) { logln(@"✗ missing bulk endpoints (out=%u in=%u)", gPipeOut, gPipeIn); return NO; }
    logln(@"✓ endpoints: bulkOut=%u bulkIn=%u intrIn=%u", gPipeOut, gPipeIn, gPipeIntr);
    return YES;
}

static void closeCamera(void) {
    if (gIface)  { (*gIface)->USBInterfaceClose(gIface); (*gIface)->Release(gIface); gIface = NULL; }
    if (gDevice) { (*gDevice)->USBDeviceClose(gDevice);  (*gDevice)->Release(gDevice); gDevice = NULL; }
}

// ─── PTP dataset cursor (bounds-checked little-endian reader) ─────────────────
typedef struct { const uint8_t *p; uint32_t len, off; } Cursor;
static BOOL curHas(Cursor *c, uint32_t n) { return c->off <= c->len && n <= c->len - c->off; }
static uint8_t  curU8 (Cursor *c) { uint8_t  v = curHas(c,1) ? c->p[c->off]        : 0; c->off += 1; return v; }
static uint16_t curU16(Cursor *c) { uint16_t v = curHas(c,2) ? get16(c->p+c->off)  : 0; c->off += 2; return v; }
static uint32_t curU32(Cursor *c) { uint32_t v = curHas(c,4) ? get32(c->p+c->off)  : 0; c->off += 4; return v; }
static NSString *curString(Cursor *c) {           // PTP string: u8 charCount (incl. NUL), UTF-16LE
    uint8_t n = curU8(c);
    NSString *s = @"";
    if (n && curHas(c, (uint32_t)n * 2))
        s = [[NSString alloc] initWithBytes:c->p + c->off length:(NSUInteger)n * 2
                                   encoding:NSUTF16LittleEndianStringEncoding] ?: @"";
    c->off += (uint32_t)n * 2;
    return [s stringByTrimmingCharactersInSet:NSCharacterSet.controlCharacterSet];
}
static NSString *curU16Array(Cursor *c) {         // AUINT16: u32 count then u16[count], as hex
    uint32_t n = curU32(c);
    NSMutableString *s = [NSMutableString string];
    for (uint32_t i = 0; i < n && curHas(c, 2); i++) [s appendFormat:@"%s0x%04X", i ? " " : "", curU16(c)];
    return s;
}

// ─── DeviceInfo: full dump — VendorExtensionDesc is what flips libgphoto2 into Fuji mode ───
static void reportDeviceInfo(void) {
    NSData *di = nil; uint16_t rc = ptp(OP_GetDeviceInfo, NULL, 0, NULL, 0, &di, NULL, NULL);
    logln(@"GetDeviceInfo(0x1001): rc=0x%04X dataBytes=%lu", rc, (unsigned long)di.length);
    if (di.length < 12) return;
    Cursor c = { di.bytes, (uint32_t)di.length, 0 };
    uint16_t std   = curU16(&c);
    uint32_t vext  = curU32(&c);
    uint16_t vver  = curU16(&c);
    NSString *vdesc = curString(&c);
    uint16_t fmode = curU16(&c);
    logln(@"  StandardVersion=%u VendorExtensionID=0x%04X (Fuji=0x000E, MTP/PTP=0x0006) v%u", std, vext, vver);
    logln(@"  VendorExtensionDesc=\"%@\"%@", vdesc,
          [vdesc containsString:@"fujifilm.co.jp"] ? @"  ← triggers libgphoto2's MTP→Fuji override" : @"");
    logln(@"  FunctionalMode=0x%04X", fmode);
    logln(@"  Operations : %@", curU16Array(&c));
    logln(@"  Events     : %@", curU16Array(&c));
    logln(@"  DeviceProps: %@", curU16Array(&c));
    logln(@"  CaptureFmts: %@", curU16Array(&c));
    logln(@"  ImageFmts  : %@", curU16Array(&c));
    NSString *manu = curString(&c), *model = curString(&c), *ver = curString(&c);
    logln(@"  Manufacturer=\"%@\" Model=\"%@\" Version=\"%@\"", manu, model, ver);
}

// ─── Device-property get/set (UINT16) ────────────────────────────────────────
static uint16_t getPropU16(uint16_t code, uint16_t *value) {
    uint32_t p = code; NSData *d = nil;
    uint16_t rc = ptp(OP_GetDevicePropValue, &p, 1, NULL, 0, &d, NULL, NULL);
    if (rc == RC_OK && d.length >= 2 && value) *value = get16(d.bytes);
    return rc;
}
static uint16_t setPropU16(uint16_t code, uint16_t value) {
    uint32_t p = code; uint8_t v[2]; put16(v, value);
    return ptp(OP_SetDevicePropValue, &p, 1, v, 2, NULL, NULL, NULL);
}

// ─── FUJI_CurrentState (0xD212): opaque blob — dump hex so we can diff states ──
static void dumpCurrentState(NSString *when) {
    uint32_t p = DPC_FUJI_CurrentState; NSData *d = nil;
    uint16_t rc = ptp(OP_GetDevicePropValue, &p, 1, NULL, 0, &d, NULL, NULL);
    NSMutableString *hex = [NSMutableString string];
    const uint8_t *b = d.bytes;
    for (NSUInteger i = 0; i < MIN(d.length, (NSUInteger)64); i++) [hex appendFormat:@"%02X ", b[i]];
    logln(@"  CurrentState(0xD212) %@: rc=0x%04X len=%lu [%@]", when, rc, (unsigned long)d.length, hex);
}

// ─── main ─────────────────────────────────────────────────────────────────────
int main(int argc, char **argv) {
    @autoreleasepool {
        logln(@"OpenXWebcam Phase 1 — raw-USB (IOUSBLib seize) live-view spike");
        logln(@"euid=%u %@", geteuid(), geteuid() == 0 ? @"(root ✓)" : @"(NOT root — seize will likely fail; use sudo)");

        NSString *framesDir = [[NSFileManager.defaultManager currentDirectoryPath] stringByAppendingPathComponent:@"frames"];
        [NSFileManager.defaultManager createDirectoryAtPath:framesDir withIntermediateDirectories:YES attributes:nil error:nil];
        for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:framesDir error:nil])
            if ([f.pathExtension isEqualToString:@"jpg"]) [NSFileManager.defaultManager removeItemAtPath:[framesDir stringByAppendingPathComponent:f] error:nil];

        if (!openCamera()) { closeCamera(); return 1; }

        // Open a PTP session — REQUIRED before InitiateOpenCapture and other
        // session-scoped ops. If ptpcamerad left a session open, close & reopen
        // so we own a clean transaction-id space.
        uint16_t sr = sessionOp(0x1002, 1, YES);           // OpenSession(sessionID=1)
        if (sr == 0x201E) {                                // SessionAlreadyOpen
            sessionOp(0x1003, 0, NO);                      // CloseSession
            sr = sessionOp(0x1002, 1, YES);                // OpenSession again
        }
        logln(@"OpenSession(0x1002): rc=0x%04X %@", sr, sr == RC_OK ? @"✓" : @"");
        gTxn = 0;                                          // next command uses TransactionID 1

        reportDeviceInfo();

        // ── Fuji capture prep — exact replica of libgphoto2 camera_prepare_capture
        // (config.c:495), which Fuji cameras get at camera_init, BEFORE any capture:
        //   d38c -> 1 ("PC Mode"; unadvertised on this cam, gphoto tolerates the error)
        //   d207 -> 2 ("USB control"; we previously only ever set 1 — the descriptor
        //              default is 2, and this is the prime DeviceBusy suspect)
        logln(@"— Fuji prep (libgphoto2 camera_prepare_capture replica) —");
        uint16_t pv = 0xFFFF, prc;
        prc = getPropU16(DPC_FUJI_PriorityMode, &pv);
        logln(@"  PriorityMode(0xD207) before: rc=0x%04X val=%u", prc, pv);
        prc = setPropU16(DPC_FUJI_PCMode, 1);
        logln(@"  Set PCMode(0xD38C)=1: rc=0x%04X%@", prc, prc == RC_OK ? @" ✓" : @" (unadvertised prop — error tolerated, gphoto does the same)");
        prc = setPropU16(DPC_FUJI_PriorityMode, 2);
        logln(@"  Set PriorityMode(0xD207)=2: rc=0x%04X%@", prc, prc == RC_OK ? @" ✓" : @"");
        pv = 0xFFFF; prc = getPropU16(DPC_FUJI_PriorityMode, &pv);
        logln(@"  PriorityMode(0xD207) after : rc=0x%04X val=%u", prc, pv);
        dumpCurrentState(@"pre-capture");

        // START live view. With the Fuji prep done this should finally leave DeviceBusy.
        logln(@"— InitiateOpenCapture(0x101C, 0, 0) —");
        uint32_t p0[2] = {0, 0};
        uint16_t rc = 0; BOOL started = NO;
        for (int attempt = 1; attempt <= 20; attempt++) {
            rc = ptp(OP_InitiateOpenCapture, p0, 2, NULL, 0, NULL, NULL, NULL);
            if (rc == RC_OK) { started = YES; logln(@"  #%d rc=0x2001 OK ✓", attempt); break; }
            logln(@"  #%d rc=0x%04X%@", attempt, rc, rc == RC_DeviceBusy ? @" (busy — retrying)" : @"");
            if (attempt == 10) {   // escalation: ForceMode(0xD230)=1 — "set by webcam app", only legal value
                uint16_t frc = setPropU16(DPC_FUJI_ForceMode, 1);
                logln(@"  … still busy at #10 — Set ForceMode(0xD230)=1: rc=0x%04X, retrying", frc);
            }
            usleep(300 * 1000);
        }
        if (!started) {
            logln(@"→ InitiateOpenCapture never returned OK (last rc=0x%04X)", rc);
            dumpCurrentState(@"post-busy");
        }

        // Poll the Fuji live-view handle for JPEG frames.
        logln(@"Polling live-view handle 0x80000001…");
        int saved = 0, notReady = 0;
        NSDate *firstFrame = nil;
        for (int i = 0; i < 400 && saved < 30; i++) {
            uint16_t oiRC = ptp(OP_GetObjectInfo, &LV_HANDLE, 1, NULL, 0, NULL, NULL, NULL);
            if (oiRC == RC_InvalidObjectHandle) {
                if (++notReady == 1) logln(@"  frame not ready yet (InvalidObjectHandle) — waiting…");
                if (notReady > 200) { logln(@"  → no frame ever became available."); break; }
                usleep(15 * 1000);
                continue;
            }
            NSData *jpeg = nil;
            uint16_t goRC = ptp(OP_GetObject, &LV_HANDLE, 1, NULL, 0, &jpeg, NULL, NULL);
            const uint8_t *jb = jpeg.bytes;
            if (goRC == RC_OK && jpeg.length > 3 && jb[0] == 0xFF && jb[1] == 0xD8) {
                if (!firstFrame) { firstFrame = [NSDate date]; logln(@"  ✓✓✓ FIRST JPEG FRAME: %lu bytes!", (unsigned long)jpeg.length); }
                [jpeg writeToFile:[framesDir stringByAppendingPathComponent:[NSString stringWithFormat:@"frame_%03d.jpg", saved]] atomically:NO];
                saved++;
            } else if (goRC == RC_DeviceBusy || goRC == RC_AccessDenied) {
                usleep(5 * 1000);
            }
            ptp(OP_DeleteObject, (uint32_t[]){LV_HANDLE, 0}, 2, NULL, 0, NULL, NULL, NULL);
        }

        double elapsed = firstFrame ? -[firstFrame timeIntervalSinceNow] : 0;
        double fps = (elapsed > 0 && saved > 1) ? (saved - 1) / elapsed : 0;
        logln(@"");
        logln(@"──────── RESULT ────────");
        logln(@"frames saved : %d", saved);
        logln(@"frame rate   : %.1f fps", fps);
        logln(@"frames dir   : %@", framesDir);
        if (saved >= 2)      logln(@"VERDICT      : ✅ raw-USB seize CAN drive Fuji live view!");
        else if (started)    logln(@"VERDICT      : ⚠️  capture started but no frame surfaced — investigate.");
        else                 logln(@"VERDICT      : ❌ InitiateOpenCapture stayed busy over raw USB too.");
        logln(@"────────────────────────");

        if (started) { uint16_t t = ptp(OP_TerminateOpenCapture, NULL, 0, NULL, 0, NULL, NULL, NULL); logln(@"TerminateOpenCapture rc=0x%04X", t); }
        closeCamera();
        return saved >= 2 ? 0 : 1;
    }
}
