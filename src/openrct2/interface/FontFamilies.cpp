/*****************************************************************************
 * Copyright (c) 2014-2026 OpenRCT2 developers
 *
 * For a complete list of all authors, please refer to contributors.md
 * Interested in contributing? Visit https://github.com/OpenRCT2/OpenRCT2
 *
 * OpenRCT2 is licensed under the GNU General Public License version 3.
 *****************************************************************************/

#include "FontFamilies.h"

#include "Fonts.h"

#ifndef DISABLE_TTF

TTFontFamily const TTFFamilyChineseSimplified = {
    #ifdef OPENRCT2_IOS
    &TTFFontWenQuanYiBitmapSong,
    #endif
    &TTFFontSimSun,        &TTFFontHeiti, &TTFFontMicroHei, &TTFFontNotoSansCJK,
};

TTFontFamily const TTFFamilyChineseTraditional = {
    #ifdef OPENRCT2_IOS
    &TTFFontWenQuanYiBitmapSong,
    #endif
    &TTFFontMingLiu,
    &TTFFontLiHeiPro,
    &TTFFontMicroHei,
    &TTFFontNotoSansCJK,
};

TTFontFamily const TTFFamilyJapanese = {
    #ifdef OPENRCT2_IOS
    &TTFFontShinonomeMincho,
    #endif
    &TTFFontHiragano,
    &TTFFontNotoSansMono,
    &TTFFontMSGothic,
    &TTFFontNotoSansCJK,
};

TTFontFamily const TTFFamilyKorean = {
    #ifdef OPENRCT2_IOS
    &TTFFontGalmuri11,
    #endif
    &TTFFontGulim,
    &TTFFontNanum,
    &TTFFontMalgun,
    &TTFFontNotoSansCJK,
};

TTFontFamily const TTFFamilyArabic = {
    &TTFFontArialUnicode,
    &TTFFontArial,
    &TTFFontNotoNaskhArabic,
};

// Vietnamese, and the fallback when the fonts of another family are missing.
TTFontFamily const TTFFamilySansSerif = {
    #ifdef OPENRCT2_IOS
    &TTFFontGalmuri11,
    #endif
    &TTFFontArialUnicode,
    &TTFFontArial,
    &TTFFontRoboto,
};

#endif // DISABLE_TTF
