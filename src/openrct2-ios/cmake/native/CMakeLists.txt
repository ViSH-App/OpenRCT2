# Everything the iOS app links or bundles besides its own Xcode sources, for one SDK:
# the pinned third-party libraries, the host graphics generator and the free assets.
# Configured and built by the Xcode target "Native dependencies" (scripts/xcode-native.sh).
cmake_minimum_required(VERSION 3.24)
project(OpenRCT2iOSNative NONE)
include(ExternalProject)

set(IOS_PLATFORM "iphoneos" CACHE STRING "iphoneos or iphonesimulator")
set(IOS_DEPLOYMENT_TARGET "" CACHE STRING "The project's IPHONEOS_DEPLOYMENT_TARGET")
set(IOS_PREFIX "" CACHE PATH "Install prefix of the libraries for IOS_PLATFORM")
set(IOS_SOURCES "" CACHE PATH "Extracted dependency sources for IOS_PLATFORM")
set(IOS_DOWNLOADS "" CACHE PATH "Shared cache of the pinned archives")
set(IOS_HOST_DIR "" CACHE PATH "Shared build of the host graphics generator")
set(IOS_DATA_DIR "" CACHE PATH "Shared prepared assets that the app bundles")
foreach(variable IOS_DEPLOYMENT_TARGET IOS_PREFIX IOS_SOURCES IOS_DOWNLOADS IOS_HOST_DIR IOS_DATA_DIR)
    if(NOT ${variable})
        message(FATAL_ERROR "${variable} is required")
    endif()
endforeach()

if(IOS_PLATFORM STREQUAL "iphoneos")
    set(IOS_TARGET "arm64-apple-ios${IOS_DEPLOYMENT_TARGET}")
elseif(IOS_PLATFORM STREQUAL "iphonesimulator")
    set(IOS_TARGET "arm64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator")
else()
    message(FATAL_ERROR "Unsupported IOS_PLATFORM: ${IOS_PLATFORM}")
endif()
get_filename_component(REPO_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../../.." ABSOLUTE)
execute_process(COMMAND xcrun --sdk ${IOS_PLATFORM} --show-sdk-path OUTPUT_VARIABLE IOS_SDK_PATH OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
execute_process(COMMAND xcrun -f clang OUTPUT_VARIABLE CLANG OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
execute_process(COMMAND xcrun -f clang++ OUTPUT_VARIABLE CLANGXX OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
cmake_host_system_information(RESULT JOBS QUERY NUMBER_OF_LOGICAL_CORES)
find_package(Python3 3.11 REQUIRED COMPONENTS Interpreter)
find_program(MAKE_PROGRAM make REQUIRED)

file(READ "${CMAKE_CURRENT_LIST_DIR}/dependencies.json" MANIFEST)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${CMAKE_CURRENT_LIST_DIR}/dependencies.json")

# The pinned archive of a manifest entry, verified and extracted into IOS_SOURCES/<name>.
function(pinned_source variable name)
    string(JSON url GET "${MANIFEST}" "${name}" url)
    string(JSON file GET "${MANIFEST}" "${name}" file)
    string(JSON sha256 GET "${MANIFEST}" "${name}" sha256)
    set(${variable} URL "${url}" URL_HASH "SHA256=${sha256}" DOWNLOAD_NAME "${file}" DOWNLOAD_DIR "${IOS_DOWNLOADS}"
        DOWNLOAD_EXTRACT_TIMESTAMP OFF SOURCE_DIR "${IOS_SOURCES}/${name}" PARENT_SCOPE)
endfunction()

set(IOS_CMAKE_ARGS
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=${IOS_PLATFORM} -DCMAKE_OSX_ARCHITECTURES=arm64
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${IOS_DEPLOYMENT_TARGET} -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX=${IOS_PREFIX} -DCMAKE_PREFIX_PATH=${IOS_PREFIX} -DBUILD_SHARED_LIBS=OFF
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO)

function(ios_library name)
    pinned_source(source ${name})
    ExternalProject_Add(${name} ${source} CMAKE_ARGS ${IOS_CMAKE_ARGS} ${ARGN})
endfunction()

# Metal only: no OpenGL ES video backend or renderers, so the app does not link OpenGLES.
ios_library(SDL -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST=OFF -DSDL_METAL=ON -DSDL_OPENGLES=OFF -DSDL_OPENGL=OFF)
ios_library(zstd SOURCE_SUBDIR build/cmake -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_SHARED=OFF -DZSTD_BUILD_TESTS=OFF)
ios_library(libpng -DPNG_SHARED=OFF -DPNG_FRAMEWORK=OFF -DPNG_TESTS=OFF -DPNG_TOOLS=OFF)
ios_library(libzip -DBUILD_TOOLS=OFF -DBUILD_REGRESS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_DOC=OFF
    -DENABLE_COMMONCRYPTO=OFF -DENABLE_GNUTLS=OFF -DENABLE_MBEDTLS=OFF -DENABLE_OPENSSL=OFF
    -DENABLE_BZIP2=OFF -DENABLE_LZMA=OFF -DENABLE_ZSTD=OFF)
ios_library(freetype -DFT_DISABLE_ZLIB=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON -DFT_DISABLE_HARFBUZZ=ON
    -DFT_DISABLE_BROTLI=ON)

# The LZMA SDK has no build system for the two decoders used for GOG installers; lzma/ builds them.
pinned_source(source 7zip)
ExternalProject_Add(7zip ${source} CONFIGURE_COMMAND "" BUILD_COMMAND "" INSTALL_COMMAND "")
ExternalProject_Add(lzmasdk SOURCE_DIR "${CMAKE_CURRENT_LIST_DIR}/lzma" DEPENDS 7zip
    CMAKE_ARGS ${IOS_CMAKE_ARGS} -DLZMA_SDK_SOURCE=${IOS_SOURCES}/7zip/C)

# g2.dat, fonts.dat, palettes.dat and tracks.dat come from the repository's sprites, packed by a
# macOS build of the engine; shared by both SDKs and rebuilt incrementally.
ExternalProject_Add(graphics SOURCE_DIR "${REPO_ROOT}" BINARY_DIR "${IOS_HOST_DIR}"
    CMAKE_ARGS -DCMAKE_BUILD_TYPE=Release -DDISABLE_GUI=ON -DMACOS_BUNDLE=OFF -DENABLE_SCRIPTING=OFF -DDISABLE_HTTP=ON
        -DDISABLE_NETWORK=ON -DDISABLE_DISCORD_RPC=ON -DDISABLE_IPO=ON
    BUILD_COMMAND ${CMAKE_COMMAND} --build <BINARY_DIR> --target graphics
    INSTALL_COMMAND ""
    BUILD_ALWAYS ON)

# Architecture-independent C++ headers from the checksum-pinned macOS dependency pack, which
# configuring the host build downloads into lib/macos.
add_custom_target(headers ALL DEPENDS graphics)
foreach(header nlohmann fmt rapidjson)
    add_custom_command(TARGET headers POST_BUILD COMMAND ${CMAKE_COMMAND} -E copy_directory
        ${REPO_ROOT}/lib/macos/include/${header} ${IOS_PREFIX}/include/${header} VERBATIM)
endforeach()

# The free assets the app bundles; never proprietary RCT2 data.
add_custom_target(assets ALL
    COMMAND ${CMAKE_COMMAND} -DREPO_ROOT=${REPO_ROOT} -DHOST_DIR=${IOS_HOST_DIR} -DDATA_DIR=${IOS_DATA_DIR}
        -DDOWNLOADS=${IOS_DOWNLOADS} -DPYTHON=${Python3_EXECUTABLE} -P ${CMAKE_CURRENT_LIST_DIR}/assets.cmake
    DEPENDS graphics
    VERBATIM)
