/* Each active tracking scope roots its collector without allocating a TLS slot. */
#if defined(_WIN32)
#define REALTIME_REACTIVE_TLS __declspec(thread)
#else
#define REALTIME_REACTIVE_TLS _Thread_local
#endif

static REALTIME_REACTIVE_TLS vdynamic *realtime_reactive_collector;
/* Module initialization claims the process-wide application thread. */
static _Atomic(uintptr_t) realtime_reactive_owner;

/* HashLink objects do not move. The hash is only a hint: collisions are
   resolved by comparing the source references themselves. */
HL_PRIM int HL_NAME(__reactive_hash)( vdynamic *source ) {
	uintptr_t address = (uintptr_t)source;
	uint32_t hash = (uint32_t)address ^ (uint32_t)(address >> 16);
	hash ^= hash >> 16;
	hash *= 0x7feb352du;
	hash ^= hash >> 15;
	hash *= 0x846ca68bu;
	return (int)(hash ^ (hash >> 16));
}

HL_PRIM bool HL_NAME(__reactive_claim_owner)( void ) {
	uintptr_t current = (uintptr_t)&realtime_reactive_collector, expected = 0;
	return atomic_compare_exchange_strong(&realtime_reactive_owner, &expected, current) || expected == current;
}

HL_PRIM bool HL_NAME(__reactive_is_owner)( void ) {
	return atomic_load(&realtime_reactive_owner) == (uintptr_t)&realtime_reactive_collector;
}

HL_PRIM bool HL_NAME(__reactive_is_tracking)( void ) {
	return realtime_reactive_collector != NULL;
}

HL_PRIM vdynamic *HL_NAME(__reactive_current_collector)( void ) {
	return realtime_reactive_collector;
}

HL_PRIM void HL_NAME(__reactive_set_collector)( vdynamic *value ) {
	if( realtime_reactive_collector == NULL && value != NULL )
		hl_add_root(&realtime_reactive_collector);
	else if( realtime_reactive_collector != NULL && value == NULL )
		hl_remove_root(&realtime_reactive_collector);
	realtime_reactive_collector = value;
}

#undef REALTIME_REACTIVE_TLS
