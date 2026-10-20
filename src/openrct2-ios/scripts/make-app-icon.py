"""Builds AppIcon.icon layers from the in-game pixel logo (resources/g2/logo.png): drops the diamond frame,
splits the tower and slide into Liquid Glass layers, and redraws the parts the diamond had clipped.
Usage: python3 make-app-icon.py <scratch-dir>   (needs Pillow)"""
import sys
from PIL import Image
S=sys.argv[1]
im=Image.open(__import__('pathlib').Path(__file__).resolve().parents[3]/'resources/g2/logo.png').convert('RGBA'); W,H=im.size; px=im.load()
lab={}
for y in range(H):
  for x in range(W):
    r,g,b,a=px[x,y]
    if not a: continue
    d=abs(x-63.5)+abs(y-63.5); grey=max(r,g,b)-min(r,g,b)<=25
    sky=b>r+40 and b>=g and r not in (99,63,139,83,159) and not (r==119 and g==119)
    warm=r>150 and r>b+60
    if sky: continue
    if d>=58 and grey and r<70: continue
    if d>=58 and b>r+15: continue
    if y<64 and d>=55 and not warm and not (62<=x<=66): continue
    lab[(x,y)]='Slide' if grey and y>=50 else 'Tower'
seen=set()
for p0 in list(lab):
  if p0 in seen: continue
  comp=[p0]; st=[p0]; seen.add(p0)
  while st:
    x,y=st.pop()
    for dx in(-1,0,1):
      for dy in(-1,0,1):
        q=(x+dx,y+dy)
        if q in lab and q not in seen: seen.add(q); st.append(q); comp.append(q)
  if len(comp)<6:
    for q in comp: del lab[q]
T=Image.new('RGBA',(W,H+16)); Sl=Image.new('RGBA',(W,H+16))
for (x,y),n in lab.items(): (Sl if n=='Slide' else T).putpixel((x,y),px[x,y])
# --- rebuild the base of the tower below the slide ---
REF=int(sys.argv[2]) if len(sys.argv)>2 else 86
refxs=[x for x in range(W) if lab.get((x,REF))=='Tower']
l0,r0=min(refxs),max(refxs); ref=[px[x,REF] for x in range(l0,r0+1)]
START=93; BASE=118
def dark(c,f): return (int(c[0]*f),int(c[1]*f),int(c[2]*f),255)
for y in range(START,BASE+4):
  grow=(y-REF)/7.0
  l=round(l0-grow); r=round(r0+grow); w=r-l+1; cx=(l+r)/2
  for x in range(l,r+1):
    t=(x-l)/max(1,w-1)
    c=ref[min(len(ref)-1,int(t*len(ref)))]
    # curved base: the rim dips toward the centre
    e=((x-cx)/(w/2))**2
    bottom=BASE+round(3*(1-e))
    if y>bottom: continue
    if y>=bottom-1: c=dark(c,0.55 if y==bottom else 0.75)
    T.putpixel((x,y),c)
T.save(S+'/T.png'); Sl.save(S+'/Sl.png')
both=Image.new('RGBA',T.size); both.alpha_composite(T); both.alpha_composite(Sl)
bg=Image.new('RGBA',T.size,(99,143,59,255)); bg.alpha_composite(both)
bg.crop((24,56,104,H+16)).resize((80*8,(H+16-56)*8),Image.NEAREST).save(S+'/rebuilt.png')
# --- restore the lower slide band's clipped underside ---
sp=Sl.load()
light=lambda c: c[3] and c[0]>=90
info={}
for x in range(W):
  ys=[y for y in range(84,H+16) if light(sp[x,y])]
  if ys: info[x]=(min(ys),max(ys))
central=[info[x][1]-info[x][0] for x in range(48,70) if x in info]
thick=max(central); print('thick',thick)
edge=min(info)
for x,(t,b) in info.items():
  if x<edge+3: continue
  want=t+thick
  if b>=want: continue
  last=sp[x,b]
  for y in range(b+1,want+1):
    sp[x,y]=last if y<want else (int(last[0]*.55),int(last[1]*.55),int(last[2]*.55),255)
Sl.save(S+'/Sl.png')
both=Image.new('RGBA',T.size); both.alpha_composite(T); both.alpha_composite(Sl)
bg=Image.new('RGBA',T.size,(99,143,59,255)); bg.alpha_composite(both)
bg.crop((24,56,104,H+16)).resize((80*8,(H+16-56)*8),Image.NEAREST).save(S+'/rebuilt.png')
bg.resize((bg.width*4,bg.height*4),Image.NEAREST).save(S+'/rebuilt_full.png')
# --- write the icon layers: 7 icon pixels per logo pixel, centred ---
D=__import__('pathlib').Path(__file__).resolve().parents[1]/'AppIcon.icon/Assets'
x0,y0,x1,y1=both.getbbox()
k=7; ox=int(512-(x0+x1)/2*k); oy=int(512-(y0+y1)/2*k)
for layer,name in ((T,'Tower'),(Sl,'Slide')):
  c=Image.new('RGBA',(1024,1024)); c.alpha_composite(layer.resize((layer.width*k,layer.height*k),Image.NEAREST),(ox,oy)); c.save(D/f'{name}.png')
