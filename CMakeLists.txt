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
    src/core/QuickTimeMetadata.cpp
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
target_link_libraries(braw_worker PRIVATE "-framework Foundation" "-framework Metal" "-framework Accelerate"
    "${BRAW_SDK_FRAMEWORK_DIR}/BlackmagicRawAPI.framework")

# ── SwiftUI App Executable ─────────────────────────
add_executable(${PROJECT_NAME}
    src/app/BrawTranscoderApp.swift
    src/app/ProjectModel.swift
    src/app/RGBWaveform.swift
    src/app/Views/ContentView.swift
    src/app/Views/SidebarView.swift
    src/app/Views/PreviewView.swift
    src/app/Views/InspectorView.swift
    src/app/Views/NumericSlider.swift
    src/app/Views/RGBWaveformView.swift
    src/app/Views/ExportView.swift
    src/app/Views/ExportControlsLayout.swift
    src/app/Views/FullWidthDropdown.swift
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
target_link_libraries(braw_reliability_test PRIVATE braw_core "-framework Accelerate")
add_dependencies(braw_reliability_test braw_worker)
add_test(NAME process_failures COMMAND braw_reliability_test)
add_executable(braw_color_metadata_test test/export_color_metadata.cpp)
target_include_directories(braw_color_metadata_test PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME export_color_metadata COMMAND braw_color_metadata_test)
add_executable(braw_quicktime_metadata_test test/quicktime_metadata.cpp src/core/QuickTimeMetadata.cpp)
target_include_directories(braw_quicktime_metadata_test PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME quicktime_metadata COMMAND braw_quicktime_metadata_test)
add_executable(braw_waveform_test test/waveform.swift src/app/RGBWaveform.swift)
add_test(NAME rgb_waveform COMMAND braw_waveform_test)
add_executable(braw_model_test test/adjusted_thumbnails.swift src/app/ProjectModel.swift src/app/RGBWaveform.swift)
target_include_directories(braw_model_test PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_compile_options(braw_model_test PRIVATE
    "SHELL:-import-objc-header ${CMAKE_SOURCE_DIR}/src/bridge/braw_api.h")
target_link_libraries(braw_model_test PRIVATE braw_core "-framework AppKit" "-framework CoreFoundation")
add_dependencies(braw_model_test braw_worker)
add_executable(braw_numeric_slider_test test/numeric_slider.swift src/app/Views/NumericSlider.swift)
target_link_libraries(braw_numeric_slider_test PRIVATE "-framework AppKit" "-framework SwiftUI")
add_test(NAME numeric_slider COMMAND braw_numeric_slider_test)
set_tests_properties(numeric_slider PROPERTIES TIMEOUT 20)
add_executable(braw_export_panel_test test/export_panel.swift src/app/ProjectModel.swift
    src/app/RGBWaveform.swift src/app/Views/ExportView.swift
    src/app/Views/ExportControlsLayout.swift src/app/Views/FullWidthDropdown.swift)
target_include_directories(braw_export_panel_test PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_compile_options(braw_export_panel_test PRIVATE
    "SHELL:-import-objc-header ${CMAKE_SOURCE_DIR}/src/bridge/braw_api.h")
target_link_libraries(braw_export_panel_test PRIVATE braw_core "-framework AppKit" "-framework SwiftUI" "-framework CoreFoundation")
add_dependencies(braw_export_panel_test braw_worker)
if(EXISTS "${BRAW_SDK_ROOT}/../Media/sample.braw")
    add_test(NAME export_panel COMMAND braw_export_panel_test "${BRAW_SDK_ROOT}/../Media/sample.braw")
    set_tests_properties(export_panel PROPERTIES ENVIRONMENT "BRAW_DECODE_PIPELINE=cpu" TIMEOUT 30)
    add_test(NAME embedded_lut COMMAND braw_reliability_test --embedded-lut "${BRAW_SDK_ROOT}/../Media/sample.braw")
    set_tests_properties(embedded_lut PROPERTIES ENVIRONMENT "BRAW_DECODE_PIPELINE=cpu" TIMEOUT 60)
    add_test(NAME geometry_tone COMMAND braw_reliability_test --geometry-tone "${BRAW_SDK_ROOT}/../Media/sample.braw")
    set_tests_properties(geometry_tone PROPERTIES ENVIRONMENT "BRAW_DECODE_PIPELINE=cpu" TIMEOUT 120)
    add_test(NAME lens_corrections COMMAND braw_reliability_test --lens "${BRAW_SDK_ROOT}/../Media/sample.braw")
    set_tests_properties(lens_corrections PROPERTIES ENVIRONMENT "BRAW_DECODE_PIPELINE=cpu" TIMEOUT 120)
    add_test(NAME gamut_compression COMMAND braw_reliability_test --gamut "${BRAW_SDK_ROOT}/../Media/sample.braw")
    set_tests_properties(gamut_compression PROPERTIES ENVIRONMENT "BRAW_DECODE_PIPELINE=cpu" TIMEOUT 120)
    add_test(NAME multichannel_audio COMMAND braw_reliability_test --multichannel-audio "${BRAW_SDK_ROOT}/../Media/sample.braw")
    set_tests_properties(multichannel_audio PROPERTIES ENVIRONMENT "BRAW_DECODE_PIPELINE=cpu" TIMEOUT 120)
    add_test(NAME export_resolutions COMMAND braw_reliability_test --resolution-export "${BRAW_SDK_ROOT}/../Media/sample.braw")
    set_tests_properties(export_resolutions PROPERTIES ENVIRONMENT "BRAW_DECODE_PIPELINE=cpu" TIMEOUT 120)
    add_test(NAME iso_adjustments COMMAND braw_reliability_test --iso "${BRAW_SDK_ROOT}/../Media/sample.braw")
    set_tests_properties(iso_adjustments PROPERTIES ENVIRONMENT "BRAW_DECODE_PIPELINE=cpu" TIMEOUT 120)
    add_test(NAME highlight_preview COMMAND braw_reliability_test --highlight-preview "${BRAW_SDK_ROOT}/../Media/sample.braw")
    set_tests_properties(highlight_preview PROPERTIES ENVIRONMENT "BRAW_DECODE_PIPELINE=cpu" TIMEOUT 60)
    add_test(NAME adjusted_thumbnails COMMAND braw_model_test "${BRAW_SDK_ROOT}/../Media/sample.braw")
    set_tests_properties(adjusted_thumbnails PROPERTIES ENVIRONMENT "BRAW_DECODE_PIPELINE=cpu" TIMEOUT 60)
endif()
