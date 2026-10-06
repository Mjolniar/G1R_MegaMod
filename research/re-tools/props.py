import os as _os
RE_DIR = globals().get('RE_DIR') or _os.path.dirname(_os.path.abspath(__file__))  # handoff: paths relative to this folder
exec(open(_os.path.join(RE_DIR, 'params.py')).read())
def prop_info(name):
    out=[]
    for o in find_all(name.encode()+b'\0'):
        va=off2va(o)
        for p in ptrs_to(va):
            pva=off2va(p)
            if secof(pva) not in ('.data','.rdata'): continue
            flags=struct.unpack_from('<Q',data,p+16)[0]
            gen=data[p+24]
            off=struct.unpack_from('<H',data,p+50)[0] if gen not in (12,) else None
            out.append((hex(pva),GEN.get(gen,hex(gen)),off,hex(flags)))
    return out
if __name__=='__main__':
    import sys
    for n in sys.argv[1:]:
        print(n, prop_info(n))
