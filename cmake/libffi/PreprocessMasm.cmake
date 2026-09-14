if(NOT DEFINED MSVC_C_COMPILER OR NOT DEFINED INPUT_FILE OR NOT DEFINED OUTPUT_FILE
    OR NOT DEFINED GENERATED_INCLUDE_DIR OR NOT DEFINED LIBFFI_SOURCE_DIR)
  message(FATAL_ERROR "Missing input to libffi MASM preprocessing")
endif()

execute_process(
  COMMAND "${MSVC_C_COMPILER}"
    /nologo /EP
    /DX86_WIN64 /DFFI_STATIC_BUILD
    "/I${GENERATED_INCLUDE_DIR}"
    "/I${LIBFFI_SOURCE_DIR}/include"
    "/I${LIBFFI_SOURCE_DIR}/src/x86"
    "${INPUT_FILE}"
  OUTPUT_FILE "${OUTPUT_FILE}"
  RESULT_VARIABLE preprocess_status
  ERROR_VARIABLE preprocess_error
)
if(NOT preprocess_status EQUAL 0)
  message(FATAL_ERROR "MSVC failed to preprocess libffi's x64 assembly: ${preprocess_error}")
endif()
file(SIZE "${OUTPUT_FILE}" preprocess_size)
if(preprocess_size EQUAL 0)
  message(FATAL_ERROR "MSVC produced an empty libffi MASM source file")
endif()
