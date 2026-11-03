#include <hl.h>
#include <stdint.h>
#include <stdio.h>

#if UINTPTR_MAX > UINT32_MAX
#ifdef _MSC_VER
# define NOINLINE __declspec(noinline)
#else
# define NOINLINE __attribute__((noinline))
#endif

static unsigned char address_bytes[sizeof(uintptr_t)];
static int owner;

static NOINLINE void make_unrooted_block(void) {
	uintptr_t address = (uintptr_t)hl_gc_alloc_gen_owner(NULL,24,MEM_KIND_NOPTR|MEM_ZERO,&owner);
	const unsigned char *bytes = (const unsigned char *)&address;
	for(unsigned int i=0;i<sizeof(address);i++) address_bytes[i] = bytes[i];
}

static NOINLINE void scrub_stack(void) {
	volatile unsigned char bytes[16384];
	for(unsigned int i=0;i<sizeof(bytes);i++) bytes[i] = 0;
}

static NOINLINE int check_boundary(void) {
	union { uintptr_t alignment; volatile unsigned char bytes[sizeof(uintptr_t)]; } boundary;
	boundary.alignment = 0;
	/* Half the apparent pointer lies beyond the registered end of the stack. */
	hl_register_thread((void *)(boundary.bytes + sizeof(uintptr_t)/2));
	make_unrooted_block();
	scrub_stack();
	for(unsigned int i=0;i<sizeof(uintptr_t);i++) boundary.bytes[i] = address_bytes[i];
	if(hl_gc_owner_live_count(&owner) != 0) {
		fprintf(stderr,"FAIL: stack scan read a partial word beyond its registered boundary\n");
		return 1;
	}
	return 0;
}

int main(void) {
	hl_global_init();
	return check_boundary();
}
#else
int main(void) { return 0; }
#endif
