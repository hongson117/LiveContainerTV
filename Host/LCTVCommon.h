#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
void LCTVLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
NSString *LCTVCachesDir(void);
NSString *LCTVAppsDir(void);
NSString *LCTVLogPath(void);
NSString *LCTVPendingPath(void);
NSString *LCTVCertPath(void);
NSString *LCTVCertPassPath(void);
NSString *LCTVReadLogTail(NSUInteger maxLen);
NS_ASSUME_NONNULL_END
