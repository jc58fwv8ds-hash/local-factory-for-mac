"""Draws the Local Factory app icon (Assets/AppIcon-1024.png) from the pixel rows in FactoryLogoView.swift, plus a
sheet of concept variants in work/. python3 scripts/render_factory_icon.py"""
from PIL import Image, ImageDraw, ImageFilter, ImageChops, ImageFont
import math, re, sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
S=1024; SS=2  # supersample
def squircle(size=824, n=5.0):
    N=S*SS; m=Image.new('L',(N,N),0); px=m.load(); r=size*SS/2; c=N/2
    for y in range(N):
        dy=abs(y+0.5-c)/r
        if dy>1: continue
        dx=(1-dy**n)**(1/n)*r
        for x in range(int(c-dx),int(c+dx)): px[x,y]=255
    return m
MASK=squircle()
def grad(top,bot):
    N=S*SS; im=Image.new('RGBA',(N,N)); d=ImageDraw.Draw(im)
    for y in range(N):
        t=y/N; d.line([(0,y),(N,y)],fill=tuple(int(top[i]+(bot[i]-top[i])*t) for i in range(3))+(255,))
    return im
def layer(): return Image.new('RGBA',(S*SS,S*SS),(0,0,0,0))
def P(pts): return [(x*SS,y*SS) for x,y in pts]
# geometry in 1024 space (icon body spans 100..924)
TEETH=[(205,330),(340,465),(475,600)]   # x0..x1 of each sawtooth
ROOF_Y=560; PEAK_Y=375
BODY=(200,560,824,890)
CHIM=(640,300,720,560)
WIN=[(250+i*145,630,250+i*145+95,775) for i in range(4)]
SMOKE=[(675,245,38),(600,180,56),(490,120,80)]
def shapes(fill, edge, winfill, glow, smoke, smoke_alpha, shadow=True):
    out=layer()
    fac=layer(); d=ImageDraw.Draw(fac)
    d.rounded_rectangle(P([(CHIM[0],CHIM[1]),(CHIM[2],CHIM[3]+20)]),radius=14*SS,fill=fill)
    for x0,x1 in TEETH: d.polygon(P([(x0,ROOF_Y+10),(x0,PEAK_Y),(x1+12,ROOF_Y+10)]),fill=fill)
    d.rounded_rectangle(P([(BODY[0],BODY[1]),(BODY[2],BODY[3])]),radius=28*SS,fill=fill)
    # top edge highlight (glass rim)
    hl=layer(); hd=ImageDraw.Draw(hl)
    hd.line(P([(BODY[0]+30,BODY[1]+4),(BODY[2]-30,BODY[1]+4)]),fill=edge,width=6*SS)
    hd.line(P([(CHIM[0]+10,CHIM[1]+5),(CHIM[2]-10,CHIM[1]+5)]),fill=edge,width=6*SS)
    for x0,x1 in TEETH: hd.line(P([(x0+4,PEAK_Y+12),(x0+4,ROOF_Y)]),fill=edge,width=5*SS)
    if shadow:
        sh=Image.new('RGBA',fac.size,(0,0,0,0)); a=fac.split()[3].point(lambda v:int(v*0.35))
        sh.putalpha(a); sh=ImageChops.offset(sh,0,14*SS).filter(ImageFilter.GaussianBlur(18*SS)); out=Image.alpha_composite(out,sh)
    out=Image.alpha_composite(out,fac); out=Image.alpha_composite(out,Image.composite(hl,layer(),fac.split()[3]))
    # windows with glow
    g=layer(); gd=ImageDraw.Draw(g)
    for x0,y0,x1,y1 in WIN: gd.rounded_rectangle(P([(x0-14,y0-14),(x1+14,y1+14)]),radius=26*SS,fill=glow)
    out=Image.alpha_composite(out,g.filter(ImageFilter.GaussianBlur(16*SS)))
    w=layer(); wd=ImageDraw.Draw(w)
    for x0,y0,x1,y1 in WIN:
        wd.rounded_rectangle(P([(x0,y0),(x1,y1)]),radius=14*SS,fill=winfill)
        wd.rounded_rectangle(P([(x0+8,y0+8),(x1-8,y0+30)]),radius=10*SS,fill=(255,255,255,90))
    out=Image.alpha_composite(out,w)
    # smoke: translucent glass blobs with a highlight
    sm=layer(); sd=ImageDraw.Draw(sm)
    for cx,cy,r in SMOKE:
        for dx,dy,k in [(0,0,1),(-r*.6,r*.25,.7),(r*.6,r*.2,.75)]:
            rr=r*k; sd.ellipse(P([(cx+dx-rr,cy+dy-rr),(cx+dx+rr,cy+dy+rr)]),fill=smoke[:3]+(smoke_alpha,))
    out=Image.alpha_composite(out,sm)
    hi=layer(); hd=ImageDraw.Draw(hi)
    pass
    out=Image.alpha_composite(out,hi.filter(ImageFilter.GaussianBlur(4*SS)))
    return out
def fit(fg, box=600):
    bb=fg.split()[3].getbbox(); art=fg.crop(bb); k=box*SS/max(art.size); art=art.resize((int(art.width*k),int(art.height*k)),Image.LANCZOS)
    out=layer(); out.alpha_composite(art,((S*SS-art.width)//2,(S*SS-art.height)//2+10*SS)); return out
def icon(bg, fg, rim=True):
    fg=fit(fg)
    base=Image.composite(bg,layer(),MASK)
    out=Image.alpha_composite(base,Image.composite(fg,layer(),MASK))
    if rim:  # glass edge: light inner rim
        edge=MASK.filter(ImageFilter.FIND_EDGES).filter(ImageFilter.GaussianBlur(3*SS))
        r=layer(); r.putalpha(edge.point(lambda v:min(255,v*3))); wh=Image.new('RGBA',r.size,(255,255,255,0)); wh.putalpha(edge.point(lambda v:min(110,v*3)))
        out=Image.alpha_composite(out,wh)
    sh=Image.new('RGBA',out.size,(0,0,0,0)); sh.putalpha(MASK.point(lambda v:int(v*0.28)))
    sh=ImageChops.offset(sh,0,18*SS).filter(ImageFilter.GaussianBlur(22*SS))
    return Image.alpha_composite(sh,out).resize((S,S),Image.LANCZOS)
light=icon(grad((255,236,206),(255,190,120)), shapes((128,134,146,255),(205,210,218,255),(255,181,46,255),(255,170,40,170),(255,255,255),205))
dark=icon(grad((52,56,64),(22,24,28)), shapes((96,101,112,255),(150,156,166,255),(255,181,46,255),(255,160,30,200),(225,228,232),170))
clear=icon(grad((150,160,175),(95,105,122)), shapes((255,255,255,95),(255,255,255,180),(255,255,255,200),(255,255,255,60),(255,255,255),120,shadow=False))
# pixel-kept version: the logo's dots on the light background, smoke kept as dots
src=open(ROOT/'Sources/HarnessApp/Views/FactoryLogoView.swift').read()
fac=re.findall(r'"([.KGWY]{24})"',src)
pal={'K':(46,51,56),'G':(140,145,156),'W':(255,181,46),'Y':(255,217,120),'S':(255,255,255),'T':(214,219,224)}
puffs=[["SS","ST"],[".SS.","SSSS","SSST",".ST."],[".SSS.","SSSSS","SSSSS","SSSST",".STT."]]
pl=layer(); pd=ImageDraw.Draw(pl); px=24*SS; ox=(S*SS-24*px)//2; oy=(S*SS-31*px)//2+20*SS
def dot(x,y,c): pd.rounded_rectangle([ox+x*px,oy+y*px,ox+x*px+px-1,oy+y*px+px-1],radius=0,fill=c+(255,))
for r,l in enumerate(fac):
    for c,s in enumerate(l):
        if s in pal: dot(c,r+8,pal[s])
for p in (.1,.4,.7):
    size=0 if p<.25 else (1 if p<.6 else 2); rnd=lambda v:int(v+0.5) if v>=0 else -int(-v+0.5)
    x=rnd(18.5-11.5*p)-size; y=rnd(6.4-7*p)-size
    for r,l in enumerate(puffs[size]):
        for c,s in enumerate(l):
            if s in pal and 0<=y+r: dot(x+c,y+r,pal[s])
pixel=icon(grad((255,236,206),(255,190,120)),pl)
# sheet on a wallpaper-like backdrop
items=[('なめらか・通常',light),('なめらか・ダーク',dark),('なめらか・クリア',clear),('ドットを残す・通常',pixel)]
T=300; W=len(items)*(T+40)+40; H=T+110
sheet=grad((205,214,228),(150,165,190)).resize((W,H)).convert('RGB')
try: f=ImageFont.truetype('/System/Library/Fonts/ヒラギノ角ゴシック W6.ttc',22)
except Exception: f=None
d=ImageDraw.Draw(sheet)
for i,(n,im) in enumerate(items):
    x=40+i*(T+40); sheet.paste(im.resize((T,T),Image.LANCZOS),(x,20),im.resize((T,T),Image.LANCZOS))
    d.text((x+10,T+50),n,fill=(30,34,40),font=f)
sheet.save(ROOT/'work/appicon-concepts.png')
pixel.save(ROOT/'Assets/AppIcon-1024.png'); print('ok')
