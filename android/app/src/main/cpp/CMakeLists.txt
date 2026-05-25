cmake_minimum_required(VERSION 3.22)
project(veriod_audio C)

set(CMAKE_C_STANDARD 99)

# --- RNNoise ---------------------------------------------------------------
file(GLOB RNNOISE_SRC
    ${CMAKE_CURRENT_SOURCE_DIR}/rnnoise/src/celt_lpc.c
    ${CMAKE_CURRENT_SOURCE_DIR}/rnnoise/src/denoise.c
    ${CMAKE_CURRENT_SOURCE_DIR}/rnnoise/src/kiss_fft.c
    ${CMAKE_CURRENT_SOURCE_DIR}/rnnoise/src/pitch.c
    ${CMAKE_CURRENT_SOURCE_DIR}/rnnoise/src/rnn.c
    ${CMAKE_CURRENT_SOURCE_DIR}/rnnoise/src/rnn_data.c
    ${CMAKE_CURRENT_SOURCE_DIR}/rnnoise/src/rnn_reader.c
)

add_library(rnnoise STATIC ${RNNOISE_SRC})
target_include_directories(rnnoise PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/rnnoise/include
)
target_include_directories(rnnoise PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/rnnoise/src
)
target_compile_options(rnnoise PRIVATE -O3 -ffast-math -w -DFLOAT_APPROX)

# --- JNI wrapper -----------------------------------------------------------
add_library(veriod_audio SHARED
    veriod_audio.c
)
target_link_libraries(veriod_audio PRIVATE rnnoise log)
target_include_directories(veriod_audio PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/rnnoise/include
)
target_compile_options(veriod_audio PRIVATE -O3)
