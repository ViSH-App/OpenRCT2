"""Bundle the pinned pixel fonts and their licenses for iOS.

Usage: fetch-fonts.py <destination> <download cache>

WenQuanYi Bitmap Song 12px: Chinese. Shinonome 12 dot Mincho, converted from BDF: Japanese.
Galmuri11: Korean and Vietnamese.
"""
import hashlib
import pathlib
import shutil
import subprocess
import sys
import tarfile
import urllib.request
import venv
import zipfile

WQY_VERSION = 'v1.0.0-RC1-Build1'
GALMURI_VERSION = 'v2.40.4'
SHINONOME_VERSION = '0.9.11p1'
FONTTOOLS = 'fonttools==4.67.0'
DOWNLOADS = {
    'WenQuanYi.Bitmap.Song.12px.ttf': (
        f'https://github.com/AmusementClub/WenQuanYi-Bitmap-Song-TTF/releases/download/{WQY_VERSION}/'
        'WenQuanYi.Bitmap.Song.12px.ttf',
        'ce94c20796987a169ea08d24207c7a00ff457fe3b5dae5db21c7b51eab60eb3c'),
    'WenQuanYi-LICENSE.txt': (
        f'https://raw.githubusercontent.com/AmusementClub/WenQuanYi-Bitmap-Song-TTF/{WQY_VERSION}/LICENSE',
        '8177f97513213526df2cf6184d8ff986c675afb514d4e68a404010521b880643'),
    'galmuri.zip': (
        f'https://github.com/quiple/galmuri/releases/download/{GALMURI_VERSION}/Galmuri-{GALMURI_VERSION}.zip',
        'c8b3d9861a62ae73c8b1178091401cd79994812437ef386413f6dd54856e60e7'),
    'shinonome.tar.bz2': (
        f'http://openlab.ring.gr.jp/efont/dist/shinonome/shinonome-{SHINONOME_VERSION}.tar.bz2',
        '95663c95c92ba5765f63ccbdf033eb93b707be01812a989c548db943479c838f'),
}
NOTICE = f"""WenQuanYi Bitmap Song 12px, TTF conversion {WQY_VERSION}
Source: https://github.com/AmusementClub/WenQuanYi-Bitmap-Song-TTF/releases/tag/{WQY_VERSION}
Copyright the WenQuanYi Board of Trustees, FangQ and Firefly; licensed under GNU GPL v2 with the
font embedding exception; see WenQuanYi-LICENSE.txt and http://wenq.org/wqy2/index.cgi?BitmapSong.

Shinonome 12 dot Mincho {SHINONOME_VERSION}, converted from BDF to Shinonome.Mincho.12.ttf
Source: http://openlab.ring.gr.jp/efont/shinonome/
The Electronic Font Open Laboratory; public domain; see Shinonome-LICENSE.txt.

Galmuri11 {GALMURI_VERSION}
Source: https://github.com/quiple/galmuri/releases/tag/{GALMURI_VERSION}
Copyright (c) 2019-2025 Lee Minseo; licensed under the SIL Open Font License 1.1; see Galmuri-LICENSE.txt.
"""


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


def fonttools_python(cache):
    """A private virtual environment with the pinned fontTools, for the BDF conversion."""
    environment = cache / f'venv-{FONTTOOLS}'
    python = environment / 'bin/python3'
    if not python.exists():
        shutil.rmtree(environment, ignore_errors=True)
        venv.create(environment, with_pip=True)
        subprocess.run([python, '-m', 'pip', 'install', '--quiet', '--disable-pip-version-check', FONTTOOLS], check=True)
    return python


def prepare(destination, cache):
    cache.mkdir(parents=True, exist_ok=True)
    # Cached under the file's own name, with the checksum pinning its version.
    archives = {name: fetch(url, f'{expected[:12]}-{name}', expected, cache) for name, (url, expected) in DOWNLOADS.items()}
    # Replace previously bundled fonts rather than merging.
    shutil.rmtree(destination, ignore_errors=True)
    destination.mkdir(parents=True)
    for name in ('WenQuanYi.Bitmap.Song.12px.ttf', 'WenQuanYi-LICENSE.txt'):
        shutil.copyfile(archives[name], destination / name)

    with zipfile.ZipFile(archives['galmuri.zip']) as archive:
        (destination / 'Galmuri11.ttf').write_bytes(archive.read('Galmuri11.ttf'))
        (destination / 'Galmuri-LICENSE.txt').write_bytes(archive.read('LICENSE.txt'))

    shinonome = cache / f'shinonome-{SHINONOME_VERSION}'
    if not (shinonome / 'bdf/shnmk12min.bdf').exists():
        shutil.rmtree(shinonome, ignore_errors=True)
        with tarfile.open(archives['shinonome.tar.bz2']) as archive:
            for member in archive.getmembers():
                parts = member.name.split('/', 1)
                if len(parts) == 2 and parts[1]:
                    member.name = parts[1]
                    archive.extract(member, shinonome, filter='data')
    converted = cache / f'Shinonome.Mincho.12-{SHINONOME_VERSION}.ttf'
    if not converted.exists():
        subprocess.run([fonttools_python(cache), '-I', pathlib.Path(__file__).with_name('bdf-to-ttf.py'),
                        shinonome / 'bdf', converted], check=True)
    shutil.copyfile(converted, destination / 'Shinonome.Mincho.12.ttf')
    # The license is in EUC-JP; bundle it as UTF-8.
    (destination / 'Shinonome-LICENSE.txt').write_text(
        (shinonome / 'LICENSE').read_bytes().decode('euc_jp'), encoding='utf-8')

    (destination / 'NOTICE.txt').write_text(NOTICE)
    print(f'Verified and bundled pixel fonts: {destination}')


if __name__ == '__main__':
    prepare(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]))
