#!/usr/bin/env python3
# Names the types of a hl-heap-tally tally from the bytecode of the process that was dumped, and rolls the live bytes up by type and package.
# usage: hl-heap-names.py <worker.hl> <tally.tsv> [top]
import sys,struct,collections
code=open(sys.argv[1],'rb').read(); pos=0
def b():
    global pos; v=code[pos]; pos+=1; return v
def i32():
    global pos; v=struct.unpack_from('<i',code,pos)[0]; pos+=4; return v
def idx():
    c=b()
    if c&0x80==0: return c
    if c&0x40==0:
        v=b()|((c&0x1F)<<8); return -v if c&0x20 else v
    v=((c&0x1F)<<24)|(b()<<16)|(b()<<8)|b(); return -v if c&0x20 else v
assert code[:3]==b'HLB'; pos=3; version=b()
flags=idx(); nints=idx(); nfloats=idx(); nstrings=idx()
nbytes=idx() if version>=5 else 0
ntypes=idx(); nglobals=idx(); nnatives=idx(); nfunctions=idx()
nconst=idx() if version>=4 else 0
entry=idx()
pos+=4*nints; pos+=8*nfloats
size=i32(); blob=code[pos:pos+size]; pos+=size
strings=[]; p=0
for _ in range(nstrings):
    n=idx(); strings.append(blob[p:p+n].decode('utf8','replace')); p+=n+1
if nbytes:
    size=i32(); pos+=size
    for _ in range(nbytes): idx()
if flags&1:
    n=idx(); size=i32(); pos+=size
    for _ in range(n): idx()
kinds=['void','ui8','ui16','i32','i64','f32','f64','bool','bytes','dyn','fun','obj','array','type','ref','virtual','dynobj','abstract','enum','null','method','struct','packed']
names=[]
for t in range(ntypes):
    k=b(); name=None
    if k in (10,20):
        n=b()
        for _ in range(n): idx()
        idx()
    elif k in (11,21):
        name=strings[idx()]; sup=idx(); idx(); nf=idx(); npr=idx(); nb=idx()
        for _ in range(nf): idx(); idx()
        for _ in range(npr): idx(); idx(); idx()
        for _ in range(nb): idx(); idx()
    elif k in (14,19,22): idx()
    elif k==17: name=strings[idx()]
    elif k==15:
        nf=idx(); fs=[]
        for _ in range(nf):
            fs.append(strings[idx()]); idx()
        name='{'+','.join(fs[:4])+(',..' if len(fs)>4 else '')+'}'
    elif k==18:
        name=strings[idx()]; idx(); nc=idx()
        for _ in range(nc):
            idx(); n=idx()
            for _ in range(n): idx()
    names.append((kinds[k] if k<len(kinds) else str(k), name))
rows=[]
for line in open(sys.argv[2]):
    if line.startswith('#'): continue
    kind,index,ptr,blocks,nbytes_=line.rstrip().split('\t')
    rows.append((kind,index if kind=='other' else int(index),int(blocks),int(nbytes_)))
total=sum(r[3] for r in rows)
base=['i32','i64','f32','f64','dyn','array','bytes','dynobj','bool']
def label(kind,index):
    if kind=='other': return index
    k=int(kind)
    if k>=1000: return 'base:'+['void','ui8','ui16','i32','i64','f32','f64','bool','bytes','dyn','fun','obj','array','type','ref','virtual','dynobj'][k-1000]
    if k==2: return 'closure'
    kk,n=names[index]; return (n or kk)+(' ['+kk+']' if kk not in('obj',) and n else (' ['+kk+']' if not n else ''))
by=collections.defaultdict(lambda:[0,0]); pkg=collections.defaultdict(lambda:[0,0])
for kind,index,blocks,nb in rows:
    l=label(kind,index)
    by[l][0]+=blocks; by[l][1]+=nb
    parts=l.split('.')
    key='.'.join(parts[:3]) if len(parts)>2 and parts[0] in('compiler',) else ('.'.join(parts[:2]) if len(parts)>1 else l)
    pkg[key][0]+=blocks; pkg[key][1]+=nb
top=int(sys.argv[3]) if len(sys.argv)>3 else 40
print('total live bytes in dump: %.2f GB'%(total/1e9))
print('\n== by package ==')
for k,v in sorted(pkg.items(),key=lambda x:-x[1][1])[:30]: print('%8.3f GB %12d  %s'%(v[1]/1e9,v[0],k))
print('\n== by type ==')
for k,v in sorted(by.items(),key=lambda x:-x[1][1])[:top]: print('%8.3f GB %12d  %s'%(v[1]/1e9,v[0],k))
