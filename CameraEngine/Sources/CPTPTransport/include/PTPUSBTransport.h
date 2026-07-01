#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const PTPUSBErrorDomain;

@interface PTPUSBInterfaceInfo : NSObject
@property (nonatomic, readonly) uint16_t vendorID;
@property (nonatomic, readonly) uint16_t productID;
@property (nonatomic, readonly, nullable) NSString *productName;
@property (nonatomic, readonly) io_service_t service;
+ (nullable instancetype)infoForService:(io_service_t)service;
@end

@interface PTPUSBTransport : NSObject

+ (NSArray<PTPUSBInterfaceInfo *> *)findPTPInterfaces;
+ (int)killProcessesNamed:(NSString *)name;
+ (nullable CFMutableDictionaryRef)newPTPInterfaceMatchingDictionary;

- (instancetype)initWithService:(io_service_t)service;
- (BOOL)openSeizingWithError:(NSError **)error;
- (void)close;

- (BOOL)write:(NSData *)data error:(NSError **)error;
- (nullable NSData *)readWithTimeout:(NSTimeInterval)timeout error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
