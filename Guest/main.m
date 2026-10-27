#import <UIKit/UIKit.h>

static NSString *LCTVCaches(void) {
    return NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
}

@interface GuestDemoVC : UIViewController
@end
@implementation GuestDemoVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemTealColor;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.textAlignment = NSTextAlignmentCenter;
    l.numberOfLines = 0;
    l.font = [UIFont boldSystemFontOfSize:48];
    l.textColor = UIColor.whiteColor;
    l.text = [NSString stringWithFormat:
              @"Hello from GuestDemo\nrunning inside LiveContainerTV\nmainBundle: %@\n\n"
              @"Press Menu or the button below to return to the host list.",
              NSBundle.mainBundle.bundleIdentifier];
    [self.view addSubview:l];

    UIButton *back = [UIButton buttonWithType:UIButtonTypeSystem];
    back.translatesAutoresizingMaskIntoConstraints = NO;
    [back setTitle:@"Return to LiveContainerTV host" forState:UIControlStateNormal];
    back.titleLabel.font = [UIFont boldSystemFontOfSize:32];
    [back addTarget:self action:@selector(returnToHost) forControlEvents:UIControlEventPrimaryActionTriggered];
    [self.view addSubview:back];

    [NSLayoutConstraint activateConstraints:@[
        [l.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:40],
        [l.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-40],
        [l.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-60],
        [back.topAnchor constraintEqualToAnchor:l.bottomAnchor constant:40],
        [back.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    ]];
}
- (void)returnToHost {
    NSString *caches = LCTVCaches();
    [[NSFileManager defaultManager] removeItemAtPath:[caches stringByAppendingPathComponent:@"lctv_pending_guest.txt"] error:nil];
    // Marker so next cold start never auto-launches a guest
    [@"1" writeToFile:[caches stringByAppendingPathComponent:@"lctv_force_host"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"LCTVSelectedGuest"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    fflush(NULL);
    usleep(100000);
    exit(0);
}
- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *p in presses) {
        if (p.type == UIPressTypeMenu) { [self returnToHost]; return; }
    }
    [super pressesBegan:presses withEvent:event];
}
@end

@interface GuestDemoDelegate : UIResponder <UIApplicationDelegate>
@property UIWindow *window;
@end
@implementation GuestDemoDelegate
- (BOOL)application:(UIApplication *)a didFinishLaunchingWithOptions:(NSDictionary *)o {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [GuestDemoVC new];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, @"GuestDemoDelegate");
    }
}
