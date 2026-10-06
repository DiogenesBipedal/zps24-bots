#!/usr/bin/env python3
"""Translate ZPS 3.x Linux vtable offsets in SourceMod-style gamedata to ZPS 2.4.

For every Offsets entry, take the 3.x Linux index, look up which virtual function sits
there in the 3.x class vtable, and find the same function in the matching 2.4 class.
Usage: port_gamedata.py OLD.so NEW.so in.txt out.txt
"""
import re, sys, subprocess
sys.path.insert(0, __file__.rsplit('/', 1)[0])
from vtable import Binary, demangle

# 3.x class -> 2.4 class used to resolve each kind of offset.
PAIRS = {'player': ('CZP_Player', 'CHL2MP_Player'),
         'weapon': ('CBaseCombatWeapon', 'CBaseCombatWeapon'),
         'filter': ('CBaseFilter', 'CBaseFilter')}
WEAPON_KEYS = {'Reload'}
def kind_of(key):
    if key.startswith('CBaseFilter::'): return 'filter'
    if key in WEAPON_KEYS: return 'weapon'
    return 'player'

def tokenize(s):
    s = re.sub(r'//[^\n]*', '', re.sub(r'/\*.*?\*/', '', s, flags=re.S))
    return re.findall(r'"(?:[^"\\]|\\.)*"|[{}]', s)

def parse(tokens, i=0):
    out = []
    while i < len(tokens):
        t = tokens[i]
        if t == '}': return out, i + 1
        key = t.strip('"'); nxt = tokens[i + 1]
        if nxt == '{':
            sub, i = parse(tokens, i + 2); out.append((key, sub))
        else:
            out.append((key, nxt.strip('"'))); i += 2
    return out, i

def dump(node, ind=0):
    lines = []
    for k, v in node:
        if isinstance(v, list):
            lines += ['\t' * ind + f'"{k}"', '\t' * ind + '{'] + dump(v, ind + 1) + ['\t' * ind + '}']
        else:
            lines.append('\t' * ind + f'"{k}"\t\t"{v}"')
    return lines

def short(d): return d.split('(')[0].split('::')[-1]

def main(old_so, new_so, src, dst):
    old, new = Binary(old_so), Binary(new_so)
    tabs = {k: (demangle(old.vtable(oc)), demangle(new.vtable(nc))) for k, (oc, nc) in PAIRS.items()}
    tree, _ = parse(tokenize(open(src).read()))
    report = []
    def walk(node, in_offsets=False):
        drop = []
        for k, v in node:
            if isinstance(v, list):
                if in_offsets and any(kk == 'linux' for kk, _ in v):
                    lin = dict(v)['linux']
                    for oldvt, newvt in [tabs[kind_of(k)]]:
                        idx = int(lin)
                        if idx < len(oldvt):
                            fn = short(oldvt[idx])
                            hits = [i for i, d in enumerate(newvt) if short(d) == fn]
                            if hits:
                                for j, (kk, vv) in enumerate(v):
                                    if kk == 'linux': v[j] = ('linux', str(hits[0]))
                                    if kk == 'windows': v[j] = ('windows', str(hits[0] - 1))
                                report.append(f'{k:32} {lin:>4} -> {hits[0]:>4}  {oldvt[idx].split("(")[0]}')
                                break
                    else:
                        report.append(f'{k:32} {lin:>4} -> dropped (no such function in 2.4)')
                        drop.append(k); continue
                walk(v, k == 'Offsets')
        node[:] = [(k, v) for k, v in node if k not in drop]
    walk(tree)
    open(dst, 'w').write('\n'.join(dump(tree)) + '\n')
    print('\n'.join(report))

if __name__ == '__main__':
    main(*sys.argv[1:5])
