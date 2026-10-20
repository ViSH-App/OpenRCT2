# Native C++ libraries consumed by OpenRCT2.xcodeproj. Xcode owns the app target,
# iOS Objective-C++ sources, Metal shaders, resources, signing, and launch scheme.
set_target_properties(openrct2 PROPERTIES OUTPUT_NAME OpenRCT2UI)
target_compile_definitions(openrct2 PRIVATE OPENRCT2_METAL)
