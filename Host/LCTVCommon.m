#import "LCTVCommon.h"
NSString *const LCTVStateChangedNotification = @"LCTVStateChanged";

NSString *LCTVCachesDir(void) {
    NSString *c = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    [[NSFileManager defaultManager] createDirectoryAtPath:c withIntermediateDirectories:YES attributes:nil error:nil];
    return c;
}
NSString *LCTVAppsDir(void) {
    NSString *d = [LCTVCachesDir() stringByAppendingPathComponent:@"LCApps"];
    [[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}
NSString *LCTVLogPath(void) { return [LCTVCachesDir() stringByAppendingPathComponent:@"lctv_diag.log"]; }
NSString *LCTVPendingPath(void) { return [LCTVCachesDir() stringByAppendingPathComponent:@"lctv_pending_guest.txt"]; }
static BOOL lctvDirWritable(NSString *d) {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil]) return NO;
    NSString *probe = [d stringByAppendingPathComponent:@".probe"];
    BOOL ok = [@"x" writeToFile:probe atomically:NO encoding:NSUTF8StringEncoding error:nil];
    [fm removeItemAtPath:probe error:nil];
    return ok;
}
NSString *LCTVDataDirKind = @"?";
NSString *LCTVDataDir(void) {
    // Prefer Application Support (not purged). tvOS may refuse it for sideloaded apps -> fall back to Caches/LCTV.
    static NSString *dir; static dispatch_once_t o;
    dispatch_once(&o, ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *as = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"LCTV"];
        NSString *cd = [LCTVCachesDir() stringByAppendingPathComponent:@"LCTV"];
        if (as && lctvDirWritable(as)) { dir = as; LCTVDataDirKind = @"ApplicationSupport"; }
        else { lctvDirWritable(cd); dir = cd; LCTVDataDirKind = @"Caches (Application Support not writable on this tvOS)"; }
        // migrate legacy cert locations (Caches root, other candidate dir) — copy, never lose the original until copy succeeds
        for (NSString *f in @[@"cert.p12", @"cert.pass", @"cert.prev.p12"]) {
            NSString *nw = [dir stringByAppendingPathComponent:f];
            if ([fm fileExistsAtPath:nw]) continue;
            for (NSString *srcDir in @[LCTVCachesDir(), as ?: @"", cd]) {
                NSString *old = [srcDir stringByAppendingPathComponent:f];
                if (srcDir.length == 0 || [old isEqual:nw] || ![fm fileExistsAtPath:old]) continue;
                if ([fm copyItemAtPath:old toPath:nw error:nil]) { [fm removeItemAtPath:old error:nil]; break; }
            }
        }
    });
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}
NSString *LCTVIconsDir(void) {
    NSString *d = [LCTVDataDir() stringByAppendingPathComponent:@"Icons"];
    [[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}
NSString *LCTVCertPath(void) { return [LCTVDataDir() stringByAppendingPathComponent:@"cert.p12"]; }
NSString *LCTVCertPassPath(void) { return [LCTVDataDir() stringByAppendingPathComponent:@"cert.pass"]; }

void LCTVLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *ts = [NSDateFormatter localizedStringFromDate:[NSDate date] dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle];
    NSString *full = [NSString stringWithFormat:@"[%@] %@\n", ts, line];
    NSLog(@"[LCTV] %@", line);
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:LCTVLogPath()];
    if (!h) { [@"" writeToFile:LCTVLogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil]; h = [NSFileHandle fileHandleForWritingAtPath:LCTVLogPath()]; }
    [h seekToEndOfFile]; [h writeData:[full dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile];
}

NSString *LCTVReadLogTail(NSUInteger maxLen) {
    NSString *log = [NSString stringWithContentsOfFile:LCTVLogPath() encoding:NSUTF8StringEncoding error:nil] ?: @"(no diag yet)";
    if (log.length > maxLen) log = [log substringFromIndex:log.length - maxLen];
    return log;
}
