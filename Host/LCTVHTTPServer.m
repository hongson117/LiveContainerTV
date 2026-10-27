#import "LCTVHTTPServer.h"
#import "LCTVCommon.h"
#import "LCTVAppManager.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <fcntl.h>
#import <errno.h>

static const uint16_t kPort = 8228;

@interface LCTVHTTPServer ()
@property int listenFd;
@property dispatch_source_t acceptSource;
@property (readwrite) BOOL running;
@end

@implementation LCTVHTTPServer

+ (instancetype)shared { static id s; static dispatch_once_t o; dispatch_once(&o,^{ s=[self new]; }); return s; }
- (uint16_t)port { return kPort; }

- (NSString *)lanIP {
    struct ifaddrs *ifa = NULL; getifaddrs(&ifa);
    NSString *ip = @"0.0.0.0";
    for (struct ifaddrs *p = ifa; p; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET) continue;
        char *name = p->ifa_name;
        if (strncmp(name, "lo", 2) == 0) continue;
        char buf[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &((struct sockaddr_in *)p->ifa_addr)->sin_addr, buf, sizeof buf);
        if (strncmp(buf, "169.254.", 8) == 0) continue; // skip link-local if we have better
        ip = @(buf);
        if (strncmp(name, "en", 2) == 0) break; // prefer en*
    }
    if (ifa) freeifaddrs(ifa);
    return ip;
}
- (NSString *)lanURL { return [NSString stringWithFormat:@"http://%@:%u", self.lanIP, kPort]; }

- (BOOL)start:(NSError **)error {
    if (self.running) return YES;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { if (error)*error=[NSError errorWithDomain:@"LCTV" code:errno userInfo:@{NSLocalizedDescriptionKey:@(strerror(errno))}]; return NO; }
    int yes = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes);
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kPort);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) < 0) {
        if (error)*error=[NSError errorWithDomain:@"LCTV" code:errno userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"bind :%u %s", kPort, strerror(errno)]}];
        close(fd); return NO;
    }
    if (listen(fd, 8) < 0) { close(fd); return NO; }
    int flags = fcntl(fd, F_GETFL, 0); fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    self.listenFd = fd;
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    self.acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, q);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.acceptSource, ^{
        [weakSelf acceptOnce];
    });
    dispatch_resume(self.acceptSource);
    self.running = YES;
    LCTVLog(@"HTTP server listening on %@", self.lanURL);
    return YES;
}

- (void)stop {
    if (self.acceptSource) { dispatch_source_cancel(self.acceptSource); self.acceptSource = nil; }
    if (self.listenFd >= 0) { close(self.listenFd); self.listenFd = -1; }
    self.running = NO;
}

- (void)acceptOnce {
    struct sockaddr_in cli; socklen_t len = sizeof cli;
    int cfd = accept(self.listenFd, (struct sockaddr *)&cli, &len);
    if (cfd < 0) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool { [self handleClient:cfd]; }
        close(cfd);
    });
}

- (NSData *)readRequest:(int)fd {
    NSMutableData *data = [NSMutableData new];
    uint8_t buf[65536];
    // Read until headers complete, then read body per Content-Length
    for (;;) {
        ssize_t n = recv(fd, buf, sizeof buf, 0);
        if (n <= 0) break;
        [data appendBytes:buf length:n];
        NSRange r = [data rangeOfData:[NSData dataWithBytes:"\r\n\r\n" length:4] options:0 range:NSMakeRange(0, data.length)];
        if (r.location == NSNotFound) { if (data.length > 64*1024*1024) break; continue; }
        NSString *head = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, r.location)] encoding:NSUTF8StringEncoding] ?: @"";
        NSInteger contentLen = 0;
        for (NSString *line in [head componentsSeparatedByString:@"\r\n"]) {
            if ([line.lowercaseString hasPrefix:@"content-length:"]) {
                contentLen = [[line substringFromIndex:15] integerValue];
            }
        }
        NSUInteger bodyStart = r.location + 4;
        while ((NSInteger)(data.length - bodyStart) < contentLen) {
            n = recv(fd, buf, sizeof buf, 0);
            if (n <= 0) break;
            [data appendBytes:buf length:n];
        }
        break;
    }
    return data;
}

- (void)sendResponse:(int)fd status:(int)status contentType:(NSString *)ctype body:(NSData *)body {
    NSString *reason = status == 200 ? @"OK" : (status == 302 ? @"Found" : @"Error");
    NSString *hdr = [NSString stringWithFormat:
        @"HTTP/1.1 %d %@\r\nContent-Type: %@\r\nContent-Length: %lu\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n",
        status, reason, ctype, (unsigned long)body.length];
    NSMutableData *out = [[hdr dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    if (body) [out appendData:body];
    const uint8_t *p = out.bytes; size_t left = out.length;
    while (left) { ssize_t n = send(fd, p, left, 0); if (n <= 0) break; p += n; left -= n; }
}

- (NSString *)htmlPage {
    NSMutableString *apps = [NSMutableString new];
    for (LCTVImportedApp *a in LCTVAppManager.shared.importedApps) {
        [apps appendFormat:@"<li><b>%@</b> (%@) patched=%@ signed=%@</li>", a.name, a.bundleId, a.patched?@"yes":@"no", a.signedOK?@"yes":@"no"];
    }
    if (!apps.length) [apps appendString:@"<li><i>none yet</i></li>"];
    BOOL hasCert = LCTVAppManager.shared.hasCertificate;
    return [NSString stringWithFormat:
     @"<!doctype html><html><head><meta charset=utf-8><meta name=viewport content=\"width=device-width,initial-scale=1\">"
     @"<title>LiveContainerTV</title>"
     @"<style>body{font-family:system-ui;max-width:720px;margin:2rem auto;padding:0 1rem;background:#0f172a;color:#e2e8f0}"
     @"h1{color:#fbbf24} a{color:#2dd4bf} .card{background:#1e293b;padding:1rem;border-radius:12px;margin:1rem 0}"
     @"input,button{font-size:1rem;padding:.5rem;margin:.25rem 0} button{background:#d4af37;border:0;border-radius:8px;cursor:pointer}"
     @".ok{color:#2dd4bf}.bad{color:#f87171}</style></head><body>"
     @"<h1>LiveContainerTV</h1>"
     @"<p>Upload a <b>tvOS</b> .ipa and (required) your Apple signing <b>.p12</b> exported from plumesign/atvloadly.</p>"
     @"<div class=card><h3>Certificate %@</h3>"
     @"<form method=POST action=/upload-p12 enctype=multipart/form-data>"
     @"<input type=file name=file accept=.p12 required><br>"
     @"Password (empty for Impactor Export P12): <input type=password name=password placeholder=\"(empty ok)\"><br>"
     @"<button type=submit>Upload .p12</button></form></div>"
     @"<div class=card><h3>Upload IPA</h3>"
     @"<form method=POST action=/upload-ipa enctype=multipart/form-data>"
     @"<input type=file name=file accept=.ipa required><br>"
     @"<button type=submit>Upload .ipa</button></form>"
     @"<form method=POST action=/fetch-url style=margin-top:1rem>"
     @"Or IPA URL: <input name=url type=url style=width:70%% placeholder=https://example.com/app.ipa> "
     @"<button type=submit>Download</button></form></div>"
     @"<div class=card><h3>Imported apps</h3><ul>%@</ul>"
     @"<p>After upload, open LiveContainerTV on the Apple TV and tap the app to launch.</p></div>"
     @"<p><a href=/status>status JSON</a> · port %u</p></body></html>",
     hasCert ? @"<span class=ok>loaded</span>" : @"<span class=bad>missing</span>",
     apps, kPort];
}

- (NSDictionary *)parseMultipart:(NSData *)body boundary:(NSString *)boundary fileData:(NSData **)fileOut fileName:(NSString **)nameOut fields:(NSMutableDictionary *)fields {
    NSData *bnd = [[NSString stringWithFormat:@"--%@", boundary] dataUsingEncoding:NSUTF8StringEncoding];
    NSData *sep = [NSData dataWithBytes:"\r\n\r\n" length:4];
    NSUInteger start = 0;
    while (start < body.length) {
        NSRange br = [body rangeOfData:bnd options:0 range:NSMakeRange(start, body.length - start)];
        if (br.location == NSNotFound) break;
        NSUInteger partStart = br.location + br.length;
        if (partStart + 2 <= body.length && ((char *)body.bytes)[partStart] == '-' && ((char *)body.bytes)[partStart+1] == '-') break;
        if (partStart + 2 <= body.length && ((char *)body.bytes)[partStart] == '\r') partStart += 2;
        NSRange next = [body rangeOfData:bnd options:0 range:NSMakeRange(partStart, body.length - partStart)];
        NSUInteger partEnd = (next.location == NSNotFound) ? body.length : next.location;
        // trim trailing \r\n
        if (partEnd >= 2 && ((char *)body.bytes)[partEnd-2] == '\r') partEnd -= 2;
        NSData *part = [body subdataWithRange:NSMakeRange(partStart, partEnd - partStart)];
        NSRange hs = [part rangeOfData:sep options:0 range:NSMakeRange(0, part.length)];
        if (hs.location == NSNotFound) { start = partEnd; continue; }
        NSString *headers = [[NSString alloc] initWithData:[part subdataWithRange:NSMakeRange(0, hs.location)] encoding:NSUTF8StringEncoding] ?: @"";
        NSData *content = [part subdataWithRange:NSMakeRange(hs.location + 4, part.length - hs.location - 4)];
        NSString *disp = nil;
        for (NSString *line in [headers componentsSeparatedByString:@"\r\n"]) {
            if ([line.lowercaseString hasPrefix:@"content-disposition:"]) disp = line;
        }
        NSString *fname = nil, *name = nil;
        if (disp) {
            NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"name=\"([^\"]+)\"" options:0 error:nil];
            NSTextCheckingResult *m = [re firstMatchInString:disp options:0 range:NSMakeRange(0, disp.length)];
            if (m) name = [disp substringWithRange:[m rangeAtIndex:1]];
            re = [NSRegularExpression regularExpressionWithPattern:@"filename=\"([^\"]*)\"" options:0 error:nil];
            m = [re firstMatchInString:disp options:0 range:NSMakeRange(0, disp.length)];
            if (m) fname = [disp substringWithRange:[m rangeAtIndex:1]];
        }
        if (fname.length) {
            if (fileOut) *fileOut = content;
            if (nameOut) *nameOut = fname;
        } else if (name) {
            NSString *val = [[NSString alloc] initWithData:content encoding:NSUTF8StringEncoding] ?: @"";
            fields[name] = val;
        }
        start = partEnd;
    }
    return fields;
}

- (void)handleClient:(int)fd {
    NSData *req = [self readRequest:fd];
    if (req.length < 4) return;
    NSRange hdrEnd = [req rangeOfData:[NSData dataWithBytes:"\r\n\r\n" length:4] options:0 range:NSMakeRange(0, req.length)];
    if (hdrEnd.location == NSNotFound) return;
    NSString *head = [[NSString alloc] initWithData:[req subdataWithRange:NSMakeRange(0, hdrEnd.location)] encoding:NSUTF8StringEncoding] ?: @"";
    NSArray *lines = [head componentsSeparatedByString:@"\r\n"];
    NSArray *reqLine = [lines.firstObject componentsSeparatedByString:@" "];
    if (reqLine.count < 2) return;
    NSString *method = reqLine[0];
    NSString *path = reqLine[1];
    NSData *body = [req subdataWithRange:NSMakeRange(hdrEnd.location + 4, req.length - hdrEnd.location - 4)];
    NSString *contentType = @"";
    for (NSString *line in lines) {
        if ([line.lowercaseString hasPrefix:@"content-type:"]) contentType = [[line substringFromIndex:13] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    }
    LCTVLog(@"HTTP %@ %@ (%lu body)", method, path, (unsigned long)body.length);

    if ([method isEqual:@"GET"] && ([path isEqual:@"/"] || [path hasPrefix:@"/index"])) {
        NSData *html = [[self htmlPage] dataUsingEncoding:NSUTF8StringEncoding];
        [self sendResponse:fd status:200 contentType:@"text/html; charset=utf-8" body:html];
        return;
    }
    if ([method isEqual:@"GET"] && [path hasPrefix:@"/status"]) {
        NSMutableArray *apps = [NSMutableArray new];
        for (LCTVImportedApp *a in LCTVAppManager.shared.importedApps) {
            [apps addObject:@{@"name":a.name?:@"", @"bundleId":a.bundleId?:@"", @"patched":@(a.patched), @"signed":@(a.signedOK)}];
        }
        NSDictionary *st = @{@"port":@(kPort), @"url":self.lanURL, @"cert":@(LCTVAppManager.shared.hasCertificate), @"apps":apps};
        NSData *json = [NSJSONSerialization dataWithJSONObject:st options:NSJSONWritingPrettyPrinted error:nil];
        [self sendResponse:fd status:200 contentType:@"application/json" body:json];
        return;
    }
    if ([method isEqual:@"POST"] && [path hasPrefix:@"/upload-p12"]) {
        NSString *bnd = nil;
        if ([contentType containsString:@"boundary="]) bnd = [[contentType componentsSeparatedByString:@"boundary="] lastObject];
        NSData *file = nil; NSString *fname = nil; NSMutableDictionary *fields = [NSMutableDictionary new];
        [self parseMultipart:body boundary:bnd fileData:&file fileName:&fname fields:fields];
        NSError *err = nil;
        BOOL ok = file && [LCTVAppManager.shared saveCertificateData:file password:fields[@"password"] ?: @"" error:&err];
        NSString *msg = ok ? @"<h2 class=ok>Certificate saved. Upload an IPA next.</h2><a href=/>Back</a>" :
                             [NSString stringWithFormat:@"<h2 class=bad>Failed: %@</h2><a href=/>Back</a>", err.localizedDescription ?: @"no file"];
        [self sendResponse:fd status:200 contentType:@"text/html; charset=utf-8" body:[msg dataUsingEncoding:NSUTF8StringEncoding]];
        return;
    }
    if ([method isEqual:@"POST"] && [path hasPrefix:@"/upload-ipa"]) {
        NSString *bnd = nil;
        if ([contentType containsString:@"boundary="]) bnd = [[contentType componentsSeparatedByString:@"boundary="] lastObject];
        NSData *file = nil; NSString *fname = nil; NSMutableDictionary *fields = [NSMutableDictionary new];
        [self parseMultipart:body boundary:bnd fileData:&file fileName:&fname fields:fields];
        NSError *err = nil;
        NSString *bid = file ? [LCTVAppManager.shared importIPAData:file suggestedName:fname ?: @"app.ipa" error:&err] : nil;
        NSString *msg = bid ? [NSString stringWithFormat:@"<h2 class=ok>Imported %@</h2><p>Open LiveContainerTV on the TV and tap Launch.</p><a href=/>Back</a>", bid] :
                              [NSString stringWithFormat:@"<h2 class=bad>Import failed: %@</h2><a href=/>Back</a>", err.localizedDescription ?: @"no file"];
        [self sendResponse:fd status:200 contentType:@"text/html; charset=utf-8" body:[msg dataUsingEncoding:NSUTF8StringEncoding]];
        return;
    }
    if ([method isEqual:@"POST"] && [path hasPrefix:@"/fetch-url"]) {
        NSString *bodyStr = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] ?: @"";
        NSString *urlStr = nil;
        for (NSString *pair in [bodyStr componentsSeparatedByString:@"&"]) {
            NSArray *kv = [pair componentsSeparatedByString:@"="];
            if (kv.count == 2 && [kv[0] isEqual:@"url"]) {
                urlStr = [[kv[1] stringByRemovingPercentEncoding] stringByReplacingOccurrencesOfString:@"+" withString:@" "];
            }
        }
        NSError *err = nil; NSString *bid = nil;
        if (urlStr.length) {
            LCTVLog(@"fetch IPA %@", urlStr);
            NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:urlStr] options:0 error:&err];
            if (data) bid = [LCTVAppManager.shared importIPAData:data suggestedName:@"download.ipa" error:&err];
        }
        NSString *msg = bid ? [NSString stringWithFormat:@"<h2 class=ok>Imported %@</h2><a href=/>Back</a>", bid] :
                              [NSString stringWithFormat:@"<h2 class=bad>Fetch failed: %@</h2><a href=/>Back</a>", err.localizedDescription ?: @"bad url"];
        [self sendResponse:fd status:200 contentType:@"text/html; charset=utf-8" body:[msg dataUsingEncoding:NSUTF8StringEncoding]];
        return;
    }
    [self sendResponse:fd status:404 contentType:@"text/plain" body:[@"not found" dataUsingEncoding:NSUTF8StringEncoding]];
}

@end
