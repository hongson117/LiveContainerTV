#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, LCTVCertState) {
    LCTVCertStateNoP12,        // nothing uploaded yet
    LCTVCertStateOK,           // p12 cert == host's signing cert
    LCTVCertStateChanged,      // atvloadly refreshed with a new cert; need new p12
    LCTVCertStateBadP12,       // p12 could not be parsed with stored password
    LCTVCertStateUnknownHost,  // no embedded.mobileprovision (simulator / unsigned)
};
@interface LCTVCert : NSObject
+ (instancetype)shared;
@property (readonly) LCTVCertState state;
@property (readonly, nullable) NSString *hostFingerprint;   // SHA1 of host signing cert (mobileprovision)
@property (readonly, nullable) NSString *p12Fingerprint;    // SHA1 of cert inside stored p12
@property (readonly, nullable) NSDate *expiry;              // provisioning / cert expiry
@property (readonly, nullable) NSString *teamName;
@property (readonly) BOOL busy;
@property (readonly, copy) NSString *busyText;
- (NSInteger)daysLeft;
- (NSString *)summary;            // short human status
/// Re-evaluate; tries key-reuse; re-signs guests whose fingerprint differs. Async, posts LCTVStateChangedNotification.
- (void)evaluateAndResignAsync:(BOOL)forceAll;
/// Synchronous evaluate (no signing).
- (void)evaluate;
@end
NS_ASSUME_NONNULL_END
