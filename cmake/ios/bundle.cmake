set(IOS_DATA_DIR "${ROOT_DIR}/build/ios-data" CACHE PATH "Prepared OpenRCT2 assets")
set(IOS_BUNDLE_IDENTIFIER "io.openrct2.personal.ipad" CACHE STRING "Personal signing bundle identifier")
set(IOS_DEVELOPMENT_TEAM "" CACHE STRING "Apple development team")
if(NOT EXISTS "${IOS_DATA_DIR}/g2.dat")
    message(FATAL_ERROR "Run scripts/ios/prepare.sh to generate the app assets first")
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
set_source_files_properties("${ROOT_DIR}/src/openrct2-ui/UiContext.iOS.mm" PROPERTIES COMPILE_FLAGS "-x objective-c++ -fmodules -fobjc-arc")
add_custom_command(TARGET openrct2 POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory "${IOS_DATA_DIR}" "$<TARGET_BUNDLE_DIR:openrct2>/data"
    COMMENT "Copying OpenRCT2 assets into iPad sandbox bundle")
