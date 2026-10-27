// LiveContainerTV PoC host: loads a guest tvOS app executable (patched to MH_DYLIB) in-process.
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <objc/runtime.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString *gGuestBundlePath;
static NSMutableString *gDiag;

static NSString *LCTVCachesDir(void) {
    NSString *c = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    [[NSFileManager defaultManager] createDirectoryAtPath:c withIntermediateDirectories:YES attributes:nil error:nil];
    return c;
}
static NSString *LCTVPendingPath(void) { return [LCTVCachesDir() stringByAppendingPathComponent:@"lctv_pending_guest.txt"]; }
static NSString *LCTVLogPath(void) { return [LCTVCachesDir() stringByAppendingPathComponent:@"lctv_diag.log"]; }

static void LCTVLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void LCTVLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *ts = [NSDateFormatter localizedStringFromDate:[NSDate date] dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle];
    NSString *full = [NSString stringWithFormat:@"[%@] %@\n", ts, line];
    NSLog(@"[LCTV] %@", line);
    if (!gDiag) gDiag = [NSMutableString new];
    [gDiag appendString:full];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:LCTVLogPath()];
    if (!h) { [@"" writeToFile:LCTVLogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil]; h = [NSFileHandle fileHandleForWritingAtPath:LCTVLogPath()]; }
    [h seekToEndOfFile]; [h writeData:[full dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile];
}

static NSBundle *lc_mainBundle(id self, SEL _cmd) {
    static NSBundle *b;
    if (!b) b = [NSBundle bundleWithPath:gGuestBundlePath];
    return b;
}

static int launchGuest(NSString *name, int argc, char **argv) {
    @try {
        LCTVLog(@"launchGuest begin name=%@", name);
        NSString *fw = [NSString stringWithFormat:@"%@/Frameworks/%@.framework", NSBundle.mainBundle.bundlePath, name];
        NSString *exe = [fw stringByAppendingPathComponent:name];
        gGuestBundlePath = fw;
        BOOL fwExists = [[NSFileManager defaultManager] fileExistsAtPath:fw];
        BOOL exeExists = [[NSFileManager defaultManager] fileExistsAtPath:exe];
        LCTVLog(@"framework path=%@ exists=%d", fw, fwExists);
        LCTVLog(@"exe path=%@ exists=%d", exe, exeExists);
        NSString *sig = [fw stringByAppendingPathComponent:@"_CodeSignature"];
        LCTVLog(@"_CodeSignature exists=%d", [[NSFileManager defaultManager] fileExistsAtPath:sig]);
        struct stat st; if (exeExists && stat(exe.UTF8String, &st) == 0) LCTVLog(@"exe size=%lld mode=%o", (long long)st.st_size, st.st_mode);

        if (!exeExists) { LCTVLog(@"ABORT: guest executable missing"); return -1; }

        dlerror(); // clear
        void *h = dlopen(exe.UTF8String, RTLD_LAZY|RTLD_GLOBAL|RTLD_FIRST);
        const char *dle = dlerror();
        LCTVLog(@"dlopen handle=%p dlerror=%s", h, dle ? dle : "(null)");
        if (!h) return -1;

        const struct mach_header_64 *hdr = NULL;
        NSString *needle = [NSString stringWithFormat:@"/%@.framework/%@", name, name];
        for (uint32_t i = 0; i < _dyld_image_count(); i++) {
            const char *iname = _dyld_get_image_name(i);
            if (iname && (strstr(iname, needle.UTF8String) || !strcmp(iname, exe.UTF8String))) {
                hdr = (const struct mach_header_64 *)_dyld_get_image_header(i);
                LCTVLog(@"found image[%u]=%s filetype=%u", i, iname, hdr ? hdr->filetype : 0);
                break;
            }
        }
        if (!hdr) { LCTVLog(@"ABORT: mach header not found after dlopen"); return -1; }

        struct load_command *lc = (void *)(hdr + 1);
        uint64_t entryoff = 0, textFileoff = 0;
        BOOL hasIdDylib = NO;
        for (uint32_t i = 0; i < hdr->ncmds; i++, lc = (void *)lc + lc->cmdsize) {
            if (lc->cmd == LC_MAIN) entryoff = ((struct entry_point_command *)lc)->entryoff;
            if (lc->cmd == LC_ID_DYLIB) hasIdDylib = YES;
            if (lc->cmd == LC_SEGMENT_64 && !strcmp(((struct segment_command_64 *)lc)->segname, "__TEXT"))
                textFileoff = ((struct segment_command_64 *)lc)->fileoff;
        }
        LCTVLog(@"LC_MAIN entryoff=0x%llx __TEXT.fileoff=0x%llx LC_ID_DYLIB=%d", entryoff, textFileoff, hasIdDylib);
        if (!entryoff) { LCTVLog(@"ABORT: no LC_MAIN"); return -1; }

        // Swizzle mainBundle so guest UIKit reads guest Info.plist
        Method m = class_getClassMethod(NSBundle.class, @selector(mainBundle));
        method_setImplementation(m, (IMP)lc_mainBundle);
        LCTVLog(@"NSBundle.mainBundle swizzled -> %@", gGuestBundlePath);

        int (*guestMain)(int, char **, char **) = (void *)((uint8_t *)hdr + (entryoff - textFileoff));
        LCTVLog(@"jumping to guest main %p", guestMain);
        extern char **environ;
        return guestMain(argc, argv, environ);
    } @catch (NSException *ex) {
        LCTVLog(@"EXCEPTION %@ : %@", ex.name, ex.reason);
        return -1;
    }
}

@interface LCTVListController : UITableViewController
@property NSArray<NSString *> *guests;
@property NSString *diagText;
@end
@implementation LCTVListController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"LiveContainerTV";
    NSMutableArray *g = [NSMutableArray new];
    NSString *dir = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks"];
    for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]) {
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"%@/%@/Info.plist", dir, f]];
        if ([info[@"LCTVGuest"] boolValue]) [g addObject:f.stringByDeletingPathExtension];
    }
    self.guests = g;
    NSString *log = [NSString stringWithContentsOfFile:LCTVLogPath() encoding:NSUTF8StringEncoding error:nil] ?: @"(no diag yet)";
    // keep last ~4KB
    if (log.length > 4000) log = [log substringFromIndex:log.length - 4000];
    self.diagText = log;
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"c"];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 80;
    UIBarButtonItem *clear = [[UIBarButtonItem alloc] initWithTitle:@"Clear log" style:UIBarButtonItemStylePlain target:self action:@selector(clearLog)];
    self.navigationItem.rightBarButtonItem = clear;
}
- (void)clearLog { [@"" writeToFile:LCTVLogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil]; self.diagText = @"(cleared)"; [self.tableView reloadData]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return 2; }
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    return s == 0 ? @"Guest apps" : @"Diagnostics (Caches/lctv_diag.log)";
}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    if (s == 0) return self.guests.count ?: 1;
    return 1;
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"c" forIndexPath:ip];
    c.textLabel.numberOfLines = 0;
    c.textLabel.font = [UIFont monospacedSystemFontOfSize:22 weight:UIFontWeightRegular];
    if (ip.section == 0) {
        c.textLabel.text = self.guests.count ? self.guests[ip.row] : @"(no guest apps bundled)";
        c.selectionStyle = self.guests.count ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    } else {
        c.textLabel.text = self.diagText;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    if (ip.section != 0 || !self.guests.count) return;
    NSString *name = self.guests[ip.row];
    // Persist pending guest to Caches file (NSUserDefaults + exit(0) was dropping the write on tvOS).
    NSError *err = nil;
    BOOL ok = [name writeToFile:LCTVPendingPath() atomically:YES encoding:NSUTF8StringEncoding error:&err];
    LCTVLog(@"wrote pending guest=%@ path=%@ ok=%d err=%@", name, LCTVPendingPath(), ok, err);
    // Also mirror to UserDefaults as backup
    [NSUserDefaults.standardUserDefaults setObject:name forKey:@"LCTVSelectedGuest"];
    [NSUserDefaults.standardUserDefaults synchronize];
    NSString *msg = [NSString stringWithFormat:@"Live Container will close. Open it again to start Demo Guest (%@).\n\npending file ok=%d\n%@", name, ok, LCTVPendingPath()];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Launch" message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        // Give the FS a moment to flush before exit.
        fflush(NULL);
        usleep(200000);
        exit(0);
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
@end

@interface LCTVAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@property NSString *launchError;
@end
@implementation LCTVAppDelegate
- (BOOL)application:(UIApplication *)a didFinishLaunchingWithOptions:(NSDictionary *)o {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    LCTVListController *list = [LCTVListController new];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:list];
    [self.window makeKeyAndVisible];
    NSString *err = self.launchError ?: [NSUserDefaults.standardUserDefaults stringForKey:@"LCTVLastLaunchError"];
    if (err.length) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"LCTVLastLaunchError"];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *shortMsg = err.length > 1500 ? [[err substringFromIndex:MAX(0,(int)err.length-1500)] stringByAppendingString:@"\n…"] : err;
            UIAlertController *al = [UIAlertController alertControllerWithTitle:@"Guest launch failed" message:shortMsg preferredStyle:UIAlertControllerStyleAlert];
            [al addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self.window.rootViewController presentViewController:al animated:YES completion:nil];
        });
    }
    return YES;
}
@end

static NSString *readPendingGuest(void) {
    NSString *fromFile = [[NSString stringWithContentsOfFile:LCTVPendingPath() encoding:NSUTF8StringEncoding error:nil]
                          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *fromUD = [NSUserDefaults.standardUserDefaults stringForKey:@"LCTVSelectedGuest"];
    LCTVLog(@"boot: pending file='%@' exists=%d  UserDefaults='%@'",
            fromFile ?: @"(nil)",
            [[NSFileManager defaultManager] fileExistsAtPath:LCTVPendingPath()],
            fromUD ?: @"(nil)");
    if (fromFile.length) return fromFile;
    return fromUD;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        LCTVLog(@"==== boot pid=%d bundle=%@", getpid(), NSBundle.mainBundle.bundleIdentifier);
        NSString *sel = readPendingGuest();
        if (sel.length) {
            // Clear BOTH stores before attempting launch so a crash won't loop forever.
            [[NSFileManager defaultManager] removeItemAtPath:LCTVPendingPath() error:nil];
            [NSUserDefaults.standardUserDefaults removeObjectForKey:@"LCTVSelectedGuest"];
            [NSUserDefaults.standardUserDefaults synchronize];
            LCTVLog(@"cleared pending; attempting launch of %@", sel);
            int r = launchGuest(sel, argc, argv);
            if (r != -1) return r;
            // Fall through to host UI with error surfaced.
            LCTVLog(@"launchGuest returned -1; showing host UI with diagnostics");
            // Stash error into a static that AppDelegate can pick up via UserDefaults-less path:
            // We re-enter UIApplicationMain; pass error via the log file + a marker file.
            NSString *err = gDiag ?: @"launch failed (see diag log)";
            [err writeToFile:[LCTVCachesDir() stringByAppendingPathComponent:@"lctv_last_error.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            // Custom UIApplicationMain then show alert from last error.
            // Use a tiny delay-free approach: set a global that AppDelegate reads.
            extern int UIApplicationMain(int, char *[], NSString *, NSString *);
            // Patch: create delegate class instance isn't available yet; store in UD for this process only.
            [NSUserDefaults.standardUserDefaults setObject:err forKey:@"LCTVLastLaunchError"];
            int code = UIApplicationMain(argc, argv, nil, NSStringFromClass(LCTVAppDelegate.class));
            return code;
        }
        LCTVLog(@"no pending guest; showing host list");
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(LCTVAppDelegate.class));
    }
}

// Make AppDelegate pick up process-local launch error
