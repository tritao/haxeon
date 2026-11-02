/* Each active tracking scope roots its collector without allocating a TLS slot. */
#if defined(_WIN32)
#define REALTIME_REACTIVE_TLS __declspec(thread)
#else
#define REALTIME_REACTIVE_TLS _Thread_local
#endif

static REALTIME_REACTIVE_TLS vdynamic *realtime_reactive_collector;

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
