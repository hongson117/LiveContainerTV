#import "LCTVCommon.h"

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
NSString *LCTVCertPath(void) { return [LCTVCachesDir() stringByAppendingPathComponent:@"cert.p12"]; }
NSString *LCTVCertPassPath(void) { return [LCTVCachesDir() stringByAppendingPathComponent:@"cert.pass"]; }

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
