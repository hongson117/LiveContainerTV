#import "LCTVCert.h"
#import "LCTVCommon.h"
#import "LCTVAppManager.h"
#import <CommonCrypto/CommonDigest.h>
#include <openssl/pkcs12.h>
#include <openssl/x509.h>
#include <openssl/evp.h>
#include <openssl/err.h>
#include <openssl/provider.h>

static NSString *sha1hex(NSData *d) {
    unsigned char md[CC_SHA1_DIGEST_LENGTH]; CC_SHA1(d.bytes, (CC_LONG)d.length, md);
    NSMutableString *s = [NSMutableString new];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) [s appendFormat:@"%02X", md[i]];
    return s;
}

static void ensureProviders(void) {
    static dispatch_once_t o; dispatch_once(&o, ^{ OSSL_PROVIDER_load(NULL, "default"); OSSL_PROVIDER_load(NULL, "legacy"); });
}

/// embedded.mobileprovision is CMS-signed; the plist sits in clear text inside.
static NSDictionary *hostProvision(void) {
    NSString *p = [NSBundle.mainBundle pathForResource:@"embedded" ofType:@"mobileprovision"];
    NSData *d = p ? [NSData dataWithContentsOfFile:p] : nil;
    if (!d) return nil;
    NSRange a = [d rangeOfData:[@"<?xml" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0, d.length)];
    NSData *endTag = [@"</plist>" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange b = [d rangeOfData:endTag options:NSDataSearchBackwards range:NSMakeRange(0, d.length)];
    if (a.location == NSNotFound || b.location == NSNotFound) return nil;
    NSData *pl = [d subdataWithRange:NSMakeRange(a.location, NSMaxRange(b) - a.location)];
    return [NSPropertyListSerialization propertyListWithData:pl options:0 format:nil error:nil];
}

typedef struct { X509 *cert; EVP_PKEY *key; } P12;
static P12 loadP12(NSData *data, NSString *pass) {
    P12 r = {0};
    if (!data.length) return r;
    ensureProviders();
    const unsigned char *pp = (const unsigned char *)data.bytes;
    PKCS12 *p = d2i_PKCS12(NULL, &pp, (long)data.length);
    if (!p) return r;
    STACK_OF(X509) *ca = NULL;
    if (!PKCS12_parse(p, pass.UTF8String, &r.key, &r.cert, &ca)) { ERR_clear_error(); r.cert = NULL; r.key = NULL; }
    if (ca) sk_X509_pop_free(ca, X509_free);
    PKCS12_free(p);
    return r;
}
static NSData *derOf(X509 *x) {
    unsigned char *buf = NULL; int n = i2d_X509(x, &buf);
    if (n <= 0) return nil;
    NSData *d = [NSData dataWithBytes:buf length:n]; OPENSSL_free(buf); return d;
}

@interface LCTVCert ()
@property (readwrite) LCTVCertState state;
@property (readwrite, nullable) NSString *hostFingerprint, *p12Fingerprint, *teamName;
@property (readwrite, nullable) NSDate *expiry;
@property (readwrite) BOOL busy;
@property (readwrite, copy) NSString *busyText;
@end

@implementation LCTVCert
+ (instancetype)shared { static LCTVCert *s; static dispatch_once_t o; dispatch_once(&o, ^{ s = [self new]; s.busyText = @""; }); return s; }

- (NSInteger)daysLeft { return self.expiry ? (NSInteger)floor([self.expiry timeIntervalSinceNow] / 86400.0) : -1; }

- (NSString *)summary {
    switch (self.state) {
        case LCTVCertStateNoP12: return @"No certificate — upload .p12";
        case LCTVCertStateBadP12: return @"Certificate unreadable — re-upload .p12";
        case LCTVCertStateChanged: return @"Certificate changed — upload new .p12";
        case LCTVCertStateUnknownHost: return @"Certificate loaded";
        case LCTVCertStateOK: {
            NSInteger d = self.daysLeft;
            return d >= 0 ? [NSString stringWithFormat:@"Certificate OK · %ld day%@ left", (long)d, d == 1 ? @"" : @"s"] : @"Certificate OK";
        }
    }
}

- (void)notify { dispatch_async(dispatch_get_main_queue(), ^{ [NSNotificationCenter.defaultCenter postNotificationName:LCTVStateChangedNotification object:nil]; }); }

/// If the stored p12's private key matches the host's (new) cert, rebuild the p12 with the host cert.
/// plumesign/atvloadly typically reuse the same key.pem, so a refresh only changes the certificate.
- (BOOL)tryKeyReuseWithHostCertDER:(NSData *)hostDER {
    LCTVAppManager *m = LCTVAppManager.shared;
    NSString *pass = m.certificatePassword;
    P12 p = loadP12(m.certificateData, pass);
    if (!p.key) return NO;
    const unsigned char *hp = (const unsigned char *)hostDER.bytes;
    X509 *host = d2i_X509(NULL, &hp, (long)hostDER.length);
    BOOL ok = NO;
    if (host && X509_check_private_key(host, p.key) == 1) {
        PKCS12 *np = PKCS12_create(pass.UTF8String, "LiveContainerTV", p.key, host, NULL, 0, 0, 0, 0, 0);
        unsigned char *buf = NULL; int n = np ? i2d_PKCS12(np, &buf) : 0;
        if (n > 0) {
            NSData *nd = [NSData dataWithBytes:buf length:n]; OPENSSL_free(buf);
            // keep a backup of the old p12
            [m.certificateData writeToFile:[LCTVDataDir() stringByAppendingPathComponent:@"cert.prev.p12"] atomically:YES];
            ok = [m saveCertificateData:nd password:pass error:nil];
            LCTVLog(@"cert: key reuse OK — rebuilt p12 with host's new certificate (%d bytes)", n);
        }
        if (np) PKCS12_free(np);
    } else {
        LCTVLog(@"cert: key reuse impossible (private key does not match new certificate)");
        ERR_clear_error();
    }
    if (host) X509_free(host);
    if (p.cert) X509_free(p.cert);
    EVP_PKEY_free(p.key);
    return ok;
}

- (void)evaluate { [self evaluateAllowReuse:NO]; }

- (void)evaluateAllowReuse:(BOOL)allowReuse {
    NSDictionary *prov = hostProvision();
    NSArray *certs = prov[@"DeveloperCertificates"];
    NSData *hostDER = certs.count ? certs.firstObject : nil;
    // A profile may list several certs; host is signed with one of them
    NSMutableSet *hostFPs = [NSMutableSet new];
    for (NSData *c in certs) if ([c isKindOfClass:NSData.class]) [hostFPs addObject:sha1hex(c)];
    self.hostFingerprint = hostDER ? sha1hex(hostDER) : nil;
    self.teamName = prov[@"TeamName"];
    NSDate *exp = prov[@"ExpirationDate"];

    LCTVAppManager *m = LCTVAppManager.shared;
    if (!m.hasCertificate) { self.p12Fingerprint = nil; self.state = LCTVCertStateNoP12; self.expiry = exp; return; }
    P12 p = loadP12(m.certificateData, m.certificatePassword);
    if (!p.cert) { self.p12Fingerprint = nil; self.state = LCTVCertStateBadP12; self.expiry = exp; if (p.key) EVP_PKEY_free(p.key); return; }
    NSData *pder = derOf(p.cert);
    self.p12Fingerprint = sha1hex(pder);
    // cert notAfter
    const ASN1_TIME *na = X509_get0_notAfter(p.cert);
    int days = 0, secs = 0;
    if (na && ASN1_TIME_diff(&days, &secs, NULL, na)) {
        NSDate *ce = [NSDate dateWithTimeIntervalSinceNow:days * 86400.0 + secs];
        exp = exp ? [exp earlierDate:ce] : ce;
    }
    X509_free(p.cert); if (p.key) EVP_PKEY_free(p.key);
    self.expiry = exp;

    if (!hostFPs.count) { self.state = LCTVCertStateUnknownHost; return; }
    if ([hostFPs containsObject:self.p12Fingerprint]) { self.state = LCTVCertStateOK; return; }
    LCTVLog(@"cert: host=%@ p12=%@ — CHANGED", self.hostFingerprint, self.p12Fingerprint);
    if (allowReuse) {
        for (NSData *c in certs) {
            if ([self tryKeyReuseWithHostCertDER:c]) { [self evaluateAllowReuse:NO]; return; }
        }
    }
    self.state = LCTVCertStateChanged;
}

- (void)evaluateAndResignAsync:(BOOL)forceAll {
    @synchronized (self) { if (self.busy) return; self.busy = YES; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self evaluateAllowReuse:YES];
        LCTVLog(@"cert: state=%ld host=%@ p12=%@ days=%ld", (long)self.state, self.hostFingerprint, self.p12Fingerprint, (long)self.daysLeft);
        [self notify];
        if (self.state == LCTVCertStateOK || self.state == LCTVCertStateUnknownHost) {
            NSArray *apps = LCTVAppManager.shared.importedApps;
            NSUInteger i = 0;
            for (LCTVImportedApp *a in apps) {
                i++;
                if (a.purged) continue;
                if (!forceAll && a.signedOK && [a.signedFingerprint isEqual:self.p12Fingerprint]) continue;
                self.busyText = [NSString stringWithFormat:@"Re-signing %@ (%lu/%lu)…", a.name, (unsigned long)i, (unsigned long)apps.count];
                [self notify];
                LCTVLog(@"cert: auto re-sign %@ (was %@)", a.bundleId, a.signedFingerprint ?: @"never");
                NSString *e = [LCTVAppManager.shared prepareAppForLaunch:a];
                if (e) LCTVLog(@"cert: re-sign %@ failed: %@", a.bundleId, e);
            }
        }
        self.busyText = @""; self.busy = NO;
        [self notify];
    });
}
@end
