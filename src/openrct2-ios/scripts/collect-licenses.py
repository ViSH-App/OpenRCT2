"""Collect the licenses of everything the iPad app ships into <destination>/index.json and text files.

Usage: collect-licenses.py <destination> <dependency sources> <bundled fonts>

The launcher's "开源许可" page lists the entries in index.json order and shows each text file.
Texts come from the pinned dependency sources, the bundled fonts and the repository itself.
"""
import functools
import json
import pathlib
import re
import shutil
import sys
import textwrap

ROOT = pathlib.Path(__file__).resolve().parents[3]
MANIFEST = ROOT / 'src/openrct2-ios/cmake/native/dependencies.json'
SOURCES = pathlib.Path()
FONTS = pathlib.Path()
THIRDPARTY = ROOT / 'src/thirdparty'

MIT = """Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""


def read(path):
    return pathlib.Path(path).read_text(encoding='utf-8', errors='replace')


def header_comment(path):
    """The leading comment block of a source file, without comment markers."""
    text = read(path).lstrip()
    if text.startswith('/*'):
        block = text[2:text.index('*/')].splitlines()
        lines = [re.sub(r'^\s*\*\s?', '', line).rstrip() for line in block]
    else:
        lines = []
        for line in text.splitlines():
            if not line.startswith('//'):
                break
            lines.append(line[2:].removeprefix(' ').rstrip())
    return textwrap.dedent('\n'.join(lines)).strip('\n') + '\n'


def creative_commons(work, licence, url, source):
    return (f'{work}\nSource: {source}\n\nLicensed under the Creative Commons {licence} license.\n'
            f'The full license text is available at {url}\n')


@functools.cache
def dependency_version(name):
    return json.loads(read(MANIFEST))[name]['version']


def asset_version(name):
    url = json.loads(read(ROOT / 'assets.json'))[name]['url']
    return re.search(r'/download/v?([^/]+)/', url).group(1)


def entries():
    yield 'openrct2', 'OpenRCT2', '', 'GPL-3.0', 'https://github.com/OpenRCT2/OpenRCT2', read(ROOT / 'licence.txt')
    yield ('objects', 'OpenRCT2 objects', asset_version('objects'), 'CC BY 4.0', 'https://github.com/OpenRCT2/objects',
           creative_commons('OpenRCT2 objects, by the OpenRCT2 contributors.', 'Attribution 4.0 International',
                            'https://creativecommons.org/licenses/by/4.0/', 'https://github.com/OpenRCT2/objects'))
    yield ('title-sequences', 'OpenRCT2 title sequences', asset_version('title-sequences'), 'CC BY 4.0',
           'https://github.com/OpenRCT2/title-sequences',
           creative_commons('OpenRCT2 title sequences, by the OpenRCT2 contributors.', 'Attribution 4.0 International',
                            'https://creativecommons.org/licenses/by/4.0/', 'https://github.com/OpenRCT2/title-sequences'))
    yield ('opensfx', 'OpenSFX', asset_version('opensfx'), 'MIT', 'https://github.com/OpenRCT2/OpenSoundEffects',
           'MIT License\n\nCopyright (c) 2019 OpenRCT2\n\n' + MIT)
    yield ('openmusic', 'OpenMusic', asset_version('openmusic'), 'CC BY-SA 4.0', 'https://github.com/OpenRCT2/OpenMusic',
           creative_commons('OpenMusic, by the OpenRCT2 contributors; see the repository for the composer of each song.',
                            'Attribution-ShareAlike 4.0 International', 'https://creativecommons.org/licenses/by-sa/4.0/',
                            'https://github.com/OpenRCT2/OpenMusic'))
    yield ('wenquanyi', 'WenQuanYi Bitmap Song', '12px', 'GPL-2.0 + font exception',
           'https://github.com/AmusementClub/WenQuanYi-Bitmap-Song-TTF', read(FONTS / 'WenQuanYi-LICENSE.txt'))
    yield ('shinonome', '東雲フォント (Shinonome)', '0.9.11', 'Public domain', 'http://openlab.ring.gr.jp/efont/shinonome/',
           read(FONTS / 'Shinonome-LICENSE.txt'))
    yield 'galmuri', 'Galmuri', '11', 'OFL-1.1', 'https://github.com/quiple/galmuri', read(FONTS / 'Galmuri-LICENSE.txt')
    yield 'sdl', 'SDL', dependency_version('SDL'), 'Zlib', 'https://www.libsdl.org', read(SOURCES / 'SDL/LICENSE.txt')
    yield ('freetype', 'FreeType', dependency_version('freetype'), 'FTL', 'https://freetype.org',
           'Portions of this software are copyright © The FreeType Project (www.freetype.org). All rights reserved.\n\n'
           + read(SOURCES / 'freetype/docs/FTL.TXT'))
    yield 'icu', 'ICU', dependency_version('icu'), 'Unicode-3.0', 'https://icu.unicode.org', read(SOURCES / 'icu/LICENSE')
    yield 'libpng', 'libpng', dependency_version('libpng'), 'libpng-2.0', 'http://www.libpng.org', read(SOURCES / 'libpng/LICENSE')
    yield 'libzip', 'libzip', dependency_version('libzip'), 'BSD-3-Clause', 'https://libzip.org', read(SOURCES / 'libzip/LICENSE')
    yield 'zstd', 'Zstandard', dependency_version('zstd'), 'BSD-3-Clause', 'https://facebook.github.io/zstd/', read(SOURCES / 'zstd/LICENSE')
    yield ('lzma-sdk', 'LZMA SDK', dependency_version('7zip'), 'Public domain', 'https://www.7-zip.org/sdk.html',
           'The LZMA and LZMA2 decoders (LzmaDec.c, Lzma2Dec.c) of the LZMA SDK by Igor Pavlov:\n\n'
           + header_comment(SOURCES / '7zip/C/LzmaDec.c') + header_comment(SOURCES / '7zip/C/Lzma2Dec.c'))
    yield ('nlohmann-json', 'JSON for Modern C++', '3.11.3', 'MIT', 'https://github.com/nlohmann/json',
           'MIT License\n\nCopyright (c) 2013-2023 Niels Lohmann\n\n' + MIT)
    yield 'sfl', 'sfl-library', '', 'Zlib', 'https://github.com/slavenf/sfl-library', header_comment(THIRDPARTY / 'sfl/devector.hpp')
    yield 'linenoise', 'cpp-linenoise', '', 'BSD-2-Clause', 'https://github.com/yhirose/cpp-linenoise', header_comment(THIRDPARTY / 'linenoise.hpp')
    yield 'picosha2', 'PicoSHA2', '', 'MIT', 'https://github.com/okdshin/PicoSHA2', header_comment(THIRDPARTY / 'picosha2.hpp')
    yield 'base64', 'base64', '', 'MIT', 'https://github.com/tobiaslocker/base64', header_comment(THIRDPARTY / 'base64.hpp')


def main(destination):
    destination = pathlib.Path(destination)
    shutil.rmtree(destination, ignore_errors=True)
    destination.mkdir(parents=True)
    index = []
    for key, name, version, licence, url, text in entries():
        (destination / f'{key}.txt').write_text(text, encoding='utf-8')
        index.append({'id': key, 'name': name, 'version': version, 'license': licence, 'url': url, 'file': f'{key}.txt'})
    (destination / 'index.json').write_text(json.dumps(index, ensure_ascii=False, indent=1), encoding='utf-8')


if __name__ == '__main__':
    SOURCES, FONTS = pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
    main(sys.argv[1])
