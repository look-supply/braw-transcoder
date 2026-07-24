cmake_minimum_required(VERSION 3.29)
project(BrawTranscoder VERSION 1.0.0 LANGUAGES C CXX OBJCXX Swift)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 20)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)
set(CMAKE_Swift_LANGUAGE_VERSION 6)

find_package(PkgConfig QUIET)
pkg_check_modules(FFMPEG IMPORTED_TARGET libavcodec libavformat libavutil libswscale)

set(BRAW_SDK_FRAMEWORK_DIR "/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Libraries")
set(BRAW_SDK_INCLUDE "${CMAKE_SOURCE_DIR}/third_party/BrawSDK")

# ── C++ Core Static Library ────────────────────────
add_library(braw_core STATIC
    src/core/BrawDecoder.mm
    src/bridge/braw_api.cpp
    src/bridge/braw_export.mm
)

target_include_directories(braw_core PRIVATE
    ${CMAKE_SOURCE_DIR}/src
    ${BRAW_SDK_INCLUDE}
)

target_link_libraries(braw_core PRIVATE
    "-framework CoreFoundation"
    "-framework AppKit"
    "-framework AudioToolbox"
    "-framework AVFoundation"
    "-framework CoreMedia"
    "-framework CoreVideo"
    "-framework VideoToolbox"
    "${BRAW_SDK_FRAMEWORK_DIR}/BlackmagicRawAPI.framework"
)

target_compile_options(braw_core PRIVATE
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-exceptions>
)

# ── SwiftUI App Executable ─────────────────────────
add_executable(${PROJECT_NAME}
    src/app/BrawTranscoderApp.swift
    src/app/ProjectModel.swift
    src/app/Views/ContentView.swift
    src/app/Views/SidebarView.swift
    src/app/Views/PreviewView.swift
    src/app/Views/InspectorView.swift
    src/app/Views/ExportView.swift
    src/app/Info.plist
)

target_include_directories(${PROJECT_NAME} PRIVATE
    ${CMAKE_SOURCE_DIR}/src
)

target_link_libraries(${PROJECT_NAME} PRIVATE
    braw_core
    "-framework AppKit"
    "-framework SwiftUI"
)

set_target_properties(${PROJECT_NAME} PROPERTIES
    MACOSX_BUNDLE TRUE
    MACOSX_BUNDLE_GUI_IDENTIFIER "com.brawtranscoder.app"
    MACOSX_BUNDLE_BUNDLE_NAME "BRAW Transcoder"
    MACOSX_BUNDLE_BUNDLE_VERSION ${PROJECT_VERSION}
    MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION}
    MACOSX_BUNDLE_ICON_FILE "AppIcon"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_SOURCE_DIR}/src/app/Info.plist"
    XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY ""
)

# Copy app icon into bundle resources
add_custom_command(TARGET ${PROJECT_NAME} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory
        "$<TARGET_BUNDLE_CONTENT_DIR:${PROJECT_NAME}>/Resources"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${CMAKE_SOURCE_DIR}/src/app/AppIcon.icns"
        "$<TARGET_BUNDLE_CONTENT_DIR:${PROJECT_NAME}>/Resources/AppIcon.icns"
    COMMENT "Copying app icon..."
)

# ── CLI Test Binary ──────────────────────────────────
add_executable(braw_test
    test/main.cpp
)
target_include_directories(braw_test PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(braw_test PRIVATE braw_core)
