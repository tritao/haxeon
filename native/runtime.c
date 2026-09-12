#define HL_NAME(n) realtime_##n
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

#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

/* Keep this as the stable build entry point. The implementation is organized
   by runtime domain below while remaining one translation unit, which lets the
   existing HDLL build commands and private helpers stay unchanged. */
#include "runtime/core.c"
#include "runtime/bytes.c"
#include "runtime/arrays.c"
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
#include "runtime/native_call.c"
#include "runtime/module_runtime.c"
#include "runtime/bindings.c"
