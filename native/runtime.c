#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#define HL_NAME(n) realtime_##n
#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <io.h>
#include <fcntl.h>
#else
#include <dlfcn.h>
#endif
#include <hl.h>
#include <hlmodule.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <stdatomic.h>
#include <ffi.h>

/* Keep this as the stable build entry point. The implementation is organized
   by runtime domain below while remaining one translation unit, which lets the
   existing HDLL build commands and private helpers stay unchanged. */
#include "runtime/core.c"
#include "runtime/reactive.c"
#include "runtime/bytes.c"
#include "runtime/sha256.c"
#include "runtime/dir_watch.c"
/* Dynamic array views preserve the backing representation when performing structural operations. */
HL_PRIM bool HL_NAME(__value_array_is)(varray *array);
HL_PRIM void HL_NAME(__value_array_remove_at)(varray *array, int index);
HL_PRIM bool HL_NAME(__value_array_compatible)(varray *left, varray *right);
HL_PRIM varray *HL_NAME(__value_array_copy)(varray *array);
HL_PRIM varray *HL_NAME(__value_array_concat)(varray *left, varray *right);
HL_PRIM varray *HL_NAME(__value_array_slice)(varray *array, int start, int end);
HL_PRIM varray *HL_NAME(__value_array_splice)(varray *array, int position, int length);
HL_PRIM void HL_NAME(__value_array_reverse)(varray *array);
HL_PRIM void HL_NAME(__value_array_resize)(varray *array, int length);
HL_PRIM vdynamic *HL_NAME(__value_array_dynamic_read)(varray *array, int index);
HL_PRIM bool HL_NAME(__value_array_dynamic_accepts)(varray *array, vdynamic *value);
HL_PRIM void HL_NAME(__value_array_dynamic_write)(varray *array, int index, vdynamic *value);
HL_PRIM void HL_NAME(__value_array_dynamic_store)(varray *array, int index, vdynamic *value);
HL_PRIM void HL_NAME(__value_array_dynamic_insert)(varray *array, int position, vdynamic *value);
HL_PRIM int HL_NAME(__value_array_insert_empty)(varray *array, int position);
#include "runtime/arrays.c"
#include "runtime/value_arrays.c"
#include "runtime/iterators.c"
#include "runtime/maps.c"
#include "runtime/strings.c"
#include "runtime/regex.c"
#include "runtime/reflection.c"
#include "runtime/files.c"
#include "runtime/int64.c"
#include "runtime/atomic_files.c"
#include "runtime/system.c"
#include "runtime/processes.c"
#include "runtime/child_processes.c"
#include "runtime/host_state.c"
#include "runtime/native_call.c"
#include "runtime/native_trace.c"
#include "runtime/memory.c"
#include "runtime/module_runtime.c"
#include "runtime/bindings.c"
