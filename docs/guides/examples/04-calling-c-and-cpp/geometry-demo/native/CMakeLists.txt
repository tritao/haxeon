cmake_minimum_required(VERSION 3.21)
project(geometry LANGUAGES C CXX)

add_library(geometry SHARED geometry.c shapes.cpp)
target_include_directories(geometry PUBLIC include)
target_compile_features(geometry PRIVATE cxx_std_20)
if(NOT WIN32)
  target_link_libraries(geometry PRIVATE m)
endif()
