#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

NS_ASSUME_NONNULL_BEGIN
void LCTVLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
NSString *LCTVCachesDir(void);
NSString *LCTVAppsDir(void);
NSString *LCTVLogPath(void);
NSString *LCTVPendingPath(void);
NSString *LCTVCertPath(void);
NSString *LCTVDataDir(void);
NSString *LCTVIconsDir(void);
extern NSString *LCTVDataDirKind;
extern BOOL LCTVQuiet; // set once a guest is running: logging becomes a no-op
/// SHA1 (hex, upper) of leaf cert in the Mach-O CMS code signature, nil if unsigned / ad-hoc.
NSString *LCTVSignerFingerprint(NSString *execPath);
extern NSString *const LCTVStateChangedNotification;
NSString *LCTVCertPassPath(void);
NSString *LCTVReadLogTail(NSUInteger maxLen);
NS_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif
