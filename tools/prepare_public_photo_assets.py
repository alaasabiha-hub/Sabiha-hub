"""Extract only car photographs from the user-supplied approved reference.
No logo, text, controls, discount badges or prices are copied into these assets.
"""
from pathlib import Path
import argparse
from PIL import Image
parser=argparse.ArgumentParser();parser.add_argument('--reference',required=True);args=parser.parse_args()
root=Path(__file__).resolve().parents[1];reference=Image.open(args.reference).convert('RGB');sx=reference.width/1536;sy=reference.height/1024
for name,box in {'premium-car':(0,120,565,341),'interior':(438,495,707,620),'wash':(812,497,1080,619),'headlight':(973,840,1162,987)}.items():
 bounds=tuple(round(value*(sx if i%2==0 else sy)) for i,value in enumerate(box));reference.crop(bounds).save(root/f'assets/customer/reference-{name}.jpg',quality=95)
print('Saved four photo-only assets; no UI or reference prices reused')
