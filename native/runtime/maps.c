HL_PRIM realtime_string_map *HL_NAME(__map_string_i32_alloc)( void ) {
	return hl_hballoc();
}

HL_PRIM void HL_NAME(__map_string_i32_set)( realtime_string_map *map, vbyte *key, int value ) {
	vdynamic *dynamic = hl_alloc_dynamic(&hlt_i32);
	dynamic->v.i = value;
	hl_hbset(map, (uchar *)key, dynamic);
}

HL_PRIM bool HL_NAME(__map_string_i32_exists)( realtime_string_map *map, vbyte *key ) {
	return hl_hbexists(map, (uchar *)key);
}

HL_PRIM vdynamic *HL_NAME(__map_string_i32_get)( realtime_string_map *map, vbyte *key ) { return hl_hbget(map, (uchar *)key); }

HL_PRIM realtime_string_map *HL_NAME(__map_string_bool_alloc)( void ) {
	return hl_hballoc();
}

HL_PRIM void HL_NAME(__map_string_bool_set)( realtime_string_map *map, vbyte *key, bool value ) {
	vdynamic *dynamic = hl_alloc_dynamic(&hlt_bool);
	dynamic->v.b = value;
	hl_hbset(map, (uchar *)key, dynamic);
}

HL_PRIM bool HL_NAME(__map_string_bool_exists)( realtime_string_map *map, vbyte *key ) {
	return hl_hbexists(map, (uchar *)key);
}

HL_PRIM vdynamic *HL_NAME(__map_string_bool_get)( realtime_string_map *map, vbyte *key ) { return hl_hbget(map, (uchar *)key); }

HL_PRIM realtime_string_map *HL_NAME(__map_string_f64_alloc)( void ) {
	return hl_hballoc();
}

HL_PRIM void HL_NAME(__map_string_f64_set)( realtime_string_map *map, vbyte *key, double value ) {
	vdynamic *dynamic = hl_alloc_dynamic(&hlt_f64);
	dynamic->v.d = value;
	hl_hbset(map, (uchar *)key, dynamic);
}

HL_PRIM bool HL_NAME(__map_string_f64_exists)( realtime_string_map *map, vbyte *key ) {
	return hl_hbexists(map, (uchar *)key);
}

HL_PRIM vdynamic *HL_NAME(__map_string_f64_get)( realtime_string_map *map, vbyte *key ) { return hl_hbget(map, (uchar *)key); }

HL_PRIM realtime_string_map *HL_NAME(__map_string_bytes_alloc)( void ) {
	return hl_hballoc();
}

HL_PRIM void HL_NAME(__map_string_bytes_set)( realtime_string_map *map, vbyte *key, vbyte *value ) {
	vdynamic *dynamic = hl_alloc_dynamic(&hlt_bytes);
	dynamic->v.bytes = value;
	hl_hbset(map, (uchar *)key, dynamic);
}

HL_PRIM bool HL_NAME(__map_string_bytes_exists)( realtime_string_map *map, vbyte *key ) {
	return hl_hbexists(map, (uchar *)key);
}

HL_PRIM vdynamic *HL_NAME(__map_string_bytes_get)( realtime_string_map *map, vbyte *key ) { return hl_hbget(map, (uchar *)key); }

HL_PRIM varray *HL_NAME(__map_string_i32_keys)( realtime_string_map *map ) { return hl_hbkeys(map); }
HL_PRIM varray *HL_NAME(__map_string_bool_keys)( realtime_string_map *map ) { return hl_hbkeys(map); }
HL_PRIM varray *HL_NAME(__map_string_f64_keys)( realtime_string_map *map ) { return hl_hbkeys(map); }
HL_PRIM varray *HL_NAME(__map_string_bytes_keys)( realtime_string_map *map ) { return hl_hbkeys(map); }
HL_PRIM varray *HL_NAME(__map_string_i32_values)( realtime_string_map *map ) { return realtime_typed_values(hl_hbvalues(map), &hlt_i32); }
HL_PRIM varray *HL_NAME(__map_string_bool_values)( realtime_string_map *map ) { return realtime_typed_values(hl_hbvalues(map), &hlt_bool); }
HL_PRIM varray *HL_NAME(__map_string_f64_values)( realtime_string_map *map ) { return realtime_typed_values(hl_hbvalues(map), &hlt_f64); }
HL_PRIM varray *HL_NAME(__map_string_bytes_values)( realtime_string_map *map ) { return realtime_typed_values(hl_hbvalues(map), &hlt_bytes); }
HL_PRIM bool HL_NAME(__map_string_i32_remove)( realtime_string_map *map, vbyte *key ) { return hl_hbremove(map, (uchar *)key); }
HL_PRIM bool HL_NAME(__map_string_bool_remove)( realtime_string_map *map, vbyte *key ) { return hl_hbremove(map, (uchar *)key); }
HL_PRIM bool HL_NAME(__map_string_f64_remove)( realtime_string_map *map, vbyte *key ) { return hl_hbremove(map, (uchar *)key); }
HL_PRIM bool HL_NAME(__map_string_bytes_remove)( realtime_string_map *map, vbyte *key ) { return hl_hbremove(map, (uchar *)key); }
HL_PRIM void HL_NAME(__map_string_i32_clear)( realtime_string_map *map ) { hl_hbclear(map); }
HL_PRIM void HL_NAME(__map_string_bool_clear)( realtime_string_map *map ) { hl_hbclear(map); }
HL_PRIM void HL_NAME(__map_string_f64_clear)( realtime_string_map *map ) { hl_hbclear(map); }
HL_PRIM void HL_NAME(__map_string_bytes_clear)( realtime_string_map *map ) { hl_hbclear(map); }

#define DEFINE_STRING_MAP_SIZE(SUFFIX) \
HL_PRIM int HL_NAME(__map_string_##SUFFIX##_size)( realtime_string_map *map ) { return hl_hbsize(map); }

DEFINE_STRING_MAP_SIZE(i32)
DEFINE_STRING_MAP_SIZE(bool)
DEFINE_STRING_MAP_SIZE(f64)
DEFINE_STRING_MAP_SIZE(bytes)

#undef DEFINE_STRING_MAP_SIZE

#define DEFINE_STRING_REF_MAP() \
HL_PRIM realtime_string_map *HL_NAME(__map_string_ref_alloc)( void ) { return hl_hballoc(); } \
HL_PRIM void HL_NAME(__map_string_ref_set)( realtime_string_map *map, vbyte *key, void *value ) { \
	hl_hbset(map, (uchar *)key, (vdynamic *)value); \
} \
HL_PRIM bool HL_NAME(__map_string_ref_exists)( realtime_string_map *map, vbyte *key ) { return hl_hbexists(map, (uchar *)key); } \
HL_PRIM vdynamic *HL_NAME(__map_string_ref_get)( realtime_string_map *map, vbyte *key ) { \
	vdynamic *dynamic = hl_hbget(map, (uchar *)key); \
	return dynamic; \
} \
HL_PRIM varray *HL_NAME(__map_string_ref_keys)( realtime_string_map *map ) { return hl_hbkeys(map); } \
HL_PRIM varray *HL_NAME(__map_string_ref_values)( realtime_string_map *map ) { return realtime_ref_values(hl_hbvalues(map)); } \
HL_PRIM bool HL_NAME(__map_string_ref_remove)( realtime_string_map *map, vbyte *key ) { return hl_hbremove(map, (uchar *)key); } \
HL_PRIM void HL_NAME(__map_string_ref_clear)( realtime_string_map *map ) { hl_hbclear(map); } \
HL_PRIM int HL_NAME(__map_string_ref_size)( realtime_string_map *map ) { return hl_hbsize(map); }

DEFINE_STRING_REF_MAP()

#undef DEFINE_STRING_REF_MAP

#define DEFINE_INT_MAP(SUFFIX, VALUE_TYPE, VALUE_FIELD, VALUE_HLTYPE) \
HL_PRIM realtime_int_map *HL_NAME(__map_int_##SUFFIX##_alloc)( void ) { return hl_hialloc(); } \
HL_PRIM void HL_NAME(__map_int_##SUFFIX##_set)( realtime_int_map *map, int key, VALUE_TYPE value ) { \
	vdynamic *dynamic = hl_alloc_dynamic(&VALUE_HLTYPE); \
	dynamic->v.VALUE_FIELD = value; \
	hl_hiset(map, key, dynamic); \
} \
HL_PRIM bool HL_NAME(__map_int_##SUFFIX##_exists)( realtime_int_map *map, int key ) { return hl_hiexists(map, key); } \
HL_PRIM vdynamic *HL_NAME(__map_int_##SUFFIX##_get)( realtime_int_map *map, int key ) { return hl_higet(map, key); }

DEFINE_INT_MAP(i32, int, i, hlt_i32)
DEFINE_INT_MAP(bool, bool, b, hlt_bool)
DEFINE_INT_MAP(f64, double, d, hlt_f64)
DEFINE_INT_MAP(bytes, vbyte *, bytes, hlt_bytes)

HL_PRIM varray *HL_NAME(__map_int_i32_keys)( realtime_int_map *map ) { return hl_hikeys(map); }
HL_PRIM varray *HL_NAME(__map_int_bool_keys)( realtime_int_map *map ) { return hl_hikeys(map); }
HL_PRIM varray *HL_NAME(__map_int_f64_keys)( realtime_int_map *map ) { return hl_hikeys(map); }
HL_PRIM varray *HL_NAME(__map_int_bytes_keys)( realtime_int_map *map ) { return hl_hikeys(map); }
HL_PRIM varray *HL_NAME(__map_int_i32_values)( realtime_int_map *map ) { return realtime_typed_values(hl_hivalues(map), &hlt_i32); }
HL_PRIM varray *HL_NAME(__map_int_bool_values)( realtime_int_map *map ) { return realtime_typed_values(hl_hivalues(map), &hlt_bool); }
HL_PRIM varray *HL_NAME(__map_int_f64_values)( realtime_int_map *map ) { return realtime_typed_values(hl_hivalues(map), &hlt_f64); }
HL_PRIM varray *HL_NAME(__map_int_bytes_values)( realtime_int_map *map ) { return realtime_typed_values(hl_hivalues(map), &hlt_bytes); }
HL_PRIM bool HL_NAME(__map_int_i32_remove)( realtime_int_map *map, int key ) { return hl_hiremove(map, key); }
HL_PRIM bool HL_NAME(__map_int_bool_remove)( realtime_int_map *map, int key ) { return hl_hiremove(map, key); }
HL_PRIM bool HL_NAME(__map_int_f64_remove)( realtime_int_map *map, int key ) { return hl_hiremove(map, key); }
HL_PRIM bool HL_NAME(__map_int_bytes_remove)( realtime_int_map *map, int key ) { return hl_hiremove(map, key); }
HL_PRIM void HL_NAME(__map_int_i32_clear)( realtime_int_map *map ) { hl_hiclear(map); }
HL_PRIM void HL_NAME(__map_int_bool_clear)( realtime_int_map *map ) { hl_hiclear(map); }
HL_PRIM void HL_NAME(__map_int_f64_clear)( realtime_int_map *map ) { hl_hiclear(map); }
HL_PRIM void HL_NAME(__map_int_bytes_clear)( realtime_int_map *map ) { hl_hiclear(map); }

#define DEFINE_INT_MAP_SIZE(SUFFIX) \
HL_PRIM int HL_NAME(__map_int_##SUFFIX##_size)( realtime_int_map *map ) { return hl_hisize(map); }

DEFINE_INT_MAP_SIZE(i32)
DEFINE_INT_MAP_SIZE(bool)
DEFINE_INT_MAP_SIZE(f64)
DEFINE_INT_MAP_SIZE(bytes)

#undef DEFINE_INT_MAP_SIZE

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
HL_PRIM varray *HL_NAME(__map_int_ref_values)( realtime_int_map *map ) { return realtime_ref_values(hl_hivalues(map)); } \
HL_PRIM bool HL_NAME(__map_int_ref_remove)( realtime_int_map *map, int key ) { return hl_hiremove(map, key); } \
HL_PRIM void HL_NAME(__map_int_ref_clear)( realtime_int_map *map ) { hl_hiclear(map); } \
HL_PRIM int HL_NAME(__map_int_ref_size)( realtime_int_map *map ) { return hl_hisize(map); }

DEFINE_INT_REF_MAP()

#undef DEFINE_INT_REF_MAP

#undef DEFINE_INT_MAP
