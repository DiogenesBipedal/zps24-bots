#!/usr/bin/env python3
"""Minimal Source RCON client: rcon.py "command" ["command" ...]

Reads the password from $ZPS24_RCON_PW_FILE (default ~/.config/zps24/rcon.pw) and talks to
127.0.0.1:27015. Prints each command's console output.
"""
import socket,struct,sys,os
pwfile=os.environ.get('ZPS24_RCON_PW_FILE', os.path.expanduser('~/.config/zps24/rcon.pw'))
pw=open(pwfile).read().strip()
def pkt(i,t,b): b=b.encode()+b'\0\0'; return struct.pack('<iii',len(b)+8,i,t)+b
def recv(s):
    n=struct.unpack('<i',s.recv(4,socket.MSG_WAITALL))[0]; d=s.recv(n,socket.MSG_WAITALL); i,t=struct.unpack('<ii',d[:8]); return i,t,d[8:-2].decode(errors='replace')
s=socket.create_connection(('127.0.0.1',int(os.environ.get('ZPS24_RCON_PORT','27015'))),timeout=10)
s.sendall(pkt(1,3,pw))
while True:
    i,t,_=recv(s)
    if t==2: break
if i==-1: sys.exit('auth failed')
for c in sys.argv[1:]:
    s.sendall(pkt(2,2,c)); s.sendall(pkt(3,0,''))
    out=''
    while True:
        i,t,b=recv(s)
        if i==3: break
        out+=b
    print(out,end='')
