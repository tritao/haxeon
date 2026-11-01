#include <hl.h>
#include <stdio.h>

/* A tiny rooted graph lets mark workers finish short batches immediately. Repeated collections exercise the case where
   workers complete before the collector reaches its wait. */
#define ROOT_COUNT 4
#define COLLECTIONS 1024

static void *roots[ROOT_COUNT];

int main(void) {
	int marker = 0;
	hl_global_init();
	hl_register_thread(&marker);
	for(int i=0;i<ROOT_COUNT;i++) {
		hl_add_root(&roots[i]);
		roots[i] = hl_gc_alloc_gen(NULL,2 * (int)sizeof(void*),MEM_KIND_DYNAMIC|MEM_ZERO);
		((void**)roots[i])[0] = &hlt_abstract;
	}
	for(int i=0;i<COLLECTIONS;i++) hl_gc_major();
	for(int i=0;i<ROOT_COUNT;i++) {
		if( roots[i] == NULL || ((void**)roots[i])[0] != &hlt_abstract ) {
			fprintf(stderr,"FAIL: rooted object %d did not survive collection\n",i);
			return 1;
		}
	}
	hl_global_free();
	puts("PASS: short parallel mark batches complete before or during the collector wait");
	return 0;
}
