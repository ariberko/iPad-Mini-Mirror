"""Draws the Mirror app icon (1024x1024, no transparency)."""
import sys
from PIL import Image, ImageDraw, ImageFilter

S = 1024
SS = 4  # supersample for smooth edges
W = S * SS

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

# Background: soft diagonal blue -> indigo gradient
top = (64, 156, 255)
bottom = (88, 86, 214)
vertical = Image.linear_gradient("L")
horizontal = vertical.rotate(90)
grad = Image.blend(vertical, horizontal.transpose(Image.FLIP_LEFT_RIGHT), 0.5).resize((W, W), Image.BICUBIC)
bg = Image.composite(Image.new("RGB", (W, W), bottom), Image.new("RGB", (W, W), top), grad)

def device(draw_img, box, radius, bezel, fill, screen_fill):
    x0, y0, x1, y1 = box
    d = ImageDraw.Draw(draw_img)
    d.rounded_rectangle(box, radius=radius, fill=fill)
    d.rounded_rectangle((x0 + bezel, y0 + bezel, x1 - bezel, y1 - bezel),
                        radius=max(1, radius - bezel), fill=screen_fill)

def shadow(box, radius, blur, offset, alpha):
    layer = Image.new("L", (W, W), 0)
    d = ImageDraw.Draw(layer)
    x0, y0, x1, y1 = box
    d.rounded_rectangle((x0, y0 + offset, x1, y1 + offset), radius=radius, fill=alpha)
    return layer.filter(ImageFilter.GaussianBlur(blur))

u = SS
# iPad (landscape), back
ipad = (150 * u, 270 * u, 790 * u, 720 * u)
ipad_r = 58 * u
# iPhone (portrait), front, overlapping bottom right
iphone = (610 * u, 400 * u, 870 * u, 880 * u)
iphone_r = 52 * u

img = bg.copy()
black = Image.new("RGB", (W, W), (20, 24, 60))
img = Image.composite(black, img, shadow(ipad, ipad_r, 30 * u, 18 * u, 90))
device(img, ipad, ipad_r, 18 * u, (255, 255, 255), (226, 236, 255))

# Mirrored "content" on the iPad: a soft rounded tile echoing the phone
d = ImageDraw.Draw(img)
d.rounded_rectangle((250 * u, 340 * u, 400 * u, 650 * u), radius=26 * u, fill=(120, 170, 255))
d.rounded_rectangle((430 * u, 340 * u, 560 * u, 480 * u), radius=22 * u, fill=(170, 200, 255))
d.rounded_rectangle((430 * u, 510 * u, 560 * u, 650 * u), radius=22 * u, fill=(150, 185, 255))

img = Image.composite(black, img, shadow(iphone, iphone_r, 30 * u, 20 * u, 110))
device(img, iphone, iphone_r, 16 * u, (255, 255, 255), (120, 170, 255))
d = ImageDraw.Draw(img)
# Dynamic island
d.rounded_rectangle((705 * u, 432 * u, 775 * u, 452 * u), radius=10 * u, fill=(255, 255, 255))

img = img.resize((S, S), Image.LANCZOS)
img.save(sys.argv[1], "PNG")
