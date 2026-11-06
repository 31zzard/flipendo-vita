#!/usr/bin/env python3
# Reads a Vita crash dump (ux0:data/*.psp2dmp, or .psp2dmp.tmp when it was not finished: a gzip'd ELF core) and prints every thread
# with its stop reason, pc, lr and sp, the ELF addresses of the ones in flipendo's code and their functions (addr2line, from the
# VitaSDK in $VITASDK or /usr/local/vitasdk). Run it BEFORE rebuilding: the ELF must be the build that crashed.
#   python3 vita/tools/psp2core.py <dump> vita/build/flipendo
import gzip, os, struct, subprocess, sys

STOP = {0: "running/waiting", 0x30002: "undefined instruction", 0x30003: "prefetch abort", 0x30004: "data abort",
        0x60080: "division by zero"}

def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]

def notes_of(core):
    phoff, phnum, phes = u32(core, 28), struct.unpack_from("<H", core, 44)[0], struct.unpack_from("<H", core, 42)[0]
    notes = {}
    for i in range(phnum):
        t, off, va, pa, fs, ms, fl, al = struct.unpack_from("<8I", core, phoff + i * phes)
        if t != 4 or off + fs > len(core):
            continue
        p = off
        while p + 12 <= off + fs:
            nsz, dsz, _ = struct.unpack_from("<3I", core, p)
            name = core[p + 12:p + 12 + nsz].rstrip(b"\0").decode("latin1")
            dp = p + 12 + ((nsz + 3) & ~3)
            notes[name] = core[dp:dp + dsz]
            p = dp + ((dsz + 3) & ~3)
    return notes

def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__ or "usage: psp2core.py <dump> [elf]")
    raw = open(sys.argv[1], "rb").read()
    try:
        core = gzip.decompress(raw)
    except Exception:
        import zlib
        core = zlib.decompressobj(16 + zlib.MAX_WBITS).decompress(raw)   # an unfinished dump: what there is
    elf = sys.argv[2] if len(sys.argv) > 2 else None
    notes = notes_of(core)

    mods = {}
    m = notes.get("MODULE_INFO", b"")
    if m:
        off = 8
        for _ in range(u32(m, 4)):
            name = m[off + 0x24:off + 0x24 + 30].split(b"\0")[0].decode("latin1")
            nseg = u32(m, off + 0x4c)
            so = off + 0x50
            segs = []
            for _ in range(nseg):
                segs.append((u32(m, so + 8), u32(m, so + 12)))
                so += 0x14
            mods[name] = segs
            off = so + 0x10
    text_base = mods.get("flipendo", [(0x81000000, 0)])[0][0]

    threads = {}
    t = notes.get("THREAD_INFO", b"")
    off = 8
    for _ in range(u32(t, 4) if t else 0):
        size = u32(t, off)
        threads[u32(t, off + 4)] = (t[off + 8:off + 40].split(b"\0")[0].decode("latin1"), u32(t, off + 0x74))
        off += size

    tool = os.path.join(os.environ.get("VITASDK", "/usr/local/vitasdk"), "bin", "arm-vita-eabi-addr2line")
    def where(addr):
        if not elf or not (text_base <= addr < text_base + 0x2000000):
            return ""
        e = addr - text_base + 0x81000000
        try:
            out = subprocess.run([tool, "-f", "-C", "-e", elf, hex(e)], capture_output=True, text=True).stdout.split("\n")
            return " = ELF %#x %s %s" % (e, out[0], out[1] if len(out) > 1 else "")
        except OSError:
            return " = ELF %#x" % e

    r = notes.get("THREAD_REG_INFO", b"")
    off = 8
    for _ in range(u32(r, 4) if r else 0):
        size = u32(r, off)
        tid = u32(r, off + 4)
        regs = [u32(r, off + 8 + 4 * k) for k in range(16)]
        name, stop = threads.get(tid, ("?", 0))
        print("%s (%#x): %s" % (name, tid, STOP.get(stop, hex(stop))))
        for label, value in (("pc", regs[15]), ("lr", regs[14])):
            print("   %s %#x%s" % (label, value, where(value & ~1)))
        print("   sp %#x r0 %#x r1 %#x r4 %#x" % (regs[13], regs[0], regs[1], regs[4]))
        off += size

if __name__ == "__main__":
    main()
