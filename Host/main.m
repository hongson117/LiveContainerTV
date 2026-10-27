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

static NSString *gGuestBundlePath;

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
        BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:execPath];
        LCTVLog(@"exe exists=%d  _CodeSignature=%d", exists,
                [[NSFileManager defaultManager] fileExistsAtPath:[fwOrAppPath stringByAppendingPathComponent:@"_CodeSignature"]]);
        if (!exists) { LCTVLog(@"ABORT missing exec"); return -1; }
        struct stat st; if (stat(execPath.UTF8String, &st) == 0) LCTVLog(@"exe size=%lld", (long long)st.st_size);
        dlerror();
        void *h = dlopen(execPath.UTF8String, RTLD_LAZY|RTLD_GLOBAL|RTLD_FIRST);
        const char *dle = dlerror();
        LCTVLog(@"dlopen handle=%p dlerror=%s", h, dle ? dle : "(null)");
        if (!h) return -1;
        const struct mach_header_64 *hdr = NULL;
        NSString *needle = execPath.lastPathComponent;
        for (uint32_t i = 0; i < _dyld_image_count(); i++) {
            const char *iname = _dyld_get_image_name(i);
            if (iname && strstr(iname, needle.UTF8String)) {
                hdr = (const struct mach_header_64 *)_dyld_get_image_header(i);
                LCTVLog(@"image[%u]=%s filetype=%u", i, iname, hdr ? hdr->filetype : 0);
                break;
            }
        }
        if (!hdr) { LCTVLog(@"ABORT no header"); return -1; }
        struct load_command *lc = (void *)(hdr + 1);
        uint64_t entryoff = 0, textFileoff = 0; BOOL hasId = NO;
        for (uint32_t i = 0; i < hdr->ncmds; i++, lc = (void *)lc + lc->cmdsize) {
            if (lc->cmd == LC_MAIN) entryoff = ((struct entry_point_command *)lc)->entryoff;
            if (lc->cmd == LC_ID_DYLIB) hasId = YES;
            if (lc->cmd == LC_SEGMENT_64 && !strcmp(((struct segment_command_64 *)lc)->segname, "__TEXT"))
                textFileoff = ((struct segment_command_64 *)lc)->fileoff;
        }
        LCTVLog(@"LC_MAIN=0x%llx textFileoff=0x%llx LC_ID_DYLIB=%d", entryoff, textFileoff, hasId);
        if (!entryoff) { LCTVLog(@"ABORT no LC_MAIN"); return -1; }
        method_setImplementation(class_getClassMethod(NSBundle.class, @selector(mainBundle)), (IMP)lc_mainBundle);
        int (*guestMain)(int, char **, char **) = (void *)((uint8_t *)hdr + (entryoff - textFileoff));
        LCTVLog(@"jumping to guest main %p", guestMain);
        extern char **environ;
        return guestMain(argc, argv, environ);
    } @catch (NSException *ex) {
        LCTVLog(@"EXCEPTION %@ %@", ex.name, ex.reason);
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

@interface LCTVListController : UITableViewController
@property NSArray *builtinGuests;
@property NSArray<LCTVImportedApp *> *imported;
@property NSString *diagText;
@property NSString *serverURL;
@end

@implementation LCTVListController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"LiveContainerTV";
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"c"];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 80;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Reload" style:UIBarButtonItemStylePlain target:self action:@selector(reload)];
    // Ensure no leftover pending while sitting on host UI
    clearPending();
    [self reload];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reload) name:UIApplicationDidBecomeActiveNotification object:nil];
}
- (void)reload {
    NSMutableArray *g = [NSMutableArray new];
    NSString *dir = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks"];
    for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]) {
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"%@/%@/Info.plist", dir, f]];
        if ([info[@"LCTVGuest"] boolValue]) [g addObject:f.stringByDeletingPathExtension];
    }
    self.builtinGuests = g;
    self.imported = LCTVAppManager.shared.importedApps;
    self.serverURL = LCTVHTTPServer.shared.lanURL;
    self.diagText = LCTVReadLogTail(4000);
    [self.tableView reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return 4; }
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    switch (s) {
        case 0: return @"Import (web upload)";
        case 1: return @"Built-in demo";
        case 2: return @"Imported apps";
        default: return @"Diagnostics";
    }
}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    if (s == 0) return 1;
    if (s == 1) return self.builtinGuests.count ?: 1;
    if (s == 2) return self.imported.count ?: 1;
    return 1;
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"c" forIndexPath:ip];
    c.textLabel.numberOfLines = 0;
    c.textLabel.font = [UIFont monospacedSystemFontOfSize:22 weight:UIFontWeightRegular];
    c.selectionStyle = UITableViewCellSelectionStyleDefault;
    if (ip.section == 0) {
        BOOL cert = LCTVAppManager.shared.hasCertificate;
        c.textLabel.text = [NSString stringWithFormat:
            @"Open on your PC/phone:\n%@\n\nCertificate: %@\n"
            @"Export: plumesign certificate export -u … -p PASS -o cert.p12\n"
            @"1) Upload .p12 (password REQUIRED)\n2) Upload tvOS .ipa\n3) Reload → Launch → reopen",
            self.serverURL ?: @"starting…", cert ? @"loaded" : @"MISSING"];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (ip.section == 1) {
        c.textLabel.text = self.builtinGuests.count ? self.builtinGuests[ip.row] : @"(none)";
        if (!self.builtinGuests.count) c.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (ip.section == 2) {
        if (!self.imported.count) { c.textLabel.text = @"(none — use web upload)"; c.selectionStyle = UITableViewCellSelectionStyleNone; }
        else {
            LCTVImportedApp *a = self.imported[ip.row];
            c.textLabel.text = [NSString stringWithFormat:@"%@\n%@  patched=%@ signed=%@",
                                a.name, a.bundleId, a.patched?@"Y":@"N", a.signedOK?@"Y":@"N"];
        }
    } else {
        c.textLabel.text = self.diagText;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 1 && self.builtinGuests.count) {
        [self scheduleLaunch:[NSString stringWithFormat:@"builtin:%@", self.builtinGuests[ip.row]] title:self.builtinGuests[ip.row]];
    } else if (ip.section == 2 && self.imported.count) {
        LCTVImportedApp *a = self.imported[ip.row];
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:a.name message:a.bundleId preferredStyle:UIAlertControllerStyleAlert];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Launch" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [self scheduleLaunch:[NSString stringWithFormat:@"import:%@", a.bundleId] title:a.name];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Re-sign" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            NSString *e = [LCTVAppManager.shared prepareAppForLaunch:a];
            UIAlertController *r = [UIAlertController alertControllerWithTitle:e?@"Re-sign failed":@"Re-signed" message:e?:@"OK" preferredStyle:UIAlertControllerStyleAlert];
            [r addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:r animated:YES completion:nil];
            [self reload];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            [LCTVAppManager.shared deleteApp:a.bundleId error:nil];
            [self reload];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:sheet animated:YES completion:nil];
    }
}
- (void)scheduleLaunch:(NSString *)token title:(NSString *)title {
    // Do NOT write pending until the user confirms OK — otherwise a crash leaves a sticky GuestDemo flag.
    NSString *msg = [NSString stringWithFormat:
                     @"LiveContainerTV will close. Open it again within 90 seconds to start %@.\n\n"
                     @"From a guest: Menu or “Return to host”. Crash / later relaunch opens the host list.",
                     title];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Launch" message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"OK — close & relaunch" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *payload = [NSString stringWithFormat:@"%@\n%.0f", token, [[NSDate date] timeIntervalSince1970]];
        NSError *err = nil;
        BOOL ok = [payload writeToFile:LCTVPendingPath() atomically:YES encoding:NSUTF8StringEncoding error:&err];
        // Also clear force-host so this intentional launch wins
        [[NSFileManager defaultManager] removeItemAtPath:LCTVForceHostPath() error:nil];
        [NSUserDefaults.standardUserDefaults setObject:token forKey:@"LCTVSelectedGuest"];
        [NSUserDefaults.standardUserDefaults synchronize];
        LCTVLog(@"wrote pending=%@ ok=%d err=%@", payload, ok, err);
        fflush(NULL);
        usleep(200000);
        exit(0);
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
@end

@interface LCTVAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end
@implementation LCTVAppDelegate
- (BOOL)application:(UIApplication *)a didFinishLaunchingWithOptions:(NSDictionary *)o {
    NSError *err = nil;
    if (![LCTVHTTPServer.shared start:&err]) LCTVLog(@"HTTP start failed: %@", err);
    clearPending(); // belt-and-suspenders while host UI is up
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:[LCTVListController new]];
    [self.window makeKeyAndVisible];
    NSString *launchErr = [NSUserDefaults.standardUserDefaults stringForKey:@"LCTVLastLaunchError"];
    if (launchErr.length) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"LCTVLastLaunchError"];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *shortMsg = launchErr.length > 1500 ? [launchErr substringFromIndex:launchErr.length - 1500] : launchErr;
            UIAlertController *al = [UIAlertController alertControllerWithTitle:@"Guest launch failed" message:shortMsg preferredStyle:UIAlertControllerStyleAlert];
            [al addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self.window.rootViewController presentViewController:al animated:YES completion:nil];
        });
    }
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        LCTVLog(@"==== boot pid=%d %@", getpid(), NSBundle.mainBundle.bundleIdentifier);
        NSString *sel = consumePendingIfFresh();
        if (sel.length) {
            // Flag already cleared inside consumePendingIfFresh
            int r = -1;
            if ([sel hasPrefix:@"builtin:"]) {
                NSString *name = [sel substringFromIndex:8];
                NSString *fw = [NSString stringWithFormat:@"%@/Frameworks/%@.framework", NSBundle.mainBundle.bundlePath, name];
                r = launchGuestAtPath(fw, [fw stringByAppendingPathComponent:name], name, argc, argv);
            } else if ([sel hasPrefix:@"import:"]) {
                NSString *bid = [sel substringFromIndex:7];
                LCTVImportedApp *app = nil;
                for (LCTVImportedApp *a in LCTVAppManager.shared.importedApps) if ([a.bundleId isEqual:bid]) { app = a; break; }
                if (!app) LCTVLog(@"ABORT imported app not found %@", bid);
                else {
                    NSString *prep = [LCTVAppManager.shared prepareAppForLaunch:app];
                    if (prep) LCTVLog(@"prepare: %@", prep);
                    r = launchGuestAtPath(app.appPath, app.execPath, app.name, argc, argv);
                }
            } else {
                // legacy bare name
                NSString *fw = [NSString stringWithFormat:@"%@/Frameworks/%@.framework", NSBundle.mainBundle.bundlePath, sel];
                r = launchGuestAtPath(fw, [fw stringByAppendingPathComponent:sel], sel, argc, argv);
            }
            if (r != -1) return r;
            NSString *err = LCTVReadLogTail(8000);
            [NSUserDefaults.standardUserDefaults setObject:err forKey:@"LCTVLastLaunchError"];
            LCTVLog(@"launch failed; showing host UI");
        }
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(LCTVAppDelegate.class));
    }
}
