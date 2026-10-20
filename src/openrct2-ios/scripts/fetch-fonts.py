"""Bundle the pinned WenQuanYi Bitmap Song 12px font and its license for iPad."""
import hashlib
import pathlib
import shutil
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[3]
VERSION = 'v1.0.0-RC1-Build1'
FILES = {
    'WenQuanYi.Bitmap.Song.12px.ttf': (
        f'https://github.com/AmusementClub/WenQuanYi-Bitmap-Song-TTF/releases/download/{VERSION}/'
        'WenQuanYi.Bitmap.Song.12px.ttf',
        'ce94c20796987a169ea08d24207c7a00ff457fe3b5dae5db21c7b51eab60eb3c'),
    'WenQuanYi-LICENSE.txt': (
        f'https://raw.githubusercontent.com/AmusementClub/WenQuanYi-Bitmap-Song-TTF/{VERSION}/LICENSE',
        '8177f97513213526df2cf6184d8ff986c675afb514d4e68a404010521b880643'),
}


def fetch(url, name, expected, cache):
    path = cache / name
    if not path.exists():
        temporary = path.with_suffix('.download')
        urllib.request.urlretrieve(url, temporary)
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != expected:
            raise RuntimeError(f'Font checksum mismatch: {url}')
        temporary.replace(path)
    if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise RuntimeError(f'Font checksum mismatch: {path}')
    return path


def prepare(destination):
    cache = ROOT / 'build/ios-font-download'
    cache.mkdir(parents=True, exist_ok=True)
    # Replace previously bundled fonts (e.g. Fusion Pixel) rather than merging.
    shutil.rmtree(destination, ignore_errors=True)
    destination.mkdir(parents=True)
    for name, (url, expected) in FILES.items():
        shutil.copyfile(fetch(url, f'{VERSION}-{name}', expected, cache), destination / name)
    (destination / 'NOTICE.txt').write_text(
        f'WenQuanYi Bitmap Song 12px, TTF conversion {VERSION}\n'
        f'Source: https://github.com/AmusementClub/WenQuanYi-Bitmap-Song-TTF/releases/tag/{VERSION}\n'
        'Copyright the WenQuanYi Board of Trustees, FangQ and Firefly; licensed under GNU GPL v2 with the\n'
        'font embedding exception; see WenQuanYi-LICENSE.txt and http://wenq.org/wqy2/index.cgi?BitmapSong.\n')
    print(f'Verified and bundled WenQuanYi Bitmap Song: {destination}')


if __name__ == '__main__':
    prepare(pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / 'build/ios-data/fonts')
