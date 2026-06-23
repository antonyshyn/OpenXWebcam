#import "include/PTPUSBTransport.h"
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/usb/IOUSBLib.h>
#import <IOUSBHost/IOUSBHost.h>
#import <libproc.h>
#import <signal.h>

NSErrorDomain const PTPUSBErrorDomain = @"PTPUSBErrorDomain";

static NSError *usbError(NSString *what, IOReturn code) {
    return [NSError errorWithDomain:PTPUSBErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey :
                                          [NSString stringWithFormat:@"%@ failed: 0x%08x", what, code]}];
}

@implementation PTPUSBInterfaceInfo {
    io_service_t _service;
}

- (instancetype)initWithService:(io_service_t)service vendorID:(uint16_t)vid productID:(uint16_t)pid {
    self = [super init];
    if (self) {
        _service = service;
        IOObjectRetain(_service);
        _vendorID = vid;
        _productID = pid;
    }
    return self;
}

- (io_service_t)service {
    return _service;
}

- (void)dealloc {
    if (_service) IOObjectRelease(_service);
}

@end

@implementation PTPUSBTransport {
    io_service_t _service;
    IOUSBDeviceInterface300 **_device;
    IOUSBInterfaceInterface300 **_iface;
    uint8_t _pipeOut, _pipeIn;
    NSMutableData *_readBuffer;
}

+ (NSArray<PTPUSBInterfaceInfo *> *)findPTPInterfaces {
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
    if (!match) return @[];

    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) != KERN_SUCCESS) return @[];

    NSMutableArray *result = [NSMutableArray array];
    io_service_t svc;
    while ((svc = IOIteratorNext(iter)) != IO_OBJECT_NULL) {
        uint16_t vid = 0, pid = 0;
        io_service_t dev = IO_OBJECT_NULL;
        if (IORegistryEntryGetParentEntry(svc, kIOServicePlane, &dev) == KERN_SUCCESS) {
            CFTypeRef v = IORegistryEntryCreateCFProperty(dev, CFSTR("idVendor"), kCFAllocatorDefault, 0);
            CFTypeRef p = IORegistryEntryCreateCFProperty(dev, CFSTR("idProduct"), kCFAllocatorDefault, 0);
            if (v) { vid = [(__bridge NSNumber *)v unsignedShortValue]; CFRelease(v); }
            if (p) { pid = [(__bridge NSNumber *)p unsignedShortValue]; CFRelease(p); }
            IOObjectRelease(dev);
        }
        [result addObject:[[PTPUSBInterfaceInfo alloc] initWithService:svc vendorID:vid productID:pid]];
        IOObjectRelease(svc);
    }
    IOObjectRelease(iter);
    return result;
}

+ (int)killProcessesNamed:(NSString *)name {
    pid_t pids[2048];
    int bytes = proc_listallpids(pids, sizeof(pids));
    int count = bytes / (int)sizeof(pid_t);
    int killed = 0;
    for (int i = 0; i < count; i++) {
        char pname[PROC_PIDPATHINFO_MAXSIZE];
        if (proc_name(pids[i], pname, sizeof(pname)) <= 0) continue;
        if (strcmp(pname, name.UTF8String) != 0) continue;
        if (kill(pids[i], SIGKILL) == 0) killed++;
    }
    return killed;
}

- (instancetype)initWithService:(io_service_t)service {
    self = [super init];
    if (self) {
        _service = service;
        IOObjectRetain(_service);
        _readBuffer = [NSMutableData dataWithLength:8 * 1024 * 1024];
    }
    return self;
}

- (void)dealloc {
    [self close];
    if (_service) {
        IOObjectRelease(_service);
        _service = IO_OBJECT_NULL;
    }
}

static void *queryPlugin(io_service_t svc, CFUUIDRef pluginType, CFUUIDBytes iid) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    if (IOCreatePlugInInterfaceForService(svc, pluginType, kIOCFPlugInInterfaceID, &plugin, &score) != KERN_SUCCESS || !plugin)
        return NULL;
    void *result = NULL;
    (*plugin)->QueryInterface(plugin, iid, &result);
    (*plugin)->Release(plugin);
    return result;
}

- (BOOL)openSeizingWithError:(NSError **)error {
    io_service_t devSvc = IO_OBJECT_NULL;
    if (IORegistryEntryGetParentEntry(_service, kIOServicePlane, &devSvc) == KERN_SUCCESS && devSvc) {
        _device = queryPlugin(devSvc, kIOUSBDeviceUserClientTypeID,
                              CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID300));
        IOObjectRelease(devSvc);
    }
    if (_device) {
        IOReturn kr = (*_device)->USBDeviceOpenSeize(_device);
        if (kr != kIOReturnSuccess) {
            (*_device)->Release(_device);
            _device = NULL;
        }
    }

    _iface = queryPlugin(_service, kIOUSBInterfaceUserClientTypeID,
                         CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID300));
    if (!_iface) {
        if (error) *error = usbError(@"create interface plugin", kIOReturnNoResources);
        [self close];
        return NO;
    }

    IOReturn kr = (*_iface)->USBInterfaceOpenSeize(_iface);
    if (kr == kIOReturnExclusiveAccess) {
        [PTPUSBTransport killProcessesNamed:@"ptpcamerad"];
        usleep(300 * 1000);
        kr = (*_iface)->USBInterfaceOpenSeize(_iface);
    }
    if (kr != kIOReturnSuccess) {
        if (error) *error = usbError(@"USBInterfaceOpenSeize", kr);
        [self close];
        return NO;
    }

    (*_iface)->SetAlternateInterface(_iface, 0);
    UInt8 nep = 0;
    (*_iface)->GetNumEndpoints(_iface, &nep);
    for (UInt8 i = 1; i <= nep; i++) {
        UInt8 dir = 0, num = 0, tt = 0, interval = 0;
        UInt16 mps = 0;
        if ((*_iface)->GetPipeProperties(_iface, i, &dir, &num, &tt, &mps, &interval) != kIOReturnSuccess) continue;
        if (tt == kUSBBulk && dir == kUSBOut && !_pipeOut) _pipeOut = i;
        if (tt == kUSBBulk && dir == kUSBIn && !_pipeIn) _pipeIn = i;
    }
    if (!_pipeOut || !_pipeIn) {
        if (error) *error = usbError(@"bulk endpoint discovery", kIOReturnNotFound);
        [self close];
        return NO;
    }
    return YES;
}

- (void)close {
    if (_iface) {
        (*_iface)->USBInterfaceClose(_iface);
        (*_iface)->Release(_iface);
        _iface = NULL;
    }
    if (_device) {
        (*_device)->USBDeviceClose(_device);
        (*_device)->Release(_device);
        _device = NULL;
    }
    _pipeOut = _pipeIn = 0;
}

- (BOOL)write:(NSData *)data error:(NSError **)error {
    if (!_iface) {
        if (error) *error = usbError(@"write on closed transport", kIOReturnNotOpen);
        return NO;
    }
    IOReturn kr = (*_iface)->WritePipeTO(_iface, _pipeOut, (void *)data.bytes, (UInt32)data.length, 0, 5000);
    if (kr != kIOReturnSuccess) {
        if (error) *error = usbError(@"WritePipe", kr);
        return NO;
    }
    return YES;
}

- (NSData *)readWithTimeout:(NSTimeInterval)timeout error:(NSError **)error {
    if (!_iface) {
        if (error) *error = usbError(@"read on closed transport", kIOReturnNotOpen);
        return nil;
    }
    UInt32 size = (UInt32)_readBuffer.length;
    IOReturn kr = (*_iface)->ReadPipeTO(_iface, _pipeIn, _readBuffer.mutableBytes, &size, 0, (UInt32)(timeout * 1000));
    if (kr != kIOReturnSuccess) {
        if (error) *error = usbError(@"ReadPipe", kr);
        return nil;
    }
    return [_readBuffer subdataWithRange:NSMakeRange(0, size)];
}

@end
