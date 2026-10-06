cmake_minimum_required(VERSION 3.25)
project(LunagramPrivateCodecTests LANGUAGES CXX)

if (NOT WIN32 OR NOT MSVC)
    message(FATAL_ERROR "Private codec tests require native Windows MSVC.")
endif()

set(CMAKE_CONFIGURATION_TYPES Debug CACHE STRING "Configurations" FORCE)
set(CMAKE_BUILD_TYPE Debug CACHE STRING "Configuration" FORCE)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
find_package(Qt6 REQUIRED COMPONENTS Core)

add_executable(lunagram_private_codec_tests
    ../private_codec.tests.cpp
    ../../../SourceFiles/lunagram/private_codec.cpp
)
target_compile_features(lunagram_private_codec_tests PRIVATE cxx_std_20)
target_compile_definitions(lunagram_private_codec_tests PRIVATE NOMINMAX)
target_include_directories(lunagram_private_codec_tests PRIVATE
    ../../../SourceFiles
)
target_link_libraries(lunagram_private_codec_tests PRIVATE Qt6::Core Crypt32)

enable_testing()
add_test(NAME native_private_codec COMMAND lunagram_private_codec_tests)
set_tests_properties(native_private_codec PROPERTIES TIMEOUT 60)
