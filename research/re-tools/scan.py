import os as _os
RE_DIR = globals().get('RE_DIR') or _os.path.dirname(_os.path.abspath(__file__))  # handoff: paths relative to this folder
exec(open(_os.path.join(RE_DIR, 'pe.py')).read())
import capstone
from capstone import x86
md=capstone.Cs(capstone.CS_ARCH_X86,capstone.CS_MODE_64); md.detail=True
text=[s for s in secs if s[0]=='.text'][0]
tstart,tend=text[3],text[3]+text[4]
def insn_at(o):
    try:
        return next(md.disasm(data[o:o+16], off2va(o)),None)
    except StopIteration: return None
def scan_disp(disp, want_write=None, mnem_filter=None):
    pat=struct.pack('<I',disp)
    res=[]
    i=data.find(pat,tstart,tend)
    while i!=-1:
        for back in range(2,9):
            ins=insn_at(i-back)
            if ins and ins.size==back+4 or (ins and ins.address+ins.size==off2va(i)+4):
                ok=False
                for op in ins.operands:
                    if op.type==x86.X86_OP_MEM and op.mem.disp==disp:
                        ok=True
                if ok:
                    if mnem_filter is None or ins.mnemonic in mnem_filter:
                        res.append(ins)
                    break
        i=data.find(pat,i+1,tend)
    return res
