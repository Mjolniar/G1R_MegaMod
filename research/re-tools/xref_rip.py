import os as _os
RE_DIR = globals().get('RE_DIR') or _os.path.dirname(_os.path.abspath(__file__))  # handoff: paths relative to this folder
import struct, numpy as np
exec(open(_os.path.join(RE_DIR, 'pe.py')).read())
text=[s for s in pe.sections if s.Name.startswith(b'.text')][0]
ts=text.PointerToRawData; tva=BASE+text.VirtualAddress; n=text.SizeOfRawData
buf=np.frombuffer(data[ts:ts+n], dtype=np.uint8)
def rip_xrefs(target, chunk=8_000_000):
    out=[]
    for s in range(0, n-4, chunk):
        e=min(n-4, s+chunk)
        b=buf[s:e+4].astype(np.int64)
        d=(b[0:e-s] | (b[1:e-s+1]<<8) | (b[2:e-s+2]<<16) | (b[3:e-s+3]<<24))
        d=np.where(d>=2**31, d-2**32, d)
        k=np.arange(s, e, dtype=np.int64)
        hit=np.nonzero(d + (tva + k + 4) == target)[0]
        out.extend((tva + s + h) for h in hit)
    return out
