import sys
from PIL import Image, ImageDraw

d = sys.argv[1]
cell = 80
pad = 14
W = cell*8 + pad*2
H = cell*8 + pad*2
out = Image.new('RGB', (W, H), 'white')
draw = ImageDraw.Draw(out)
files = 'abcdefgh'
for r in range(8):
    for c in range(8):
        im = Image.open(f'{d}/cell_{r}{c}.png').convert('RGB').resize((cell, cell))
        out.paste(im, (pad + c*cell, pad + r*cell))
for r in range(9):
    draw.line([(pad, pad+r*cell), (pad+8*cell, pad+r*cell)], fill='red', width=1)
for c in range(9):
    draw.line([(pad+c*cell, pad), (pad+c*cell, pad+8*cell)], fill='red', width=1)
for c in range(8):
    draw.text((pad + c*cell + cell//2 - 4, 0), files[c], fill='red')
for r in range(8):
    draw.text((0, pad + r*cell + cell//2 - 6), str(8-r), fill='red')
out.save(sys.argv[2])
print('saved', sys.argv[2])
