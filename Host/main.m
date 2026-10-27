#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <objc/runtime.h>
#import <sys/stat.h>
#import <unistd.h>
#import "LCTVCommon.h"
#import "LCTVHTTPServer.h"
#import "LCTVAppManager.h"
#import "LCTVUI.h"
#import "LCTVCert.h"

static NSString *gGuestBundlePath;
#import <execinfo.h>
#import <signal.h>
#import <fcntl.h>
#import <mach-o/fat.h>
#import <dlfcn.h>

static NSMutableArray *gFailReasons;
static void LCTVFail(NSString *r) { if (!gFailReasons) gFailReasons = [NSMutableArray new]; [gFailReasons addObject:r]; LCTVLog(@"FAIL %@", r); }
static NSString *gPreloadSummary;

#pragma mark - Crash capture (guest)
static int gCrashFD = -1;
static const struct mach_header *gGuestHdr;
NSString *LCTVCrashPath(void) { return [LCTVCachesDir() stringByAppendingPathComponent:@"lctv_last_crash.txt"]; }
static void wr(const char *s) { if (gCrashFD >= 0 && s) write(gCrashFD, s, strlen(s)); }
static void wrhex(uintptr_t v) { char b[19] = "0x"; for (int i = 0; i < 16; i++) { int n = (v >> ((15 - i) * 4)) & 0xf; b[2+i] = n < 10 ? '0'+n : 'a'+n-10; } b[18] = 0; wr(b); }
static void crashSignal(int sig, siginfo_t *info, void *ctx) {
    wr("\n=== SIGNAL "); wr(sig == SIGSEGV ? "SIGSEGV" : sig == SIGABRT ? "SIGABRT" : sig == SIGBUS ? "SIGBUS" : sig == SIGILL ? "SIGILL" : sig == SIGTRAP ? "SIGTRAP" : sig == SIGFPE ? "SIGFPE" : "?");
    wr(" fault addr="); wrhex((uintptr_t)info->si_addr); wr(" guest base="); wrhex((uintptr_t)gGuestHdr); wr("\n");
    void *bt[64]; int n = backtrace(bt, 64);
    for (int i = 0; i < n; i++) { // image + offset (dladdr is not strictly async-safe but works in practice)
        Dl_info di; wrhex((uintptr_t)bt[i]);
        if (dladdr(bt[i], &di) && di.dli_fname) {
            const char *base = strrchr(di.dli_fname, '/'); wr("  "); wr(base ? base + 1 : di.dli_fname);
            wr(" +"); wrhex((uintptr_t)bt[i] - (uintptr_t)di.dli_fbase);
            if (di.dli_sname) { wr("  "); wr(di.dli_sname); }
        }
        wr("\n");
    }
    fsync(gCrashFD);
    signal(sig, SIG_DFL); raise(sig);
}
static void crashException(NSException *e) {
    NSString *s = [NSString stringWithFormat:@"\n=== UNCAUGHT EXCEPTION %@\nreason: %@\nuserInfo: %@\n%@\n", e.name, e.reason, e.userInfo, [e.callStackSymbols componentsJoinedByString:@"\n"]];
    wr(s.UTF8String); fsync(gCrashFD);
}
static void installCrashCapture(NSString *label) {
    NSString *p = LCTVCrashPath();
    gCrashFD = open(p.fileSystemRepresentation, O_WRONLY|O_CREAT|O_TRUNC, 0644);
    NSString *head = [NSString stringWithFormat:@"guest=%@ at %@\n", label, NSDate.date];
    wr(head.UTF8String);
    // file stays tiny on clean runs; header-only means no crash
    NSSetUncaughtExceptionHandler(crashException);
    struct sigaction sa = {0}; sa.sa_sigaction = crashSignal; sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    int sigs[] = {SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGTRAP, SIGFPE}; for (int k = 0; k < 6; k++) sigaction(sigs[k], &sa, NULL);
}

#pragma mark - App group container hook
static IMP gOrigGroupURL;
static NSURL *lc_groupURL(id self, SEL _cmd, NSString *gid) {
    NSURL *u = gOrigGroupURL ? ((NSURL *(*)(id, SEL, NSString *))gOrigGroupURL)(self, _cmd, gid) : nil;
    if (u) return u;
    NSString *d = [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"LCTVGroups"] stringByAppendingPathComponent:gid ?: @"default"];
    [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return [NSURL fileURLWithPath:d isDirectory:YES];
}

#pragma mark - Info.plist override: host bundle instance reports guest's Info.plist
static NSBundle *gHostBundleObj; static NSDictionary *gGuestInfo; static IMP gOrigInfo, gOrigObjForKey;
static NSBundle *lc_mainBundle(id self, SEL _cmd);
static NSDictionary *lc_info(NSBundle *self, SEL _cmd) {
    if (self == gHostBundleObj && gGuestInfo) return gGuestInfo;
    return ((NSDictionary *(*)(id, SEL))gOrigInfo)(self, _cmd); }
static id lc_objForKey(NSBundle *self, SEL _cmd, NSString *k) {
    if (self == gHostBundleObj && gGuestInfo) return gGuestInfo[k];
    return ((id (*)(id, SEL, id))gOrigObjForKey)(self, _cmd, k); }
static void installInfoOverride(NSBundle *host) {
    gHostBundleObj = host;
    gGuestInfo = [NSDictionary dictionaryWithContentsOfFile:[gGuestBundlePath stringByAppendingPathComponent:@"Info.plist"]];
    gOrigInfo = method_setImplementation(class_getInstanceMethod(NSBundle.class, @selector(infoDictionary)), (IMP)lc_info);
    gOrigObjForKey = method_setImplementation(class_getInstanceMethod(NSBundle.class, @selector(objectForInfoDictionaryKey:)), (IMP)lc_objForKey);
}

#pragma mark - Guest preflight
static void logGuestInfo(NSString *bundlePath) {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"Info.plist"]];
    NSMutableArray *notes = [NSMutableArray new];
    NSDictionary *scene = info[@"UIApplicationSceneManifest"];
    if (scene) [notes addObject:[NSString stringWithFormat:@"UIApplicationSceneManifest multi=%@ configs=%@", scene[@"UIApplicationSupportsMultipleScenes"], [scene[@"UISceneConfigurations"] allKeys]]];
    for (NSString *k in @[@"UIRequiredDeviceCapabilities", @"UIBackgroundModes", @"NSExtension", @"UIApplicationExitsOnSuspend", @"MinimumOSVersion", @"UILaunchStoryboardName", @"UIMainStoryboardFile"])
        if (info[k]) [notes addObject:[NSString stringWithFormat:@"%@=%@", k, info[k]]];
    NSString *plugins = [bundlePath stringByAppendingPathComponent:@"PlugIns"];
    NSArray *pl = [NSFileManager.defaultManager contentsOfDirectoryAtPath:plugins error:nil];
    if (pl.count) [notes addObject:[NSString stringWithFormat:@"PlugIns (extensions, not supported): %@", pl]];
    if (scene) [notes addObject:@"NOTE: guest uses scenes (SwiftUI App / scene delegate). Host Info.plist has no scene manifest; UIKit may read the host's."];
    LCTVLog(@"guest info: %@", [notes componentsJoinedByString:@" | "]);
}
/// Pre-dlopen every embedded framework by absolute path (multi-pass for dependency order) so @rpath / @executable_path
/// install-name lookups resolve to already-loaded images even if a load command couldn't be rewritten.
static void preloadFrameworks(NSString *bundlePath) {
    NSString *fw = [bundlePath stringByAppendingPathComponent:@"Frameworks"];
    NSMutableArray *todo = [NSMutableArray new];
    for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:fw error:nil]) {
        NSString *full = [fw stringByAppendingPathComponent:f];
        if ([f.pathExtension isEqual:@"framework"]) {
            NSDictionary *i = [NSDictionary dictionaryWithContentsOfFile:[full stringByAppendingPathComponent:@"Info.plist"]];
            [todo addObject:[full stringByAppendingPathComponent:i[@"CFBundleExecutable"] ?: f.stringByDeletingPathExtension]];
        } else if ([f.pathExtension isEqual:@"dylib"]) [todo addObject:full];
    }
    NSUInteger loaded = 0; NSString *lastErr = nil;
    [todo filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *p, id b) {
        FILE *f = fopen(p.fileSystemRepresentation, "rb"); if (!f) return NO; uint32_t m = 0; fread(&m, 4, 1, f); fclose(f);
        return m == MH_MAGIC_64 || m == FAT_CIGAM || m == FAT_MAGIC; }]];
    for (int pass = 0; pass < 6 && todo.count; pass++) {
        NSMutableArray *left = [NSMutableArray new];
        for (NSString *p in todo) {
            if (dlopen(p.fileSystemRepresentation, RTLD_LAZY|RTLD_GLOBAL)) loaded++;
            else { [left addObject:p]; const char *e = dlerror(); lastErr = e ? @(e) : nil; }
        }
        if (left.count == todo.count) break;
        todo = left;
    }
    gPreloadSummary = [NSString stringWithFormat:@"preload: %lu loaded, %lu failed%@", (unsigned long)loaded, (unsigned long)todo.count, todo.count ? [NSString stringWithFormat:@" %@ (%@)", [todo valueForKey:@"lastPathComponent"], lastErr] : @""];
    LCTVLog(@"preload: %lu frameworks loaded, %lu failed%@", (unsigned long)loaded, (unsigned long)todo.count, todo.count ? [@" last error: " stringByAppendingString:lastErr ?: @"?"] : @"");
}
#import <mach/mach_time.h>
static uint64_t gT0, gTLast; static NSMutableString *gTimings;
static double msSince(uint64_t t) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return (mach_absolute_time() - t) * (double)tb.numer / tb.denom / 1e6; }
static void T(NSString *step) {
    if (!gTimings) gTimings = [NSMutableString new];
    [gTimings appendFormat:@"%@ +%.1fms (t=%.1fms)\n", step, msSince(gTLast), msSince(gT0)];
    gTLast = mach_absolute_time();
}
static void flushTimings(NSString *label) {
    if (!gTimings) return;
    NSString *s = [NSString stringWithFormat:@"%@ boot (%@):\n%@", label, [NSDate date], gTimings];
    [NSUserDefaults.standardUserDefaults setObject:s forKey:@"LCTVLastBootTimings"];
    LCTVLog(@"timings:\n%@", gTimings);
}

static NSString *LCTVForceHostPath(void) {
    return [LCTVCachesDir() stringByAppendingPathComponent:@"lctv_force_host"];
}

static NSBundle *lc_mainBundle(id self, SEL _cmd) {
    static NSBundle *b;
    if (!b) b = [NSBundle bundleWithPath:gGuestBundlePath];
    return b;
}

static int launchGuestAtPath(NSString *fwOrAppPath, NSString *execPath, NSString *label, int argc, char **argv) {
    @try {
        LCTVLog(@"launchGuest begin label=%@ path=%@", label, execPath);
        gGuestBundlePath = fwOrAppPath;
        logGuestInfo(fwOrAppPath);
        installCrashCapture(label);
        Method gm = class_getInstanceMethod(NSFileManager.class, @selector(containerURLForSecurityApplicationGroupIdentifier:));
        if (gm) gOrigGroupURL = method_setImplementation(gm, (IMP)lc_groupURL);
        T(@"pre-dlopen setup");
        NSBundle *hostBundle = NSBundle.mainBundle;
        method_setImplementation(class_getClassMethod(NSBundle.class, @selector(mainBundle)), (IMP)lc_mainBundle);
        installInfoOverride(hostBundle);
        preloadFrameworks(fwOrAppPath);
        T(@"preload frameworks");
        dlerror();
        void *h = dlopen(execPath.UTF8String, RTLD_LAZY|RTLD_GLOBAL|RTLD_FIRST);
        const char *dle = dlerror();
        T(@"dlopen");
        if (!h) LCTVFail([NSString stringWithFormat:@"dlopen failed: %s", dle ? dle : "(null)"]);
        if (!h) return -1;
        const struct mach_header_64 *hdr = NULL;
        // Exact match only (old strstr matched Stremio.app/Frameworks/TVVLCKit...). Normalize /private/var vs /var.
        NSString *(^norm)(NSString *) = ^NSString *(NSString *x) {
            x = x.stringByResolvingSymlinksInPath.stringByStandardizingPath;
            return [x hasPrefix:@"/private/"] ? [x substringFromIndex:8] : x; };
        NSString *want = norm(execPath);
        NSString *suffix = [@"/" stringByAppendingString:[[execPath.stringByDeletingLastPathComponent lastPathComponent] stringByAppendingPathComponent:execPath.lastPathComponent]];
        int fallback = -1;
        for (uint32_t i = 0; i < _dyld_image_count(); i++) {
            const char *iname = _dyld_get_image_name(i);
            if (!iname) continue;
            NSString *in = @(iname);
            if (fallback < 0 && [in hasSuffix:suffix]) fallback = i;
            if ([norm(in) isEqualToString:want] || (i == (uint32_t)_dyld_image_count() - 1 && fallback >= 0 && (i = fallback, 1))) {
                hdr = (const struct mach_header_64 *)_dyld_get_image_header(i); gGuestHdr = (const void *)hdr;
                LCTVLog(@"image[%u]=%s filetype=%u", i, iname, hdr ? hdr->filetype : 0);
                break;
            }
        }
        if (!hdr) { LCTVFail([NSString stringWithFormat:@"guest image not found among loaded images (%@)", want]); return -1; }
        if (hdr->filetype != MH_DYLIB && hdr->filetype != MH_EXECUTE) LCTVLog(@"WARNING image filetype %u", hdr->filetype);
        struct load_command *lc = (void *)(hdr + 1);
        uint64_t entryoff = 0, textFileoff = 0; BOOL hasId = NO;
        for (uint32_t i = 0; i < hdr->ncmds; i++, lc = (void *)lc + lc->cmdsize) {
            if (lc->cmd == LC_MAIN) entryoff = ((struct entry_point_command *)lc)->entryoff;
            if (lc->cmd == LC_ID_DYLIB) hasId = YES;
            if (lc->cmd == LC_SEGMENT_64 && !strcmp(((struct segment_command_64 *)lc)->segname, "__TEXT"))
                textFileoff = ((struct segment_command_64 *)lc)->fileoff;
        }
        LCTVLog(@"LC_MAIN=0x%llx textFileoff=0x%llx LC_ID_DYLIB=%d", entryoff, textFileoff, hasId);
        if (!entryoff) { LCTVFail(@"no LC_MAIN in guest image"); return -1; }
        int (*guestMain)(int, char **, char **) = (void *)((uint8_t *)hdr + (entryoff - textFileoff));
        T(@"resolve main");
        flushTimings(label);
        LCTVQuiet = ![NSUserDefaults.standardUserDefaults boolForKey:@"LCTVVerboseGuest"]; // no host logging while guest runs
        extern char **environ;
        return guestMain(argc, argv, environ);
    } @catch (NSException *ex) {
        LCTVFail([NSString stringWithFormat:@"exception %@: %@", ex.name, ex.reason]);
        return -1;
    }
}

/// Clear any pending guest selection immediately (file + UserDefaults). Call before deciding to launch.
static void clearPending(void) {
    [[NSFileManager defaultManager] removeItemAtPath:LCTVPendingPath() error:nil];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"LCTVSelectedGuest"];
    [NSUserDefaults.standardUserDefaults synchronize];
}

/// Read pending token. Clears the flag as soon as it is read. Only returns a token if it was
/// written very recently (explicit just-selected relaunch). Stale / crash-relaunch → nil (host list).
static NSString *consumePendingIfFresh(void) {
    NSString *path = LCTVPendingPath();
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL forceHost = [fm fileExistsAtPath:LCTVForceHostPath()];
    if (forceHost) {
        LCTVLog(@"boot: lctv_force_host present — skipping guest, going to host list");
        [fm removeItemAtPath:LCTVForceHostPath() error:nil];
        clearPending();
        return nil;
    }

    NSString *raw = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    NSString *fromUD = [NSUserDefaults.standardUserDefaults stringForKey:@"LCTVSelectedGuest"];
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    NSDate *mtime = attrs[NSFileModificationDate];
    NSTimeInterval age = mtime ? -[mtime timeIntervalSinceNow] : 1e9;

    // Parse "token\nunix_ts" or legacy bare token
    NSString *token = nil;
    NSTimeInterval writtenAge = age;
    if (raw.length) {
        NSArray *lines = [[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                          componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
        lines = [lines filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
        if (lines.count >= 1) token = lines[0];
        if (lines.count >= 2) {
            double ts = [lines[1] doubleValue];
            if (ts > 1000000000) writtenAge = [[NSDate date] timeIntervalSince1970] - ts;
        }
    }
    if (!token.length && fromUD.length) {
        token = fromUD;
        // UD-only with no fresh file → treat as stale (crash left UD behind)
        writtenAge = 1e9;
    }

    LCTVLog(@"boot pending token='%@' age=%.1fs fileAge=%.1fs UD='%@' forceHost=%d",
            token ?: @"(nil)", writtenAge, age, fromUD ?: @"(nil)", forceHost);

    // ALWAYS clear before any launch decision — never leave a sticky flag for crash-relaunch
    clearPending();

    if (!token.length) return nil;

    // Only auto-launch if pending was written in the last 90 seconds (user just tapped Launch → OK)
    const NSTimeInterval kMaxFresh = 90.0;
    if (writtenAge > kMaxFresh) {
        LCTVLog(@"boot: stale pending (%.1fs > %.0fs) — host list (crash-relaunch safe)", writtenAge, kMaxFresh);
        return nil;
    }
    LCTVLog(@"boot: fresh pending — will launch %@", token);
    return token;
}

@interface LCTVAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end
@implementation LCTVAppDelegate
- (BOOL)application:(UIApplication *)a didFinishLaunchingWithOptions:(NSDictionary *)o {
    LCTVLog(@"==== host boot pid=%d", getpid());
    NSError *err = nil;
    if (![LCTVHTTPServer.shared start:&err]) LCTVLog(@"HTTP start failed: %@", err);
    clearPending(); // belt-and-suspenders while host UI is up
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:[LCTVHomeController new]];
    // Boot-time certificate check: detect atvloadly cert refresh, reuse key if possible, re-sign stale guests.
    [LCTVCert.shared evaluateAndResignAsync:NO];
    [self.window makeKeyAndVisible];
    NSString *launchErr = [NSUserDefaults.standardUserDefaults stringForKey:@"LCTVLastLaunchError"];
    if (launchErr.length) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"LCTVLastLaunchError"];
        [NSUserDefaults.standardUserDefaults setObject:launchErr forKey:@"LCTVLastLaunchErrorCopy"];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *shortMsg = launchErr.length > 900 ? [[launchErr substringToIndex:900] stringByAppendingString:@"…"] : launchErr; // reason is first
            UIAlertController *al = [UIAlertController alertControllerWithTitle:@"Guest launch failed" message:shortMsg preferredStyle:UIAlertControllerStyleAlert];
            [al addAction:[UIAlertAction actionWithTitle:@"Show details" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                [(UINavigationController *)self.window.rootViewController pushViewController:[LCTVDiagController new] animated:YES]; }]];
            [al addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [self.window.rootViewController presentViewController:al animated:YES completion:nil];
        });
    }
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        gT0 = gTLast = mach_absolute_time();
        NSString *sel = consumePendingIfFresh();
        T(@"pending check");
        if (sel.length) {
            // Flag already cleared inside consumePendingIfFresh
            int r = -1;
            if ([sel hasPrefix:@"builtin:"]) {
                NSString *name = [sel substringFromIndex:8];
                NSString *fw = [NSString stringWithFormat:@"%@/Frameworks/%@.framework", NSBundle.mainBundle.bundlePath, name];
                r = launchGuestAtPath(fw, [fw stringByAppendingPathComponent:name], name, argc, argv);
            } else if ([sel hasPrefix:@"import:"]) {
                NSString *bid = [sel substringFromIndex:7];
                LCTVImportedApp *app = [LCTVAppManager.shared appForBundleIdFast:bid];
                T(@"lookup");
                if (!app) LCTVFail([NSString stringWithFormat:@"imported app not found: %@", bid]);
                else {
                    // Fast path: host already patched+fixed+signed this exact exe (manifest) -> straight to dlopen.
                    if (![LCTVAppManager.shared isPreparedFast:app]) {
                        LCTVLog(@"boot: manifest miss for %@ — preparing (slow, one-time)", bid);
                        NSString *prep = [LCTVAppManager.shared prepareAppForLaunch:app];
                        if (prep) LCTVLog(@"prepare: %@", prep);
                        T(@"prepare (manifest miss)");
                    } else T(@"manifest hit");
                    r = launchGuestAtPath(app.appPath, app.execPath, app.name, argc, argv);
                }
            } else {
                // legacy bare name
                NSString *fw = [NSString stringWithFormat:@"%@/Frameworks/%@.framework", NSBundle.mainBundle.bundlePath, sel];
                r = launchGuestAtPath(fw, [fw stringByAppendingPathComponent:sel], sel, argc, argv);
            }
            if (r != -1) return r;
            flushTimings(@"failed");
            NSMutableString *err = [NSMutableString new];
            [err appendFormat:@"REASON: %@\n", gFailReasons.count ? [gFailReasons componentsJoinedByString:@"\n"] : @"(unknown — see Diagnostics)"];
            if (gPreloadSummary) [err appendFormat:@"%@\n", gPreloadSummary];
            NSArray *lines = [LCTVReadLogTail(6000) componentsSeparatedByString:@"\n"];
            NSArray *tail = [lines subarrayWithRange:NSMakeRange(lines.count > 10 ? lines.count - 10 : 0, MIN(lines.count, 10))];
            [err appendFormat:@"\n— last log lines —\n%@", [tail componentsJoinedByString:@"\n"]];
            [NSUserDefaults.standardUserDefaults setObject:err forKey:@"LCTVLastLaunchError"];
            LCTVLog(@"launch failed; showing host UI");
        }
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(LCTVAppDelegate.class));
    }
}
