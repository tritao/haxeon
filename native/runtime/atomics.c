HL_API int hl_atomic_load32( int *address );
HL_API int hl_atomic_store32( int *address, int value );
HL_API int hl_atomic_exchange32( int *address, int value );
HL_API int hl_atomic_compare_exchange32( int *address, int expected, int replacement );
HL_API int hl_atomic_add32( int *address, int value );

static int *native_atomic_i32_address( vbyte *address ) {
	if( address == NULL || ((uintptr_t)address % _Alignof(int)) != 0 )
		hl_error("AtomicInt32 requires a non-null naturally aligned address");
	return (int*)address;
}

HL_PRIM int HL_NAME(native_atomic_i32_load)( vbyte *address ) {
	return hl_atomic_load32(native_atomic_i32_address(address));
}

HL_PRIM void HL_NAME(native_atomic_i32_store)( vbyte *address, int value ) {
	hl_atomic_store32(native_atomic_i32_address(address),value);
}

HL_PRIM int HL_NAME(native_atomic_i32_exchange)( vbyte *address, int value ) {
	return hl_atomic_exchange32(native_atomic_i32_address(address),value);
}

HL_PRIM int HL_NAME(native_atomic_i32_compare_exchange)( vbyte *address, int expected, int replacement ) {
	return hl_atomic_compare_exchange32(native_atomic_i32_address(address),expected,replacement);
}

HL_PRIM int HL_NAME(native_atomic_i32_fetch_add)( vbyte *address, int value ) {
	return hl_atomic_add32(native_atomic_i32_address(address),value);
}

HL_PRIM void HL_NAME(native_atomic_fence)() {
	atomic_thread_fence(memory_order_seq_cst);
}
