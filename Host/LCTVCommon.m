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
NSString *LCTVDataDir(void) {
    // Application Support is NOT purged by tvOS (unlike Caches) — keep cert, icons, registry here.
    NSString *d = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"LCTV"];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    static dispatch_once_t o; dispatch_once(&o, ^{
        for (NSString *f in @[@"cert.p12", @"cert.pass"]) {
            NSString *old = [LCTVCachesDir() stringByAppendingPathComponent:f], *nw = [d stringByAppendingPathComponent:f];
            if ([fm fileExistsAtPath:old] && ![fm fileExistsAtPath:nw]) [fm moveItemAtPath:old toPath:nw error:nil];
        }
    });
    return d;
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
