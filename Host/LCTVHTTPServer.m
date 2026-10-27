#import "LCTVHTTPServer.h"
#import "LCTVCommon.h"
#import "LCTVAppManager.h"
#import "zsigner.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <fcntl.h>
#import <errno.h>
#import <unistd.h>

static const uint16_t kPort = 8228;
static const NSUInteger kMaxBodyBytes = 512ull * 1024ull * 1024ull; // 512 MB
static const NSUInteger kStreamToDiskThreshold = 256ull * 1024ull;   // 256 KB

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
        const char *name = p->ifa_name;
        if (!name || strncmp(name, "lo", 2) == 0) continue;
        char buf[INET_ADDRSTRLEN] = {0};
        inet_ntop(AF_INET, &((struct sockaddr_in *)p->ifa_addr)->sin_addr, buf, sizeof buf);
        if (strncmp(buf, "169.254.", 8) == 0) continue;
        ip = @(buf);
        if (strncmp(name, "en", 2) == 0) break;
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
    if (listen(fd, 16) < 0) { close(fd); return NO; }
    int flags = fcntl(fd, F_GETFL, 0); fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    self.listenFd = fd;
    self.acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.acceptSource, ^{ [weakSelf drainAccept]; });
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

- (void)drainAccept {
    for (;;) {
        struct sockaddr_in cli; socklen_t len = sizeof cli;
        int cfd = accept(self.listenFd, (struct sockaddr *)&cli, &len);
        if (cfd < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            LCTVLog(@"accept error: %s", strerror(errno));
            break;
        }
        // Force blocking + timeouts on the client socket
        int fl = fcntl(cfd, F_GETFL, 0); fcntl(cfd, F_SETFL, fl & ~O_NONBLOCK);
        struct timeval tv = { .tv_sec = 300, .tv_usec = 0 };
        setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        setsockopt(cfd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
        int one = 1; setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool {
                @try { [self handleClient:cfd]; }
                @catch (NSException *ex) {
                    LCTVLog(@"HTTP EXCEPTION %@ %@", ex.name, ex.reason);
                    NSString *msg = [NSString stringWithFormat:@"<h2 class=bad>Server error</h2><pre>%@\n%@</pre><a href=/>Back</a>", ex.name, ex.reason];
                    [self sendResponse:cfd status:500 contentType:@"text/html; charset=utf-8" body:[msg dataUsingEncoding:NSUTF8StringEncoding]];
                }
            }
            close(cfd);
        });
    }
}

- (void)sendResponse:(int)fd status:(int)status contentType:(NSString *)ctype body:(NSData *)body {
    if (fd < 0) return;
    if (!body) body = [NSData data];
    if (!ctype) ctype = @"text/plain";
    NSString *reason = (status == 200) ? @"OK" : (status == 100 ? @"Continue" : (status == 400 ? @"Bad Request" : @"Error"));
    NSString *hdr = [NSString stringWithFormat:
                     @"HTTP/1.1 %d %@\r\nContent-Type: %@\r\nContent-Length: %lu\r\nConnection: close\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\n\r\n",
                     status, reason, ctype, (unsigned long)body.length];
    NSMutableData *out = [NSMutableData dataWithData:[hdr dataUsingEncoding:NSUTF8StringEncoding]];
    [out appendData:body];
    const uint8_t *p = out.bytes; size_t left = out.length;
    while (left > 0) {
        ssize_t n = send(fd, p, left, 0);
        if (n < 0) { if (errno == EINTR) continue; LCTVLog(@"send error: %s", strerror(errno)); break; }
        if (n == 0) break;
        p += n; left -= (size_t)n;
    }
}

- (void)send100Continue:(int)fd {
    const char *msg = "HTTP/1.1 100 Continue\r\n\r\n";
    send(fd, msg, strlen(msg), 0);
}

- (NSString *)htmlPage {
    NSMutableString *apps = [NSMutableString new];
    for (LCTVImportedApp *a in LCTVAppManager.shared.importedApps) {
        [apps appendFormat:@"<li><b>%@</b> (%@) patched=%@ signed=%@</li>",
         a.name ?: @"?", a.bundleId ?: @"?", a.patched ? @"yes" : @"no", a.signedOK ? @"yes" : @"no"];
    }
    if (!apps.length) [apps appendString:@"<li><i>none yet</i></li>"];
    BOOL hasCert = LCTVAppManager.shared.hasCertificate;
    return [NSString stringWithFormat:
     @"<!doctype html><html><head><meta charset=utf-8><meta name=viewport content=\"width=device-width,initial-scale=1\">"
     @"<title>LiveContainerTV</title>"
     @"<style>body{font-family:system-ui;max-width:720px;margin:2rem auto;padding:0 1rem;background:#0f172a;color:#e2e8f0}"
     @"h1{color:#fbbf24} a{color:#2dd4bf} .card{background:#1e293b;padding:1rem;border-radius:12px;margin:1rem 0}"
     @"input,button{font-size:1rem;padding:.5rem;margin:.25rem 0} button{background:#d4af37;border:0;border-radius:8px;cursor:pointer}"
     @".ok{color:#2dd4bf}.bad{color:#f87171} code{background:#334155;padding:2px 6px;border-radius:4px}</style></head><body>"
     @"<h1>LiveContainerTV</h1>"
     @"<p>Upload a <b>tvOS</b> .ipa and your signing <b>.p12</b>.</p>"
     @"<div class=card><h3>Certificate %@</h3>"
     @"<p>Export on Windows (password is <b>required</b>):</p>"
     @"<pre>plumesign certificate export -u you@appleid.com -p YOURPASS -o certificate.p12</pre>"
     @"<form method=POST action=/upload-p12 enctype=multipart/form-data>"
     @"<input type=file name=file accept=.p12,application/x-pkcs12 required><br>"
     @"P12 password: <input type=password name=password required placeholder=\"same as -p\"><br>"
     @"<button type=submit>Upload .p12</button></form></div>"
     @"<div class=card><h3>Upload IPA</h3>"
     @"<form method=POST action=/upload-ipa enctype=multipart/form-data>"
     @"<input type=file name=file accept=.ipa required><br>"
     @"<button type=submit>Upload .ipa</button></form>"
     @"<form method=POST action=/fetch-url style=margin-top:1rem>"
     @"Or IPA URL: <input name=url type=url style=\"width:70%%\" placeholder=https://example.com/app.ipa> "
     @"<button type=submit>Download</button></form></div>"
     @"<div class=card><h3>Imported apps</h3><ul>%@</ul>"
     @"<p>On the Apple TV: Reload → select app → Launch → reopen LiveContainerTV.</p></div>"
     @"<p><a href=/status>status JSON</a> · port %u · <a href=/diag>diag log</a></p></body></html>",
     hasCert ? @"<span class=ok>loaded</span>" : @"<span class=bad>missing</span>",
     apps, (unsigned)kPort];
}

/// Read headers fully, handle 100-continue, then stream body to a temp file. Returns YES on success.
- (BOOL)readRequest:(int)fd headers:(NSString **)headersOut bodyPath:(NSString **)bodyPathOut bodyData:(NSData **)bodyDataOut error:(NSString **)errOut {
    NSMutableData *buf = [NSMutableData data];
    uint8_t tmp[64 * 1024];
    NSRange hdrRange = {NSNotFound, 0};
    // 1) Read until end of headers
    while (hdrRange.location == NSNotFound) {
        ssize_t n = recv(fd, tmp, sizeof tmp, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errOut) *errOut = [NSString stringWithFormat:@"recv headers: %s", strerror(errno)];
            return NO;
        }
        if (n == 0) { if (errOut) *errOut = @"client closed during headers"; return NO; }
        [buf appendBytes:tmp length:(NSUInteger)n];
        if (buf.length > 1024 * 1024) { if (errOut) *errOut = @"headers too large"; return NO; }
        hdrRange = [buf rangeOfData:[NSData dataWithBytes:"\r\n\r\n" length:4] options:0 range:NSMakeRange(0, buf.length)];
    }
    NSString *head = [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, hdrRange.location)] encoding:NSUTF8StringEncoding] ?: @"";
    if (headersOut) *headersOut = head;

    NSInteger contentLen = -1;
    BOOL expectContinue = NO;
    NSString *contentType = @"";
    for (NSString *line in [head componentsSeparatedByString:@"\r\n"]) {
        NSString *ll = line.lowercaseString;
        if ([ll hasPrefix:@"content-length:"]) {
            contentLen = [[[line substringFromIndex:15] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] integerValue];
        } else if ([ll hasPrefix:@"expect:"] && [ll containsString:@"100-continue"]) {
            expectContinue = YES;
        } else if ([ll hasPrefix:@"content-type:"]) {
            contentType = [[line substringFromIndex:13] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        }
    }
    (void)contentType;

    if (expectContinue) {
        LCTVLog(@"HTTP sending 100 Continue");
        [self send100Continue:fd];
    }

    NSUInteger bodyAlready = buf.length - (hdrRange.location + 4);
    const uint8_t *bodyStart = (const uint8_t *)buf.bytes + hdrRange.location + 4;

    if (contentLen < 0) {
        // No body
        if (bodyDataOut) *bodyDataOut = [NSData data];
        if (bodyPathOut) *bodyPathOut = nil;
        return YES;
    }
    if ((NSUInteger)contentLen > kMaxBodyBytes) {
        if (errOut) *errOut = [NSString stringWithFormat:@"body too large (%ld)", (long)contentLen];
        return NO;
    }

    BOOL toDisk = (NSUInteger)contentLen >= kStreamToDiskThreshold;
    NSString *path = nil;
    NSFileHandle *fh = nil;
    NSMutableData *mem = nil;
    if (toDisk) {
        path = [LCTVCachesDir() stringByAppendingPathComponent:[NSString stringWithFormat:@"http-body-%@.bin", NSUUID.UUID.UUIDString]];
        [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) { if (errOut) *errOut = @"cannot open temp body file"; return NO; }
        if (bodyAlready > 0) [fh writeData:[NSData dataWithBytes:bodyStart length:bodyAlready]];
    } else {
        mem = [NSMutableData dataWithCapacity:(NSUInteger)contentLen];
        if (bodyAlready > 0) [mem appendBytes:bodyStart length:MIN(bodyAlready, (NSUInteger)contentLen)];
    }

    NSUInteger got = MIN(bodyAlready, (NSUInteger)contentLen);
    while (got < (NSUInteger)contentLen) {
        size_t want = MIN(sizeof tmp, (NSUInteger)contentLen - got);
        ssize_t n = recv(fd, tmp, want, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            [fh closeFile];
            if (path) [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            if (errOut) *errOut = [NSString stringWithFormat:@"recv body @%lu: %s", (unsigned long)got, strerror(errno)];
            return NO;
        }
        if (n == 0) {
            [fh closeFile];
            if (path) [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            if (errOut) *errOut = [NSString stringWithFormat:@"client closed early (%lu/%ld)", (unsigned long)got, (long)contentLen];
            return NO;
        }
        if (fh) [fh writeData:[NSData dataWithBytes:tmp length:(NSUInteger)n]];
        else [mem appendBytes:tmp length:(NSUInteger)n];
        got += (NSUInteger)n;
    }
    [fh closeFile];
    if (bodyPathOut) *bodyPathOut = path;
    if (bodyDataOut) *bodyDataOut = mem ?: (path ? [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil] : [NSData data]);
    LCTVLog(@"HTTP body ok len=%ld disk=%d", (long)contentLen, toDisk);
    return YES;
}

- (NSString *)extractBoundary:(NSString *)contentType {
    if (!contentType.length) return nil;
    NSRange r = [contentType rangeOfString:@"boundary=" options:NSCaseInsensitiveSearch];
    if (r.location == NSNotFound) return nil;
    NSString *b = [contentType substringFromIndex:r.location + r.length];
    // trim ; and whitespace, strip quotes
    NSRange semi = [b rangeOfString:@";"];
    if (semi.location != NSNotFound) b = [b substringToIndex:semi.location];
    b = [b stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if ([b hasPrefix:@"\""] && [b hasSuffix:@"\""] && b.length >= 2) b = [b substringWithRange:NSMakeRange(1, b.length - 2)];
    return b.length ? b : nil;
}

- (BOOL)parseMultipart:(NSData *)body boundary:(NSString *)boundary
              fileData:(NSData **)fileOut fileName:(NSString **)nameOut
                fields:(NSMutableDictionary *)fields error:(NSString **)errOut {
    if (!boundary.length) { if (errOut) *errOut = @"missing multipart boundary"; return NO; }
    if (!body) { if (errOut) *errOut = @"empty body"; return NO; }
    NSData *bnd = [[NSString stringWithFormat:@"--%@", boundary] dataUsingEncoding:NSUTF8StringEncoding];
    NSData *sep = [NSData dataWithBytes:"\r\n\r\n" length:4];
    NSUInteger start = 0;
    NSInteger parts = 0;
    while (start < body.length) {
        NSRange br = [body rangeOfData:bnd options:0 range:NSMakeRange(start, body.length - start)];
        if (br.location == NSNotFound) break;
        NSUInteger partStart = br.location + br.length;
        if (partStart + 2 <= body.length) {
            const char *c = (const char *)body.bytes + partStart;
            if (c[0] == '-' && c[1] == '-') break; // closing --
            if (c[0] == '\r' && c[1] == '\n') partStart += 2;
        }
        NSRange next = [body rangeOfData:bnd options:0 range:NSMakeRange(partStart, body.length - partStart)];
        NSUInteger partEnd = (next.location == NSNotFound) ? body.length : next.location;
        if (partEnd >= 2) {
            const char *c = (const char *)body.bytes + partEnd - 2;
            if (c[0] == '\r' && c[1] == '\n') partEnd -= 2;
        }
        if (partEnd <= partStart) { start = partEnd; continue; }
        NSData *part = [body subdataWithRange:NSMakeRange(partStart, partEnd - partStart)];
        NSRange hs = [part rangeOfData:sep options:0 range:NSMakeRange(0, part.length)];
        if (hs.location == NSNotFound) { start = partEnd; continue; }
        NSString *partHeaders = [[NSString alloc] initWithData:[part subdataWithRange:NSMakeRange(0, hs.location)] encoding:NSUTF8StringEncoding] ?: @"";
        NSData *content = [part subdataWithRange:NSMakeRange(hs.location + 4, part.length - hs.location - 4)];
        NSString *disp = nil;
        for (NSString *line in [partHeaders componentsSeparatedByString:@"\r\n"]) {
            if ([line.lowercaseString hasPrefix:@"content-disposition:"]) disp = line;
        }
        NSString *fname = nil, *name = nil;
        if (disp) {
            NSRegularExpression *reName = [NSRegularExpression regularExpressionWithPattern:@"name=\"([^\"]+)\"" options:0 error:nil];
            NSTextCheckingResult *m = [reName firstMatchInString:disp options:0 range:NSMakeRange(0, disp.length)];
            if (m) name = [disp substringWithRange:[m rangeAtIndex:1]];
            NSRegularExpression *reFile = [NSRegularExpression regularExpressionWithPattern:@"filename=\"([^\"]*)\"" options:0 error:nil];
            m = [reFile firstMatchInString:disp options:0 range:NSMakeRange(0, disp.length)];
            if (m) fname = [disp substringWithRange:[m rangeAtIndex:1]];
        }
        if (fname != nil) { // even empty filename means file field
            if (fileOut) *fileOut = content;
            if (nameOut) *nameOut = fname.length ? fname : @"upload.bin";
        } else if (name) {
            NSString *val = [[NSString alloc] initWithData:content encoding:NSUTF8StringEncoding] ?: @"";
            // strip trailing CR
            val = [val stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            fields[name] = val;
        }
        parts++;
        start = (next.location == NSNotFound) ? body.length : next.location;
    }
    LCTVLog(@"multipart parts=%ld file=%lu fields=%lu", (long)parts, (unsigned long)(fileOut && *fileOut ? [*fileOut length] : 0), (unsigned long)fields.count);
    return YES;
}

- (NSString *)htmlErr:(NSString *)msg {
    return [NSString stringWithFormat:@"<!doctype html><html><body style=\"font-family:system-ui;background:#0f172a;color:#e2e8f0;padding:2rem\">"
            @"<h2 style=color:#f87171>Error</h2><pre>%@</pre><p><a href=/ style=color:#2dd4bf>Back</a></p></body></html>", msg ?: @"unknown"];
}
- (NSString *)htmlOk:(NSString *)msg {
    return [NSString stringWithFormat:@"<!doctype html><html><body style=\"font-family:system-ui;background:#0f172a;color:#e2e8f0;padding:2rem\">"
            @"<h2 style=color:#2dd4bf>OK</h2><p>%@</p><p><a href=/ style=color:#2dd4bf>Back</a></p></body></html>", msg ?: @"done"];
}

- (void)handleClient:(int)fd {
    NSString *headers = nil, *bodyPath = nil, *readErr = nil;
    NSData *bodyData = nil;
    if (![self readRequest:fd headers:&headers bodyPath:&bodyPath bodyData:&bodyData error:&readErr]) {
        LCTVLog(@"HTTP read failed: %@", readErr);
        [self sendResponse:fd status:400 contentType:@"text/html; charset=utf-8" body:[[self htmlErr:readErr ?: @"read failed"] dataUsingEncoding:NSUTF8StringEncoding]];
        if (bodyPath) [[NSFileManager defaultManager] removeItemAtPath:bodyPath error:nil];
        return;
    }
    @try {
        NSArray *lines = [headers componentsSeparatedByString:@"\r\n"];
        NSArray *reqLine = [lines.firstObject componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        reqLine = [reqLine filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
        if (reqLine.count < 2) {
            [self sendResponse:fd status:400 contentType:@"text/html; charset=utf-8" body:[[self htmlErr:@"bad request line"] dataUsingEncoding:NSUTF8StringEncoding]];
            return;
        }
        NSString *method = reqLine[0];
        NSString *path = reqLine[1];
        NSString *contentType = @"";
        for (NSString *line in lines) {
            if ([line.lowercaseString hasPrefix:@"content-type:"])
                contentType = [[line substringFromIndex:13] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        }
        LCTVLog(@"HTTP %@ %@ body=%lu", method, path, (unsigned long)bodyData.length);

        if ([method isEqual:@"GET"] && ([path isEqual:@"/"] || [path hasPrefix:@"/index"])) {
            [self sendResponse:fd status:200 contentType:@"text/html; charset=utf-8" body:[[self htmlPage] dataUsingEncoding:NSUTF8StringEncoding]];
            return;
        }
        if ([method isEqual:@"GET"] && [path hasPrefix:@"/status"]) {
            NSMutableArray *apps = [NSMutableArray new];
            for (LCTVImportedApp *a in LCTVAppManager.shared.importedApps) {
                [apps addObject:@{@"name": a.name ?: @"", @"bundleId": a.bundleId ?: @"", @"patched": @(a.patched), @"signed": @(a.signedOK)}];
            }
            NSDictionary *st = @{@"port": @(kPort), @"url": self.lanURL ?: @"", @"cert": @(LCTVAppManager.shared.hasCertificate), @"apps": apps};
            NSData *json = [NSJSONSerialization dataWithJSONObject:st options:NSJSONWritingPrettyPrinted error:nil] ?: [NSData data];
            [self sendResponse:fd status:200 contentType:@"application/json" body:json];
            return;
        }
        if ([method isEqual:@"GET"] && [path hasPrefix:@"/diag"]) {
            NSString *log = LCTVReadLogTail(16000);
            [self sendResponse:fd status:200 contentType:@"text/plain; charset=utf-8" body:[log dataUsingEncoding:NSUTF8StringEncoding]];
            return;
        }
        if ([method isEqual:@"POST"] && [path hasPrefix:@"/upload-p12"]) {
            NSString *bnd = [self extractBoundary:contentType];
            NSData *file = nil; NSString *fname = nil; NSMutableDictionary *fields = [NSMutableDictionary new];
            NSString *perr = nil;
            [self parseMultipart:bodyData boundary:bnd fileData:&file fileName:&fname fields:fields error:&perr];
            LCTVLog(@"upload-p12 fname=%@ size=%lu passLen=%lu parseErr=%@", fname, (unsigned long)file.length, (unsigned long)[fields[@"password"] length], perr);
            if (!file.length) {
                [self sendResponse:fd status:400 contentType:@"text/html; charset=utf-8"
                              body:[[self htmlErr:perr ?: @"No .p12 file in form (check boundary / file field)"] dataUsingEncoding:NSUTF8StringEncoding]];
                return;
            }
            NSString *pass = fields[@"password"] ?: @"";
            if (!pass.length) {
                [self sendResponse:fd status:400 contentType:@"text/html; charset=utf-8"
                              body:[[self htmlErr:@"P12 password is required (the -p you used with plumesign certificate export)."] dataUsingEncoding:NSUTF8StringEncoding]];
                return;
            }
            NSError *err = nil;
            BOOL ok = [LCTVAppManager.shared saveCertificateData:file password:pass error:&err];
            // Soft-validate with ZSigner if available (must not crash)
            NSString *validateNote = @"";
            if (ok) {
                @try {
                    {
                        NSString *team = [ZSigner getTeamIdWithCert:file pass:pass];
                        validateNote = team.length
                            ? [NSString stringWithFormat:@" Team ID: %@.", team]
                            : @" Warning: could not parse P12 with OpenSSL (wrong password or need legacy ciphers). File was still saved — try Re-sign after IPA import.";
                        LCTVLog(@"p12 validate team=%@", team ?: @"(nil)");
                    }
                } @catch (NSException *ex) {
                    validateNote = [NSString stringWithFormat:@" Warning: P12 check threw %@.", ex.name];
                    LCTVLog(@"p12 validate exception %@", ex);
                }
            }
            NSString *html = ok
                ? [self htmlOk:[NSString stringWithFormat:@"Certificate saved (%@, %lu bytes).%@", fname, (unsigned long)file.length, validateNote]]
                : [self htmlErr:err.localizedDescription ?: @"save failed"];
            [self sendResponse:fd status:ok ? 200 : 500 contentType:@"text/html; charset=utf-8" body:[html dataUsingEncoding:NSUTF8StringEncoding]];
            return;
        }
        if ([method isEqual:@"POST"] && [path hasPrefix:@"/upload-ipa"]) {
            NSString *bnd = [self extractBoundary:contentType];
            NSData *file = nil; NSString *fname = nil; NSMutableDictionary *fields = [NSMutableDictionary new];
            NSString *perr = nil;
            [self parseMultipart:bodyData boundary:bnd fileData:&file fileName:&fname fields:fields error:&perr];
            if (!file.length) {
                [self sendResponse:fd status:400 contentType:@"text/html; charset=utf-8"
                              body:[[self htmlErr:perr ?: @"No .ipa in form"] dataUsingEncoding:NSUTF8StringEncoding]];
                return;
            }
            // Write to disk first for large IPAs then import
            NSString *tmp = [LCTVCachesDir() stringByAppendingPathComponent:[NSString stringWithFormat:@"upload-%@.ipa", NSUUID.UUID.UUIDString]];
            NSError *err = nil;
            if (![file writeToFile:tmp options:NSDataWritingAtomic error:&err]) {
                [self sendResponse:fd status:500 contentType:@"text/html; charset=utf-8" body:[[self htmlErr:err.localizedDescription] dataUsingEncoding:NSUTF8StringEncoding]];
                return;
            }
            // Free mapped multipart memory before unzip
            file = nil; bodyData = nil;
            NSString *bid = [LCTVAppManager.shared importIPAAtPath:tmp error:&err];
            [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
            NSString *html = bid
                ? [self htmlOk:[NSString stringWithFormat:@"Imported <code>%@</code>. On the TV: Reload → Launch.", bid]]
                : [self htmlErr:err.localizedDescription ?: @"import failed"];
            [self sendResponse:fd status:bid ? 200 : 500 contentType:@"text/html; charset=utf-8" body:[html dataUsingEncoding:NSUTF8StringEncoding]];
            return;
        }
        if ([method isEqual:@"POST"] && [path hasPrefix:@"/fetch-url"]) {
            NSString *bodyStr = [[NSString alloc] initWithData:bodyData encoding:NSUTF8StringEncoding] ?: @"";
            NSString *urlStr = nil;
            for (NSString *pair in [bodyStr componentsSeparatedByString:@"&"]) {
                NSArray *kv = [pair componentsSeparatedByString:@"="];
                if (kv.count >= 2 && [kv[0] isEqual:@"url"]) {
                    NSString *raw = [[kv subarrayWithRange:NSMakeRange(1, kv.count - 1)] componentsJoinedByString:@"="];
                    urlStr = [[raw stringByRemovingPercentEncoding] stringByReplacingOccurrencesOfString:@"+" withString:@" "];
                }
            }
            NSError *err = nil; NSString *bid = nil;
            if (urlStr.length) {
                LCTVLog(@"fetch IPA %@", urlStr);
                NSURL *url = [NSURL URLWithString:urlStr];
                NSString *tmp = [LCTVCachesDir() stringByAppendingPathComponent:[NSString stringWithFormat:@"fetch-%@.ipa", NSUUID.UUID.UUIDString]];
                // Stream download to disk
                NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingUncached error:&err];
                if (data && [data writeToFile:tmp atomically:YES]) {
                    bid = [LCTVAppManager.shared importIPAAtPath:tmp error:&err];
                }
                [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
            } else {
                err = [NSError errorWithDomain:@"LCTV" code:1 userInfo:@{NSLocalizedDescriptionKey:@"missing url"}];
            }
            NSString *html = bid ? [self htmlOk:[NSString stringWithFormat:@"Imported %@", bid]]
                                 : [self htmlErr:err.localizedDescription ?: @"fetch failed"];
            [self sendResponse:fd status:bid ? 200 : 500 contentType:@"text/html; charset=utf-8" body:[html dataUsingEncoding:NSUTF8StringEncoding]];
            return;
        }
        [self sendResponse:fd status:404 contentType:@"text/html; charset=utf-8" body:[[self htmlErr:@"not found"] dataUsingEncoding:NSUTF8StringEncoding]];
    } @finally {
        if (bodyPath) [[NSFileManager defaultManager] removeItemAtPath:bodyPath error:nil];
    }
}

@end
