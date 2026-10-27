#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface LCTVHTTPServer : NSObject
@property (readonly) uint16_t port;
@property (readonly, getter=isRunning) BOOL running;
@property (readonly) NSString *lanURL;
+ (instancetype)shared;
- (BOOL)start:(NSError **)error;
- (void)stop;
@end
NS_ASSUME_NONNULL_END
