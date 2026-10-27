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
