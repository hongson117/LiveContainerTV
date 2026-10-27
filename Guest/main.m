#import <UIKit/UIKit.h>
@interface GuestDemoDelegate : UIResponder <UIApplicationDelegate> @property UIWindow *window; @end
@implementation GuestDemoDelegate
- (BOOL)application:(UIApplication*)a didFinishLaunchingWithOptions:(NSDictionary*)o {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *vc = [UIViewController new]; vc.view.backgroundColor = UIColor.systemTealColor;
    UILabel *l = [[UILabel alloc] initWithFrame:vc.view.bounds]; l.textAlignment = NSTextAlignmentCenter; l.numberOfLines = 0; l.font = [UIFont boldSystemFontOfSize:60];
    l.text = [NSString stringWithFormat:@"Hello from GuestDemo\nrunning inside LiveContainerTV\nmainBundle: %@", NSBundle.mainBundle.bundleIdentifier];
    [vc.view addSubview:l]; self.window.rootViewController = vc; [self.window makeKeyAndVisible]; return YES; }
@end
int main(int argc, char *argv[]) { @autoreleasepool { return UIApplicationMain(argc, argv, nil, @"GuestDemoDelegate"); } }
