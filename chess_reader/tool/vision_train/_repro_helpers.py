import numpy as np, onnxruntime as ort
from PIL import Image
from model import CELL, CLASSES
def otsu(lum):
    hist=np.bincount(lum.ravel(),minlength=256).astype(np.float64)
    total=lum.size; sum_=np.dot(np.arange(256),hist); sumB=wB=0.0;best=0.0;thr=127
    for i in range(256):
        wB+=hist[i]
        if wB==0: continue
        wF=total-wB
        if wF==0: break
        sumB+=i*hist[i]; mB=sumB/wB; mF=(sum_-sumB)/wF; b=wB*wF*(mB-mF)**2
        if b>best: best=b;thr=i
    return thr
def locate(gray,minrel=0.18,maxasp=0.12):
    h,w=gray.shape; thr=otsu(gray); dark=gray<thr
    labels=np.zeros((h,w),np.int32); parent=[0]
    def find(x):
        root=x
        while parent[root]!=root: root=parent[root]
        while parent[x]!=root: parent[x],x=root,parent[x]
        return root
    def union(a,b):
        ra,rb=find(a),find(b)
        if ra!=rb: parent[rb]=ra
    nl=1
    for y in range(h):
        drow=dark[y]; lrow=labels[y]; urow=labels[y-1] if y>0 else None
        for x in range(w):
            if not drow[x]: continue
            left=lrow[x-1] if x>0 else 0; up=urow[x] if y>0 else 0
            if left==0 and up==0: lrow[x]=nl;parent.append(nl);nl+=1
            elif left!=0 and up!=0:
                lrow[x]=left
                if left!=up: union(left,up)
            else: lrow[x]=left if left!=0 else up
    ys,xs=np.nonzero(labels)
    boxes={}
    for y,x in zip(ys,xs):
        r=find(labels[y,x])
        if r in boxes:
            b=boxes[r];b[0]=min(b[0],x);b[1]=min(b[1],y);b[2]=max(b[2],x);b[3]=max(b[3],y)
        else: boxes[r]=[x,y,x,y]
    minside=min(w,h)*minrel; cands=[]
    for b in boxes.values():
        bw=b[2]-b[0]+1;bh=b[3]-b[1]+1;size=(bw+bh)//2
        if size<minside or abs(bw-bh)/size>maxasp: continue
        cands.append((b[0],b[1],size))
    cands.sort(key=lambda c:-c[2]); return cands
def crop_inside_frame(gray,l,t,size):
    sub=gray[t:t+size,l:l+size].astype(np.int32); n=sub.shape[0]; mp=n//8
    top,bot,le,ri=0,n-1,0,n-1
    while top<mp and (sub[top]<128).mean()>0.8: top+=1
    while bot>n-mp and (sub[bot]<128).mean()>0.8: bot-=1
    while le<mp and (sub[:,le]<128).mean()>0.8: le+=1
    while ri>n-mp and (sub[:,ri]<128).mean()>0.8: ri-=1
    return gray[t+top:t+bot+1,l+le:l+ri+1]
_sess=ort.InferenceSession('../../assets/models/square_classifier2.onnx')
def cdm(c):
    lo=(CELL*22)//100;hi=CELL-lo;return float((c[lo:hi,lo:hi]<=-0.14).mean())
def classify(inner):
    h,w=inner.shape; x=np.zeros((64,2,CELL,CELL),np.float32)
    for r in range(8):
        for f in range(8):
            ys,ye=round(r*h/8),round((r+1)*h/8);xs,xe=round(f*w/8),round((f+1)*w/8)
            g=np.asarray(Image.fromarray(inner[ys:ye,xs:xe].astype(np.uint8)).resize((CELL,CELL),Image.BILINEAR),np.float32)
            x[r*8+f,0]=(g/255.0-0.5)/0.5
    lo=_sess.run(None,{'cells':x})[0]; out=[]
    for i in range(64):
        empty=x[i,0].std()<0.08 or cdm(x[i,0])<0.05
        out.append('' if empty else CLASSES[int(lo[i].argmax())])
    return out
def to_fen(labels):
    rows=[]
    for r in range(8):
        s='';e=0
        for f in range(8):
            c=labels[r*8+f]
            if c=='':e+=1
            else:
                if e:s+=str(e);e=0
                s+=c
        if e:s+=str(e)
        rows.append(s)
    return '/'.join(rows)
