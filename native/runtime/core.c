/* A Haxe String is a HashLink String object: UTF-16 data plus its length in code units. The data
   stays NUL-terminated so C consumers such as hl_to_utf8 can read it directly. */
static inline int realtime_string_length( vstring *value ) {
	return value == NULL ? 0 : value->length;
}

static inline const uchar *realtime_string_data( vstring *value ) {
	return value == NULL ? NULL : value->bytes;
}

static inline bool realtime_is_string( vdynamic *value ) {
	return value != NULL && hl_is_string_type(value->t);
}

/* Wraps already NUL-terminated data without copying it. */
static vstring *realtime_string_wrap( uchar *data, int length ) {
	vstring *result = hl_alloc_string(data,length);
	if( result == NULL ) hl_fatal("HashLink String type is not registered");
	return result;
}

/* A new String with `length` uninitialized code units, returned through `data`. */
static vstring *realtime_string_alloc( int length, uchar **data ) {
	uchar *output = (uchar *)hl_alloc_bytes((length + 1) * (int)sizeof(uchar));
	output[length] = 0;
	if( data != NULL ) *data = output;
	return realtime_string_wrap(output,length);
}

static vstring *realtime_string_copy( const uchar *data, int length ) {
	uchar *output;
	vstring *result = realtime_string_alloc(length,&output);
	if( length > 0 ) memcpy(output,data,length * sizeof(uchar));
	return result;
}

/* Copies a NUL-terminated UTF-16 buffer; NULL stays NULL. */
static vstring *realtime_string_of_ustr( const uchar *data ) {
	return data == NULL ? NULL : realtime_string_copy(data,(int)ustrlen(data));
}

/* Wraps an array of NUL-terminated UTF-16 buffers, as HashLink's own natives return, as Strings. */
static varray *realtime_string_array( varray *buffers ) {
	if( buffers == NULL ) return NULL;
	varray *result = hl_alloc_array(hl_string_type, buffers->size);
	uchar **source = hl_aptr(buffers, uchar *);
	vstring **target = hl_aptr(result, vstring *);
	for( int i = 0; i < buffers->size; i++ )
		target[i] = source[i] == NULL ? NULL : realtime_string_wrap(source[i], (int)ustrlen(source[i]));
	return result;
}

static const char *realtime_string_utf8( vstring *value ) {
	return value == NULL ? NULL : hl_to_utf8(value->bytes);
}

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

HL_PRIM double HL_NAME(__math_sqrt)(double value) {
	return sqrt(value);
}

// Used by the HL host only through the Wasm-shaped natives; Math.abs/min/max are inlined there but the declarations
// are still imported, so the library must define them. NaN in either operand gives NaN and -0.0 is below 0.0.
HL_PRIM double HL_NAME(__math_abs)(double value) {
	return fabs(value);
}

HL_PRIM double HL_NAME(__math_min)(double left, double right) {
	if (left != left || right != right)
		return NAN;
	return left < right ? left : (right < left ? right : (signbit(left) ? left : right));
}

HL_PRIM double HL_NAME(__math_max)(double left, double right) {
	if (left != left || right != right)
		return NAN;
	return left > right ? left : (right > left ? right : (signbit(left) ? right : left));
}

HL_PRIM double HL_NAME(__math_atan2)(double y, double x) {
	return atan2(y, x);
}

HL_PRIM double HL_NAME(__math_exp)(double value) {
	return exp(value);
}

HL_PRIM double HL_NAME(__math_log)(double value) {
	return log(value);
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

HL_PRIM int HL_NAME(__math_floor)(double value) {
	return (int)floor(value);
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
extern realtime_string_map *hl_hbcopy( realtime_string_map *map );

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
extern realtime_int_map *hl_hicopy( realtime_int_map *map );

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
	varray *roots;
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
