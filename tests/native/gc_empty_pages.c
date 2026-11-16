/* windows.h before hl.h: its SDK headers do not build after hl.h's definitions. */
#ifdef _WIN32
#	include <windows.h>
#else
#	include <pthread.h>
#endif
#include <hl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

HL_API void hl_gc_enable(bool enabled);
HL_API double hl_gc_heap_bytes(void);
static void *anchor;
static int failures, finalizers, dirty_reuse;
static void finalize(void *value) { (void)value; finalizers++; }
static void *allocate(void *argument) {
	int marker = 0, phase = *(int*)argument;
	hl_register_thread(&marker);
	if( phase == 0 ) {
		anchor = hl_gc_alloc_gen(NULL,8<<20,MEM_KIND_NOPTR|MEM_ZERO);
		hl_add_root(&anchor);
		memset(anchor,0x5a,8<<20);
		for(int i=0;i<(64<<20)/24;i++) memset(hl_gc_alloc_gen(NULL,24,MEM_KIND_RAW|MEM_ZERO),0xa5,24);
	} else {
		for(int round=0;round<1000;round++) {
			unsigned char *dirty = hl_gc_alloc_gen(NULL,24,MEM_KIND_RAW);
			if( dirty[0] == 0xa5 ) dirty_reuse++;
			memset(dirty,0xa5,24);
			for(int size=1;size<=40;size++) {
				unsigned char *p = hl_gc_alloc_gen(NULL,size,MEM_KIND_RAW|MEM_ZERO);
				int allocated = hl_gc_get_memsize(p);
				for(int index=0;index<allocated;index++) if(p[index] != 0) failures++;
				memset(p,0xa5,allocated);
				p = hl_gc_alloc_gen(NULL,size,MEM_KIND_RAW);
				allocated = hl_gc_get_memsize(p);
				for(int index=size;index<allocated;index++) if(p[index] != 0) failures++;
				memset(p,0xa5,allocated);
			}
		}
	}
	for(int i=0;i<1024;i++) {
		void **p = hl_gc_alloc_gen(NULL,2*sizeof(void*),MEM_KIND_FINALIZER|MEM_ZERO);
		p[0] = (void*)finalize;
	}
	hl_unregister_thread();
	return NULL;
}
#ifdef _WIN32
static DWORD WINAPI allocate_thread(LPVOID phase) {
	allocate(phase);
	return 0;
}
#endif
/* Allocates on a thread of its own and waits for it. */
static int run(int phase) {
#ifdef _WIN32
	HANDLE thread = CreateThread(NULL,0,allocate_thread,&phase,0,NULL);
	if( thread == NULL ) return 0;
	int joined = WaitForSingleObject(thread,INFINITE) == WAIT_OBJECT_0;
	CloseHandle(thread);
	return joined;
#else
	pthread_t thread;
	if(pthread_create(&thread,NULL,allocate,&phase)) return 0;
	return pthread_join(thread,NULL)==0;
#endif
}
int main(int argc, char **argv) {
	int marker=0, mode;
	if(argc!=2) return 2;
	mode=atoi(argv[1]);
	hl_global_init(); hl_register_thread(&marker); hl_gc_enable(false);
	if(!run(0)) return 3;
	hl_gc_major();
	double heap=hl_gc_heap_bytes();
	if(heap > (8+4+2)*(double)(1<<20)) { fprintf(stderr,"budget exceeded: %.0f\n",heap); return 4; }
	if(mode && heap <= 9*(double)(1<<20)) { fprintf(stderr,"no empty-page retention: %.0f\n",heap); return 5; }
	if(finalizers != 1024 || !run(1)) return 6;
	if(failures || (mode && !dirty_reuse)) { fprintf(stderr,"zeroing/reuse failure: %d %d\n",failures,dirty_reuse); return 7; }
	hl_gc_major(); hl_gc_major();
	if(finalizers != 2048) return 8;
	hl_remove_root(&anchor); anchor=NULL;
	for(int i=0;i<6;i++) hl_gc_major();
	heap=hl_gc_heap_bytes();
	if(heap > 2*(double)(1<<20)) { fprintf(stderr,"old peak not shed: %.0f\n",heap); return 9; }
	hl_unregister_thread(); hl_global_free();
	puts("PASS: empty-page budget, dirty reuse, zeroing, padding, finalizers and heap shrink");
	return 0;
}
