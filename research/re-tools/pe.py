import os as _os
RE_DIR = globals().get('RE_DIR') or _os.path.dirname(_os.path.abspath(__file__))  # handoff: paths relative to this folder
# the game executable: G1R_GAME_EXE, else the copy in the project folder (..\..\re\G1R-Win64-Shipping.exe), else game.exe here
GAME_EXE = _os.environ.get('G1R_GAME_EXE') or next((p for p in (_os.path.join(RE_DIR, '..', '..', 're', 'G1R-Win64-Shipping.exe'), _os.path.join(RE_DIR, 'game.exe')) if _os.path.isfile(p)), _os.path.join(RE_DIR, 'game.exe'))
import pefile, struct, mmap, re
f=open(GAME_EXE,'rb'); data=mmap.mmap(f.fileno(),0,access=mmap.ACCESS_READ)
pe=pefile.PE(GAME_EXE, fast_load=True)
BASE=pe.OPTIONAL_HEADER.ImageBase
secs=[(s.Name.rstrip(b'\0').decode(),s.VirtualAddress,s.Misc_VirtualSize,s.PointerToRawData,s.SizeOfRawData) for s in pe.sections]
def off2va(o):
    for n,va,vs,ro,rs in secs:
        if ro<=o<ro+rs: return BASE+va+(o-ro)
def va2off(v):
    r=v-BASE
    for n,va,vs,ro,rs in secs:
        if va<=r<va+max(vs,rs): return ro+(r-va)
def secof(v):
    r=v-BASE
    for n,va,vs,ro,rs in secs:
        if va<=r<va+max(vs,rs): return n
def cstr(v,maxl=200):
    o=va2off(v)
    if o is None: return None
    e=data.find(b'\0',o,o+maxl)
    return data[o:e].decode('latin1')
def find_all(b):
    res=[];i=data.find(b)
    while i!=-1: res.append(i); i=data.find(b,i+1)
    return res
def ptrs_to(v):
    return find_all(struct.pack('<Q',v))
def q(v): return struct.unpack_from('<Q',data,va2off(v))[0]
