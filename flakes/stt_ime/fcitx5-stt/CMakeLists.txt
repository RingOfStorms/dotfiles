cmake_minimum_required(VERSION 3.16)
project(fcitx5-stt VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Find Fcitx5
find_package(Fcitx5Core REQUIRED)
find_package(Fcitx5Utils REQUIRED)

# Path to stt-stream binary (set by Nix)
if(NOT DEFINED STT_STREAM_PATH)
    set(STT_STREAM_PATH "stt-stream")
endif()

# Configure header with path
configure_file(
    ${CMAKE_CURRENT_SOURCE_DIR}/src/config.h.in
    ${CMAKE_CURRENT_BINARY_DIR}/config.h
)

# Build the addon shared library
add_library(stt MODULE
    src/stt.cpp
)

target_include_directories(stt PRIVATE
    ${CMAKE_CURRENT_BINARY_DIR}
)

target_link_libraries(stt PRIVATE
    Fcitx5::Core
    Fcitx5::Utils
)

# Set output name without "lib" prefix
set_target_properties(stt PROPERTIES PREFIX "")

# Install targets - use standard paths, Nix postInstall will handle fcitx5 paths
install(TARGETS stt DESTINATION lib/fcitx5)
install(FILES data/stt.conf DESTINATION share/fcitx5/addon)
install(FILES data/stt-im.conf DESTINATION share/fcitx5/inputmethod)
