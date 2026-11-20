/* Allocates a known set of blocks and runs the heap census on it: by `hl_gc_census` (mode 0) or by a collection
   (mode 1, with HL_GC_CENSUS_AT set). tests/integration/test-gc-census.sh reads what it prints. */
#include <hl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

HL_API void hl_gc_enable(bool enabled);
HL_API void hl_gc_census(vbyte *label);

#define BLOCKS 1000
#define BLOCK_SIZE 4096
static void **anchor;

int main(int argc, char **argv) {
	int marker = 0;
	if( argc != 2 ) return 2;
	int mode = atoi(argv[1]);
	hl_global_init();
	hl_register_thread(&marker);
	hl_gc_enable(false);
	anchor = (void**)hl_gc_alloc_gen(NULL,BLOCKS * sizeof(void*),MEM_KIND_RAW|MEM_ZERO);
	hl_add_root(&anchor);
	for(int i=0;i<BLOCKS;i++) {
		anchor[i] = hl_gc_alloc_gen(NULL,BLOCK_SIZE,MEM_KIND_NOPTR|MEM_ZERO);
		memset(anchor[i],0x5a,BLOCK_SIZE);
	}
	if( mode == 0 ) hl_gc_census((vbyte*)"known");
	else hl_gc_major();
	hl_remove_root(&anchor);
	hl_unregister_thread();
	hl_global_free();
	puts("PASS: census ran");
	return 0;
}
