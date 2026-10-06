#!/usr/bin/env python3
"""Dump Itanium-ABI vtables from an unstripped 32-bit Linux Source server binary.

vtable.py server.so CLASS            -> print "index symbol" for every virtual
vtable.py server.so CLASS --find SYM -> print the index of SYM (demangled name prefix)
"""
import sys, struct, subprocess
from elftools.elf.elffile import ELFFile
from elftools.elf.relocation import RelocationSection

class Binary:
    def __init__(self, path):
        self.f = open(path, 'rb'); self.elf = ELFFile(self.f)
        self.syms = {}; self.addr2sym = {}
        for sec in self.elf.iter_sections():
            if sec.header.sh_type in ('SHT_SYMTAB', 'SHT_DYNSYM'):
                for s in sec.iter_symbols():
                    if s.name and s['st_value']:
                        self.syms[s.name] = (s['st_value'], s['st_size'])
                        if s['st_info']['type'] == 'STT_FUNC':
                            self.addr2sym.setdefault(s['st_value'], s.name)
        # relocations: address -> symbol name (R_386_32 against named symbols)
        self.rel = {}
        for sec in self.elf.iter_sections():
            if isinstance(sec, RelocationSection):
                st = self.elf.get_section(sec['sh_link'])
                for r in sec.iter_relocations():
                    if r['r_info_sym']:
                        s = st.get_symbol(r['r_info_sym'])
                        if s.name: self.rel[r['r_offset']] = s.name

    def read(self, addr, n):
        for seg in self.elf.iter_segments():
            if seg['p_type'] == 'PT_LOAD' and seg['p_vaddr'] <= addr < seg['p_vaddr'] + seg['p_filesz']:
                self.f.seek(seg['p_offset'] + addr - seg['p_vaddr']); return self.f.read(n)
        return b'\0' * n

    def vtable(self, cls):
        name = f'_ZTV{len(cls)}{cls}'
        addr, size = self.syms[name]
        out = []
        # primary vtable: skip offset-to-top and typeinfo, stop at the next offset-to-top/typeinfo pair
        for i in range((size - 8) // 4):
            a = addr + 8 + 4 * i
            if a in self.rel: sym = self.rel[a]
            else:
                v = struct.unpack('<I', self.read(a, 4))[0]
                sym = self.addr2sym.get(v)
                if sym is None:
                    if i > 0 and (a + 4) in self.rel and self.rel[a + 4].startswith('_ZTI'): break  # secondary vtable
                    sym = f'<0x{v:x}>'
            if sym.startswith('_ZTI'): break
            out.append(sym)
        return out

def demangle(names):
    p = subprocess.run(['c++filt'], input='\n'.join(names), capture_output=True, text=True)
    return p.stdout.splitlines()

if __name__ == '__main__':
    b = Binary(sys.argv[1]); vt = b.vtable(sys.argv[2]); dm = demangle(vt)
    if '--find' in sys.argv:
        want = sys.argv[sys.argv.index('--find') + 1]
        for i, d in enumerate(dm):
            if d.split('(')[0].endswith(want): print(i, d)
    else:
        for i, (m, d) in enumerate(zip(vt, dm)): print(i, d)
