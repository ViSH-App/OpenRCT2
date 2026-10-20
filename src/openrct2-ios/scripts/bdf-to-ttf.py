"""Convert the Shinonome 12 dot BDF fonts into one pixel-outline TTF for iPad.

Usage: bdf-to-ttf.py <shinonome bdf dir> <output.ttf>

Each font pixel becomes a 100 unit square on a 1500 unit em, the same grid as the bundled
WenQuanYi Bitmap Song TTF, so the engine draws both pixel-exact at 15 ppem.
Kanji and kana come from the JIS X 0208 Mincho face, Latin from the ISO 8859-1 half-width face and
half-width katakana from the JIS X 0201 face.
"""
import pathlib
import sys

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen

UNIT = 100
NAME = 'Shinonome Mincho 12'

# The euc_jp codec maps a few JIS cells to code points that Japanese text rarely uses; also map the
# fullwidth forms that the language files use.
ALIASES = {0x301C: 0xFF5E, 0x2212: 0xFF0D, 0x2016: 0x2225, 0x00A2: 0xFFE0, 0x00A3: 0xFFE1, 0x00AC: 0xFFE2}


def read_bdf(path):
    glyphs = {}
    lines = iter(path.read_text(encoding='latin-1').splitlines())
    for line in lines:
        if not line.startswith('STARTCHAR'):
            continue
        encoding = width = box = None
        rows = []
        for line in lines:
            key, _, value = line.partition(' ')
            if key == 'ENCODING':
                encoding = int(value.split()[0])
            elif key == 'DWIDTH':
                width = int(value.split()[0])
            elif key == 'BBX':
                box = [int(v) for v in value.split()]
            elif key == 'BITMAP':
                for line in lines:
                    if line == 'ENDCHAR':
                        break
                    rows.append(line)
                break
        if encoding is not None and encoding >= 0:
            glyphs[encoding] = (width, box, rows)
    return glyphs


def jis_to_unicode(code):
    try:
        return ord(bytes([(code >> 8) | 0x80, (code & 0xFF) | 0x80]).decode('euc_jp'))
    except (UnicodeDecodeError, TypeError):
        return None


def outline(width, box, rows):
    """Pixel rows as rectangles, one per horizontal run, wound clockwise."""
    w, h, x0, y0 = box
    pen = TTGlyphPen(None)
    lsb = None
    for index, row in enumerate(rows):
        bits = bin(int(row, 16))[2:].zfill(len(row) * 4)[:w]
        y = (y0 + h - 1 - index) * UNIT
        x = 0
        while x < w:
            if bits[x] != '1':
                x += 1
                continue
            start = x
            while x < w and bits[x] == '1':
                x += 1
            left, right = (x0 + start) * UNIT, (x0 + x) * UNIT
            lsb = left if lsb is None else min(lsb, left)
            pen.moveTo((left, y))
            pen.lineTo((left, y + UNIT))
            pen.lineTo((right, y + UNIT))
            pen.lineTo((right, y))
            pen.closePath()
    return pen.glyph(), width * UNIT, lsb or 0


def main(source, output):
    source = pathlib.Path(source)
    chars = {}
    for code, glyph in read_bdf(source / 'shnmk12min.bdf').items():
        if (unicode := jis_to_unicode(code)) is not None:
            chars[unicode] = glyph
    for code, glyph in read_bdf(source / 'shnm6x12r.bdf').items():
        if 0xA1 <= code <= 0xDF:
            chars[0xFF61 + code - 0xA1] = glyph
    for code, glyph in read_bdf(source / 'shnm6x12a.bdf').items():
        if 0x20 <= code <= 0x7E or 0xA0 <= code <= 0xFF:
            chars[code] = glyph
    for original, alias in ALIASES.items():
        if original in chars and alias not in chars:
            chars[alias] = chars[original]

    order = ['.notdef'] + [f'uni{code:04X}' for code in sorted(chars)]
    glyf = {'.notdef': TTGlyphPen(None).glyph()}
    metrics = {'.notdef': (6 * UNIT, 0)}
    for code in sorted(chars):
        glyph, advance, lsb = outline(*chars[code])
        name = f'uni{code:04X}'
        glyf[name] = glyph
        metrics[name] = (advance, lsb)

    builder = FontBuilder(15 * UNIT, isTTF=True)
    builder.setupGlyphOrder(order)
    builder.setupCharacterMap({code: f'uni{code:04X}' for code in chars})
    builder.setupGlyf(glyf)
    builder.setupHorizontalMetrics(metrics)
    builder.setupHorizontalHeader(ascent=12 * UNIT, descent=-3 * UNIT)
    builder.setupNameTable({
        'familyName': NAME, 'styleName': 'Regular', 'uniqueFontIdentifier': NAME,
        'fullName': NAME, 'psName': 'ShinonomeMincho12',
        'copyright': 'Shinonome font family, The Electronic Font Open Laboratory; public domain',
    })
    builder.setupOS2(sTypoAscender=12 * UNIT, sTypoDescender=-3 * UNIT, sTypoLineGap=0,
                     usWinAscent=12 * UNIT, usWinDescent=3 * UNIT)
    builder.setupPost()
    builder.save(output)
    print(f'Converted {len(chars)} Shinonome glyphs: {output}')


if __name__ == '__main__':
    main(*sys.argv[1:3])
