#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface LCTVImportedApp : NSObject
@property NSString *bundleId;
@property NSString *name;
@property NSString *appPath;   // .../LCApps/<id>/<Name>.app
@property NSString *execPath;
@property BOOL patched;
@property BOOL signedOK;
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
@end
NS_ASSUME_NONNULL_END
