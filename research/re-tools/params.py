import os as _os
RE_DIR = globals().get('RE_DIR') or _os.path.dirname(_os.path.abspath(__file__))  # handoff: paths relative to this folder
import struct
exec(open(_os.path.join(RE_DIR, 'pe.py')).read())
GEN={0:'Byte',1:'Int8',2:'Int16',3:'Int',4:'Int64',5:'UInt16',6:'UInt32',7:'UInt64',8:'UnsizedInt',9:'UnsizedUInt',10:'Float',11:'Double',12:'Bool',13:'SoftClass',14:'WeakObject',15:'LazyObject',16:'SoftObject',17:'Class',18:'Object',19:'Interface',20:'Name',21:'Str',22:'Array',23:'Map',24:'Set',25:'Struct',26:'Delegate',27:'InlineMCDelegate',28:'SparseMCDelegate',29:'Text',30:'Enum',31:'FieldPath',32:'LWCReal'}
def params_of(fname):
    res=[]
    for o in find_all(fname.encode()+b'\0'):
        va=off2va(o)
        for p in ptrs_to(va):
            pva=off2va(p)
            if secof(pva)!='.data': continue
            outer=struct.unpack_from('<Q',data,p-16)[0]
            if secof(outer)!='.text': continue
            arr=struct.unpack_from('<Q',data,p+24)[0]; n=struct.unpack_from('<H',data,p+32)[0]; size=struct.unpack_from('<H',data,p+34)[0]
            fflags=struct.unpack_from('<I',data,p+40)[0]
            props=[]
            if n and arr and va2off(arr) is not None:
                for i in range(n):
                    pp=struct.unpack_from('<Q',data,va2off(arr)+8*i)[0]
                    po=va2off(pp)
                    if po is None: props.append('?'); continue
                    nm=cstr(struct.unpack_from('<Q',data,po)[0],80)
                    flags=struct.unpack_from('<Q',data,po+16)[0]
                    gen=data[po+24]
                    off=struct.unpack_from('<H',data,po+50)[0]
                    kind=GEN.get(gen,hex(gen))
                    tags=[]
                    if flags&0x400: tags.append('ret')
                    elif flags&0x100 and not flags&0x8000000: tags.append('out')
                    if flags&0x8000000: tags.append('ref')
                    if flags&0x2: tags.append('const')
                    props.append(f"{nm}:{kind}@{off}{('['+','.join(tags)+']') if tags else ''}")
            res.append((hex(pva-16),n,size,hex(fflags),props))
    return res
if __name__=='__main__':
    import sys
    for f in sys.argv[1:]:
        for r in params_of(f): print(f, r)
