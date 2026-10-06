import os as _os
RE_DIR = globals().get('RE_DIR') or _os.path.dirname(_os.path.abspath(__file__))  # handoff: paths relative to this folder
exec(open(_os.path.join(RE_DIR, 'redis_.py')).read())
import numpy as np
tbytes=np.frombuffer(data,dtype=np.uint8,count=tend,offset=0)
def callers(target):
    # find E8 rel32 calls to target
    res=[]
    idx=np.where(tbytes[tstart:tend]==0xE8)[0]+tstart
    rel=np.frombuffer(data,dtype=np.int32,count=1,offset=0) # dummy
    # vectorized: read int32 after each E8
    o=idx+1
    o=o[o+4<tend]
    vals=(tbytes[o].astype(np.int64) | (tbytes[o+1].astype(np.int64)<<8) | (tbytes[o+2].astype(np.int64)<<16) | (tbytes[o+3].astype(np.int64)<<24))
    vals=np.where(vals>=2**31, vals-2**32, vals)
    # va of next instr = off2va(o+4)
    text=[s for s in secs if s[0]=='.text'][0]
    va_next=(o+4-text[3])+BASE+text[1]
    tgt=va_next+vals
    hits=o[tgt==target]-1
    return [off2va(int(h)) for h in hits]
