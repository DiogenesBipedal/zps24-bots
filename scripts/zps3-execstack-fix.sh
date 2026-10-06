#!/bin/sh
# Re-apply the glibc 2.41 fix for native Linux Zombie Panic! Source after a Steam update or file verify.
# It clears the executable-stack flag (PT_GNU_STACK PF_X) on any 32-bit .so in the game's bin/ that has it set.
G="$HOME/.local/share/Steam/steamapps/common/Zombie Panic Source"
python3 - "$G"/bin/*.so <<'EOF'
import struct, sys
for p in sys.argv[1:]:
    d = bytearray(open(p, 'rb').read())
    if d[:4] != b'\x7fELF' or d[4] != 1:
        continue
    phoff = struct.unpack_from('<I', d, 28)[0]; phes, phn = struct.unpack_from('<HH', d, 42)
    for i in range(phn):
        o = phoff + i * phes
        if struct.unpack_from('<I', d, o)[0] == 0x6474e551:
            f = struct.unpack_from('<I', d, o + 24)[0]
            if f & 1:
                struct.pack_into('<I', d, o + 24, f & ~1); open(p, 'wb').write(d); print('fixed', p.split('/')[-1])
EOF
