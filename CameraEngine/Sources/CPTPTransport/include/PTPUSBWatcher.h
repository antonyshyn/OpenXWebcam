#import <Foundation/Foundation.h>
#import "PTPUSBTransport.h"

NS_ASSUME_NONNULL_BEGIN

@interface PTPUSBInterfaceInfo (RegistryID)
@property (nonatomic, readonly) uint64_t registryID;
@end

@interface PTPUSBWatcher : NSObject

@property (nonatomic, copy, nullable) void (^onAttach)(PTPUSBInterfaceInfo *info);
@property (nonatomic, copy, nullable) void (^onDetach)(uint64_t registryID);

- (BOOL)startOnQueue:(dispatch_queue_t)queue;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
