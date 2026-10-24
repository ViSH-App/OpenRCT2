"""Widen the glyphs of a pixel-outline font whose pixels reach past their advance.

Usage: widen-overhanging-glyphs.py <input font> <output font> <pixel units>

WenQuanYi Bitmap Song's yen sign is 7 pixels wide on a 6 pixel advance, so it touches the digit after
it, as in the CN¥ prefix of money amounts. Each such glyph gets an advance one pixel past its ink.
"""
import pathlib
import sys

from fontTools.pens.boundsPen import BoundsPen
from fontTools.ttLib import TTFont


def widen(source, destination, unit):
    font = TTFont(source)
    glyphs = font.getGlyphSet()
    metrics = font['hmtx'].metrics
    for name in font.getGlyphOrder():
        pen = BoundsPen(glyphs)
        glyphs[name].draw(pen)
        advance, lsb = metrics[name]
        if pen.bounds is not None and pen.bounds[2] > advance:
            metrics[name] = (int(pen.bounds[2]) + unit, lsb)
            print(f'Widened {name} from {advance} to {metrics[name][0]} units')
    font.save(destination)


if __name__ == '__main__':
    widen(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), int(sys.argv[3]))
