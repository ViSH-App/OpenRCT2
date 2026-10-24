# This target is UIKit on iPhoneOS or the iOS simulator, never Catalyst.
if(NOT CMAKE_OSX_SYSROOT MATCHES "iphoneos|iPhoneOS|iphonesimulator|iPhoneSimulator")
    message(FATAL_ERROR "The iOS port requires the iPhoneOS or iPhoneSimulator SDK.")
endif()
add_compile_definitions(OPENRCT2_IOS)
# Built for the same SDK by src/openrct2-ios/cmake/native (the Xcode target "Native").
set(IOS_DEPENDENCIES "" CACHE PATH "arm64 dependencies for the SDK being built")
if(NOT IOS_DEPENDENCIES)
    message(FATAL_ERROR "IOS_DEPENDENCIES is required; build through OpenRCT2.xcodeproj.")
endif()
list(PREPEND CMAKE_PREFIX_PATH "${IOS_DEPENDENCIES}")
list(PREPEND CMAKE_FIND_ROOT_PATH "${IOS_DEPENDENCIES}")
set(ENV{PKG_CONFIG_LIBDIR} "${IOS_DEPENDENCIES}/lib/pkgconfig")
set(ENV{PKG_CONFIG_PATH} "")
foreach(feature MACOS_USE_DEPENDENCIES MACOS_BUNDLE ENABLE_SCRIPTING WITH_TESTS)
    set(${feature} OFF CACHE BOOL "Disabled on iOS" FORCE)
endforeach()
foreach(feature DISABLE_HTTP DISABLE_DISCORD_RPC DISABLE_VERSION_CHECKER DISABLE_OPENGL DISABLE_FLAC DISABLE_VORBIS DISABLE_IPO)
    set(${feature} ON CACHE BOOL "Disabled on iOS" FORCE)
endforeach()

set(PNG_LIBRARY "${IOS_DEPENDENCIES}/lib/libpng16.a" CACHE FILEPATH "libpng" FORCE)
set(PNG_PNG_INCLUDE_DIR "${IOS_DEPENDENCIES}/include/libpng16" CACHE PATH "libpng headers" FORCE)

set(PNG_LIBRARY_RELEASE "${IOS_DEPENDENCIES}/lib/libpng16.a" CACHE FILEPATH "static libpng" FORCE)
set(PNG_LIBRARY_DEBUG "${IOS_DEPENDENCIES}/lib/libpng16.a" CACHE FILEPATH "static libpng" FORCE)
# Multiplayer: Crypt.Apple.cpp replaces OpenSSL; there is no HTTP client yet, so only direct connections work.
set(DISABLE_NETWORK OFF CACHE BOOL "Multiplayer" FORCE)
