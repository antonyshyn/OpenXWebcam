#import "include/PTPUSBWatcher.h"

@implementation PTPUSBInterfaceInfo (RegistryID)

- (uint64_t)registryID {
    uint64_t entryID = 0;
    IORegistryEntryGetRegistryEntryID(self.service, &entryID);
    return entryID;
}

@end

@implementation PTPUSBWatcher {
    IONotificationPortRef _port;
    io_iterator_t _publishIterator;
    io_iterator_t _terminateIterator;
}

static void publishCallback(void *refcon, io_iterator_t iterator) {
    PTPUSBWatcher *watcher = (__bridge PTPUSBWatcher *)refcon;
    io_service_t svc;
    while ((svc = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        PTPUSBInterfaceInfo *info = [PTPUSBInterfaceInfo infoForService:svc];
        IOObjectRelease(svc);
        if (info && watcher.onAttach) watcher.onAttach(info);
    }
}

static void terminateCallback(void *refcon, io_iterator_t iterator) {
    PTPUSBWatcher *watcher = (__bridge PTPUSBWatcher *)refcon;
    io_service_t svc;
    while ((svc = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        uint64_t entryID = 0;
        IORegistryEntryGetRegistryEntryID(svc, &entryID);
        IOObjectRelease(svc);
        if (entryID && watcher.onDetach) watcher.onDetach(entryID);
    }
}

- (BOOL)startOnQueue:(dispatch_queue_t)queue {
    if (_port) return YES;

    _port = IONotificationPortCreate(kIOMainPortDefault);
    if (!_port) return NO;
    IONotificationPortSetDispatchQueue(_port, queue);

    CFMutableDictionaryRef publishMatch = [PTPUSBTransport newPTPInterfaceMatchingDictionary];
    CFMutableDictionaryRef terminateMatch = [PTPUSBTransport newPTPInterfaceMatchingDictionary];
    if (!publishMatch || !terminateMatch) {
        if (publishMatch) CFRelease(publishMatch);
        if (terminateMatch) CFRelease(terminateMatch);
        [self stop];
        return NO;
    }

    kern_return_t kr = IOServiceAddMatchingNotification(_port, kIOFirstPublishNotification, publishMatch,
                                                        publishCallback, (__bridge void *)self, &_publishIterator);
    if (kr != KERN_SUCCESS) {
        CFRelease(terminateMatch);
        [self stop];
        return NO;
    }
    publishCallback((__bridge void *)self, _publishIterator);

    kr = IOServiceAddMatchingNotification(_port, kIOTerminatedNotification, terminateMatch,
                                          terminateCallback, (__bridge void *)self, &_terminateIterator);
    if (kr != KERN_SUCCESS) {
        [self stop];
        return NO;
    }
    terminateCallback((__bridge void *)self, _terminateIterator);

    return YES;
}

- (void)stop {
    if (_publishIterator) {
        IOObjectRelease(_publishIterator);
        _publishIterator = 0;
    }
    if (_terminateIterator) {
        IOObjectRelease(_terminateIterator);
        _terminateIterator = 0;
    }
    if (_port) {
        IONotificationPortDestroy(_port);
        _port = NULL;
    }
}

- (void)dealloc {
    [self stop];
}

@end
