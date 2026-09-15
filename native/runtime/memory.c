#ifdef _WIN32
#include <malloc.h>
#endif

static bool realtime_valid_alignment( int alignment ) {
	return alignment > 0 && (alignment & (alignment - 1)) == 0;
}

HL_PRIM vbyte *HL_NAME(native_alloc)( int size, int alignment ) {
	if( size <= 0 ) hl_error("Native memory allocation size must be positive");
	if( !realtime_valid_alignment(alignment) ) hl_error("Native memory alignment must be a positive power of two");
	void *memory = NULL;
	if( alignment < (int)sizeof(void *) ) alignment = (int)sizeof(void *);
#ifdef _WIN32
	memory = _aligned_malloc((size_t)size, (size_t)alignment);
#else
	if( posix_memalign(&memory, (size_t)alignment, (size_t)size) != 0 ) memory = NULL;
#endif
	if( memory == NULL ) hl_error("Native memory allocation failed");
	return (vbyte *)memory;
}

HL_PRIM void HL_NAME(native_free)( vbyte *pointer ) {
#ifdef _WIN32
	_aligned_free(pointer);
#else
	free(pointer);
#endif
}

HL_PRIM bool HL_NAME(native_is_aligned)( vbyte *pointer, int alignment ) {
	if( pointer == NULL ) return false;
	if( !realtime_valid_alignment(alignment) ) hl_error("Native memory alignment must be a positive power of two");
	return ((uintptr_t)pointer % (uintptr_t)alignment) == 0;
}
