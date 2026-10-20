"""Fetch pinned sources for the iPhoneOS dependency build (Python 3.12+)."""
import concurrent.futures
import hashlib
import pathlib
import shutil
import tarfile
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2] / 'build/ios-deps/sources'
SOURCES = {
    'SDL': ('https://codeload.github.com/libsdl-org/SDL/tar.gz/refs/tags/release-2.32.10',
            '03f9d7c191a837525c9cda6406af2f2e48be02b5e7eb03d949cc9f1e9ca41c8b'),
    'zstd': ('https://codeload.github.com/facebook/zstd/tar.gz/refs/tags/v1.5.7',
             '37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3'),
    'libpng': ('https://codeload.github.com/pnggroup/libpng/tar.gz/refs/tags/v1.6.50',
               '71158e53cfdf2877bc99bcab33641d78df3f48e6e0daad030afe9cb8c031aa46'),
    'libzip': ('https://libzip.org/download/libzip-1.11.4.tar.xz',
               '8a247f57d1e3e6f6d11413b12a6f28a9d388de110adc0ec608d893180ed7097b'),
    'freetype': ('https://codeload.github.com/freetype/freetype/tar.gz/refs/tags/VER-2-13-3',
                 'bc5c898e4756d373e0d991bab053036c5eb2aa7c0d5c67e8662ddc6da40c4103'),
    'icu': ('https://github.com/unicode-org/icu/releases/download/release-76-1/icu4c-76_1-src.tgz',
            'dfacb46bfe4747410472ce3e1144bf28a102feeaa4e3875bac9b4c6cf30f4f3e'),
}


def fetch(item):
    name, (url, expected) = item
    archive = ROOT / (name + '.archive')
    if not archive.exists():
        temporary = archive.with_suffix('.download')
        urllib.request.urlretrieve(url, temporary)
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != expected:
            raise RuntimeError(f'Checksum mismatch: {temporary}')
        temporary.replace(archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
        raise RuntimeError(f'Checksum mismatch: {archive}; remove this cached archive and retry')
    destination = ROOT / name
    if not destination.exists():
        staging = ROOT / (name + '.partial')
        if staging.exists():
            shutil.rmtree(staging)  # Only our incomplete extraction, never an installed dependency.
        staging.mkdir()
        with tarfile.open(archive) as source:
            for member in source.getmembers():
                parts = member.name.split('/', 1)
                if len(parts) == 2 and parts[1]:
                    member.name = parts[1]
                    source.extract(member, staging, filter='data')
        staging.rename(destination)
    print(f'Verified {name}', flush=True)


if __name__ == '__main__':
    ROOT.mkdir(parents=True, exist_ok=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as executor:
        list(executor.map(fetch, SOURCES.items()))
