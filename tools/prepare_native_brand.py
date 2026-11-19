"""Package the original approved logo for platform icon/launch slots.

Only uniform resizing and safe background padding; never crop/recolor the logo.
Requires Pillow. Run from any directory. No generated substitute brand artwork.
"""
from pathlib import Path
import hashlib
import json
from PIL import Image

root = Path(__file__).resolve().parents[1]
source = root / 'assets/sabiha_brand_approved.png'
original_hash = hashlib.sha256(source.read_bytes()).hexdigest()
logo = Image.open(source).convert('RGBA')

def square(size, inset=.17):
    canvas = Image.new('RGBA', (size, size), 'white')
    resized = logo.copy()
    bound = round(size * (1 - 2 * inset))
    resized.thumbnail((bound, bound), Image.Resampling.LANCZOS)
    canvas.alpha_composite(resized, ((size-resized.width)//2, (size-resized.height)//2))
    return canvas.convert('RGB')

for density, size in [('mdpi',48),('hdpi',72),('xhdpi',96),('xxhdpi',144),('xxxhdpi',192)]:
    square(size).save(root / f'android/app/src/main/res/mipmap-{density}/ic_launcher.png')

res = root / 'android/app/src/main/res'
(res / 'drawable-nodpi').mkdir(exist_ok=True)
square(720, .32).save(res / 'drawable-nodpi/sabiha_launch.png')
for folder in ['drawable', 'drawable-v21']:
    (res / folder / 'launch_background.xml').write_text('''<?xml version="1.0" encoding="utf-8"?>
<layer-list xmlns:android="http://schemas.android.com/apk/res/android">
    <item android:drawable="@color/sabiha_navy" />
    <item android:width="200dp" android:height="200dp" android:gravity="center" android:drawable="@drawable/sabiha_launch" />
</layer-list>
''')
(res / 'values/colors.xml').write_text('''<?xml version="1.0" encoding="utf-8"?>
<resources><color name="sabiha_navy">#071A36</color></resources>
''')
for folder in ['values', 'values-night']:
    (res / folder / 'styles.xml').write_text('''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <style name="LaunchTheme" parent="@android:style/Theme.Light.NoTitleBar">
        <item name="android:windowBackground">@drawable/launch_background</item>
        <item name="android:statusBarColor">@color/sabiha_navy</item>
        <item name="android:navigationBarColor">@color/sabiha_navy</item>
        <item name="android:windowLightStatusBar">false</item>
    </style>
    <style name="NormalTheme" parent="@android:style/Theme.Light.NoTitleBar">
        <item name="android:windowBackground">@color/sabiha_navy</item>
        <item name="android:statusBarColor">@color/sabiha_navy</item>
        <item name="android:navigationBarColor">@color/sabiha_navy</item>
        <item name="android:windowLightStatusBar">false</item>
    </style>
</resources>
''')
for folder in ['values-v31', 'values-night-v31']:
    (res / folder).mkdir(exist_ok=True)
    (res / folder / 'styles.xml').write_text('''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <style name="LaunchTheme" parent="@android:style/Theme.Light.NoTitleBar">
        <item name="android:windowBackground">@drawable/launch_background</item>
        <item name="android:windowSplashScreenBackground">@color/sabiha_navy</item>
        <item name="android:windowSplashScreenAnimatedIcon">@drawable/sabiha_launch</item>
        <item name="android:windowSplashScreenAnimationDuration">200</item>
        <item name="android:statusBarColor">@color/sabiha_navy</item>
        <item name="android:navigationBarColor">@color/sabiha_navy</item>
        <item name="android:windowLightStatusBar">false</item>
    </style>
</resources>
''')

icons = root / 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
for entry in json.loads((icons / 'Contents.json').read_text())['images']:
    size = round(float(entry['size'].split('x')[0]) * float(entry['scale'].replace('x','')))
    square(size).save(icons / entry['filename'])
launch = root / 'ios/Runner/Assets.xcassets/LaunchImage.imageset'
for scale in [1,2,3]:
    square(200*scale, .08).save(launch / ('LaunchImage' + (f'@{scale}x' if scale>1 else '') + '.png'))

story = root / 'ios/Runner/Base.lproj/LaunchScreen.storyboard'
s = story.read_text().replace('contentMode="center" image="LaunchImage"', 'contentMode="scaleAspectFit" image="LaunchImage"')
s = s.replace('red="1" green="1" blue="1"', 'red="0.02745098" green="0.10196078" blue="0.21176471"')
anchor = '<constraints>'
if 'sabiha-launch-width' not in s:
    s = s.replace(anchor, anchor + '''
                            <constraint firstItem="YRO-k0-Ey4" firstAttribute="width" constant="200" id="sabiha-launch-width"/>
                            <constraint firstItem="YRO-k0-Ey4" firstAttribute="height" constant="200" id="sabiha-launch-height"/>''', 1)
s = s.replace('name="LaunchImage" width="168" height="185"', 'name="LaunchImage" width="200" height="200"')
story.write_text(s)
assert hashlib.sha256(source.read_bytes()).hexdigest() == original_hash
print('Native icon and launch assets prepared; original bitmap SHA256 unchanged.')
