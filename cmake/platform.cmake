# Helpers for linking platform specific libraries

function(target_link_platform_libraries target)

if (IOS)
    target_link_libraries(${target} "-framework Foundation" "-framework UIKit" "-framework CoreText")
elseif (APPLE)
    target_link_libraries(${target} "-framework Cocoa -framework CoreServices")
elseif(WIN32)
    target_link_libraries(${target} gdi32)
endif ()

endfunction()
