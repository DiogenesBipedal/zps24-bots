#!/usr/bin/env python3
"""Make a ZPS 3.x map (Source 2013, BSP v20) load on the ZPS 2.4 server and client (Source 2007).

    bsp_to_24.py in.bsp out.bsp [--physprops]

What it changes (in a copy; the input is never touched):
  * static props: game lump 'sprp' version 10 (72-byte records) -> version 6 (64 bytes). The 2007
    engine segfaults on v10 while loading the map. A v10 record starts with the exact v6 fields up
    to ForcedFadeScale; the rest (CPU/GPU levels, diffuse modulation, extra flags) is replaced by
    v6's MinDXLevel/MaxDXLevel = 0.
  * entities: 3.x item classes that 2.4 doesn't have are renamed to their 2.4 counterparts
    (rifle/shotgun/revolver ammo, barricade ammo -> hammer, pills -> health vial). Other 3.x-only
    entities (item_armor, prop_itemcrate, weapons_limit, ...) are left; 2.4 skips them.
  * physics props whose 2.4 model crashes CPhysicsPropMultiplayer::Spawn are dropped.
  * --physprops: prop_physics_multiplayer -> prop_physics. Needed when a map has many of them
    (zpo_lake_of_the_dead: crashes in CPhysicsPropMultiplayer::Spawn past ~80 props).

The client needs the same converted file (same CRC), in zps/maps of the 2.4 install.
"""
import re
import struct
import sys

RENAME = {
    'item_ammo_rifle': 'item_ammo_rifle_clip',
    'item_ammo_shotgun': 'item_ammo_shotgun_clip',
    'item_ammo_revolver': 'item_ammo_357',
    'item_ammo_barricade': 'weapon_barricade',
    'item_ammo_barricadepile': 'weapon_barricade',
    'item_pills': 'item_healthvial',
}
BAD_PHYS_MODELS = ['models/gibs/airboat_broken_engine.mdl']


def lump(b, i):
    return struct.unpack_from('<ii', b, 8 + 16 * i)


def append(b, data):
    while len(b) % 4:
        b += b'\0'
    base = len(b)
    b += data
    return base


def static_props_to_v6(b):
    ofs, _ = lump(b, 35)
    n = struct.unpack_from('<i', b, ofs)[0]
    entries = []
    changed = False
    for i in range(n):
        gid, flags, ver, go, gl = struct.unpack_from('<4sHHii', b, ofs + 4 + 16 * i)
        d = bytes(b[go:go + gl])
        if gid[::-1] == b'sprp' and ver == 10:
            p = 0
            names = struct.unpack_from('<i', d, p)[0]; p += 4 + 128 * names
            leaves = struct.unpack_from('<i', d, p)[0]; p += 4 + 2 * leaves
            count = struct.unpack_from('<i', d, p)[0]; p += 4
            size = (len(d) - p) // count if count else 72
            out = bytearray(d[:p])
            for k in range(count):
                out += d[p + k * size:p + k * size + 60] + struct.pack('<HH', 0, 0)
            d, ver, changed = bytes(out), 6, True
            print('static props: %d records v10 (%d bytes) -> v6' % (count, size))
        entries.append((gid, flags, ver, d))
    if not changed:
        return
    # Game lump offsets are absolute: write the whole block again at the end of the file.
    head = 4 + 16 * len(entries)
    while len(b) % 4:
        b += b'\0'
    base = len(b)
    blob, body = bytearray(struct.pack('<i', len(entries))), bytearray()
    for gid, flags, ver, d in entries:
        blob += struct.pack('<4sHHii', gid, flags, ver, base + head + len(body), len(d))
        body += d
        while len(body) % 4:
            body += b'\0'
    b += blob + body
    struct.pack_into('<ii', b, 8 + 16 * 35, base, len(blob) + len(body))


def fix_entities(b, physprops):
    ofs, ln = lump(b, 0)
    text = b[ofs:ofs + ln].rstrip(b'\0').decode('latin1')
    for old, new in RENAME.items():
        k = text.count('"classname" "%s"' % old)
        if k:
            print('entities: %d x %s -> %s' % (k, old, new))
            text = text.replace('"classname" "%s"' % old, '"classname" "%s"' % new)
    blocks = re.findall(r'\{[^{}]*\}', text)
    keep = [e for e in blocks
            if not ('prop_physics' in e and any('"model" "%s"' % m in e.lower() for m in BAD_PHYS_MODELS))]
    if len(keep) != len(blocks):
        print('entities: dropped %d crashing physics prop(s)' % (len(blocks) - len(keep)))
    text = '\n'.join(keep) + '\n'
    if physprops:
        k = text.count('"classname" "prop_physics_multiplayer"')
        text = text.replace('"classname" "prop_physics_multiplayer"', '"classname" "prop_physics"')
        print('entities: %d x prop_physics_multiplayer -> prop_physics' % k)
    new = text.encode('latin1') + b'\0'
    if len(new) <= ln:
        b[ofs:ofs + ln] = new + b'\0' * (ln - len(new))
        struct.pack_into('<i', b, 12, len(new))
    else:
        base = append(b, new)
        struct.pack_into('<ii', b, 8, base, len(new))


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if len(args) != 2:
        sys.exit(__doc__)
    b = bytearray(open(args[0], 'rb').read())
    if b[:4] != b'VBSP' or struct.unpack_from('<i', b, 4)[0] != 20:
        sys.exit('not a v20 BSP')
    static_props_to_v6(b)
    fix_entities(b, '--physprops' in sys.argv)
    open(args[1], 'wb').write(b)
    print('wrote', args[1])


if __name__ == '__main__':
    main()
