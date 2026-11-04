#include <limits.h>

/* Each active tracking scope roots its collector without allocating a TLS slot. */
#if defined(_WIN32)
#define REALTIME_REACTIVE_TLS __declspec(thread)
#else
#define REALTIME_REACTIVE_TLS _Thread_local
#endif

static REALTIME_REACTIVE_TLS vdynamic *realtime_reactive_collector;
/* Module initialization claims the process-wide application thread. */
static _Atomic(uintptr_t) realtime_reactive_owner;
static _Atomic(uint64_t) realtime_reactive_next_id;

/* Dynamic operands here are genuine object references; never invoke value comparison. */
HL_PRIM bool HL_NAME(__reference_identity)( vdynamic *left, vdynamic *right ) {
	return left == right;
}

/* Reserve a 63-bit positive range atomically, including across independent threads. */
HL_PRIM int64_t HL_NAME(__reactive_reserve_ids)( int count ) {
	uint64_t current = atomic_load_explicit(&realtime_reactive_next_id, memory_order_relaxed);
	for( ;; ) {
		uint64_t base = current > (uint64_t)INT64_MAX - (uint64_t)count ? 0 : current;
		if( atomic_compare_exchange_weak_explicit(&realtime_reactive_next_id, &current, base + (uint64_t)count,
			memory_order_relaxed, memory_order_relaxed) ) return (int64_t)(base + 1);
	}
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
