# Convert a thin arm64 MH_EXECUTE into MH_DYLIB (same idea as LiveContainer's LCPatchExecSlice).
import struct, sys
p = sys.argv[1]; d = bytearray(open(p,'rb').read())
magic, cpu, sub, ft, ncmds, sz, flags, _ = struct.unpack_from('<IiiIIIII', d, 0)
assert magic == 0xfeedfacf, 'need thin arm64'
MH_DYLIB, MH_PIE, MH_NO_REEXPORTED_DYLIBS = 6, 0x200000, 0x100000
struct.pack_into('<I', d, 12, MH_DYLIB)
struct.pack_into('<I', d, 24, (flags | MH_NO_REEXPORTED_DYLIBS) & ~MH_PIE)
off = 32
for _ in range(ncmds):
    cmd, csz = struct.unpack_from('<II', d, off)
    if cmd == 0x19 and d[off+8:off+18].rstrip(b'\0') == b'__PAGEZERO':
        struct.pack_into('<QQ', d, off+24, 0x100000000 - 0x4000, 0x4000)
    off += csz
open(p,'wb').write(d); print('patched', p)
