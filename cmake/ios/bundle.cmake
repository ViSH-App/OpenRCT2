set(IOS_DATA_DIR "${ROOT_DIR}/build/ios-data" CACHE PATH "Prepared OpenRCT2 assets")
set(IOS_BUNDLE_IDENTIFIER "io.openrct2.personal.ipad" CACHE STRING "Personal signing bundle identifier")
set(IOS_DEVELOPMENT_TEAM "" CACHE STRING "Apple development team")
if(NOT EXISTS "${IOS_DATA_DIR}/g2.dat")
    message(FATAL_ERROR "Run scripts/ios/prepare.sh to generate the app assets first")
endif()
if(NOT EXISTS "${IOS_DATA_DIR}/fonts/NotoSansCJKsc-Regular.otf")
    message(FATAL_ERROR "Run scripts/ios/prepare.sh to bundle the iPad Chinese font")
endif()
set_target_properties(openrct2 PROPERTIES
    MACOSX_BUNDLE TRUE OUTPUT_NAME "OpenRCT2-iPad"
    MACOSX_BUNDLE_INFO_PLIST "${ROOT_DIR}/distribution/ios/Info.plist.in"
    XCODE_EXPLICIT_FILE_TYPE "wrapper.application"
    XCODE_ATTRIBUTE_LD_NO_PIE "NO"
    XCODE_GENERATE_SCHEME TRUE
    XCODE_SCHEME_EXECUTABLE "${CMAKE_BINARY_DIR}/Release-iphoneos/OpenRCT2-iPad.app"
    XCODE_SCHEME_LAUNCH_CONFIGURATION "Release"
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "${IOS_BUNDLE_IDENTIFIER}"
    XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "2"
    XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS "iphoneos"
    XCODE_ATTRIBUTE_SUPPORTS_MACCATALYST "NO"
    XCODE_ATTRIBUTE_SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD "YES"
    XCODE_ATTRIBUTE_CODE_SIGN_STYLE "Automatic"
    XCODE_ATTRIBUTE_DEVELOPMENT_TEAM "${IOS_DEVELOPMENT_TEAM}"
    XCODE_ATTRIBUTE_ENABLE_USER_SCRIPT_SANDBOXING "NO")
target_link_libraries(openrct2 "-framework UniformTypeIdentifiers" "-framework AVFAudio")
set_source_files_properties("${ROOT_DIR}/src/openrct2-ui/IosApplication.mm" "${ROOT_DIR}/src/openrct2-ui/UiContext.iOS.mm" PROPERTIES COMPILE_FLAGS "-x objective-c++ -fmodules -fobjc-arc")
add_custom_command(TARGET openrct2 POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory "${IOS_DATA_DIR}" "$<TARGET_BUNDLE_DIR:openrct2>/data"
    COMMENT "Copying OpenRCT2 assets into iPad sandbox bundle")

# Native indexed Metal rasterizer. Compile shaders with the iPhoneOS Metal toolchain.
target_compile_definitions(openrct2 PRIVATE OPENRCT2_METAL)
target_link_libraries(openrct2 "-framework Metal" "-framework QuartzCore")
set(METAL_SOURCE "${ROOT_DIR}/src/openrct2-ui/drawing/engines/metal/MetalDrawingEngine.mm")
set_source_files_properties("${METAL_SOURCE}" PROPERTIES COMPILE_FLAGS "-x objective-c++ -fmodules -fobjc-arc")
add_custom_command(OUTPUT "${CMAKE_BINARY_DIR}/OpenRCT2.metallib"
    COMMAND xcrun --sdk iphoneos metal -std=ios-metal2.3 -mios-version-min=16.0 -c
        "${ROOT_DIR}/src/openrct2-ui/drawing/engines/metal/MetalShaders.metal" -o "${CMAKE_BINARY_DIR}/OpenRCT2.air"
    COMMAND xcrun --sdk iphoneos metallib "${CMAKE_BINARY_DIR}/OpenRCT2.air" -o "${CMAKE_BINARY_DIR}/OpenRCT2.metallib"
    DEPENDS "${ROOT_DIR}/src/openrct2-ui/drawing/engines/metal/MetalShaders.metal")
add_custom_target(ipad-metal-shaders DEPENDS "${CMAKE_BINARY_DIR}/OpenRCT2.metallib")
add_dependencies(openrct2 ipad-metal-shaders)
add_custom_command(TARGET openrct2 POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${CMAKE_BINARY_DIR}/OpenRCT2.metallib" "$<TARGET_BUNDLE_DIR:openrct2>/OpenRCT2.metallib")
option(IOS_METAL_VALIDATE "Compare native Metal frame pixels against the software renderer" OFF)
if(IOS_METAL_VALIDATE)
    set_target_properties(openrct2 PROPERTIES XCODE_SCHEME_ENVIRONMENT "OPENRCT2_METAL_VALIDATE=1")
endif()

option(IOS_METAL_COMPARE_GPU "Compare optimised and reference rasterizers at native density" OFF)
if(IOS_METAL_COMPARE_GPU)
    set_property(TARGET openrct2 APPEND PROPERTY XCODE_SCHEME_ENVIRONMENT "OPENRCT2_METAL_COMPARE_GPU=1")
endif()
