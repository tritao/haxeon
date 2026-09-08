#define HL_NAME(n) patch_core_##n
#include <hl.h>
#include <stdint.h>

HL_PRIM void HL_NAME(fault)( int address ) {
	if( address ) *(volatile int*)(uintptr_t)address = 0;
}

DEFINE_PRIM(_VOID, fault, _I32);
