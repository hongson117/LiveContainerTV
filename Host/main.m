// LiveContainerTV PoC host: loads a guest tvOS app executable (patched to MH_DYLIB) in-process.
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <objc/runtime.h>

static NSString *gGuestBundlePath;
static NSBundle *lc_mainBundle(id self, SEL _cmd) { static NSBundle *b; if(!b) b=[NSBundle bundleWithPath:gGuestBundlePath]; return b; }

static int launchGuest(NSString *name, int argc, char **argv) {
    NSString *fw = [NSString stringWithFormat:@"%@/Frameworks/%@.framework", NSBundle.mainBundle.bundlePath, name];
    NSString *exe = [fw stringByAppendingPathComponent:name];
    gGuestBundlePath = fw;
    void *h = dlopen(exe.UTF8String, RTLD_LAZY|RTLD_GLOBAL|RTLD_FIRST);
    if (!h) { NSLog(@"[LCTV] dlopen failed: %s", dlerror()); return -1; }
    const struct mach_header_64 *hdr = NULL;
    for (uint32_t i = 0; i < _dyld_image_count(); i++)
        if (!strcmp(_dyld_get_image_name(i), exe.UTF8String) || strstr(_dyld_get_image_name(i), [NSString stringWithFormat:@"/%@.framework/%@", name, name].UTF8String)) { hdr = (void*)_dyld_get_image_header(i); break; }
    if (!hdr) { NSLog(@"[LCTV] header not found"); return -1; }
    struct load_command *lc = (void*)(hdr + 1); uint64_t entryoff = 0, textvm = 0;
    for (uint32_t i = 0; i < hdr->ncmds; i++, lc = (void*)lc + lc->cmdsize) {
        if (lc->cmd == LC_MAIN) entryoff = ((struct entry_point_command*)lc)->entryoff;
        if (lc->cmd == LC_SEGMENT_64 && !strcmp(((struct segment_command_64*)lc)->segname, "__TEXT")) textvm = ((struct segment_command_64*)lc)->fileoff;
    }
    if (!entryoff) { NSLog(@"[LCTV] no LC_MAIN"); return -1; }
    // Make [NSBundle mainBundle] return the guest bundle so its Info.plist/resources are used.
    method_setImplementation(class_getClassMethod(NSBundle.class, @selector(mainBundle)), (IMP)lc_mainBundle);
    int (*guestMain)(int, char**, char**) = (void*)((uint8_t*)hdr + entryoff - textvm);
    NSLog(@"[LCTV] jumping to %@ main %p", name, guestMain);
    extern char **environ;
    return guestMain(argc, argv, environ);
}

@interface LCTVListController : UITableViewController @property NSArray<NSString*> *guests; @end
@implementation LCTVListController
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"LiveContainerTV";
    NSMutableArray *g = [NSMutableArray new];
    NSString *dir = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks"];
    for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]) {
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"%@/%@/Info.plist", dir, f]];
        if ([info[@"LCTVGuest"] boolValue]) [g addObject:f.stringByDeletingPathExtension];
    }
    self.guests = g; [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"c"]; }
- (NSInteger)tableView:(UITableView*)t numberOfRowsInSection:(NSInteger)s { return self.guests.count ?: 1; }
- (UITableViewCell*)tableView:(UITableView*)t cellForRowAtIndexPath:(NSIndexPath*)ip { UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"c" forIndexPath:ip];
    c.textLabel.text = self.guests.count ? self.guests[ip.row] : @"(no guest apps bundled)"; return c; }
- (void)tableView:(UITableView*)t didSelectRowAtIndexPath:(NSIndexPath*)ip { if (!self.guests.count) return;
    [NSUserDefaults.standardUserDefaults setObject:self.guests[ip.row] forKey:@"LCTVSelectedGuest"]; [NSUserDefaults.standardUserDefaults synchronize];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Launch" message:[NSString stringWithFormat:@"LiveContainerTV will close. Open it again to start %@.", self.guests[ip.row]] preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(id x){ exit(0); }]];
    [self presentViewController:a animated:YES completion:nil]; }
@end

@interface LCTVAppDelegate : UIResponder <UIApplicationDelegate> @property UIWindow *window; @end
@implementation LCTVAppDelegate
- (BOOL)application:(UIApplication*)a didFinishLaunchingWithOptions:(NSDictionary*)o {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:[LCTVListController new]];
    [self.window makeKeyAndVisible]; return YES; }
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSString *sel = [NSUserDefaults.standardUserDefaults stringForKey:@"LCTVSelectedGuest"];
        if (sel) { [NSUserDefaults.standardUserDefaults removeObjectForKey:@"LCTVSelectedGuest"]; [NSUserDefaults.standardUserDefaults synchronize];
            int r = launchGuest(sel, argc, argv); if (r != -1) return r; }
        return UIApplicationMain(argc, argv, nil, @"LCTVAppDelegate");
    }
}
