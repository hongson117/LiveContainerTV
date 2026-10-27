#import <sys/stat.h>
#import "LCTVAppManager.h"
#import "LCTVCommon.h"
#import "LCTVMachOPatch.h"
#import <zlib.h>
#import "../ZSign/zsigner.h"
#import "LCTVCert.h"

@implementation LCTVImportedApp
- (NSString *)shortName {
    NSString *n = self.name.length ? self.name : self.bundleId;
    return n.length > 22 ? [[n substringToIndex:21] stringByAppendingString:@"…"] : n;
}
@end

static NSCache *gIconMem;
__attribute__((constructor)) static void initIconMem(void) { gIconMem = [NSCache new]; }
static NSString *const kRegistry = @"LCTVKnownApps"; // bid -> {name, version}

@implementation LCTVAppManager

+ (instancetype)shared { static LCTVAppManager *s; static dispatch_once_t o; dispatch_once(&o,^{ s=[self new]; }); return s; }

static NSString *exeStamp(NSString *path) {
    struct stat st; if (stat(path.fileSystemRepresentation, &st) != 0) return nil;
    return [NSString stringWithFormat:@"%lld:%ld.%ld:%llu", (long long)st.st_size, (long)st.st_mtimespec.tv_sec, (long)st.st_mtimespec.tv_nsec, (unsigned long long)st.st_ino];
}
/// Prepared-state manifest: exe stamp + cert fp recorded after patch+fixup+sign. Equal => nothing to do at launch.
- (BOOL)isPreparedFast:(LCTVImportedApp *)app {
    NSString *want = [[NSUserDefaults standardUserDefaults] stringForKey:[@"prep." stringByAppendingString:app.bundleId]];
    NSString *have = exeStamp(app.execPath);
    return want.length && have && [want isEqual:have];
}
- (void)recordPrepared:(LCTVImportedApp *)app {
    NSString *st = exeStamp(app.execPath);
    if (st) [[NSUserDefaults standardUserDefaults] setObject:st forKey:[@"prep." stringByAppendingString:app.bundleId]];
}
/// O(1) lookup for the guest boot path: no directory scan of other apps, no signature parsing.
- (LCTVImportedApp *)appForBundleIdFast:(NSString *)bid {
    NSString *dir = [LCTVAppsDir() stringByAppendingPathComponent:bid];
    for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]) {
        if (![f.pathExtension.lowercaseString isEqual:@"app"]) continue;
        NSString *app = [dir stringByAppendingPathComponent:f];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[app stringByAppendingPathComponent:@"Info.plist"]];
        LCTVImportedApp *a = [LCTVImportedApp new];
        a.bundleId = info[@"CFBundleIdentifier"] ?: bid;
        a.name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: f.stringByDeletingPathExtension;
        a.appPath = app;
        a.execPath = [app stringByAppendingPathComponent:info[@"CFBundleExecutable"] ?: f.stringByDeletingPathExtension];
        return a;
    }
    return nil;
}

- (void)registerAppIfNeeded:(LCTVImportedApp *)a {
    NSDictionary *reg = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kRegistry];
    if (reg[a.bundleId]) return;
    NSMutableDictionary *m = [reg mutableCopy] ?: [NSMutableDictionary new];
    m[a.bundleId] = @{@"name": a.name ?: a.bundleId, @"version": a.version ?: @""};
    [[NSUserDefaults standardUserDefaults] setObject:m forKey:kRegistry];
}

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
            a.signedFingerprint = [[NSUserDefaults standardUserDefaults] stringForKey:[@"signedFP." stringByAppendingString:a.bundleId]];
            a.signedDate = [[NSUserDefaults standardUserDefaults] stringForKey:[@"signedAt." stringByAppendingString:a.bundleId]];
            a.version = info[@"CFBundleShortVersionString"];
            if (![fm fileExistsAtPath:a.execPath]) a.purged = YES;
            else {
                // Trust the real signature over metadata (handles apps signed by older builds / migrated)
                NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
                NSString *stamp = exeStamp(a.execPath), *sk = [@"sigStamp." stringByAppendingString:a.bundleId];
                NSString *fp = nil;
                if (stamp && [[ud stringForKey:sk] isEqual:stamp]) fp = a.signedFingerprint;
                else { fp = LCTVSignerFingerprint(a.execPath); if (stamp && fp) [ud setObject:stamp forKey:sk]; }
                if (fp) {
                    if (![fp isEqual:a.signedFingerprint]) {
                        a.signedFingerprint = fp;
                        [[NSUserDefaults standardUserDefaults] setObject:fp forKey:[@"signedFP." stringByAppendingString:a.bundleId]];
                    }
                    if (!a.signedOK) { a.signedOK = YES; [[NSUserDefaults standardUserDefaults] setBool:YES forKey:[@"signed." stringByAppendingString:a.bundleId]]; }
                }
                [self registerAppIfNeeded:a];
            }
            [out addObject:a];
        }
    }
    // Apps we imported before whose folder tvOS purged from Caches
    NSDictionary *reg = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kRegistry];
    NSSet *present = [NSSet setWithArray:[out valueForKey:@"bundleId"]];
    for (NSString *bid in reg) {
        if ([present containsObject:bid]) continue;
        LCTVImportedApp *a = [LCTVImportedApp new];
        a.bundleId = bid; a.name = reg[bid][@"name"] ?: bid; a.version = reg[bid][@"version"];
        a.purged = YES; a.appPath = @""; a.execPath = @"";
        [out addObject:a];
    }
    [out sortUsingComparator:^NSComparisonResult(LCTVImportedApp *x, LCTVImportedApp *y) { return [x.name localizedCaseInsensitiveCompare:y.name]; }];
    return out;
}

- (BOOL)hasCertificate { return [NSFileManager.defaultManager fileExistsAtPath:LCTVCertPath()]; }
- (NSData *)certificateData { return [NSData dataWithContentsOfFile:LCTVCertPath()]; }
- (NSString *)certificatePassword {
    return [[NSString stringWithContentsOfFile:LCTVCertPassPath() encoding:NSUTF8StringEncoding error:nil] ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
}
- (BOOL)saveCertificateData:(NSData *)p12 password:(NSString *)password error:(NSError **)error {
    [NSFileManager.defaultManager createDirectoryAtPath:LCTVCertPath().stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    if (![p12 writeToFile:LCTVCertPath() options:NSDataWritingAtomic error:error]) return NO;
    [(password ?: @"") writeToFile:LCTVCertPassPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    LCTVLog(@"saved cert.p12 (%lu bytes) passLen=%lu", (unsigned long)p12.length, (unsigned long)(password ?: @"").length);
    return YES;
}

- (BOOL)deleteApp:(NSString *)bundleId error:(NSError **)error {
    NSString *dir = [LCTVAppsDir() stringByAppendingPathComponent:bundleId];
    BOOL ok = [NSFileManager.defaultManager removeItemAtPath:dir error:error];
    [self forgetApp:bundleId];
    LCTVLog(@"delete %@ ok=%d", bundleId, ok);
    if (!ok) { ok = YES; if (error) *error = nil; } // purged entries have no folder
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

    NSMutableDictionary *reg = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:kRegistry] mutableCopy] ?: [NSMutableDictionary new];
    reg[bid] = @{@"name": app.name ?: bid, @"version": info[@"CFBundleShortVersionString"] ?: @""};
    [[NSUserDefaults standardUserDefaults] setObject:reg forKey:kRegistry];
    [[NSFileManager defaultManager] removeItemAtPath:[self iconCachePath:bid] error:nil];
    [gIconMem removeObjectForKey:bid];
    if (NSThread.isMainThread) (void)[self iconForApp:app]; else dispatch_sync(dispatch_get_main_queue(), ^{ (void)[self iconForApp:app]; });
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
    // Fix load paths: guest main exe gets LC_RPATH @loader_path/Frameworks; every nested Mach-O gets
    // @executable_path rewritten relative to the guest .app root (dyld would otherwise resolve to the host).
    LCTVFixGuestLoadPaths(app.execPath, @"", YES, nil);
    NSDirectoryEnumerator *en = [[NSFileManager defaultManager] enumeratorAtPath:app.appPath];
    NSString *rel; NSUInteger nFix = 0;
    while ((rel = [en nextObject])) {
        NSString *full = [app.appPath stringByAppendingPathComponent:rel];
        if ([full isEqualToString:app.execPath]) continue;
        BOOL dir = NO; [[NSFileManager defaultManager] fileExistsAtPath:full isDirectory:&dir];
        if (dir) continue;
        NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:full];
        NSData *m = [fh readDataOfLength:4]; [fh closeFile];
        if (m.length < 4 || *(const uint32_t *)m.bytes != 0xfeedfacf) continue;
        NSUInteger depth = rel.stringByDeletingLastPathComponent.pathComponents.count;
        NSMutableArray *ups = [NSMutableArray new];
        for (NSUInteger i = 0; i < depth; i++) [ups addObject:@".."];
        LCTVFixGuestLoadPaths(full, [ups componentsJoinedByString:@"/"], NO, nil);
        nFix++;
    }
    LCTVLog(@"fixup: scanned %lu nested Mach-O files", (unsigned long)nFix);
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
    [[LCTVCert shared] evaluate];
    NSString *fp = [LCTVCert shared].p12Fingerprint;
    if (fp) [[NSUserDefaults standardUserDefaults] setObject:fp forKey:[@"signedFP." stringByAppendingString:app.bundleId]];
    [[NSUserDefaults standardUserDefaults] setObject:[NSDateFormatter localizedStringFromDate:NSDate.date dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle]
                                              forKey:[@"signedAt." stringByAppendingString:app.bundleId]];
    [self recordPrepared:app];
    LCTVLog(@"signed OK %@ (ZSign signs each Mach-O in place; no _CodeSignature folder is expected)", app.bundleId);
    return nil;
}


#pragma mark - Icons

- (NSString *)iconCachePath:(NSString *)bid { return [LCTVIconsDir() stringByAppendingPathComponent:[bid stringByAppendingString:@".png"]]; }
- (NSString *)iconPathForBundleId:(NSString *)bid {
    NSString *p = [self iconCachePath:bid];
    return [NSFileManager.defaultManager fileExistsAtPath:p] ? p : nil;
}
- (void)forgetApp:(NSString *)bid {
    NSMutableDictionary *reg = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:kRegistry] mutableCopy];
    [reg removeObjectForKey:bid];
    [[NSUserDefaults standardUserDefaults] setObject:reg ?: @{} forKey:kRegistry];
    for (NSString *k in @[@"signed.", @"signedFP.", @"signedAt.", @"patched.", @"prep.", @"sigStamp."]) [[NSUserDefaults standardUserDefaults] removeObjectForKey:[k stringByAppendingString:bid]];
    [NSFileManager.defaultManager removeItemAtPath:[self iconCachePath:bid] error:nil];
    [gIconMem removeObjectForKey:bid];
}

+ (UIImage *)letterTileFor:(NSString *)name size:(CGSize)size {
    NSString *letter = name.length ? [[name substringToIndex:1] uppercaseString] : @"?";
    NSUInteger h = name.hash;
    UIColor *c1 = [UIColor colorWithHue:(h % 360) / 360.0 saturation:0.65 brightness:0.85 alpha:1];
    UIColor *c2 = [UIColor colorWithHue:((h + 40) % 360) / 360.0 saturation:0.8 brightness:0.45 alpha:1];
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGGradientRef g = CGGradientCreateWithColors(cs, (__bridge CFArrayRef)@[(id)c1.CGColor, (id)c2.CGColor], NULL);
        CGContextDrawLinearGradient(ctx.CGContext, g, CGPointZero, CGPointMake(size.width, size.height), 0);
        CGGradientRelease(g); CGColorSpaceRelease(cs);
        UIFont *f = [UIFont systemFontOfSize:size.height * 0.5 weight:UIFontWeightHeavy];
        NSDictionary *at = @{NSFontAttributeName: f, NSForegroundColorAttributeName: UIColor.whiteColor};
        CGSize ts = [letter sizeWithAttributes:at];
        [letter drawAtPoint:CGPointMake((size.width - ts.width) / 2, (size.height - ts.height) / 2) withAttributes:at];
    }];
}

static UIImage *fitTile(UIImage *img, CGSize size) {
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [UIColor.blackColor setFill]; UIRectFill(CGRectMake(0, 0, size.width, size.height));
        CGFloat s = MAX(size.width / img.size.width, size.height / img.size.height);
        CGSize d = CGSizeMake(img.size.width * s, img.size.height * s);
        [img drawInRect:CGRectMake((size.width - d.width) / 2, (size.height - d.height) / 2, d.width, d.height)];
    }];
}

- (UIImage *)extractIconFromBundle:(NSString *)appPath {
    NSBundle *b = [NSBundle bundleWithPath:appPath];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[appPath stringByAppendingPathComponent:@"Info.plist"]];
    NSMutableArray *names = [NSMutableArray new];
    for (NSString *k in @[@"CFBundleIcons", @"CFBundleIcons~tv"]) {
        NSDictionary *pi = info[k][@"CFBundlePrimaryIcon"];
        if ([pi isKindOfClass:NSDictionary.class]) {
            if (pi[@"CFBundleIconName"]) [names addObject:pi[@"CFBundleIconName"]];
            for (NSString *f in pi[@"CFBundleIconFiles"]) [names addObject:f];
        } else if ([pi isKindOfClass:NSString.class]) [names addObject:pi];
    }
    if (info[@"CFBundleIconFile"]) [names addObject:info[@"CFBundleIconFile"]];
    [names addObjectsFromArray:@[@"App Icon", @"App Icon - App Store", @"App Icon - Large", @"App Icon - Small", @"AppIcon", @"Top Shelf Image", @"Top Shelf Image Wide"]];
    if (b) for (NSString *n in names) {
        UIImage *img = nil;
        @try { img = [UIImage imageNamed:n inBundle:b compatibleWithTraitCollection:nil]; } @catch (NSException *e) {}
        if (img.size.width > 8) { LCTVLog(@"icon: '%@' from Assets.car %.0fx%.0f", n, img.size.width, img.size.height); return img; }
    }
    // loose PNGs
    UIImage *best = nil;
    for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:appPath error:nil]) {
        if (![f.pathExtension.lowercaseString isEqual:@"png"] || [f.lowercaseString rangeOfString:@"icon"].location == NSNotFound) continue;
        UIImage *img = [UIImage imageWithContentsOfFile:[appPath stringByAppendingPathComponent:f]];
        if (img.size.width * img.scale > best.size.width * best.scale) best = img;
    }
    if (best) LCTVLog(@"icon: loose PNG %.0fx%.0f", best.size.width, best.size.height);
    return best;
}

- (UIImage *)iconForApp:(LCTVImportedApp *)app {
    NSCache *mem = gIconMem;
    UIImage *c = [mem objectForKey:app.bundleId];
    if (c) return c;
    NSString *p = [self iconCachePath:app.bundleId];
    UIImage *img = [UIImage imageWithContentsOfFile:p];
    if (!img) {
        CGSize sz = CGSizeMake(400, 240);
        UIImage *src = app.appPath.length ? [self extractIconFromBundle:app.appPath] : nil;
        img = src ? fitTile(src, sz) : [LCTVAppManager letterTileFor:app.name ?: app.bundleId size:sz];
        if (src || !app.purged) [UIImagePNGRepresentation(img) writeToFile:p atomically:YES];
    }
    [mem setObject:img forKey:app.bundleId];
    return img;
}

@end
