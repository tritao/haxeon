HL_PRIM vbyte *HL_NAME(native_alloc)( int size ) {
	if( size <= 0 ) hl_error("Native memory allocation size must be positive");
	void *memory = malloc((size_t)size);
	if( memory == NULL ) hl_error("Native memory allocation failed");
	return (vbyte *)memory;
}

HL_PRIM void HL_NAME(native_free)( vbyte *pointer ) {
	free(pointer);
}
