cmake_minimum_required(VERSION 3.29)
set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "Minimum macOS version")
project(BrawTranscoder VERSION 1.0.0 LANGUAGES C CXX OBJCXX Swift)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 20)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)
set(CMAKE_Swift_LANGUAGE_VERSION 6)

set(BRAW_SDK_ROOT "/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac" CACHE PATH "Installed BRAW SDK")
set(BRAW_SDK_FRAMEWORK_DIR "${BRAW_SDK_ROOT}/Libraries")
set(BRAW_SDK_INCLUDE "${BRAW_SDK_ROOT}/Include")
if(NOT EXISTS "${BRAW_SDK_INCLUDE}/BlackmagicRawAPI.h")
    message(FATAL_ERROR "Install Blackmagic RAW SDK 6.0 or set BRAW_SDK_ROOT")
endif()
set(BRAW_SANITIZER "" CACHE STRING "Optional sanitizer: address or thread")
if(BRAW_SANITIZER)
    add_compile_options("$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-fsanitize=${BRAW_SANITIZER}>")
    add_link_options("$<$<LINK_LANGUAGE:CXX,OBJCXX>:-fsanitize=${BRAW_SANITIZER}>"
        "$<$<LINK_LANGUAGE:Swift>:-sanitize=${BRAW_SANITIZER}>")
endif()

# ── C++ Core Static Library ────────────────────────
add_library(braw_core STATIC
    src/core/BrawDecoder.mm
    src/core/ChildProcess.cpp
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
)

target_compile_options(braw_core PRIVATE
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-exceptions>
)

# The SDK is linked only into the worker, never the UI or bridge.
add_executable(braw_worker src/worker/main.mm src/worker/SDKDecoder.mm)
target_include_directories(braw_worker PRIVATE ${CMAKE_SOURCE_DIR}/src ${BRAW_SDK_INCLUDE})
target_compile_definitions(braw_worker PRIVATE BRAW_SDK_LIBRARY_PATH="${BRAW_SDK_FRAMEWORK_DIR}")
target_compile_options(braw_worker PRIVATE -fobjc-arc)
target_link_libraries(braw_worker PRIVATE "-framework Foundation" "-framework Metal"
    "${BRAW_SDK_FRAMEWORK_DIR}/BlackmagicRawAPI.framework")

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

target_compile_options(${PROJECT_NAME} PRIVATE
    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-import-objc-header ${CMAKE_SOURCE_DIR}/src/bridge/braw_api.h>")
if(BRAW_SANITIZER)
    target_compile_options(${PROJECT_NAME} PRIVATE "$<$<COMPILE_LANGUAGE:Swift>:-sanitize=${BRAW_SANITIZER}>")
endif()
add_dependencies(${PROJECT_NAME} braw_worker)

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
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "$<TARGET_FILE:braw_worker>" "$<TARGET_BUNDLE_CONTENT_DIR:${PROJECT_NAME}>/MacOS/braw_worker"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${CMAKE_SOURCE_DIR}/third_party/ffmpeg/ffmpeg" "$<TARGET_BUNDLE_CONTENT_DIR:${PROJECT_NAME}>/MacOS/ffmpeg"
    COMMAND /usr/bin/codesign --force --sign - "$<TARGET_BUNDLE_CONTENT_DIR:${PROJECT_NAME}>/MacOS/braw_worker"
    COMMAND /usr/bin/codesign --force --sign - "$<TARGET_BUNDLE_CONTENT_DIR:${PROJECT_NAME}>/MacOS/ffmpeg"
    COMMAND /usr/bin/codesign --force --sign - "$<TARGET_BUNDLE_DIR:${PROJECT_NAME}>"
    COMMENT "Bundling app icon, encoder and decoder worker..."
)

# ── CLI Test Binary ──────────────────────────────────
# CLI integration checks must exercise the same encoder as the app bundle.
configure_file("${CMAKE_SOURCE_DIR}/third_party/ffmpeg/ffmpeg"
    "${CMAKE_BINARY_DIR}/ffmpeg" COPYONLY)
add_executable(braw_test
    test/main.cpp
)
target_include_directories(braw_test PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(braw_test PRIVATE braw_core)

add_dependencies(braw_test braw_worker)

include(CTest)
add_executable(braw_reliability_test test/reliability.cpp)
target_include_directories(braw_reliability_test PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(braw_reliability_test PRIVATE braw_core)
add_dependencies(braw_reliability_test braw_worker)
add_test(NAME process_failures COMMAND braw_reliability_test)
