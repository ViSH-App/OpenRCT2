"""Bundle the pinned Noto Sans CJK SC font and its SIL OFL license for iPad."""
import hashlib
import pathlib
import shutil
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = 'https://raw.githubusercontent.com/notofonts/noto-cjk/523d033d6cb47f4a80c58a35753646f5c3608a78/'
FILES = {
    'NotoSansCJKsc-Regular.otf': ('Sans/OTF/SimplifiedChinese/NotoSansCJKsc-Regular.otf',
        '2c76254f6fc379fddfce0a7e84fb5385bb135d3e399294f6eeb6680d0365b74b'),
    'OFL.txt': ('LICENSE', '6a73f9541c2de74158c0e7cf6b0a58ef774f5a780bf191f2d7ec9cc53efe2bf2'),
}


def prepare(destination):
    cache = ROOT / 'build/ios-font-download'
    cache.mkdir(parents=True, exist_ok=True)
    destination.mkdir(parents=True, exist_ok=True)
    for name, (path, expected) in FILES.items():
        source = cache / name
        if not source.exists():
            temporary = source.with_suffix('.download')
            urllib.request.urlretrieve(BASE + path, temporary)
            if hashlib.sha256(temporary.read_bytes()).hexdigest() != expected:
                raise RuntimeError(f'Font checksum mismatch: {name}')
            temporary.replace(source)
        if hashlib.sha256(source.read_bytes()).hexdigest() != expected:
            raise RuntimeError(f'Font checksum mismatch: {source}')
        shutil.copy2(source, destination / name)
    (destination / 'NOTICE.txt').write_text(
        'Noto Sans CJK SC Regular 2.004\n'
        'Source: https://github.com/notofonts/noto-cjk/tree/523d033d6cb47f4a80c58a35753646f5c3608a78\n'
        'Licensed under SIL Open Font License 1.1; see OFL.txt.\n')
    print(f'Verified and bundled Noto Sans CJK SC: {destination}')


if __name__ == '__main__':
    prepare(pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / 'build/ios-data/fonts')
