#!/usr/bin/env python3
"""Pack a Mac app bundle into a disk image (a ".dmg") with a nice layout: the app on the left, a symlink to /Applications on the right, a background with an arrow between the two, a custom icon on the
volume, and the window opened in icon view at a fixed size.

    scripts/mac_dmg.py "Super Mario Bros. Wonder.app"
    scripts/mac_dmg.py --out ~/Desktop --format ulfo "Yoshi's Crafted World.app"

The app bundle is not changed: it is copied into the image. The image is built read-write (the window layout and the volume icon are written into it) and then converted to a compressed read-only
image, so the finished .dmg opens with the same window on every Mac. Nothing has to be installed: dragging the app to /Applications copies it there.

The layout is written by the Finder over AppleScript, so the script needs permission to control the Finder (System Settings > Privacy & Security > Automation). With --no-layout the image is built
without it (a plain volume with the app and the symlink).

The background is drawn with Pillow (python3 -m pip install pillow). Without it the image is built without a background, the rest of the layout unchanged.
"""
import argparse
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

DEFAULT_WINDOW = (600, 400)      # the Finder window (points)
DEFAULT_ICON = 128               # the icon size in the window (points)
APP_POS = (170, 190)             # where the app icon is placed in the icon view (points, from the view's top left)
APPS_POS = (430, 190)            # where the /Applications symlink is placed

# The window's layout. "measure" places the two items and reads back where the Finder put them (its own coordinates, which the background is drawn in), "finish" writes the background.
LAYOUT_SCRIPT = '''on run argv
	set volName to item 1 of argv
	set mode to item 2 of argv
	set bgPath to item 3 of argv
	set appName to item 4 of argv
	set iconSize to (item 5 of argv) as integer
	set AppleScript's text item delimiters to ","
	set appParts to text items of (item 6 of argv)
	set appsParts to text items of (item 7 of argv)
	set winParts to text items of (item 8 of argv)
	tell application "Finder"
		tell disk volName
			open
			set theWindow to missing value
			repeat 40 times   -- the window needs a moment before its items can be placed
				try
					set theWindow to container window
					if (count of items of theWindow) > 0 then exit repeat
				end try
				delay 0.25
			end repeat
			delay 1
			set current view of theWindow to icon view
			set toolbar visible of theWindow to false
			set statusbar visible of theWindow to false
			set the bounds of theWindow to {(item 1 of winParts) as integer, (item 2 of winParts) as integer, (item 3 of winParts) as integer, (item 4 of winParts) as integer}
			set viewOptions to the icon view options of theWindow
			set arrangement of viewOptions to not arranged
			set icon size of viewOptions to iconSize
			set text size of viewOptions to 12
			if mode is "measure" then
				set position of item appName of theWindow to {(item 1 of appParts) as integer, (item 2 of appParts) as integer}
				set position of item "Applications" of theWindow to {(item 1 of appsParts) as integer, (item 2 of appsParts) as integer}
			end if
			if bgPath is not "" then
				set background picture of viewOptions to ((POSIX file bgPath) as alias)
			end if
			update without registering applications
			delay 1
			close
		end tell
	end tell
	if mode is "measure" then
		tell application "Finder"   -- the window is opened again: it then shows the places the Finder stored
			tell disk volName
				open
				set theWindow to missing value
				repeat 40 times
					try
						set theWindow to container window
						if (count of items of theWindow) > 0 then exit repeat
					end try
					delay 0.25
				end repeat
				delay 1
				set r to ""
				try
					set p to position of item appName of theWindow
					set r to r & "app=" & (item 1 of p as text) & "," & (item 2 of p as text)
				on error
					set r to r & "app=0,0"
				end try
				try
					set p to position of item "Applications" of theWindow
					set r to r & ";apps=" & (item 1 of p as text) & "," & (item 2 of p as text)
				on error
					set r to r & ";apps=0,0"
				end try
				close
			end tell
		end tell
		return r
	end if
end run'''


def say(msg: str) -> None:
    print(msg, flush=True)


def fail(msg: str) -> 'NoReturn':
    print(f'[RED] {msg}', file=sys.stderr, flush=True)
    sys.exit(1)


def run(cmd, check=True, timeout=None):
    try:
        p = subprocess.run([str(c) for c in cmd], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        fail(f'{cmd[0]} did not finish in {timeout} s')
    if check and p.returncode:
        out = (p.stderr or p.stdout).strip().splitlines()
        fail(f'{cmd[0]} failed (exit {p.returncode}): {out[-1] if out else "no message"}')
    return p


def app_info(app: Path):
    """The app's display name and its icon (an .icns in Contents/Resources), read from its Info.plist."""
    plist = app / 'Contents' / 'Info.plist'
    if not plist.is_file():
        fail(f'{app} is not a Mac app bundle (no Contents/Info.plist)')
    with open(plist, 'rb') as f:
        pl = plistlib.load(f)
    name = pl.get('CFBundleDisplayName') or pl.get('CFBundleName') or app.stem
    res = app / 'Contents' / 'Resources'
    icon = None
    named = pl.get('CFBundleIconFile')
    if named:
        for cand in (res / f'{named}.icns', res / named):
            if cand.is_file():
                icon = cand
                break
    if icon is None:
        found = sorted(res.glob('*.icns'))
        icon = found[0] if found else None
    return name, icon


def font(size: int):
    """A bold sans font for the background's title, or the default one."""
    from PIL import ImageFont
    for path, index in (('/System/Library/Fonts/Avenir Next.ttc', 0), ('/System/Library/Fonts/Supplemental/Arial Bold.ttf', 0),
                        ('/System/Library/Fonts/Supplemental/Arial.ttf', 0)):
        if Path(path).is_file():
            try:
                return ImageFont.truetype(path, size, index=index)
            except OSError:
                pass
    return ImageFont.load_default()


def make_background(title: str, out: Path, window, icon_size: int, app_at, apps_at):
    """The window's background: a dark blue gradient with a soft light in the corner, an arrow from the app to the /Applications symlink and the game's name below.

    The picture is drawn in the window's own coordinates (points, from the window's top left): the Finder draws it there, one pixel to one point, so the arrow sits between the two icons."""
    try:
        from PIL import Image, ImageChops, ImageDraw, ImageFilter
    except ImportError:
        say('[RED] the background needs Pillow (python3 -m pip install pillow); the image is built without one')
        return False
    w, h = window
    top, bottom = (40, 58, 80), (12, 17, 24)
    grad = Image.new('RGB', (1, h))
    for y in range(h):
        t = y / max(1, h - 1)
        grad.putpixel((0, y), tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    img = grad.resize((w, h))
    glow = Image.new('L', (w, h), 0)
    ImageDraw.Draw(glow).ellipse([-w * 0.30, -h * 0.62, w * 0.78, h * 0.62], fill=64)
    glow = glow.filter(ImageFilter.GaussianBlur(w * 0.10))
    blue = Image.new('RGB', (w, h), (64, 110, 180))
    img = ImageChops.screen(img, ImageChops.multiply(blue, Image.merge('RGB', (glow, glow, glow))))

    # the arrow from the app to the /Applications symlink
    ax, ay = app_at
    bx, by = apps_at
    half = icon_size / 2
    x1, x2 = ax + half + 18, bx - half - 18
    y = (ay + by) / 2
    head = 20
    line = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    ld = ImageDraw.Draw(line)
    ld.line([(x1, y), (x2 - head, y)], fill=(205, 218, 235, 235), width=8)
    ld.polygon([(x2, y), (x2 - head, y - head * 0.62), (x2 - head, y + head * 0.62)], fill=(205, 218, 235, 235))
    img = Image.alpha_composite(img.convert('RGBA'), line).convert('RGB')

    # the name below (the picture is cut off at the bottom of the window, so it is kept clear of it)
    d = ImageDraw.Draw(img)
    f = font(22)
    text = title
    while d.textlength(text, font=f) > w * 0.8 and len(text) > 4:
        text = text[:-2]
        if not text.endswith('…'):
            text += '…'
    tw = d.textlength(text, font=f)
    d.text(((w - tw) / 2, max(y + 90, h - 70)), text, font=f, fill=(226, 234, 245))
    img.save(out)
    return True


def volume_icon(icon: Path, mount: Path) -> bool:
    """The image's own icon (the game's icon on the volume): the .icns at the volume's root and the custom icon flag on it. The Finder takes the .icns away when it opens the volume, so this is
    done after the window's layout is written."""
    if icon is None:
        return False
    try:
        shutil.copy(icon, mount / '.VolumeIcon.icns')
    except OSError as e:
        say(f'[RED] the volume icon was not copied ({e})')
        return False
    p = run(['SetFile', '-a', 'C', mount], check=False)
    if p.returncode:
        say(f'[RED] the volume icon was not set ({(p.stderr or p.stdout).strip() or "SetFile failed"})')
        return False
    return True


def hide(path: Path) -> None:
    """The helper files are hidden: a dot in the name is not enough for the Finder."""
    p = run(['SetFile', '-a', 'V', path], check=False)
    if p.returncode:
        say(f'[RED] {path.name} was not hidden ({(p.stderr or p.stdout).strip() or "SetFile failed"})')


def write_layout(volume: str, mode: str, background: Path, app_name: str, window, icon_size: int, tries: int = 3):
    """The window's layout (the icon view, the icon positions, the background), written by the Finder into the image's .DS_Store. In the "measure" mode the places the Finder put the two
    items are returned: the background is drawn in them.

    A busy Finder (a copy or a search of its own) has no window ready for the disk, so a failure is tried again a few times before it is given up."""
    x, y = 100, 100
    bounds = f'{x},{y},{x + window[0]},{y + window[1]}'
    cmd = ['osascript', '-e', LAYOUT_SCRIPT, volume, mode, str(background) if background else '', app_name, str(icon_size),
           f'{APP_POS[0]},{APP_POS[1]}', f'{APPS_POS[0]},{APPS_POS[1]}', bounds]
    p = None
    for attempt in range(tries):
        p = run(cmd, check=False, timeout=300)
        if not p.returncode:
            break
        if attempt + 1 < tries:
            say(f'· the Finder was busy ({p.stderr.strip().splitlines()[-1] if p.stderr.strip() else "no message"}), trying again')
            time.sleep(3)
    if p.returncode:
        msg = (p.stderr or p.stdout).strip().splitlines()
        say(f'[RED] the window layout was not written ({msg[-1] if msg else "osascript failed"}); the image opens in the Finder\'s own view')
        say('     (the Finder has to allow the automation: System Settings > Privacy & Security > Automation)')
        return None
    if mode != 'measure':
        return None
    out = {}
    for part in (p.stdout or '').split(';'):
        if '=' in part:
            k, v = part.split('=')
            try:
                out[k.strip()] = tuple(int(x) for x in v.split(','))
            except ValueError:
                pass
    return out


def finder_shows_all_files() -> bool:
    """Whether the Finder shows the hidden files (then the image's helper folder is visible in the window)."""
    p = subprocess.run(['defaults', 'read', 'com.apple.finder', 'AppleShowAllFiles'], capture_output=True, text=True)
    return p.returncode == 0 and p.stdout.strip() == '1'


def dir_size(path: Path) -> int:
    p = subprocess.run(['du', '-sk', str(path)], capture_output=True, text=True)
    return int(p.stdout.split()[0]) if p.returncode == 0 else 0


def build(app: Path, out: Path, args) -> None:
    name, icon = app_info(app)
    volume = name.replace(':', '-').replace('/', '-')
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists():
        out.unlink()

    tmp = Path(tempfile.mkdtemp(prefix='nxdmg-'))
    rw = tmp / 'rw.dmg'
    mount = Path(tempfile.mkdtemp(prefix='nxdmg-mnt-'))   # the Finder shows a disk under the name of its mount point: a name of its own keeps it apart from the volumes of other runs
    try:
        size_mb = dir_size(app) // 1024 + 400
        say(f'· {name}: an image of {size_mb} MB, from {app}')
        run(['hdiutil', 'create', '-size', f'{size_mb}m', '-fs', 'HFS+', '-volname', volume, '-ov', rw])   # a blank image is UDRW
        run(['hdiutil', 'attach', '-nobrowse', '-noverify', '-noautoopen', '-mountpoint', mount, rw])
        if not os.path.ismount(mount):
            fail(f'the image was not mounted at {mount}')   # writing into a plain folder would leave the image empty

        run(['ditto', '--rsrc', '--extattr', app, mount / app.name], timeout=7200)   # the bundle is copied as it is (ditto merges a directory into an existing one)
        (mount / 'Applications').symlink_to('/Applications')
        (mount / '.background').mkdir(exist_ok=True)

        if not args.no_layout:
            where = write_layout(mount.name, 'measure', None, app.name, args.window, args.icon_size)
            if where and 'app' in where and 'apps' in where:
                background = tmp / 'background.png'
                if make_background(args.title or name, background, args.window, args.icon_size, where['app'], where['apps']):
                    shutil.copy(background, mount / '.background' / 'background.png')
                    write_layout(mount.name, 'finish', mount / '.background' / 'background.png', app.name, args.window, args.icon_size)
            else:
                say('[RED] the places of the two icons were not read back; the image opens in the Finder\'s own view')
        if volume_icon(icon, mount):
            say('· the volume icon is the game\'s own icon')
        hide(mount / '.background')
        hide(mount / '.VolumeIcon.icns')

        run(['sync'])
        if not os.path.ismount(mount):
            say('[RED] the volume is no longer mounted; the image is empty')
        p = run(['hdiutil', 'detach', mount], check=False)
        if p.returncode:
            say(f'[RED] the volume was not detached ({p.stderr.strip() or "hdiutil failed"})')

        say(f'· compressing to {args.format.upper()} (a few minutes for {size_mb} MB)')
        run(['hdiutil', 'convert', '-format', args.format.upper(), '-o', out, rw], timeout=7200)
        if args.verify:
            run(['hdiutil', 'verify', out], timeout=3600)
            say('· the image is verified')
        say(f'✓ {out} ({out.stat().st_size / (1 << 30):.1f} GB)')
        if finder_shows_all_files():
            say('· the Finder shows all files: the image\'s helper folder ".background" is then visible in the window (Cmd+Shift+. hides it)')
    finally:
        run(['hdiutil', 'detach', mount], check=False)   # the volume is left mounted when a step failed
        if args.keep:
            say(f'· the read-write image is kept in {tmp}')
        else:
            shutil.rmtree(tmp, ignore_errors=True)
        shutil.rmtree(mount, ignore_errors=True)        # the mount point is a folder of its own, it goes too


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0], formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    ap.add_argument('app', nargs='+', type=Path, help='the app bundle(s) to pack')
    ap.add_argument('--out', type=Path, default=None, help='where the image is written (default: next to the app)')
    ap.add_argument('--name', default=None, help='the image\'s name without the extension (default: the app\'s name)')
    ap.add_argument('--format', default='udzo', choices=['udzo', 'ulfo', 'u3zo', 'udrw'], help='the compression: udzo (default), ulfo (smaller, slower), u3zo (larger), udrw (none)')
    ap.add_argument('--title', default=None, help='the name on the background (default: the app\'s name)')
    ap.add_argument('--window', nargs=2, type=int, default=list(DEFAULT_WINDOW), metavar=('W', 'H'), help='the window size in points (default: 600 400)')
    ap.add_argument('--icon-size', type=int, default=DEFAULT_ICON, help='the icon size in the window (default: 128)')
    ap.add_argument('--no-layout', action='store_true', help='do not set the window layout (no Finder automation, no background)')
    ap.add_argument('--verify', action='store_true', help='verify the finished image')
    ap.add_argument('--keep', action='store_true', help='keep the read-write image')
    args = ap.parse_args()

    for app in args.app:
        app = app.expanduser().resolve()
        if not app.is_dir():
            fail(f'{app} does not exist')
        name, _ = app_info(app)
        out_dir = args.out.expanduser() if args.out else app.parent
        out = out_dir / f'{args.name or name}.dmg'
        build(app, out, args)
    return 0


if __name__ == '__main__':
    sys.exit(main())
