typedef struct realtime_string_map realtime_string_map;

HL_PRIM bool HL_NAME(__math_is_nan)( double value ) {
	return isnan(value);
}

HL_PRIM bool HL_NAME(__math_is_finite)(double value) {
	return isfinite(value);
}

HL_PRIM double HL_NAME(__math_pow)(double value, double exponent) {
	return pow(value, exponent);
}

HL_PRIM double HL_NAME(__math_cos)(double value) {
	return cos(value);
}

HL_PRIM double HL_NAME(__math_sin)(double value) {
	return sin(value);
}

HL_PRIM double HL_NAME(__math_tan)(double value) {
	return tan(value);
}

HL_PRIM double HL_NAME(__math_fmod)(double value, double modulus) {
	return fmod(value, modulus);
}

HL_PRIM int HL_NAME(__math_round)(double value) {
	return (int)floor(value + 0.5);
}

HL_PRIM int HL_NAME(__math_ceil)(double value) {
	return (int)ceil(value);
}
extern realtime_string_map *hl_hballoc( void );
extern void hl_hbset( realtime_string_map *map, uchar *key, vdynamic *value );
extern bool hl_hbexists( realtime_string_map *map, uchar *key );
extern vdynamic *hl_hbget( realtime_string_map *map, uchar *key );
extern varray *hl_hbkeys( realtime_string_map *map );
extern varray *hl_hbvalues( realtime_string_map *map );
extern int hl_hbsize( realtime_string_map *map );
extern bool hl_hbremove( realtime_string_map *map, uchar *key );
extern void hl_hbclear( realtime_string_map *map );

static void realtime_raise_module_exception( void ) {
	/* A module exception owns generation-specific type metadata. Never let that
	   value escape into the host exception machinery after the call returns. */
	hl_thread_info *thread = hl_get_thread();
	thread->exc_value = NULL;
	thread->exc_stack_count = 0;
	memset(thread->exc_stack_trace,0,sizeof(thread->exc_stack_trace));
	hl_error("Runtime module call raised an exception");
}

typedef struct realtime_int_map realtime_int_map;
extern realtime_int_map *hl_hialloc( void );
extern void hl_hiset( realtime_int_map *map, int key, vdynamic *value );
extern bool hl_hiexists( realtime_int_map *map, int key );
extern vdynamic *hl_higet( realtime_int_map *map, int key );
extern varray *hl_hikeys( realtime_int_map *map );
extern varray *hl_hivalues( realtime_int_map *map );
extern int hl_hisize( realtime_int_map *map );
extern bool hl_hiremove( realtime_int_map *map, int key );
extern void hl_hiclear( realtime_int_map *map );

typedef struct {
	int offset;
	char *value;
} realtime_bytes_owned_utf8;

typedef struct realtime_bytes {
	void (*finalize)( void * );
	vbyte *data;
	int length;
	realtime_bytes_owned_utf8 *owned_utf8;
	int owned_utf8_count;
	int owned_utf8_capacity;
	struct realtime_bytes *owner;
} realtime_bytes;

typedef struct {
	void (*finalize)( void * );
	vbyte *data;
	int length;
	int position;
	bool big_endian;
} realtime_bytes_input;

typedef struct {
	void (*finalize)( void * );
	vbyte *data;
	int length;
	int capacity;
	bool big_endian;
} realtime_bytes_output;

typedef struct { double milliseconds; } realtime_date;
extern double hl_sys_time( void );

HL_PRIM realtime_date *HL_NAME(__date_now)( void ) {
	realtime_date *date = (realtime_date *)hl_gc_alloc_raw(sizeof(realtime_date));
	date->milliseconds = hl_sys_time() * 1000.0;
	return date;
}

HL_PRIM double HL_NAME(__date_get_time)( realtime_date *date ) { return date->milliseconds; }
