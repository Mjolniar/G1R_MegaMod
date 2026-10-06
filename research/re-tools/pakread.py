"""Reads files out of an Unreal pak (version 11, index not encrypted), read only.

    python pakread.py <file.pak> --list [substring]
    python pakread.py <file.pak> --oodle <oo2core_9_win64.dll> --out <dir> <path in pak> [...]

The game's pak (G1R-Windows.pak) holds the non-asset files (config .ini, loose data); the assets are in the
IoStore files next to it (.ucas/.utoc), which this does not read. Entries compressed with Oodle need the Oodle DLL
(oo2core_9_win64.dll; the game links Oodle into its program, other installed games bring the DLL). Windows Python
(ctypes loads the DLL). Nothing is written except into --out.
"""
import argparse
import ctypes
import os
import struct
import sys

MAGIC = b"\xe1\x12\x6f\x5a"


def fstring(buf, o):
    n, = struct.unpack_from("<i", buf, o)
    o += 4
    if n == 0:
        return "", o
    if n < 0:
        return buf[o:o - 2 * n].decode("utf-16-le").rstrip("\0"), o - 2 * n
    return buf[o:o + n].decode("latin-1").rstrip("\0"), o + n


class Pak:
    def __init__(self, path):
        self.f = open(path, "rb")
        f = self.f
        f.seek(0, 2)
        size = f.tell()
        f.seek(size - 512)
        tail = f.read(512)
        i = tail.rfind(MAGIC)
        if i < 0:
            raise SystemExit("no pak footer")
        self.version, = struct.unpack_from("<i", tail, i + 4)
        index_offset, index_size = struct.unpack_from("<qq", tail, i + 8)
        if tail[i - 1] != 0:
            raise SystemExit("the index is encrypted")
        if self.version < 10:
            raise SystemExit("pak version %d: only 10 and later are read here" % self.version)
        names = tail[i + 24 + 20:i + 24 + 20 + 5 * 32]
        self.methods = [None] + [names[k * 32:(k + 1) * 32].rstrip(b"\0").decode() for k in range(5)]
        f.seek(index_offset)
        idx = f.read(index_size)
        o = 0
        self.mount, o = fstring(idx, o)
        self.count, = struct.unpack_from("<i", idx, o)
        o += 4 + 8
        has_ph, = struct.unpack_from("<I", idx, o)
        o += 4
        if has_ph:
            o += 16 + 20
        has_fd, = struct.unpack_from("<I", idx, o)
        o += 4
        if not has_fd:
            raise SystemExit("the pak has no full directory index")
        fd_offset, fd_size = struct.unpack_from("<qq", idx, o)
        o += 16 + 20
        enc_size, = struct.unpack_from("<i", idx, o)
        o += 4
        self.encoded = idx[o:o + enc_size]
        f.seek(fd_offset)
        fd = f.read(fd_size)
        o = 0
        dirs, = struct.unpack_from("<i", fd, o)
        o += 4
        self.files = {}
        for _ in range(dirs):
            d, o = fstring(fd, o)
            n, = struct.unpack_from("<i", fd, o)
            o += 4
            for _ in range(n):
                name, o = fstring(fd, o)
                at, = struct.unpack_from("<i", fd, o)
                o += 4
                self.files[d + name] = at

    def entry(self, name):
        at = self.files[name]
        if at < 0:
            raise SystemExit("%s: an entry that is not encoded (not read here)" % name)
        enc = self.encoded
        v, = struct.unpack_from("<I", enc, at)
        q = at + 4

        def take(wide):
            nonlocal q
            if wide:
                x, = struct.unpack_from("<I", enc, q)
                q += 4
            else:
                x, = struct.unpack_from("<Q", enc, q)
                q += 8
            return x
        e = {"method": (v >> 23) & 0x3F, "encrypted": bool(v & (1 << 22)), "blocks": (v >> 6) & 0xFFFF}
        e["offset"] = take(v & (1 << 31))
        e["size_raw"] = take(v & (1 << 30))
        e["size"] = take(v & (1 << 29)) if e["method"] else e["size_raw"]
        e["block_size"] = e["size_raw"] if e["size_raw"] < 65536 else ((v & 0x3F) << 11)
        return e

    def read(self, name, oodle=None):
        e = self.entry(name)
        if e["encrypted"]:
            raise SystemExit("%s is encrypted" % name)
        f = self.f
        f.seek(e["offset"])
        head = f.read(8 + 8 + 8 + 4 + 20 + 4 + 16 * max(1, e["blocks"]) + 5)
        q = 24
        method, = struct.unpack_from("<I", head, q)
        q += 4 + 20
        if method == 0:
            f.seek(e["offset"] + q + 1 + 4)
            return f.read(e["size_raw"])
        if self.methods[method] != "Oodle":
            raise SystemExit("%s: compression %s is not read here" % (name, self.methods[method]))
        if oodle is None:
            raise SystemExit("%s is compressed with Oodle: give --oodle" % name)
        n, = struct.unpack_from("<i", head, q)
        q += 4
        blocks = [struct.unpack_from("<qq", head, q + 16 * k) for k in range(n)]
        out, left = [], e["size_raw"]
        for start, end in blocks:
            f.seek(e["offset"] + start)
            packed = f.read(end - start)
            raw = min(left, e["block_size"])
            buf = ctypes.create_string_buffer(raw)
            got = oodle(packed, len(packed), buf, raw, 1, 0, 0, None, 0, None, None, None, 0, 3)
            if got != raw:
                raise SystemExit("%s: Oodle gave %d of %d bytes" % (name, got, raw))
            out.append(buf.raw)
            left -= raw
        return b"".join(out)


def load_oodle(path):
    dll = ctypes.CDLL(path)
    fn = dll.OodleLZ_Decompress
    fn.restype = ctypes.c_ssize_t
    fn.argtypes = [ctypes.c_void_p, ctypes.c_ssize_t, ctypes.c_void_p, ctypes.c_ssize_t, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                   ctypes.c_void_p, ctypes.c_ssize_t, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ssize_t, ctypes.c_int]
    return fn


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pak")
    ap.add_argument("--list", nargs="?", const="", metavar="SUBSTRING")
    ap.add_argument("--oodle")
    ap.add_argument("--out")
    ap.add_argument("names", nargs="*")
    a = ap.parse_args()
    pak = Pak(a.pak)
    if a.list is not None:
        for name in sorted(pak.files):
            if a.list.lower() in name.lower():
                e = pak.entry(name) if pak.files[name] >= 0 else None
                print(name, e["size_raw"] if e else "?", pak.methods[e["method"]] if e and e["method"] else "")
        return 0
    if not a.out or not a.names:
        ap.error("give --out and the paths to read (or --list)")
    oodle = load_oodle(a.oodle) if a.oodle else None
    os.makedirs(a.out, exist_ok=True)
    for name in a.names:
        data = pak.read(name, oodle)
        dst = os.path.join(a.out, name.replace("/", "__"))
        with open(dst, "wb") as f:
            f.write(data)
        print("wrote", dst, len(data))
    return 0


if __name__ == "__main__":
    sys.exit(main())
