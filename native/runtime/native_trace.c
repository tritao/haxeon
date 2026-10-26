/* Records NativeKit's trace points (nativekit_trace.h) in the profiler. NativeKit depends on nothing here: it calls
   whatever sink its host installs, and this file is the sink Haxeon installs, through the library the FFI loaded. Zones
   become profiler spans and dequeued inputs become PROFILE_EVENT_INPUT events. While no session is recording, the
   sink's switch (hl_prof_on) is off and NativeKit calls nothing. */
#include <nativekit_trace.h>
#include <hlprof.h>
#include <profile_events.h>

static uint64_t (NK_CALL *native_trace_now_ns)( void );
static nk_trace_sink native_trace_sink;

static void NK_CALL native_trace_zone_begin( void *user_data, const nk_trace_location *location ) {
	(void)user_data;
	hl_prof_span_begin(location->name,(int)strlen(location->name),HL_PROF_UTF8);
}

static void NK_CALL native_trace_zone_end( void *user_data ) {
	(void)user_data;
	hl_prof_span_end();
}

static void NK_CALL native_trace_event( void *user_data, nk_trace_event_kind kind, uint64_t os_time_ns, int64_t a, int64_t b ) {
	unsigned char payload[32];
	uint32_t input;
	uint64_t age = PROFILE_INPUT_AGE_UNKNOWN;
	(void)user_data;
	switch( kind ) {
	case NK_TRACE_EVENT_INPUT_MOVE: input = PROFILE_INPUT_MOVE; break;
	case NK_TRACE_EVENT_INPUT_BUTTON: input = PROFILE_INPUT_BUTTON; break;
	case NK_TRACE_EVENT_INPUT_KEY: input = PROFILE_INPUT_KEY; break;
	case NK_TRACE_EVENT_POLLED_MOVE: input = PROFILE_INPUT_POLLED_MOVE; break;
	case NK_TRACE_EVENT_POLLED_BUTTON: input = PROFILE_INPUT_POLLED_BUTTON; break;
	case NK_TRACE_EVENT_POLLED_KEY: input = PROFILE_INPUT_POLLED_KEY; break;
	default: return;
	}
	/* The OS stamp is on NativeKit's clock, which may not be the profiler's, so the age is taken on NativeKit's. */
	if( os_time_ns != 0 ) {
		uint64_t now = native_trace_now_ns();
		if( now >= os_time_ns ) age = now - os_time_ns;
	}
	uint32_t zero = 0;
	memcpy(payload,&input,4);
	memcpy(payload + 4,&zero,4);
	memcpy(payload + 8,&age,8);
	memcpy(payload + 16,&a,8);
	memcpy(payload + 24,&b,8);
	hl_prof_event(PROFILE_EVENT_INPUT,payload,sizeof(payload));
}

/* Installs the sink in `library`, which the FFI must already have loaded (any NativeKit call loads it). Returns false
   when the library is not loaded or has no trace sink, as in a NativeKit built before nativekit_trace.h. */
HL_PRIM bool HL_NAME(native_trace_install)( vstring *library ) {
	const char *name = library == NULL ? NULL : realtime_string_utf8(library);
	haxeon_native_control *control = name == NULL ? NULL : haxeon_native_cached_control(name);
	void (NK_CALL *set_sink)( const nk_trace_sink * );
	if( control == NULL ) return false;
#ifdef _WIN32
	set_sink = (void (NK_CALL *)( const nk_trace_sink * ))GetProcAddress((HMODULE)control->handle,"nk_set_trace_sink");
	native_trace_now_ns = (uint64_t (NK_CALL *)( void ))GetProcAddress((HMODULE)control->handle,"nk_time_now_ns");
#else
	set_sink = (void (NK_CALL *)( const nk_trace_sink * ))haxeon_native_dlsym(control->handle,"nk_set_trace_sink",NULL);
	native_trace_now_ns = (uint64_t (NK_CALL *)( void ))haxeon_native_dlsym(control->handle,"nk_time_now_ns",NULL);
#endif
	if( set_sink == NULL || native_trace_now_ns == NULL ) return false;
	/* hl_prof_on is a libhl export, so its address is set here rather than in a static initializer. */
	native_trace_sink.struct_size = sizeof(native_trace_sink);
	native_trace_sink.enabled = &hl_prof_on;
	native_trace_sink.zone_begin = native_trace_zone_begin;
	native_trace_sink.zone_end = native_trace_zone_end;
	native_trace_sink.event = native_trace_event;
	set_sink(&native_trace_sink);
	return true;
}
