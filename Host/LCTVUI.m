#import "LCTVUI.h"
#import "LCTVCommon.h"
#import "LCTVAppManager.h"
#import "LCTVHTTPServer.h"
#import "LCTVCert.h"

static NSString *forceHostPath(void) { return [LCTVCachesDir() stringByAppendingPathComponent:@"lctv_force_host"]; }
static UIColor *rgb(int r, int g, int b) { return [UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:1]; }

#pragma mark - Tile model

@interface LCTVTile : NSObject
@property NSString *token, *title, *subtitle;
@property UIImage *icon;
@property LCTVImportedApp *app; // nil for built-in
@property BOOL dim;
@end
@implementation LCTVTile @end

#pragma mark - Cell

@interface LCTVTileCell : UICollectionViewCell
@property UIImageView *img; @property UILabel *title, *badge;
@end
@implementation LCTVTileCell
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        _img = [UIImageView new];
        _img.adjustsImageWhenAncestorFocused = YES;   // tvOS parallax lift + shine
        _img.contentMode = UIViewContentModeScaleAspectFill;
        _img.translatesAutoresizingMaskIntoConstraints = NO;
        _title = [UILabel new];
        _title.font = [UIFont systemFontOfSize:28 weight:UIFontWeightSemibold];
        _title.textColor = UIColor.whiteColor; _title.textAlignment = NSTextAlignmentCenter;
        _title.translatesAutoresizingMaskIntoConstraints = NO;
        _badge = [UILabel new];
        _badge.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
        _badge.textColor = UIColor.blackColor; _badge.textAlignment = NSTextAlignmentCenter;
        _badge.layer.cornerRadius = 12; _badge.layer.masksToBounds = YES;
        _badge.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_img]; [self.contentView addSubview:_title]; [_img.overlayContentView addSubview:_badge];
        [NSLayoutConstraint activateConstraints:@[
            [_img.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [_img.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [_img.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [_img.heightAnchor constraintEqualToAnchor:_img.widthAnchor multiplier:0.6],
            [_title.topAnchor constraintEqualToAnchor:_img.bottomAnchor constant:24],
            [_title.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [_title.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [_badge.topAnchor constraintEqualToAnchor:_img.overlayContentView.topAnchor constant:12],
            [_badge.trailingAnchor constraintEqualToAnchor:_img.overlayContentView.trailingAnchor constant:-12],
            [_badge.heightAnchor constraintEqualToConstant:34],
        ]];
    }
    return self;
}
- (void)didUpdateFocusInContext:(UIFocusUpdateContext *)c withAnimationCoordinator:(UIFocusAnimationCoordinator *)co {
    [co addCoordinatedAnimations:^{
        self.title.transform = self.isFocused ? CGAffineTransformMakeTranslation(0, 22) : CGAffineTransformIdentity;
        self.title.textColor = self.isFocused ? rgb(253, 224, 71) : UIColor.whiteColor;
    } completion:nil];
}
@end

#pragma mark - Chip

static UILabel *makeChip(void) {
    UILabel *l = [UILabel new];
    l.font = [UIFont systemFontOfSize:24 weight:UIFontWeightSemibold];
    l.textColor = UIColor.whiteColor;
    l.layer.cornerRadius = 22; l.layer.masksToBounds = YES;
    l.textAlignment = NSTextAlignmentCenter;
    [l.heightAnchor constraintEqualToConstant:44].active = YES;
    return l;
}
static void setChip(UILabel *l, NSString *text, UIColor *bg) {
    l.text = [NSString stringWithFormat:@"   %@   ", text]; l.backgroundColor = bg; l.hidden = text.length == 0;
}

#pragma mark - Diagnostics

@interface LCTVDiagController : UIViewController
@property UITextView *tv;
@end
@implementation LCTVDiagController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Diagnostics";
    self.view.backgroundColor = rgb(10, 14, 32);
    _tv = [UITextView new];
    _tv.font = [UIFont monospacedSystemFontOfSize:22 weight:UIFontWeightRegular];
    _tv.textColor = rgb(203, 213, 225); _tv.backgroundColor = rgb(17, 24, 39);
    _tv.selectable = YES; _tv.scrollEnabled = YES; _tv.userInteractionEnabled = YES;
    _tv.panGestureRecognizer.allowedTouchTypes = @[@(UITouchTypeIndirect)];
    _tv.layer.cornerRadius = 16;
    _tv.translatesAutoresizingMaskIntoConstraints = NO;
    UIStackView *btns = [UIStackView new]; btns.spacing = 30; btns.translatesAutoresizingMaskIntoConstraints = NO;
    NSArray *defs = @[@[@"Refresh", @"reload"], @[@"Re-sign all apps", @"resignAll"], @[@"Clear log", @"clearLog"]];
    for (NSArray *d in defs) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:d[0] forState:UIControlStateNormal];
        [b addTarget:self action:NSSelectorFromString(d[1]) forControlEvents:UIControlEventPrimaryActionTriggered];
        [btns addArrangedSubview:b];
    }
    [self.view addSubview:btns]; [self.view addSubview:_tv];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [btns.topAnchor constraintEqualToAnchor:g.topAnchor constant:10],
        [btns.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [_tv.topAnchor constraintEqualToAnchor:btns.bottomAnchor constant:30],
        [_tv.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [_tv.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [_tv.bottomAnchor constraintEqualToAnchor:g.bottomAnchor],
    ]];
    [self reload];
}
- (void)reload {
    LCTVCert *c = LCTVCert.shared;
    NSString *head = [NSString stringWithFormat:@"Web: %@\n%@\nHost cert SHA1: %@\np12 cert SHA1:  %@\nTeam: %@\nData dir: %@ (%@)\n\n",
                      LCTVHTTPServer.shared.lanURL ?: @"?", c.summary, c.hostFingerprint ?: @"(no embedded.mobileprovision)",
                      c.p12Fingerprint ?: @"-", c.teamName ?: @"-", LCTVDataDir(), LCTVDataDirKind];
    head = [head stringByAppendingFormat:@"Last guest boot timings:\n%@\n\n", [NSUserDefaults.standardUserDefaults stringForKey:@"LCTVLastBootTimings"] ?: @"(none yet)"];
    _tv.text = [head stringByAppendingString:LCTVReadLogTail(20000)];
    [_tv scrollRangeToVisible:NSMakeRange(_tv.text.length, 0)];
}
- (void)resignAll { [LCTVCert.shared evaluateAndResignAsync:YES]; [self reload]; }
- (void)clearLog { [@"" writeToFile:LCTVLogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil]; [self reload]; }
@end

#pragma mark - Home

@interface LCTVHomeController () <UICollectionViewDataSource, UICollectionViewDelegate>
@property UICollectionView *cv;
@property NSArray<LCTVTile *> *tiles;
@property UILabel *certChip, *urlChip, *busyChip, *banner, *empty;
@end

@implementation LCTVHomeController

- (void)viewDidLoad {
    [super viewDidLoad];
    CAGradientLayer *bg = [CAGradientLayer layer];
    bg.colors = @[(id)rgb(15, 14, 52).CGColor, (id)rgb(7, 30, 70).CGColor];
    bg.startPoint = CGPointMake(0, 0); bg.endPoint = CGPointMake(1, 1);
    bg.frame = UIScreen.mainScreen.bounds;
    [self.view.layer insertSublayer:bg atIndex:0];

    // Header: logo + wordmark
    NSString *logoPath = [NSBundle.mainBundle pathForResource:@"lctv_logo" ofType:@"png"];
    UIImageView *logo = [[UIImageView alloc] initWithImage:[UIImage imageWithContentsOfFile:logoPath]];
    logo.contentMode = UIViewContentModeScaleAspectFit;
    [logo.widthAnchor constraintEqualToConstant:110].active = YES; [logo.heightAnchor constraintEqualToConstant:110].active = YES;
    UILabel *word = [UILabel new];
    NSMutableAttributedString *w = [[NSMutableAttributedString alloc] initWithString:@"LiveContainer"
        attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:58 weight:UIFontWeightHeavy], NSForegroundColorAttributeName: UIColor.whiteColor}];
    [w appendAttributedString:[[NSAttributedString alloc] initWithString:@" TV"
        attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:58 weight:UIFontWeightHeavy], NSForegroundColorAttributeName: rgb(245, 158, 11)}]];
    word.attributedText = w;
    UIStackView *brand = [[UIStackView alloc] initWithArrangedSubviews:@[logo, word]];
    brand.spacing = 24; brand.alignment = UIStackViewAlignmentCenter;

    _certChip = makeChip(); _urlChip = makeChip(); _busyChip = makeChip();
    UIStackView *chips = [[UIStackView alloc] initWithArrangedSubviews:@[_certChip, _urlChip, _busyChip]];
    chips.spacing = 16; chips.alignment = UIStackViewAlignmentCenter;

    UIButton *diag = [UIButton buttonWithType:UIButtonTypeSystem];
    [diag setTitle:@"Diagnostics" forState:UIControlStateNormal];
    [diag addTarget:self action:@selector(openDiag) forControlEvents:UIControlEventPrimaryActionTriggered];
    UIButton *refresh = [UIButton buttonWithType:UIButtonTypeSystem];
    [refresh setTitle:@"Refresh" forState:UIControlStateNormal];
    [refresh addTarget:self action:@selector(refreshTapped) forControlEvents:UIControlEventPrimaryActionTriggered];
    UIStackView *btns = [[UIStackView alloc] initWithArrangedSubviews:@[refresh, diag]];
    btns.spacing = 24;

    UIStackView *right = [[UIStackView alloc] initWithArrangedSubviews:@[chips, btns]];
    right.axis = UILayoutConstraintAxisVertical; right.alignment = UIStackViewAlignmentTrailing; right.spacing = 18;
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[brand, [UIView new], right]];
    header.alignment = UIStackViewAlignmentCenter;
    header.translatesAutoresizingMaskIntoConstraints = NO;

    _banner = [UILabel new];
    _banner.numberOfLines = 0; _banner.textAlignment = NSTextAlignmentCenter;
    _banner.font = [UIFont systemFontOfSize:30 weight:UIFontWeightBold];
    _banner.textColor = UIColor.whiteColor; _banner.layer.cornerRadius = 18; _banner.layer.masksToBounds = YES;
    _banner.translatesAutoresizingMaskIntoConstraints = NO;

    UICollectionViewFlowLayout *fl = [UICollectionViewFlowLayout new];
    fl.itemSize = CGSizeMake(380, 380 * 0.6 + 80);
    fl.minimumInteritemSpacing = 48; fl.minimumLineSpacing = 90;
    fl.sectionInset = UIEdgeInsetsMake(40, 0, 60, 0);
    _cv = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:fl];
    _cv.backgroundColor = UIColor.clearColor; _cv.clipsToBounds = NO;
    _cv.dataSource = self; _cv.delegate = self;
    _cv.remembersLastFocusedIndexPath = YES;
    [_cv registerClass:LCTVTileCell.class forCellWithReuseIdentifier:@"t"];
    _cv.translatesAutoresizingMaskIntoConstraints = NO;

    _empty = [UILabel new];
    _empty.numberOfLines = 0; _empty.textAlignment = NSTextAlignmentCenter;
    _empty.font = [UIFont systemFontOfSize:30]; _empty.textColor = rgb(148, 163, 184);
    _empty.translatesAutoresizingMaskIntoConstraints = NO;

    for (UIView *v in @[header, _banner, _cv, _empty]) [self.view addSubview:v];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:g.topAnchor],
        [header.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [_banner.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:24],
        [_banner.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [_banner.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [_cv.topAnchor constraintEqualToAnchor:_banner.bottomAnchor constant:10],
        [_cv.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [_cv.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [_cv.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_empty.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-40],
        [_empty.centerXAnchor constraintEqualToAnchor:g.centerXAnchor],
    ]];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload) name:LCTVStateChangedNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload) name:UIApplicationDidBecomeActiveNotification object:nil];
    [self reload];
}

- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments { return @[_cv]; }

- (void)refreshTapped { [LCTVCert.shared evaluateAndResignAsync:NO]; [self reload]; }
- (void)openDiag { [self.navigationController pushViewController:[LCTVDiagController new] animated:YES]; }

- (void)reload {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self reload]; }); return; }
    NSMutableArray *t = [NSMutableArray new];
    LCTVAppManager *m = LCTVAppManager.shared;
    for (LCTVImportedApp *a in m.importedApps) {
        LCTVTile *x = [LCTVTile new];
        x.app = a; x.token = [@"import:" stringByAppendingString:a.bundleId]; x.title = a.shortName;
        x.icon = [m iconForApp:a];
        if (a.purged) { x.subtitle = @"Re-import"; x.dim = YES; }
        else if (!a.signedOK) x.subtitle = @"Not signed";
        else if (LCTVCert.shared.p12Fingerprint && a.signedFingerprint && ![a.signedFingerprint isEqual:LCTVCert.shared.p12Fingerprint]) x.subtitle = @"Re-sign";
        [t addObject:x];
    }
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"LCTVScreenshotDemo"]) { // CI screenshot only
        for (NSArray *d in @[@[@"OrivioTV", @""], @[@"Infuse", @""], @[@"Kodi", @"Re-sign"], @[@"Old App", @"Re-import"]]) {
            LCTVTile *x = [LCTVTile new]; x.title = d[0]; x.subtitle = d[1]; x.token = @"demo";
            x.icon = [LCTVAppManager letterTileFor:d[0] size:CGSizeMake(400, 240)];
            x.dim = [d[1] isEqual:@"Re-import"];
            [t insertObject:x atIndex:0];
        }
    }
    self.tiles = t;
    [_cv reloadData];

    LCTVCert *c = LCTVCert.shared;
    NSString *url = LCTVHTTPServer.shared.lanURL ?: @"starting…";
    UIColor *green = rgb(22, 163, 74), *amber = rgb(217, 119, 6), *red = rgb(220, 38, 38);
    UIColor *cc = c.state == LCTVCertStateOK || c.state == LCTVCertStateUnknownHost ? (c.daysLeft >= 0 && c.daysLeft < 2 ? amber : green) : red;
    setChip(_certChip, c.summary, cc);
    setChip(_urlChip, url, rgb(51, 65, 85));
    setChip(_busyChip, c.busy ? (c.busyText.length ? c.busyText : @"Checking…") : @"", rgb(79, 70, 229));
    NSString *bannerText = nil;
    if (c.state == LCTVCertStateChanged) bannerText = [NSString stringWithFormat:@"Certificate changed — upload new p12 at %@\nAll apps will be re-signed automatically.", url];
    else if (c.state == LCTVCertStateNoP12) bannerText = [NSString stringWithFormat:@"Upload your .p12 certificate at %@ to sign apps.", url];
    else if (c.state == LCTVCertStateBadP12) bannerText = [NSString stringWithFormat:@"Stored .p12 can't be opened (wrong password?). Re-upload at %@", url];
    _banner.text = bannerText ? [NSString stringWithFormat:@"\n%@\n", bannerText] : nil;
    _banner.backgroundColor = c.state == LCTVCertStateNoP12 ? amber : red;
    _banner.hidden = bannerText == nil;
    _empty.text = [NSString stringWithFormat:@"Add apps: open %@ on your computer or phone and upload a tvOS .ipa", url];
}

- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s { return self.tiles.count; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)ip {
    LCTVTileCell *c = [cv dequeueReusableCellWithReuseIdentifier:@"t" forIndexPath:ip];
    LCTVTile *t = self.tiles[ip.item];
    c.img.image = t.icon; c.img.alpha = t.dim ? 0.45 : 1;
    c.title.text = t.title;
    c.badge.text = t.subtitle.length ? [NSString stringWithFormat:@"  %@  ", t.subtitle] : nil;
    c.badge.hidden = !t.subtitle.length;
    c.badge.backgroundColor = [t.subtitle isEqual:@"Demo"] ? rgb(148, 163, 184) : rgb(251, 191, 36);
    return c;
}

- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)ip {
    LCTVTile *t = self.tiles[ip.item];
    if (t.app.purged) { [self showActionsFor:t]; return; }
    [self showActionsFor:t];
}

- (UIContextMenuConfiguration *)collectionView:(UICollectionView *)cv contextMenuConfigurationForItemsAtIndexPaths:(NSArray<NSIndexPath *> *)ips point:(CGPoint)p API_AVAILABLE(tvos(17.0)) {
    if (ips.count != 1) return nil;
    LCTVTile *t = self.tiles[ips.firstObject.item];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *s) {
        NSMutableArray *items = [NSMutableArray new];
        if (!t.app.purged) [items addObject:[UIAction actionWithTitle:@"Launch" image:[UIImage systemImageNamed:@"play.fill"] identifier:nil handler:^(UIAction *a) { [self launch:t]; }]];
        if (t.app && !t.app.purged) [items addObject:[UIAction actionWithTitle:@"Re-sign" image:[UIImage systemImageNamed:@"signature"] identifier:nil handler:^(UIAction *a) { [self resign:t]; }]];
        [items addObject:[UIAction actionWithTitle:@"Info" image:[UIImage systemImageNamed:@"info.circle"] identifier:nil handler:^(UIAction *a) { [self info:t]; }]];
        if (t.app) {
            UIAction *d = [UIAction actionWithTitle:@"Delete" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *a) { [self confirmDelete:t]; }];
            d.attributes = UIMenuElementAttributesDestructive; [items addObject:d];
        }
        return [UIMenu menuWithTitle:t.title children:items];
    }];
}

- (void)showActionsFor:(LCTVTile *)t {
    NSString *msg = t.app.purged ? @"tvOS removed this app's files to free space. Upload the .ipa again from the web page to restore it." : (t.app ? t.app.bundleId : @"Built-in demo guest");
    UIAlertController *s = [UIAlertController alertControllerWithTitle:t.title message:msg preferredStyle:UIAlertControllerStyleActionSheet];
    if (!t.app.purged) [s addAction:[UIAlertAction actionWithTitle:@"Launch" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self launch:t]; }]];
    if (t.app && !t.app.purged) [s addAction:[UIAlertAction actionWithTitle:@"Re-sign" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self resign:t]; }]];
    [s addAction:[UIAlertAction actionWithTitle:@"Info" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self info:t]; }]];
    if (t.app) [s addAction:[UIAlertAction actionWithTitle:t.app.purged ? @"Remove from list" : @"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) { [self confirmDelete:t]; }]];
    [s addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:s animated:YES completion:nil];
}

- (void)alert:(NSString *)title msg:(NSString *)msg {
    UIAlertController *r = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [r addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:r animated:YES completion:nil];
}

- (void)resign:(LCTVTile *)t {
    LCTVImportedApp *a = t.app;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *e = [LCTVAppManager.shared prepareAppForLaunch:a];
        dispatch_async(dispatch_get_main_queue(), ^{ [self reload]; [self alert:e ? @"Re-sign failed" : @"Re-signed" msg:e ?: a.name]; });
    });
}

- (void)info:(LCTVTile *)t {
    LCTVImportedApp *a = t.app;
    NSString *m = a ? [NSString stringWithFormat:@"Bundle ID: %@\nVersion: %@\nStatus: %@\nSigned: %@\nCert SHA1: %@\nPath: %@",
                       a.bundleId, a.version ?: @"?", a.purged ? @"files purged — re-import needed" : (a.signedOK ? @"ready" : @"not signed"),
                       a.signedDate ?: @"never", a.signedFingerprint ?: @"-", a.appPath.length ? a.appPath.lastPathComponent : @"-"]
                    : @"Built-in demo guest bundled with LiveContainerTV.\nMenu or “Return to host” comes back here.";
    [self alert:t.title msg:m];
}

- (void)confirmDelete:(LCTVTile *)t {
    UIAlertController *s = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Delete %@?", t.title] message:@"Its data inside LiveContainerTV will be removed." preferredStyle:UIAlertControllerStyleAlert];
    [s addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [LCTVAppManager.shared deleteApp:t.app.bundleId error:nil]; [self reload];
    }]];
    [s addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:s animated:YES completion:nil];
}

- (void)launchNow:(LCTVTile *)t {
    NSString *payload = [NSString stringWithFormat:@"%@\n%.0f", t.token, [[NSDate date] timeIntervalSince1970]];
    NSError *err = nil;
    BOOL ok = [payload writeToFile:LCTVPendingPath() atomically:YES encoding:NSUTF8StringEncoding error:&err];
    [[NSFileManager defaultManager] removeItemAtPath:forceHostPath() error:nil];
    [NSUserDefaults.standardUserDefaults setObject:t.token forKey:@"LCTVSelectedGuest"];
    [NSUserDefaults.standardUserDefaults synchronize];
    LCTVLog(@"wrote pending=%@ ok=%d err=%@", payload, ok, err);
    exit(0);
}
- (void)launchPrepared:(LCTVTile *)t {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    if ([ud boolForKey:@"LCTVSkipLaunchHint"]) { [self launchNow:t]; return; }
    NSString *msg = [NSString stringWithFormat:@"tvOS doesn't let an app restart itself, so LiveContainerTV closes now. Open it again within 90 seconds and %@ starts straight away.\n\nPress Menu inside the app to come back here.", t.title];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:[@"Launch " stringByAppendingString:t.title] message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Close & relaunch" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self launchNow:t]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Don't ask again" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [ud setBool:YES forKey:@"LCTVSkipLaunchHint"]; [self launchNow:t]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)launch:(LCTVTile *)t {
    LCTVImportedApp *app = t.app;
    if (!app || [LCTVAppManager.shared isPreparedFast:app]) { [self launchPrepared:t]; return; }
    // Do the expensive patch/fixup/sign NOW in host mode so the guest boot is just dlopen.
    UIAlertController *wait = [UIAlertController alertControllerWithTitle:[@"Preparing " stringByAppendingString:t.title] message:@"One-time setup (patch + sign). Next launches skip this." preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:wait animated:YES completion:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *e = [LCTVAppManager.shared prepareAppForLaunch:app];
        dispatch_async(dispatch_get_main_queue(), ^{
            [wait dismissViewControllerAnimated:YES completion:^{
                if (e && ![LCTVAppManager.shared isPreparedFast:app]) {
                    UIAlertController *f = [UIAlertController alertControllerWithTitle:@"Prepare failed" message:e preferredStyle:UIAlertControllerStyleAlert];
                    [f addAction:[UIAlertAction actionWithTitle:@"Launch anyway" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){ [self launchPrepared:t]; }]];
                    [f addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
                    [self presentViewController:f animated:YES completion:nil];
                } else [self launchPrepared:t];
            }];
        });
    });
}
@end
