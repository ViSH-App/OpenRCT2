"""Bundle the pinned Fusion Pixel Font (Simplified Chinese) and its licenses for iPad."""
import hashlib
import pathlib
import shutil
import sys
import urllib.request
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[3]
VERSION = '2026.10.16'
BASE = f'https://github.com/TakWolf/fusion-pixel-font/releases/download/{VERSION}/'
ARCHIVES = {
    '10px': '2a99376b73ab0139fb0e144b839c61c59f17d46388096a0025209e3972b4945a',
    '8px': 'f68fa139be61ccf31dc15c2afe086fa9318530a5d92fe14a4a42a236672bf5f7',
}


def download(size, expected, cache):
    name = f'fusion-pixel-font-{size}-proportional-otf-v{VERSION}.zip'
    archive = cache / name
    if not archive.exists():
        temporary = archive.with_suffix('.download')
        urllib.request.urlretrieve(BASE + name, temporary)
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != expected:
            raise RuntimeError(f'Font checksum mismatch: {name}')
        temporary.replace(archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
        raise RuntimeError(f'Font checksum mismatch: {archive}')
    return archive


def prepare(destination):
    cache = ROOT / 'build/ios-font-download'
    cache.mkdir(parents=True, exist_ok=True)
    # Replace previously bundled fonts (e.g. Noto Sans CJK) rather than merging.
    shutil.rmtree(destination, ignore_errors=True)
    destination.mkdir(parents=True)
    for size, expected in ARCHIVES.items():
        with zipfile.ZipFile(download(size, expected, cache)) as z:
            for member in z.infolist():
                path = pathlib.PurePosixPath(member.filename)
                if member.is_dir():
                    continue
                if path.is_absolute() or '..' in path.parts:
                    raise ValueError(member.filename)
                if path.name == f'fusion-pixel-{size}-proportional-zh_hans.otf':
                    target = destination / path.name
                elif path.name == 'OFL.txt' and len(path.parts) == 1:
                    target = destination / 'OFL.txt'
                elif path.parts[0] == 'LICENSES':
                    target = destination / 'LICENSES' / size / pathlib.PurePosixPath(*path.parts[1:])
                else:
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(z.read(member))
    (destination / 'NOTICE.txt').write_text(
        f'Fusion Pixel Font {VERSION} (10px and 8px, proportional, zh_hans)\n'
        f'Source: https://github.com/TakWolf/fusion-pixel-font/releases/tag/{VERSION}\n'
        'Licensed under SIL Open Font License 1.1; see OFL.txt.\n'
        'Licenses of the upstream fonts it is built from are under LICENSES/.\n')
    print(f'Verified and bundled Fusion Pixel Font: {destination}')


if __name__ == '__main__':
    prepare(pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / 'build/ios-data/fonts')
