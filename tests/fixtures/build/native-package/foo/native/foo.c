#define HL_NAME(n) foo_##n
#include <hl.h>
#include "foo.h"

HL_PRIM int HL_NAME(answer)(void) {
	return FOO_ANSWER;
}

DEFINE_PRIM_WITH_NAME(_I32, answer, _NO_ARG, foo_answer);
