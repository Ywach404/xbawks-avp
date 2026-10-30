# CMake toolchain for arm64-apple-xros-simulator.
#
# Modelled on UTM's generate_cmake_toolchain() in scripts/build_dependencies.sh.
# CMAKE_SYSTEM_NAME visionOS needs CMake >= 3.28.
#
# Override the deployment target with -DXROS_DEPLOYMENT_TARGET=.. if needed.
# 26.0 is this project's floor (the JIT probe ran against it); UTM builds its
# own libraries at 1.0, and linking minos-1.0 dylibs into a 26.0 target is fine.

cmake_minimum_required(VERSION 3.28)

set(CMAKE_SYSTEM_NAME visionOS)
set(CMAKE_SYSTEM_PROCESSOR "arm64")

if(NOT DEFINED XROS_DEPLOYMENT_TARGET)
  set(XROS_DEPLOYMENT_TARGET "26.0")
endif()

set(CMAKE_OSX_SYSROOT xrsimulator CACHE STRING "" FORCE)
set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "" FORCE)
set(CMAKE_OSX_DEPLOYMENT_TARGET "${XROS_DEPLOYMENT_TARGET}" CACHE STRING "" FORCE)
set(CMAKE_MACOSX_BUNDLE OFF CACHE BOOL "")

# Nothing built for the device can be run on the host.
set(CMAKE_CROSSCOMPILING ON)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

# Look for headers and libraries in the sysroot, not on the host.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM BEFORE)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
