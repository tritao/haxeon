/* Scalar values (Int, Int64, Bool, Float) are kept unboxed in the VM's scalar-valued maps (hl_hss_, hl_his_), 64 bits
   each: an Int or a Bool widened, a Float by its bits. Compiled code looks a key up with `index`, then reads the value of
   the entry found with `value`, so no lookup boxes. `get` boxes the value it finds, for bytecode built before `index`.
   String maps (hl_hs, hl_hss_) keep the key Strings themselves, so a key listing is an array of those Strings. */

static int64 realtime_map_f64_bits( double value ) {
	int64 bits;
	memcpy(&bits, &value, sizeof(bits));
	return bits;
}

static double realtime_map_f64_value( int64 bits ) {
	double value;
	memcpy(&value, &bits, sizeof(value));
	return value;
}

#define REALTIME_MAP_I32_STORE(value) ((int64)(value))
#define REALTIME_MAP_I32_LOAD(bits) ((int)(bits))
#define REALTIME_MAP_I64_STORE(value) ((int64)(value))
#define REALTIME_MAP_I64_LOAD(bits) ((int64)(bits))
#define REALTIME_MAP_BOOL_STORE(value) ((int64)((value) ? 1 : 0))
#define REALTIME_MAP_BOOL_LOAD(bits) ((bits) != 0)
#define REALTIME_MAP_F64_STORE(value) realtime_map_f64_bits(value)
#define REALTIME_MAP_F64_LOAD(bits) realtime_map_f64_value(bits)

#define DEFINE_STRING_SCALAR_MAP(SUFFIX, VALUE_TYPE, CODEC, VALUE_HLTYPE) \
HL_PRIM realtime_string_map *HL_NAME(__map_string_##SUFFIX##_alloc)( void ) { return hl_hss_alloc(); } \
HL_PRIM void HL_NAME(__map_string_##SUFFIX##_set)( realtime_string_map *map, vstring *key, VALUE_TYPE value ) { \
	hl_hss_set(map, key, REALTIME_MAP_##CODEC##_STORE(value)); \
} \
HL_PRIM bool HL_NAME(__map_string_##SUFFIX##_exists)( realtime_string_map *map, vstring *key ) { return hl_hss_exists(map, key); } \
HL_PRIM int HL_NAME(__map_string_##SUFFIX##_index)( realtime_string_map *map, vstring *key ) { return hl_hss_index(map, key); } \
HL_PRIM VALUE_TYPE HL_NAME(__map_string_##SUFFIX##_value)( realtime_string_map *map, int index ) { \
	return REALTIME_MAP_##CODEC##_LOAD(hl_hss_value(map, index)); \
} \
HL_PRIM vdynamic *HL_NAME(__map_string_##SUFFIX##_get)( realtime_string_map *map, vstring *key ) { \
	int index = hl_hss_index(map, key); \
	if( index < 0 ) return NULL; \
	VALUE_TYPE value = REALTIME_MAP_##CODEC##_LOAD(hl_hss_value(map, index)); \
	return hl_make_dyn(&value, &VALUE_HLTYPE); \
} \
HL_PRIM varray *HL_NAME(__map_string_##SUFFIX##_keys)( realtime_string_map *map ) { return hl_hss_keys(map); } \
HL_PRIM varray *HL_NAME(__map_string_##SUFFIX##_values)( realtime_string_map *map ) { return hl_hss_values(map, &VALUE_HLTYPE); } \
HL_PRIM bool HL_NAME(__map_string_##SUFFIX##_remove)( realtime_string_map *map, vstring *key ) { return hl_hss_remove(map, key); } \
HL_PRIM void HL_NAME(__map_string_##SUFFIX##_clear)( realtime_string_map *map ) { hl_hss_clear(map); } \
HL_PRIM realtime_string_map *HL_NAME(__map_string_##SUFFIX##_copy)( realtime_string_map *map ) { return hl_hss_copy(map); } \
HL_PRIM int HL_NAME(__map_string_##SUFFIX##_size)( realtime_string_map *map ) { return hl_hss_size(map); }

DEFINE_STRING_SCALAR_MAP(i32, int, I32, hlt_i32)
DEFINE_STRING_SCALAR_MAP(i64, int64_t, I64, hlt_i64)
DEFINE_STRING_SCALAR_MAP(bool, bool, BOOL, hlt_bool)
DEFINE_STRING_SCALAR_MAP(f64, double, F64, hlt_f64)

#undef DEFINE_STRING_SCALAR_MAP

HL_PRIM realtime_string_map *HL_NAME(__map_string_bytes_alloc)( void ) { return hl_hsalloc(); }
HL_PRIM void HL_NAME(__map_string_bytes_set)( realtime_string_map *map, vstring *key, vstring *value ) {
	hl_hsset(map, key, (vdynamic *)value);
}
HL_PRIM bool HL_NAME(__map_string_bytes_exists)( realtime_string_map *map, vstring *key ) { return hl_hsexists(map, key); }
HL_PRIM vdynamic *HL_NAME(__map_string_bytes_get)( realtime_string_map *map, vstring *key ) { return hl_hsget(map, key); }
HL_PRIM varray *HL_NAME(__map_string_bytes_keys)( realtime_string_map *map ) { return hl_hskeys(map); }
HL_PRIM varray *HL_NAME(__map_string_bytes_values)( realtime_string_map *map ) { return realtime_typed_values(hl_hsvalues(map), hl_string_type); }
HL_PRIM bool HL_NAME(__map_string_bytes_remove)( realtime_string_map *map, vstring *key ) { return hl_hsremove(map, key); }
HL_PRIM void HL_NAME(__map_string_bytes_clear)( realtime_string_map *map ) { hl_hsclear(map); }
HL_PRIM realtime_string_map *HL_NAME(__map_string_bytes_copy)( realtime_string_map *map ) { return hl_hscopy(map); }
HL_PRIM int HL_NAME(__map_string_bytes_size)( realtime_string_map *map ) { return hl_hssize(map); }

/* A reference map holding native handles of `type` (a map in a map) holds each as it is, not boxed: the listing of its
   values already has the representation of an array of `type`, which it is retyped to. */
static varray *realtime_map_handles( varray *values, hl_type *type ) {
	values->at = type;
	return values;
}

#define DEFINE_STRING_REF_MAP() \
HL_PRIM realtime_string_map *HL_NAME(__map_string_ref_alloc)( void ) { return hl_hsalloc(); } \
HL_PRIM void HL_NAME(__map_string_ref_set)( realtime_string_map *map, vstring *key, void *value ) { \
	hl_hsset(map, key, (vdynamic *)value); \
} \
HL_PRIM bool HL_NAME(__map_string_ref_exists)( realtime_string_map *map, vstring *key ) { return hl_hsexists(map, key); } \
HL_PRIM vdynamic *HL_NAME(__map_string_ref_get)( realtime_string_map *map, vstring *key ) { \
	vdynamic *dynamic = hl_hsget(map, key); \
	return dynamic; \
} \
HL_PRIM varray *HL_NAME(__map_string_ref_keys)( realtime_string_map *map ) { return hl_hskeys(map); } \
HL_PRIM varray *HL_NAME(__map_string_ref_values)( realtime_string_map *map ) { return hl_hsvalues(map); } \
HL_PRIM varray *HL_NAME(__map_string_ref_handles)( realtime_string_map *map, hl_type *type ) { return realtime_map_handles(hl_hsvalues(map), type); } \
HL_PRIM bool HL_NAME(__map_string_ref_remove)( realtime_string_map *map, vstring *key ) { return hl_hsremove(map, key); } \
HL_PRIM void HL_NAME(__map_string_ref_clear)( realtime_string_map *map ) { hl_hsclear(map); } \
HL_PRIM realtime_string_map *HL_NAME(__map_string_ref_copy)( realtime_string_map *map ) { return hl_hscopy(map); } \
HL_PRIM int HL_NAME(__map_string_ref_size)( realtime_string_map *map ) { return hl_hssize(map); }

DEFINE_STRING_REF_MAP()

#undef DEFINE_STRING_REF_MAP

#define DEFINE_INT_SCALAR_MAP(SUFFIX, VALUE_TYPE, CODEC, VALUE_HLTYPE) \
HL_PRIM realtime_int_map *HL_NAME(__map_int_##SUFFIX##_alloc)( void ) { return hl_his_alloc(); } \
HL_PRIM void HL_NAME(__map_int_##SUFFIX##_set)( realtime_int_map *map, int key, VALUE_TYPE value ) { \
	hl_his_set(map, key, REALTIME_MAP_##CODEC##_STORE(value)); \
} \
HL_PRIM bool HL_NAME(__map_int_##SUFFIX##_exists)( realtime_int_map *map, int key ) { return hl_his_exists(map, key); } \
HL_PRIM int HL_NAME(__map_int_##SUFFIX##_index)( realtime_int_map *map, int key ) { return hl_his_index(map, key); } \
HL_PRIM VALUE_TYPE HL_NAME(__map_int_##SUFFIX##_value)( realtime_int_map *map, int index ) { \
	return REALTIME_MAP_##CODEC##_LOAD(hl_his_value(map, index)); \
} \
HL_PRIM vdynamic *HL_NAME(__map_int_##SUFFIX##_get)( realtime_int_map *map, int key ) { \
	int index = hl_his_index(map, key); \
	if( index < 0 ) return NULL; \
	VALUE_TYPE value = REALTIME_MAP_##CODEC##_LOAD(hl_his_value(map, index)); \
	return hl_make_dyn(&value, &VALUE_HLTYPE); \
} \
HL_PRIM varray *HL_NAME(__map_int_##SUFFIX##_keys)( realtime_int_map *map ) { return hl_his_keys(map); } \
HL_PRIM varray *HL_NAME(__map_int_##SUFFIX##_values)( realtime_int_map *map ) { return hl_his_values(map, &VALUE_HLTYPE); } \
HL_PRIM bool HL_NAME(__map_int_##SUFFIX##_remove)( realtime_int_map *map, int key ) { return hl_his_remove(map, key); } \
HL_PRIM void HL_NAME(__map_int_##SUFFIX##_clear)( realtime_int_map *map ) { hl_his_clear(map); } \
HL_PRIM realtime_int_map *HL_NAME(__map_int_##SUFFIX##_copy)( realtime_int_map *map ) { return hl_his_copy(map); } \
HL_PRIM int HL_NAME(__map_int_##SUFFIX##_size)( realtime_int_map *map ) { return hl_his_size(map); }

DEFINE_INT_SCALAR_MAP(i32, int, I32, hlt_i32)
DEFINE_INT_SCALAR_MAP(i64, int64_t, I64, hlt_i64)
DEFINE_INT_SCALAR_MAP(bool, bool, BOOL, hlt_bool)
DEFINE_INT_SCALAR_MAP(f64, double, F64, hlt_f64)

#undef DEFINE_INT_SCALAR_MAP

HL_PRIM realtime_int_map *HL_NAME(__map_int_bytes_alloc)( void ) { return hl_hialloc(); }
HL_PRIM void HL_NAME(__map_int_bytes_set)( realtime_int_map *map, int key, vstring *value ) { hl_hiset(map, key, (vdynamic *)value); }
HL_PRIM bool HL_NAME(__map_int_bytes_exists)( realtime_int_map *map, int key ) { return hl_hiexists(map, key); }
HL_PRIM vdynamic *HL_NAME(__map_int_bytes_get)( realtime_int_map *map, int key ) { return hl_higet(map, key); }
HL_PRIM varray *HL_NAME(__map_int_bytes_keys)( realtime_int_map *map ) { return hl_hikeys(map); }
HL_PRIM varray *HL_NAME(__map_int_bytes_values)( realtime_int_map *map ) { return realtime_typed_values(hl_hivalues(map), hl_string_type); }
HL_PRIM bool HL_NAME(__map_int_bytes_remove)( realtime_int_map *map, int key ) { return hl_hiremove(map, key); }
HL_PRIM void HL_NAME(__map_int_bytes_clear)( realtime_int_map *map ) { hl_hiclear(map); }
HL_PRIM realtime_int_map *HL_NAME(__map_int_bytes_copy)( realtime_int_map *map ) { return hl_hicopy(map); }
HL_PRIM int HL_NAME(__map_int_bytes_size)( realtime_int_map *map ) { return hl_hisize(map); }

#define DEFINE_INT_REF_MAP() \
HL_PRIM realtime_int_map *HL_NAME(__map_int_ref_alloc)( void ) { return hl_hialloc(); } \
HL_PRIM void HL_NAME(__map_int_ref_set)( realtime_int_map *map, int key, void *value ) { \
	hl_hiset(map, key, (vdynamic *)value); \
} \
HL_PRIM bool HL_NAME(__map_int_ref_exists)( realtime_int_map *map, int key ) { return hl_hiexists(map, key); } \
HL_PRIM vdynamic *HL_NAME(__map_int_ref_get)( realtime_int_map *map, int key ) { \
	vdynamic *dynamic = hl_higet(map, key); \
	return dynamic; \
} \
HL_PRIM varray *HL_NAME(__map_int_ref_keys)( realtime_int_map *map ) { return hl_hikeys(map); } \
HL_PRIM varray *HL_NAME(__map_int_ref_values)( realtime_int_map *map ) { return hl_hivalues(map); } \
HL_PRIM varray *HL_NAME(__map_int_ref_handles)( realtime_int_map *map, hl_type *type ) { return realtime_map_handles(hl_hivalues(map), type); } \
HL_PRIM bool HL_NAME(__map_int_ref_remove)( realtime_int_map *map, int key ) { return hl_hiremove(map, key); } \
HL_PRIM void HL_NAME(__map_int_ref_clear)( realtime_int_map *map ) { hl_hiclear(map); } \
HL_PRIM realtime_int_map *HL_NAME(__map_int_ref_copy)( realtime_int_map *map ) { return hl_hicopy(map); } \
HL_PRIM int HL_NAME(__map_int_ref_size)( realtime_int_map *map ) { return hl_hisize(map); }

DEFINE_INT_REF_MAP()

#undef DEFINE_INT_REF_MAP

/* The maps above are the VM's own (maps.h): an arena copies and evacuates them along the VM's map layout, which the
   scalar-valued maps share (their values block holds keys only, or no pointers). */
#if defined(__GNUC__)
__attribute__((constructor)) static void realtime_map_layouts( void ) {
	static const uchar *names[] = {
		USTR("map_string_i32"), USTR("map_string_i64"), USTR("map_string_bool"), USTR("map_string_f64"), USTR("map_string_bytes"),
		USTR("map_string_ref"), USTR("map_int_i32"), USTR("map_int_i64"), USTR("map_int_bool"), USTR("map_int_f64"),
		USTR("map_int_bytes"), USTR("map_int_ref")
	};
	for( unsigned i = 0; i < sizeof(names) / sizeof(names[0]); i++ )
		hl_gc_arena_register_layout(names[i], hl_gc_arena_map_layout);
}
#endif
