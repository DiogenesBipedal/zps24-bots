#!/usr/bin/env python3
"""Clear the executable-stack flag (PT_GNU_STACK PF_X) on 32-bit ELF files.

glibc 2.41+ refuses to dlopen() a library whose PT_GNU_STACK segment asks for an executable
stack ("cannot enable executable stack as shared object requires: Invalid argument"). Source
engine binaries from 2007-2013 were linked that way. Clearing the bit is a one-byte header
change; the code never actually needs an executable stack.

Usage: clear_execstack.py FILE...
"""
import struct
import sys

PT_GNU_STACK = 0x6474E551
PF_X = 1

for path in sys.argv[1:]:
    data = bytearray(open(path, 'rb').read())
    if data[:4] != b'\x7fELF' or data[4] != 1:  # ELF, 32-bit class
        continue
    phoff = struct.unpack_from('<I', data, 28)[0]
    phentsize, phnum = struct.unpack_from('<HH', data, 42)
    for i in range(phnum):
        entry = phoff + i * phentsize
        if struct.unpack_from('<I', data, entry)[0] != PT_GNU_STACK:
            continue
        flags = struct.unpack_from('<I', data, entry + 24)[0]  # p_flags
        if flags & PF_X:
            struct.pack_into('<I', data, entry + 24, flags & ~PF_X)
            open(path, 'wb').write(data)
            print('cleared execstack:', path)
