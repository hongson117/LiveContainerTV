#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface LCTVImportedApp : NSObject
@property NSString *bundleId;
@property NSString *name;
@property NSString *appPath;   // .../LCApps/<id>/<Name>.app
@property NSString *execPath;
@property BOOL patched;
@property BOOL signedOK;
@property BOOL purged;                       // folder removed by tvOS cache purge → needs re-import
@property (nullable) NSString *signedFingerprint; // SHA1 of cert used at last successful sign
@property (nullable) NSString *version;
@property (nullable) NSString *signedDate;
@end
@interface LCTVImportedApp (UI)
- (NSString *)shortName;
@end

@interface LCTVAppManager : NSObject
+ (instancetype)shared;
- (NSArray<LCTVImportedApp *> *)importedApps;
- (nullable NSString *)importIPAAtPath:(NSString *)ipaPath error:(NSError **)error;
- (nullable NSString *)importIPAData:(NSData *)data suggestedName:(NSString *)name error:(NSError **)error;
- (BOOL)deleteApp:(NSString *)bundleId error:(NSError **)error;
- (BOOL)saveCertificateData:(NSData *)p12 password:(NSString *)password error:(NSError **)error;
- (BOOL)hasCertificate;
- (NSString *)certificatePassword;
- (nullable NSData *)certificateData;
/// Patch + sign guest .app. Returns nil on success, error string otherwise.
- (nullable NSString *)prepareAppForLaunch:(LCTVImportedApp *)app;
/// Guest icon (cached PNG in Application Support; extracted from Assets.car/PNGs, else letter tile).
- (UIImage *)iconForApp:(LCTVImportedApp *)app;
- (nullable NSString *)iconPathForBundleId:(NSString *)bid;
- (void)forgetApp:(NSString *)bundleId;
+ (UIImage *)letterTileFor:(NSString *)name size:(CGSize)size;
@end
NS_ASSUME_NONNULL_END
