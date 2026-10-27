import os, json
from PIL import Image, ImageDraw, ImageFont
B = "Host/Assets.xcassets/App Icon & Top Shelf Image.brandassets"
F = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
def J(p, d): os.makedirs(p, exist_ok=True); json.dump(d, open(p+"/Contents.json","w"), indent=1)
INFO = {"version":1,"author":"xcode"}
def back(w,h):
    im = Image.new("RGB",(w,h)); d = ImageDraw.Draw(im)
    for y in range(h): t=y/h; d.line([(0,y),(w,y)], fill=(int(20+30*t),int(40+60*t),int(90+80*t)))
    return im
def front(w,h):
    im = Image.new("RGBA",(w,h),(0,0,0,0)); d = ImageDraw.Draw(im); s=h/240
    bx=[w*0.22,h*0.2,w*0.78,h*0.8]; d.rounded_rectangle(bx,radius=int(18*s),outline=(255,255,255,255),width=int(8*s))
    for i in range(1,4): x=bx[0]+(bx[2]-bx[0])*i/4; d.line([(x,bx[1]+10*s),(x,bx[3]-10*s)],fill=(255,255,255,90),width=int(4*s))
    f=ImageFont.truetype(F,int(70*s)); t="LC TV"; tw=d.textlength(t,font=f)
    d.text(((w-tw)/2,h*0.5-40*s),t,font=f,fill=(255,200,60
