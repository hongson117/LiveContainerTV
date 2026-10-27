#import "LCTVAppManager.h"
#import "LCTVCommon.h"
#import "LCTVMachOPatch.h"
#import <zlib.h>
#import "../ZSign/zsigner.h"

@implementation LCTVImportedApp
@end

@implementation LCTVAppManager

+ (instancetype)shared { static LCTVAppManager *s; static dispatch_once_t o; dispatch_once(&o,^{ s=[self new]; }); return s; }

- (NSArray<LCTVImportedApp *> *)importedApps {
    NSMutableArray *out = [NSMutableArray new];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *bid in [fm contentsOfDirectoryAtPath:LCTVAppsDir() error:nil]) {
        NSString *dir = [LCTVAppsDir() stringByAppendingPathComponent:bid];
        BOOL isDir = NO; if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) continue;
        for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:nil]) {
            if (![f.pathExtension.lowercaseString isEqual:@"app"]) continue;
            NSString *app = [dir stringByAppendingPathComponent:f];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[app stringByAppendingPathComponent:@"Info.plist"]];
            LCTVImportedApp *a = [LCTVImportedApp new];
            a.bundleId = info[@"CFBundleIdentifier"] ?: bid;
            a.name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: f.stringByDeletingPathExtension;
            a.appPath = app;
            NSString *execName = info[@"CFBundleExecutable"] ?: f.stringByDeletingPathExtension;
            a.execPath = [app stringByAppendingPathComponent:execName];
            a.patched = [[NSUserDefaults standardUserDefaults] boolForKey:[@"patched." stringByAppendingString:a.bundleId]];
            a.signedOK = [[NSUserDefaults standardUserDefaults] boolForKey:[@"signed." stringByAppendingString:a.bundleId]];
            [out addObject:a];
        }
    }
    return out;
}

- (BOOL)hasCertificate { return [NSFileManager.defaultManager fileExistsAtPath:LCTVCertPath()]; }
- (NSData *)certificateData { return [NSData dataWithContentsOfFile:LCTVCertPath()]; }
- (NSString *)certificatePassword {
    return [[NSString stringWithContentsOfFile:LCTVCertPassPath() encoding:NSUTF8StringEncoding error:nil] ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
}
- (BOOL)saveCertificateData:(NSData *)p12 password:(NSString *)password error:(NSError **)error {
    if (![p12 writeToFile:LCTVCertPath() options:NSDataWritingAtomic error:error]) return NO;
    [(password ?: @"") writeToFile:LCTVCertPassPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    LCTVLog(@"saved cert.p12 (%lu bytes) passLen=%lu", (unsigned long)p12.length, (unsigned long)(password ?: @"").length);
    return YES;
}

- (BOOL)deleteApp:(NSString *)bundleId error:(NSError **)error {
    NSString *dir = [LCTVAppsDir() stringByAppendingPathComponent:bundleId];
    BOOL ok = [NSFileManager.defaultManager removeItemAtPath:dir error:error];
    LCTVLog(@"delete %@ ok=%d", bundleId, ok);
    return ok;
}

#pragma mark - ZIP (minimal)

static uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1]<<8) | ((uint32_t)p[2]<<16) | ((uint32_t)p[3]<<24); }
static uint16_t rd16(const uint8_t *p) { return (uint16_t)p[0] | ((uint16_t)p[1]<<8); }

- (BOOL)unzipData:(NSData *)zip toDirectory:(NSString *)dest error:(NSError **)error {
    const uint8_t *b = zip.bytes; size_t n = zip.length;
    // Find EOCD
    if (n < 22) { if (error)*error=[NSError errorWithDomain:@"LCTV" code:10 userInfo:@{NSLocalizedDescriptionKey:@"zip too small"}]; return NO; }
    size_t eocd = n - 22;
    while (eocd > 0 && rd32(b + eocd) != 0x06054b50) eocd--;
    if (rd32(b + eocd) != 0x06054b50) { if (error)*error=[NSError errorWithDomain:@"LCTV" code:11 userInfo:@{NSLocalizedDescriptionKey:@"EOCD not found"}]; return NO; }
    uint32_t cdOff = rd32(b + eocd + 16);
    uint16_t entries = rd16(b + eocd + 10);
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:nil];
    size_t p = cdOff;
    for (uint16_t i = 0; i < entries && p + 46 <= n; i++) {
        if (rd32(b + p) != 0x02014b50) break;
        uint16_t method = rd16(b + p + 10);
        uint32_t comp = rd32(b + p + 20);
        uint32_t uncomp = rd32(b + p + 24);
        uint16_t nlen = rd16(b + p + 28);
        uint16_t elen = rd16(b + p + 30);
        uint16_t clen = rd16(b + p + 32);
        uint32_t lhoff = rd32(b + p + 42);
        NSString *name = [[NSString alloc] initWithBytes:b+p+46 length:nlen encoding:NSUTF8StringEncoding] ?: @"";
        p += 46 + nlen + elen + clen;
        if ([name hasSuffix:@"/"]) continue;
        if (lhoff + 30 > n) continue;
        if (rd32(b + lhoff) != 0x04034b50) continue;
        uint16_t lnlen = rd16(b + lhoff + 26);
        uint16_t lelen = rd16(b + lhoff + 28);
        const uint8_t *payload = b + lhoff + 30 + lnlen + lelen;
        if ((size_t)(payload - b) + comp > n) continue;
        NSData *outData = nil;
        if (method == 0) {
            outData = [NSData dataWithBytes:payload length:comp];
        } else if (method == 8) {
            NSMutableData *dst = [NSMutableData dataWithLength:uncomp ? uncomp : comp * 4 + 1024];
            z_stream strm = {0};
            strm.next_in = (Bytef *)payload; strm.avail_in = comp;
            strm.next_out = dst.mutableBytes; strm.avail_out = (uInt)dst.length;
            // negative windowBits = raw deflate
            if (inflateInit2(&strm, -MAX_WBITS) != Z_OK) continue;
            int zr = inflate(&strm, Z_FINISH);
            inflateEnd(&strm);
            if (zr != Z_STREAM_END && zr != Z_OK) {
                // try zlib wrapper
                strm = (z_stream){0};
                strm.next_in = (Bytef *)payload; strm.avail_in = comp;
                dst = [NSMutableData dataWithLength:uncomp ?: comp * 4 + 1024];
                strm.next_out = dst.mutableBytes; strm.avail_out = (uInt)dst.length;
                if (inflateInit2(&strm, MAX_WBITS) != Z_OK) continue;
                zr = inflate(&strm, Z_FINISH);
                inflateEnd(&strm);
                if (zr != Z_STREAM_END && zr != Z_OK) continue;
            }
            dst.length = strm.total_out;
            outData = dst;
        } else {
            LCTVLog(@"zip: skip %@ method=%u", name, method);
            continue;
        }
        NSString *outPath = [dest stringByAppendingPathComponent:name];
        [fm createDirectoryAtPath:outPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        [outData writeToFile:outPath atomically:YES];
    }
    return YES;
}

- (NSString *)importIPAData:(NSData *)data suggestedName:(NSString *)name error:(NSError **)error {
    NSString *tmp = [LCTVCachesDir() stringByAppendingPathComponent:[NSString stringWithFormat:@"import-%@.ipa", NSUUID.UUID.UUIDString]];
    if (![data writeToFile:tmp atomically:YES]) { if (error)*error=[NSError errorWithDomain:@"LCTV" code:20 userInfo:@{NSLocalizedDescriptionKey:@"write tmp failed"}]; return nil; }
    NSString *bid = [self importIPAAtPath:tmp error:error];
    [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
    return bid;
}

- (NSString *)importIPAAtPath:(NSString *)ipaPath error:(NSError **)error {
    LCTVLog(@"import IPA %@", ipaPath);
    NSData *data = [NSData dataWithContentsOfFile:ipaPath options:NSDataReadingMappedIfSafe error:error];
    if (!data) return nil;
    NSString *stage = [LCTVCachesDir() stringByAppendingPathComponent:[NSString stringWithFormat:@"stage-%@", NSUUID.UUID.UUIDString]];
    if (![self unzipData:data toDirectory:stage error:error]) return nil;
    NSString *payload = [stage stringByAppendingPathComponent:@"Payload"];
    NSArray *apps = [NSFileManager.defaultManager contentsOfDirectoryAtPath:payload error:nil];
    NSString *appName = nil;
    for (NSString *f in apps) if ([f.pathExtension.lowercaseString isEqual:@"app"]) { appName = f; break; }
    if (!appName) { if (error)*error=[NSError errorWithDomain:@"LCTV" code:21 userInfo:@{NSLocalizedDescriptionKey:@"No .app in Payload"}]; return nil; }
    NSString *appSrc = [payload stringByAppendingPathComponent:appName];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[appSrc stringByAppendingPathComponent:@"Info.plist"]];
    NSString *bid = info[@"CFBundleIdentifier"] ?: appName.stringByDeletingPathExtension;
    NSString *destDir = [LCTVAppsDir() stringByAppendingPathComponent:bid];
    [NSFileManager.defaultManager removeItemAtPath:destDir error:nil];
    [NSFileManager.defaultManager createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *destApp = [destDir stringByAppendingPathComponent:appName];
    NSError *err = nil;
    if (![NSFileManager.defaultManager moveItemAtPath:appSrc toPath:destApp error:&err]) {
        if (error) *error = err; return nil;
    }
    [NSFileManager.defaultManager removeItemAtPath:stage error:nil];

    LCTVImportedApp *app = [LCTVImportedApp new];
    app.bundleId = bid; app.appPath = destApp;
    NSString *execName = info[@"CFBundleExecutable"] ?: appName.stringByDeletingPathExtension;
    app.execPath = [destApp stringByAppendingPathComponent:execName];
    app.name = info[@"CFBundleDisplayName"] ?: execName;

    NSString *prepErr = [self prepareAppForLaunch:app];
    if (prepErr) LCTVLog(@"prepare warning: %@", prepErr);
    LCTVLog(@"imported %@ -> %@", bid, destApp);
    return bid;
}

- (NSString *)prepareAppForLaunch:(LCTVImportedApp *)app {
    NSError *err = nil;
    if (![[NSFileManager defaultManager] fileExistsAtPath:app.execPath])
        return [NSString stringWithFormat:@"missing exec %@", app.execPath];
    // Strip existing code signature folder before patch/sign
    [[NSFileManager defaultManager] removeItemAtPath:[app.appPath stringByAppendingPathComponent:@"_CodeSignature"] error:nil];

    if (!LCTVPatchExecToDylib(app.execPath, &err))
        return [NSString stringWithFormat:@"patch failed: %@", err.localizedDescription];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:[@"patched." stringByAppendingString:app.bundleId]];

    if (![self hasCertificate]) {
        LCTVLog(@"no cert.p12 — guest will likely fail dlopen (library validation)");
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:[@"signed." stringByAppendingString:app.bundleId]];
        return @"No certificate. Upload a .p12 via the web UI (port 8228).";
    }

    __block NSString *signErr = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSData *cert = [self certificateData];
    NSString *pass = [self certificatePassword];
    [ZSigner signWithAppPath:app.appPath
                    bundleId:NSBundle.mainBundle.bundleIdentifier
                        cert:cert
                        pass:pass
           completionHandler:^(BOOL success, NSError *error) {
        if (!success) signErr = error.localizedDescription ?: @"sign failed";
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 180 * NSEC_PER_SEC));

    if (signErr) {
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:[@"signed." stringByAppendingString:app.bundleId]];
        LCTVLog(@"sign failed: %@", signErr);
        return signErr;
    }
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:[@"signed." stringByAppendingString:app.bundleId]];
    LCTVLog(@"signed OK %@", app.bundleId);
    return nil;
}

@end
