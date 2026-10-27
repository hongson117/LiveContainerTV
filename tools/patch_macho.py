#!/usr/bin/env python3
"""Convert thin arm64 MH_EXECUTE → MH_DYLIB and ensure LC_ID_DYLIB exists."""
import os, struct, sys

def rnd8(v):
    return (v + 7) & ~7

def patch(path):
    data = bytearray(open(path, "rb").read())
    magic, = struct.unpack_from("<I", data, 0)
    assert magic == 0xFEEDFACF, f"need thin arm64, got {magic:#x}"
    filetype, ncmds, sizeofcmds, flags = struct.unpack_from("<IIII", data, 12)
    MH_DYLIB, MH_PIE, MH_NO_REEXPORTED = 6, 0x200000, 0x100000
    LC_SEGMENT_64, LC_ID_DYLIB, LC_LOAD_DYLINKER = 0x19, 0xD, 0xE

    struct.pack_into("<I", data, 12, MH_DYLIB)
    struct.pack_into("<I", data, 24, (flags | MH_NO_REEXPORTED) & ~MH_PIE)

    off = 32
    text_off = None
    has_id = False
    dylinker_off = None
    for _ in range(ncmds):
        cmd, csz = struct.unpack_from("<II", data, off)
        if cmd == LC_SEGMENT_64:
            name = data[off+8:off+24].split(b"\0", 1)[0]
            if name == b"__PAGEZERO":
                struct.pack_into("<QQ", data, off+24, 0x100000000 - 0x4000, 0x4000)
            if name == b"__TEXT":
                nsects = struct.unpack_from("<I", data, off+64)[0]
                for j in range(nsects):
                    so = off + 72 + j * 80
                    if data[so:so+16].split(b"\0", 1)[0] == b"__text":
                        text_off = struct.unpack_from("<I", data, so+48)[0]
        elif cmd == LC_ID_DYLIB:
            has_id = True
        elif cmd == LC_LOAD_DYLINKER:
            dylinker_off = off
        off += csz

    if not has_id:
        iname = os.path.basename(path).encode() + b"\0"
        id_size = rnd8(24 + len(iname))
        cmds_end = 32 + sizeofcmds
        free = (text_off if text_off is not None else cmds_end) - cmds_end
        placed = False
        if free >= id_size:
            blob = bytearray(id_size)
            struct.pack_into("<II", blob, 0, LC_ID_DYLIB, id_size)
            struct.pack_into("<I", blob, 8, 24)
            struct.pack_into("<III", blob, 12, 1, 0x10000, 0x10000)
            blob[24:24+len(iname)] = iname
            data[cmds_end:cmds_end+id_size] = blob
            struct.pack_into("<I", data, 16, ncmds + 1)
            struct.pack_into("<I", data, 20, sizeofcmds + id_size)
            print(f"inserted LC_ID_DYLIB size={id_size} free={free}")
            placed = True
        elif dylinker_off is not None:
            cmd, csz = struct.unpack_from("<II", data, dylinker_off)
            if csz >= 24 + len(iname):
                struct.pack_into("<II", data, dylinker_off, LC_ID_DYLIB, csz)
                struct.pack_into("<I", data, dylinker_off + 8, 24)
                struct.pack_into("<III", data, dylinker_off + 12, 1, 0x10000, 0x10000)
                data[dylinker_off+24:dylinker_off+csz] = b"\0" * (csz - 24)
                data[dylinker_off+24:dylinker_off+24+len(iname)] = iname
                print("replaced LC_LOAD_DYLINKER with LC_ID_DYLIB")
                placed = True
        if not placed:
            print(f"WARNING: could not add LC_ID_DYLIB (free={free})")

    open(path, "wb").write(data)
    print("patched", path)

if __name__ == "__main__":
    patch(sys.argv[1])
