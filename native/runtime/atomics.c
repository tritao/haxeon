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

static int native_atomic_order( int order ) {
	switch( order ) {
	case 0: return memory_order_relaxed;
	case 1: return memory_order_acquire;
	case 2: return memory_order_release;
	case 3: return memory_order_acq_rel;
	case 4: return memory_order_seq_cst;
	default: hl_error("AtomicInt32 received an invalid memory order"); return memory_order_seq_cst;
	}
}

static void native_validate_load_order( int order ) {
	if( order == memory_order_release || order == memory_order_acq_rel )
		hl_error("Atomic loads cannot use release ordering");
}

static void native_validate_store_order( int order ) {
	if( order == memory_order_acquire || order == memory_order_acq_rel )
		hl_error("Atomic stores cannot use acquire ordering");
}

HL_PRIM int HL_NAME(native_atomic_i32_load)( vbyte *address, int order ) {
	int *target = native_atomic_i32_address(address), result;
	order = native_atomic_order(order);
	native_validate_load_order(order);
	#if defined(__GNUC__) || defined(__clang__)
	__atomic_load(target,&result,order);
	#else
	(void)order;
	result = hl_atomic_load32(target);
	#endif
	return result;
}

HL_PRIM void HL_NAME(native_atomic_i32_store)( vbyte *address, int value, int order ) {
	int *target = native_atomic_i32_address(address);
	order = native_atomic_order(order);
	native_validate_store_order(order);
	#if defined(__GNUC__) || defined(__clang__)
	__atomic_store(target,&value,order);
	#else
	(void)order;
	hl_atomic_store32(target,value);
	#endif
}

HL_PRIM int HL_NAME(native_atomic_i32_exchange)( vbyte *address, int value, int order ) {
	int *target = native_atomic_i32_address(address), result;
	order = native_atomic_order(order);
	#if defined(__GNUC__) || defined(__clang__)
	__atomic_exchange(target,&value,&result,order);
	#else
	(void)order;
	result = hl_atomic_exchange32(target,value);
	#endif
	return result;
}

HL_PRIM int HL_NAME(native_atomic_i32_compare_exchange)( vbyte *address, int expected, int replacement, int order ) {
	int *target = native_atomic_i32_address(address), failureOrder;
	order = native_atomic_order(order);
	failureOrder = order == memory_order_release ? memory_order_relaxed : order == memory_order_acq_rel ? memory_order_acquire : order;
	#if defined(__GNUC__) || defined(__clang__)
	__atomic_compare_exchange(target,&expected,&replacement,false,order,failureOrder);
	#else
	(void)order;
	expected = hl_atomic_compare_exchange32(target,expected,replacement);
	#endif
	return expected;
}

HL_PRIM int HL_NAME(native_atomic_i32_fetch_add)( vbyte *address, int value, int order ) {
	int *target = native_atomic_i32_address(address), result;
	order = native_atomic_order(order);
	#if defined(__GNUC__) || defined(__clang__)
	result = __atomic_fetch_add(target,value,order);
	#else
	(void)order;
	result = hl_atomic_add32(target,value);
	#endif
	return result;
}

static vbyte **native_atomic_pointer_address( vbyte *address ) {
	if( address == NULL || ((uintptr_t)address % _Alignof(void*)) != 0 )
		hl_error("AtomicPointer requires a non-null naturally aligned address");
	return (vbyte**)address;
}

HL_PRIM vbyte *HL_NAME(native_atomic_ptr_load)( vbyte *address, int order ) {
	vbyte **target = native_atomic_pointer_address(address), *result;
	order = native_atomic_order(order);
	native_validate_load_order(order);
	#if defined(__GNUC__) || defined(__clang__)
	__atomic_load(target,&result,order);
	#elif defined(_MSC_VER)
	(void)order;
	result = (vbyte*)InterlockedCompareExchangePointer((PVOID volatile*)target,NULL,NULL);
	#else
	result = (vbyte*)(uintptr_t)atomic_load_explicit((atomic_uintptr_t*)target,order);
	#endif
	return result;
}

HL_PRIM void HL_NAME(native_atomic_ptr_store)( vbyte *address, vbyte *value, int order ) {
	vbyte **target = native_atomic_pointer_address(address);
	order = native_atomic_order(order);
	native_validate_store_order(order);
	#if defined(__GNUC__) || defined(__clang__)
	__atomic_store(target,&value,order);
	#elif defined(_MSC_VER)
	(void)order;
	InterlockedExchangePointer((PVOID volatile*)target,value);
	#else
	atomic_store_explicit((atomic_uintptr_t*)target,(uintptr_t)value,order);
	#endif
}

HL_PRIM vbyte *HL_NAME(native_atomic_ptr_exchange)( vbyte *address, vbyte *value, int order ) {
	vbyte **target = native_atomic_pointer_address(address), *result;
	order = native_atomic_order(order);
	#if defined(__GNUC__) || defined(__clang__)
	__atomic_exchange(target,&value,&result,order);
	#elif defined(_MSC_VER)
	(void)order;
	result = (vbyte*)InterlockedExchangePointer((PVOID volatile*)target,value);
	#else
	result = (vbyte*)(uintptr_t)atomic_exchange_explicit((atomic_uintptr_t*)target,(uintptr_t)value,order);
	#endif
	return result;
}

HL_PRIM vbyte *HL_NAME(native_atomic_ptr_compare_exchange)( vbyte *address, vbyte *expected, vbyte *replacement, int order ) {
	vbyte **target = native_atomic_pointer_address(address), *observed = expected;
	int failureOrder;
	order = native_atomic_order(order);
	failureOrder = order == memory_order_release ? memory_order_relaxed : order == memory_order_acq_rel ? memory_order_acquire : order;
	#if defined(__GNUC__) || defined(__clang__)
	__atomic_compare_exchange(target,&observed,&replacement,false,order,failureOrder);
	#elif defined(_MSC_VER)
	(void)failureOrder;
	observed = (vbyte*)InterlockedCompareExchangePointer((PVOID volatile*)target,replacement,expected);
	#else
	atomic_compare_exchange_strong_explicit((atomic_uintptr_t*)target,(uintptr_t*)&observed,(uintptr_t)replacement,order,failureOrder);
	#endif
	return observed;
}

HL_PRIM void HL_NAME(native_atomic_fence)( int order ) {
	atomic_thread_fence(native_atomic_order(order));
}
