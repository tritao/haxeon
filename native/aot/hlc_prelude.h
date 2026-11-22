/*
 * What the C a `--target=hlc` build generates takes from the SDK: the part of `hlc.h` that is the same for every program
 * (docs/design/AOT_BACKEND.md). The generated `hlc.h` defines the program's options before it includes this
 * (HLC_INLINE_ALLOCATION) and adds what depends on the program after.
 */
#ifndef HLC_PRELUDE_H
#define HLC_PRELUDE_H
#include <math.h>
#include <string.h>
#include <stddef.h>
#include <hl.h>

#if defined(__GNUC__)
#pragma GCC diagnostic ignored "-Wunused-label"
#pragma GCC diagnostic ignored "-Wunused-variable"
#pragma GCC diagnostic ignored "-Wunused-but-set-variable"
#endif

/*
 * The program's functions are in a section of their own, which tells the stack capture its frames (`hlc_stack.c`). A
 * development build (HLC_EXACT_FRAMES, `HlcBuild`) does not let the C compiler inline them into each other, so a Haxe stack
 * trace has the JIT's frames exactly; a release build does, and the stack capture restores the inlined frames from the debug
 * information (DWARF, or the PDB with MSVC). MSVC's compilers (cl, clang-cl) do not define __GNUC__ and take the same
 * requests as __declspec.
 */
#if defined(HLC_EXACT_FRAMES) && defined(__GNUC__)
#define HLC_NOINLINE __attribute__((noinline))
#elif defined(HLC_EXACT_FRAMES) && defined(_MSC_VER)
#define HLC_NOINLINE __declspec(noinline)
#else
#define HLC_NOINLINE
#endif
#if defined(__ELF__) && defined(__GNUC__)
#define HLC_FUNCTION __attribute__((section("hlc_text"))) HLC_NOINLINE
#elif defined(_WIN32) && defined(__GNUC__)
#define HLC_FUNCTION __attribute__((section(".text$hlc.2"))) HLC_NOINLINE
#elif defined(_WIN32) && defined(_MSC_VER)
#define HLC_FUNCTION __declspec(code_seg(".text$hlc.2")) HLC_NOINLINE
#else
#define HLC_FUNCTION HLC_NOINLINE
#endif

void hl_jit_null_field_access( int fhash );
/* A trampoline pair of one C calling shape (`hlc_signatures` in image.c, which `hlc_main.c` searches by key). */
typedef struct { const char *key; void *(*call)( void *f, void **a, vdynamic *out ); void *wrap; } hlc_signature;
static inline double hlc_f64( unsigned int high, unsigned int low ) {
	unsigned long long bits = ((unsigned long long)high << 32) | low; double value;
	memcpy(&value,&bits,sizeof(value)); return value;
}

#ifdef HLC_INLINE_ALLOCATION
/*
 * `hlc_new`: an object allocated from the thread's allocation buffer as the JIT's inline allocation does, by the descriptor
 * the collector gave for its type (`hl_jit_alloc_data`), and through the collector's slow path otherwise. Where the collector
 * gives no descriptor (other targets, debug collectors) the descriptor is empty and `hl_alloc_obj` allocates.
 */
#if defined(__GNUC__) && defined(__linux__) && (defined(__x86_64__) || defined(__aarch64__))
#define HLC_INLINE_ALLOC
static inline unsigned char *hlc_thread_pointer( void ) {
	unsigned char *p;
#if defined(__x86_64__)
	__asm__("mov %%fs:0,%0" : "=r"(p));
#else
	__asm__("mrs %0, tpidr_el0" : "=r"(p));
#endif
	return p;
}
#endif
static inline void *hlc_new( hl_jit_alloc_data *d, hl_type *t ) {
#ifdef HLC_INLINE_ALLOC
	if( !d->type ) return hl_alloc_obj(t);
	for(int i=0;i<d->nguards;i++) {
		hl_jit_alloc_guard *g = d->guards + i;
		uint64 v = g->bytes == 1 ? *(volatile unsigned char*)g->address : g->bytes == 4 ? *(volatile unsigned int*)g->address : *(volatile uint64*)g->address;
		if( v & g->mask ) return hl_jit_alloc_slow(t);
	}
	if( !d->runtime->allocation_ready ) return hl_jit_alloc_slow(t);
	unsigned char *th = *(unsigned char**)(hlc_thread_pointer() + d->tls_offset);
	if( !th ) return hl_jit_alloc_slow(t);
	unsigned char *tlab = *(unsigned char**)(th + d->tlab_field);
	if( !tlab ) return hl_jit_alloc_slow(t);
	unsigned char **slot = (unsigned char**)(tlab + d->slot_offset);
	unsigned char *p = slot[0];
	if( !p || (uintptr_t)(p + d->block) > (uintptr_t)slot[1] ) return hl_jit_alloc_slow(t);
	slot[0] = p + d->block;
	for(int o=HL_WSIZE;o<d->block;o+=HL_WSIZE) *(void**)(p + o) = NULL;
	*(hl_type**)p = d->type;
	return p;
#else
	return hl_alloc_obj(t);
#endif
}
#endif

#if defined(__GNUC__)
#define HLC_STRING2(x) #x
#define HLC_STRING(x) HLC_STRING2(x)
/* Weak where the linker allows it: a native the libraries lack is the loader's error at start-up, as for the JIT, not a link error. */
#if defined(__ELF__)
#define HLC_SYMBOL(name) __asm__(HLC_STRING(__USER_LABEL_PREFIX__) name) __attribute__((weak))
#else
#define HLC_SYMBOL(name) __asm__(HLC_STRING(__USER_LABEL_PREFIX__) name)
#endif
#endif

#endif
