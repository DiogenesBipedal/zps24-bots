#!/usr/bin/env python3
"""Turn a map's daylight into night: patch light_environment (and the sky) in a copy of the BSP,
ready for VRAD to bake the lighting again.

    bsp_relight.py in.bsp out.bsp [--light "R G B brightness"] [--ambient "R G B brightness"]
                                  [--sky skyname]
    bsp_relight.py --to-v10 in.bsp out.bsp    static props v6 -> v10, for the SDK 2013 VRAD
    bsp_relight.py --to-v6 in.bsp out.bsp     and back after the bake, for 2.4

Source bakes the sun and sky light into the lightmaps, and on most maps every light shares light
style 0 with the sun, so a server can't dim the outside at runtime. This edits the entity lump
only (light_environment's _light/_lightHDR and _ambient/_ambientHDR, worldspawn's skyname); run
VRAD on the output afterwards (docs/MANUAL.md, "Night maps"). Lights inside the houses keep their
values, so after the bake the outside is dark and the inside lit.

Defaults: a faint blue moonlight and very low ambient. The client needs the same file (same CRC)
in zps/maps of the 2.4 install.
"""
import argparse
import re
import struct
import sys

from bsp_to_24 import append, lump, static_props_to_v6, write_game_lumps


def set_key(block, key, value):
    pat = r'"%s" "[^"]*"' % re.escape(key)
    if re.search(pat, block):
        return re.sub(pat, '"%s" "%s"' % (key, value), block)
    return block[:-1].rstrip() + ' "%s" "%s" }' % (key, value)


def static_props_to_v10(b):
    """2.4 maps have static prop lump v6 (64-byte records); the Source SDK 2013 VRAD only loads
    v10 ("stale map version"). v10 = the same first 60 bytes, then CPU/GPU levels (0 = all),
    diffuse modulation (white) and extra flags (none): 72 bytes."""
    ofs, _ = lump(b, 35)
    n = struct.unpack_from('<i', b, ofs)[0]
    entries, changed = [], False
    for i in range(n):
        gid, flags, ver, go, gl = struct.unpack_from('<4sHHii', b, ofs + 4 + 16 * i)
        d = bytes(b[go:go + gl])
        if gid[::-1] == b'sprp' and ver == 6:
            p = 0
            names = struct.unpack_from('<i', d, p)[0]; p += 4 + 128 * names
            leaves = struct.unpack_from('<i', d, p)[0]; p += 4 + 2 * leaves
            count = struct.unpack_from('<i', d, p)[0]; p += 4
            out = bytearray(d[:p])
            for k in range(count):
                out += d[p + k * 64:p + k * 64 + 60] + bytes(4) + b'\xff' * 4 + bytes(4)
            d, ver, changed = bytes(out), 10, True
            print('static props: %d records v6 -> v10' % count)
        entries.append((gid, flags, ver, d))
    if changed:
        write_game_lumps(b, entries)


def convert(mode, src, dst):
    b = bytearray(open(src, 'rb').read())
    (static_props_to_v10 if mode == '--to-v10' else static_props_to_v6)(b)
    open(dst, 'wb').write(b)
    print('wrote', dst)


def main():
    if len(sys.argv) == 4 and sys.argv[1] in ('--to-v10', '--to-v6'):
        return convert(*sys.argv[1:])
    ap = argparse.ArgumentParser(usage=__doc__)
    ap.add_argument('src')
    ap.add_argument('dst')
    ap.add_argument('--light', default='60 75 120 6')
    ap.add_argument('--ambient', default='30 38 60 2')
    ap.add_argument('--sky', default='sky_night01')
    a = ap.parse_args()
    b = bytearray(open(a.src, 'rb').read())
    if b[:4] != b'VBSP' or struct.unpack_from('<i', b, 4)[0] not in (19, 20):
        sys.exit('not a v19/v20 BSP')
    ofs, ln = lump(b, 0)
    text = b[ofs:ofs + ln].rstrip(b'\0').decode('latin1')
    blocks = re.findall(r'\{[^{}]*\}', text)
    suns = 0
    for i, e in enumerate(blocks):
        if '"classname" "light_environment"' in e:
            for k in ('_light', '_lightHDR'):
                e = set_key(e, k, a.light)
            for k in ('_ambient', '_ambientHDR'):
                e = set_key(e, k, a.ambient)
            blocks[i] = e
            suns += 1
        elif '"classname" "worldspawn"' in e and a.sky:
            blocks[i] = set_key(e, 'skyname', a.sky)
    if not suns:
        sys.exit('no light_environment: nothing to relight')
    new = ('\n'.join(blocks) + '\n').encode('latin1') + b'\0'
    if len(new) <= ln:
        b[ofs:ofs + ln] = new + b'\0' * (ln - len(new))
        struct.pack_into('<i', b, 12, len(new))
    else:
        base = append(b, new)
        struct.pack_into('<ii', b, 8, base, len(new))
    open(a.dst, 'wb').write(b)
    print('relit %d light_environment(s): light %s, ambient %s, sky %s -> %s' % (suns, a.light, a.ambient, a.sky, a.dst))
    print('now bake: vrad -game <2.4 zps dir> %s' % a.dst)


if __name__ == '__main__':
    main()
