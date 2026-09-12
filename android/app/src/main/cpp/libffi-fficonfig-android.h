/* Android build configuration for upstream libffi 3.8.0. */
#define EH_FRAME_FLAGS "a"
#define FFI_EXEC_STATIC_TRAMP 1
#define FFI_MMAP_EXEC_WRIT 1
#define HAVE_ALLOCA_H 1
#define HAVE_AS_CFI_PSEUDO_OP 1
#define HAVE_AS_X86_64_UNWIND_SECTION_TYPE 1
#define HAVE_DLFCN_H 1
#define HAVE_HIDDEN_VISIBILITY_ATTRIBUTE 1
#define HAVE_INT128 1
#define HAVE_INTTYPES_H 1
#define HAVE_LONG_DOUBLE 1
#define HAVE_MEMCPY 1
#define HAVE_RO_EH_FRAME 1
#define HAVE_STDINT_H 1
#define HAVE_STDIO_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRINGS_H 1
#define HAVE_STRING_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1
#define SIZEOF_DOUBLE 8
#define SIZEOF_LONG_DOUBLE 16
#define SIZEOF_SIZE_T 8
#define STDC_HEADERS 1

#ifdef HAVE_HIDDEN_VISIBILITY_ATTRIBUTE
#ifdef LIBFFI_ASM
#ifdef __APPLE__
#define FFI_HIDDEN(name) .private_extern name
#else
#define FFI_HIDDEN(name) .hidden name
#endif
#else
#define FFI_HIDDEN __attribute__ ((visibility ("hidden")))
#endif
#else
#ifdef LIBFFI_ASM
#define FFI_HIDDEN(name)
#else
#define FFI_HIDDEN
#endif
#endif
