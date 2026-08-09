cmake_minimum_required(VERSION 3.5)

project(no_ui LANGUAGES CXX)

set(CMAKE_INCLUDE_CURRENT_DIR ON)

set(CMAKE_AUTOUIC ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 配置QT cmake的路径
if(CMAKE_SYSTEM_NAME MATCHES "Windows")
  # 将C:/Qt/5.15.2/mingw81_64类似的目录添加到QT_PLATFORM_DIR的环境变量中
  set(CMAKE_PREFIX_PATH "${CMAKE_PREFIX_PATH};$ENV{QT_PLATFORM_DIR}")
  message(STATUS "CMAKE_PREFIX_PATH: ${CMAKE_PREFIX_PATH}")
  # 将C:/Qt/Tools/mingw810_64/bin类似的目录添加到QT_GCC_PLATFORM_DIR的环境变量中
  set(MY_GCC_PATH_ "$ENV{QT_GCC_PLATFORM_DIR}")
  if(NOT "${MY_GCC_PATH_}" STREQUAL "")
    string(REPLACE "\\" "\\\\" MY_GCC_PATH ${MY_GCC_PATH_})
  else()
    set(MY_GCC_PATH "")
  endif()
  message(STATUS "MY_GCC_PATH: ${MY_GCC_PATH}")
endif(CMAKE_SYSTEM_NAME MATCHES "Windows")
find_package(Qt5Core)

if(NOT DEFINED MY_PROJECT_VERSION)
  set(MY_PROJECT_VERSION "V1.4.0")
endif()
configure_file(
  "${CMAKE_SOURCE_DIR}/../version.h.in"
  "${CMAKE_BINARY_DIR}/version.h"
)
include_directories(${CMAKE_BINARY_DIR})
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
  message(STATUS "ues debug libs")
  # message(FATAL_ERROR "Debug mode is not supported by default. You need to add the debug libraries and modify the CMakeLists.txt file accordingly.")
  set(MYCMAKE_LIBS_TYPE "release")
else()
  message(STATUS "ues release libs")
  set(MYCMAKE_LIBS_TYPE "release")
endif(CMAKE_BUILD_TYPE STREQUAL "Debug")

if(CMAKE_SYSTEM_NAME MATCHES "Linux")
  if(CMAKE_HOST_SYSTEM_PROCESSOR MATCHES "aarch64")
    message(STATUS "current platform: Linux arm64")
    set(MYCMAKE_MATCHES "linux_arm64")
  elseif(CMAKE_HOST_SYSTEM_PROCESSOR MATCHES "x86_64")
    message(STATUS "current platform: Linux amd64")
    set(MYCMAKE_MATCHES "linux_amd64")
  endif(CMAKE_HOST_SYSTEM_PROCESSOR MATCHES "aarch64")
elseif(CMAKE_SYSTEM_NAME MATCHES "Windows")
  message(STATUS "current platform: Windows")
  set(MYCMAKE_MATCHES "win_amd64")
endif(CMAKE_SYSTEM_NAME MATCHES "Linux")

message(STATUS "MYCMAKE_MATCHES:${MYCMAKE_MATCHES}")
message(STATUS "MYCMAKE_LIBS_TYPE:${MYCMAKE_LIBS_TYPE}")

set(original_path "${CMAKE_SOURCE_DIR}/../libs/${MYCMAKE_MATCHES}/${MYCMAKE_LIBS_TYPE}")
get_filename_component(MY_LIB_CMAKE_PREFIX_PATH ${original_path} REALPATH)
set(CMAKE_PREFIX_PATH "${CMAKE_PREFIX_PATH};${MY_LIB_CMAKE_PREFIX_PATH}")
message(STATUS "MY_LIB_CMAKE_PREFIX_PATH:${MY_LIB_CMAKE_PREFIX_PATH}")
find_package(Libssh2 CONFIG REQUIRED)

add_executable(no_ui
  main.cpp
  argsparse.h
  argsparse.cpp
  ../remotesshoperation.h
  ../remotesshoperation.cpp
  ../datatypes.h
)
target_link_libraries(no_ui PRIVATE Qt5::Core)

# edit by user
if(CMAKE_SYSTEM_NAME MATCHES "Linux")
  if(CMAKE_HOST_SYSTEM_PROCESSOR MATCHES "aarch64")
    target_link_libraries(no_ui PRIVATE Libssh2::libssh2_shared)
  elseif(CMAKE_HOST_SYSTEM_PROCESSOR MATCHES "x86_64")
    target_link_libraries(no_ui PRIVATE Libssh2::libssh2_shared)
  endif(CMAKE_HOST_SYSTEM_PROCESSOR MATCHES "aarch64")
elseif(CMAKE_SYSTEM_NAME MATCHES "Windows")
  target_link_libraries(no_ui PRIVATE WS2_32.lib)
  target_link_libraries(no_ui PRIVATE Libssh2::libssh2_static)
  get_target_property(qmake_exec_filepath Qt5::qmake IMPORTED_LOCATION)
  get_filename_component(qt_exec_bin_dir "${qmake_exec_filepath}" DIRECTORY)
  find_program(windeployqt_exec_filepath windeployqt HINTS "${qt_exec_bin_dir}")
  message(STATUS "find windeployqt ${windeployqt_exec_filepath}")
  message(STATUS "MY_GCC_PATH:${MY_GCC_PATH}")
  set(enigma_virtual_box_com_path "${MY_LIB_CMAKE_PREFIX_PATH}/../enigmavbconsole.exe")
  message(STATUS "enigma_virtual_box_com_path:${enigma_virtual_box_com_path}")
  set(7z_tool_path "${MY_LIB_CMAKE_PREFIX_PATH}/../7z.exe")
  message(STATUS "7z_tool_path:${7z_tool_path}")
  set(MY_OUTPUT_NAME "qt_batch_deployment_no_ui_${MY_PROJECT_VERSION}.7z")
  message(STATUS "MY_OUTPUT_NAME:${MY_OUTPUT_NAME}")
  install(CODE "execute_process(COMMAND \"${CMAKE_COMMAND}\" -E make_directory \"${CMAKE_BINARY_DIR}/output/qt_batch_deployment_no_ui\")")
  install(CODE "execute_process(COMMAND \"${CMAKE_COMMAND}\" -E copy_directory \"${MY_LIB_CMAKE_PREFIX_PATH}/../openssl/bin\" \"${CMAKE_BINARY_DIR}/output/qt_batch_deployment_no_ui\")")
  install(CODE "execute_process(COMMAND \"${CMAKE_COMMAND}\" -E copy \"${CMAKE_BINARY_DIR}/no_ui.exe\" \"${CMAKE_BINARY_DIR}/output/qt_batch_deployment_no_ui/qt_batch_deployment_no_ui.exe\")")
  install(CODE "execute_process(COMMAND \"${CMAKE_COMMAND}\" -E env PATH=\"${MY_GCC_PATH}\"  \"${windeployqt_exec_filepath}\" --dir \"${CMAKE_BINARY_DIR}/output/qt_batch_deployment_no_ui\" \"${CMAKE_BINARY_DIR}/output/qt_batch_deployment_no_ui/qt_batch_deployment_no_ui.exe\")")
  install(CODE "execute_process(COMMAND \"${CMAKE_COMMAND}\" -E env \"${7z_tool_path}\" a -mx=9 \"${CMAKE_BINARY_DIR}/output/${MY_OUTPUT_NAME}\" \"${CMAKE_BINARY_DIR}/output/qt_batch_deployment_no_ui/*\")")
endif(CMAKE_SYSTEM_NAME MATCHES "Linux")

include(GNUInstallDirs)
install(TARGETS no_ui
    BUNDLE DESTINATION "${CMAKE_BINARY_DIR}/output"
    LIBRARY DESTINATION "${CMAKE_BINARY_DIR}/output"
    RUNTIME DESTINATION "${CMAKE_BINARY_DIR}/output"
)
# edit by user
