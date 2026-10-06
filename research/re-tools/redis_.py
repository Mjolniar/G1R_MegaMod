import os as _os
RE_DIR = globals().get('RE_DIR') or _os.path.dirname(_os.path.abspath(__file__))  # handoff: paths relative to this folder
exec(open(_os.path.join(RE_DIR, 'scan.py')).read())
import bisect
pd=[s for s in secs if s[0]=='.pdata'][0]
funcs=[]
for k in range(0,pd[2],12):
    b,e,u=struct.unpack_from('<III',data,pd[3]+k)
    if b==0: break
    funcs.append((BASE+b,BASE+e))
funcs.sort(); fstarts=[f[0] for f in funcs]
def func_of(va):
    i=bisect.bisect_right(fstarts,va)-1
    if i>=0 and funcs[i][0]<=va<funcs[i][1]: return funcs[i]
def dis(start,end=None,maxn=400,show=True):
    if end is None:
        f=func_of(start); end=f[1] if f else start+0x200
    o=va2off(start); out=[]
    for ins in md.disasm(data[o:o+(end-start)],start):
        out.append(ins)
        if len(out)>=maxn: break
    if show:
        for ins in out:
            extra=''
            for op in ins.operands:
                if op.type==x86.X86_OP_MEM and op.mem.base==x86.X86_REG_RIP:
                    tgt=ins.address+ins.size+op.mem.disp
                    sec=secof(tgt)
                    if sec=='.rdata':
                        try:
                            fv=struct.unpack_from('<d',data,va2off(tgt))[0]; ff=struct.unpack_from('<f',data,va2off(tgt))[0]
                            s=cstr(tgt,60)
                            extra=f'   ; [{hex(tgt)}] d={fv:.6g} f={ff:.6g} s={s[:30]!r}'
                        except Exception: pass
                    else: extra=f'   ; [{hex(tgt)}] {sec}'
            print(f'{ins.address:#x}: {ins.mnemonic} {ins.op_str}{extra}')
    return out
