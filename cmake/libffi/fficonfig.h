/* Haxeon's generated-config equivalent for libffi's MSVC Windows x64 build.
   Keep this limited to the platform features enabled by this target. */
#ifndef HAXEON_LIBFFI_CONFIG_H
#define HAXEON_LIBFFI_CONFIG_H

#define STDC_HEADERS 1
#define HAVE_MEMCPY 1
#define HAVE_ALLOCA_H 0
#define HAVE_LONG_DOUBLE 0
#define HAVE_LONG_DOUBLE_VARIANT 0
#define WORDS_BIGENDIAN 0
#define FFI_EXEC_TRAMPOLINE_TABLE 0
#define FFI_MMAP_EXEC_WRIT 1
#define FFI_MMAP_EXEC_SELINUX 0
#define FFI_CLOSURE_FREE_CODE 0
#define FFI_NO_RAW_API 0
#define FFI_NO_STRUCTS 0
#define SIZEOF_DOUBLE 8
#define SIZEOF_LONG_DOUBLE 8
#define SIZEOF_SIZE_T 8

#ifdef LIBFFI_ASM
#define FFI_HIDDEN(name)
#else
#define FFI_HIDDEN
#endif

#endif
