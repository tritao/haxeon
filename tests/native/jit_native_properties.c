/* Separate HDLL: the marker must work without LIBHL_EXPORTS. */
#define HL_NAME(n) test_##n
#include <hl.h>

HL_PRIM void HL_NAME(flagged_throw)(void) { hl_error("flagged"); }
HL_PRIM void HL_NAME(unflagged_throw)(void) { hl_error("unflagged"); }
HL_PRIM double HL_NAME(ordinary_call)(double value) { return value + 0.5; }
DEFINE_PRIM_NORETURN(_VOID,flagged_throw,_NO_ARG);
DEFINE_PRIM(_VOID,unflagged_throw,_NO_ARG);
DEFINE_PRIM(_F64,ordinary_call,_F64);
