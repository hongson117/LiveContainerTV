#import "LCTVMachOPatch.h"
#import "LCTVCommon.h"
#import <mach-o/loader.h>
#import <mach-o/fat.h>

static uint32_t rnd8(uint32_t v) { return (v + 7) & ~7u; }

BOOL LCTVPatchExecToDylib(NSString *path, NSError **error) {
    NSMutableData *data = [NSMutableData dataWithContentsOfFile:path options:0 error:error];
    if (!data) return NO;
    uint8_t *bytes = data.mutableBytes;
    size_t len = data.length;
    if (len < sizeof(struct mach_header_64)) { if (error) *error = [NSError errorWithDomain:@"LCTV" code:1 userInfo:@{NSLocalizedDescriptionKey:@"file too small"}]; return NO; }
    uint32_t magic = *(uint32_t *)bytes;
    if (magic == FAT_CIGAM || magic == FAT_MAGIC) {
        if (error) *error = [NSError errorWithDomain:@"LCTV" code:2 userInfo:@{NSLocalizedDescriptionKey:@"fat binary not supported yet; use thin arm64"}];
        return NO;
    }
    if (magic != MH_MAGIC_64) {
        if (error) *error = [NSError errorWithDomain:@"LCTV" code:3 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"bad magic %08x", magic]}];
        return NO;
    }
    struct mach_header_64 *hdr = (struct mach_header_64 *)bytes;
    hdr->filetype = MH_DYLIB;
    hdr->flags = (hdr->flags | MH_NO_REEXPORTED_DYLIBS) & ~MH_PIE;

    uint8_t *cmdp = bytes + sizeof(*hdr);
    uint32_t textOff = 0; BOOL hasId = NO; struct load_command *dylinker = NULL;
    for (uint32_t i = 0; i < hdr->ncmds; i++) {
        struct load_command *lc = (struct load_command *)cmdp;
        if (lc->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *seg = (void *)lc;
            if (!strncmp(seg->segname, "__PAGEZERO", 16)) {
                seg->vmaddr = 0x100000000ULL - 0x4000ULL;
                seg->vmsize = 0x4000;
            }
            if (!strncmp(seg->segname, "__TEXT", 16)) {
                struct section_64 *sect = (void *)(seg + 1);
                for (uint32_t j = 0; j < seg->nsects; j++) {
                    if (!strncmp(sect[j].sectname, "__text", 16)) textOff = sect[j].offset;
                }
            }
        } else if (lc->cmd == LC_ID_DYLIB) hasId = YES;
        else if (lc->cmd == LC_LOAD_DYLINKER) dylinker = lc;
        cmdp += lc->cmdsize;
    }

    if (!hasId) {
        const char *iname = path.lastPathComponent.UTF8String;
        uint32_t nameLen = (uint32_t)strlen(iname) + 1;
        uint32_t idSize = rnd8(24 + nameLen);
        uint32_t cmdsEnd = (uint32_t)sizeof(struct mach_header_64) + hdr->sizeofcmds;
        uint32_t freeSpace = (textOff ? textOff : cmdsEnd) - cmdsEnd;
        if (freeSpace >= idSize) {
            struct dylib_command *dc = (void *)(bytes + cmdsEnd);
            memset(dc, 0, idSize);
            dc->cmd = LC_ID_DYLIB;
            dc->cmdsize = idSize;
            dc->dylib.name.offset = 24;
            dc->dylib.timestamp = 1;
            dc->dylib.current_version = 0x10000;
            dc->dylib.compatibility_version = 0x10000;
            memcpy((uint8_t *)dc + 24, iname, nameLen);
            hdr->ncmds += 1;
            hdr->sizeofcmds += idSize;
            LCTVLog(@"patch: inserted LC_ID_DYLIB size=%u", idSize);
        } else if (dylinker && dylinker->cmdsize >= 24 + nameLen) {
            struct dylib_command *dc = (void *)dylinker;
            uint32_t csz = dylinker->cmdsize;
            memset(dc, 0, csz);
            dc->cmd = LC_ID_DYLIB;
            dc->cmdsize = csz;
            dc->dylib.name.offset = 24;
            dc->dylib.timestamp = 1;
            dc->dylib.current_version = 0x10000;
            dc->dylib.compatibility_version = 0x10000;
            memcpy((uint8_t *)dc + 24, iname, nameLen);
            LCTVLog(@"patch: replaced LC_LOAD_DYLINKER with LC_ID_DYLIB");
        } else {
            LCTVLog(@"patch: WARNING no space for LC_ID_DYLIB free=%u", freeSpace);
        }
    }
    if (![data writeToFile:path options:NSDataWritingAtomic error:error]) return NO;
    LCTVLog(@"patch: OK %@", path);
    return YES;
}

#pragma mark - Load path fixups (rpath / @executable_path)

static NSMutableArray *gPendingRpaths; // rpaths that didn't fit in place -> appended as new LC_RPATH
static BOOL rewriteStr(uint8_t *cmdBase, uint32_t cmdsize, uint32_t strOff, NSString *from, NSString *to, NSString *tag) {
    char *s = (char *)cmdBase + strOff;
    size_t cap = cmdsize - strOff;
    NSString *cur = [[NSString alloc] initWithBytes:s length:strnlen(s, cap) encoding:NSUTF8StringEncoding];
    if (![cur hasPrefix:from]) return NO;
    NSString *nw = [to stringByAppendingString:[cur substringFromIndex:from.length]];
    const char *n = nw.UTF8String; size_t nl = strlen(n) + 1;
    if (nl > cap) {
        if ([tag isEqual:@"rpath"]) { [gPendingRpaths addObject:nw]; LCTVLog(@"fixup: rpath '%@' too long in place -> will append '%@'", cur, nw); }
        else LCTVLog(@"fixup: no room %@ '%@' -> '%@' (covered by framework preload)", tag, cur, nw);
        return NO;
    }
    memset(s, 0, cap); memcpy(s, n, nl);
    LCTVLog(@"fixup: %@ '%@' -> '%@'", tag, cur, nw);
    return YES;
}

BOOL LCTVFixGuestLoadPaths(NSString *path, NSString *relToAppRoot, BOOL addLoaderRpath, NSError **error) {
    NSMutableData *data = [NSMutableData dataWithContentsOfFile:path options:0 error:error];
    if (!data || data.length < sizeof(struct mach_header_64)) return NO;
    uint8_t *bytes = data.mutableBytes;
    if (*(uint32_t *)bytes != MH_MAGIC_64) { LCTVLog(@"fixup: skip non-thin %@", path.lastPathComponent); return YES; }
    struct mach_header_64 *hdr = (void *)bytes;
    // @executable_path inside the guest means the guest .app root
    NSString *exeRepl = relToAppRoot.length ? [@"@loader_path/" stringByAppendingString:relToAppRoot] : @"@loader_path";
    uint8_t *p = bytes + sizeof(*hdr);
    uint32_t firstSect = UINT32_MAX; BOOL hasLoaderFw = NO; BOOL changed = NO;
    gPendingRpaths = [NSMutableArray new];
    for (uint32_t i = 0; i < hdr->ncmds; i++) {
        struct load_command *lc = (void *)p;
        if (lc->cmd == LC_RPATH) {
            struct rpath_command *rc = (void *)lc;
            const char *s = (char *)lc + rc->path.offset;
            if (!strcmp(s, "@loader_path/Frameworks")) hasLoaderFw = YES;
            changed |= rewriteStr(p, lc->cmdsize, rc->path.offset, @"@executable_path", exeRepl, @"rpath");
            if (!strcmp((char *)lc + rc->path.offset, "@loader_path/Frameworks")) hasLoaderFw = YES;
        } else if (lc->cmd == LC_LOAD_DYLIB || lc->cmd == LC_LOAD_WEAK_DYLIB || lc->cmd == LC_REEXPORT_DYLIB || lc->cmd == LC_LAZY_LOAD_DYLIB) {
            struct dylib_command *dc = (void *)lc;
            changed |= rewriteStr(p, lc->cmdsize, dc->dylib.name.offset, @"@executable_path", exeRepl, @"dylib");
        } else if (lc->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *seg = (void *)lc;
            struct section_64 *sect = (void *)(seg + 1);
            for (uint32_t j = 0; j < seg->nsects; j++)
                if (sect[j].offset && sect[j].offset < firstSect) firstSect = sect[j].offset;
        }
        p += lc->cmdsize;
    }
    NSMutableArray *toAdd = [gPendingRpaths mutableCopy];
    if (addLoaderRpath && !hasLoaderFw) [toAdd addObject:@"@loader_path/Frameworks"];
    for (NSString *rpS in toAdd) {
        const char *rp = rpS.UTF8String;
        uint32_t sz = rnd8((uint32_t)sizeof(struct rpath_command) + (uint32_t)strlen(rp) + 1);
        uint32_t end = (uint32_t)sizeof(*hdr) + hdr->sizeofcmds;
        uint32_t freeSp = (firstSect == UINT32_MAX ? end : firstSect) - end;
        if (freeSp >= sz) {
            struct rpath_command *rc = (void *)(bytes + end);
            memset(rc, 0, sz);
            rc->cmd = LC_RPATH; rc->cmdsize = sz; rc->path.offset = sizeof(struct rpath_command);
            strcpy((char *)rc + sizeof(struct rpath_command), rp);
            hdr->ncmds++; hdr->sizeofcmds += sz; changed = YES;
            LCTVLog(@"fixup: added LC_RPATH %s to %@", rp, path.lastPathComponent);
        } else {
            LCTVLog(@"fixup: no header space for LC_RPATH %s (free=%u) in %@ — relying on framework preload", rp, freeSp, path.lastPathComponent);
        }
    }
    if (changed && ![data writeToFile:path options:NSDataWritingAtomic error:error]) return NO;
    return YES;
}
