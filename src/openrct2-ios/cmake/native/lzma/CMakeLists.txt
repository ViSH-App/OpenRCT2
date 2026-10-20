# The LZMA and LZMA2 decoders of the LZMA SDK (public domain), for GOG installer extraction.
cmake_minimum_required(VERSION 3.24)
project(lzmasdk C)
add_library(lzmasdk STATIC "${LZMA_SDK_SOURCE}/LzmaDec.c" "${LZMA_SDK_SOURCE}/Lzma2Dec.c")
install(TARGETS lzmasdk ARCHIVE DESTINATION lib)
foreach(header 7zTypes.h 7zWindows.h Compiler.h Precomp.h LzmaDec.h Lzma2Dec.h)
    install(FILES "${LZMA_SDK_SOURCE}/${header}" DESTINATION include/lzma-sdk)
endforeach()
