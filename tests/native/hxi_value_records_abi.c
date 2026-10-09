typedef signed char hxi_i8;
typedef unsigned char hxi_u8;
typedef signed short hxi_i16;
typedef signed int hxi_i32;
typedef signed long long hxi_i64;

typedef struct hxi_point {
	hxi_i32 x;
	hxi_i32 y;
} hxi_point;

typedef struct hxi_gapped {
	hxi_i8 tag;
	hxi_u8 reserved[7];
	hxi_i32 value;
} hxi_gapped;

typedef struct hxi_padded {
	hxi_i8 tag;
	hxi_i32 value;
} hxi_padded;

typedef struct hxi_pointer {
	void *value;
} hxi_pointer;

typedef struct hxi_type_info_pair {
	hxi_u8 tag;
	hxi_i64 value;
	float ratio;
} hxi_type_info_pair;

_Static_assert(sizeof(hxi_point) == 8, "point size");
_Static_assert(_Alignof(hxi_point) == 4, "point alignment");
_Static_assert(sizeof(hxi_gapped) == 12, "gapped size");
_Static_assert(_Alignof(hxi_gapped) == 4, "gapped alignment");
_Static_assert(sizeof(hxi_padded) == 8, "padded size");
_Static_assert(_Alignof(hxi_padded) == 4, "padded alignment");
_Static_assert(sizeof(hxi_pointer) == __SIZEOF_POINTER__, "pointer size");
_Static_assert(_Alignof(hxi_pointer) == __SIZEOF_POINTER__, "pointer alignment");
_Static_assert(sizeof(hxi_type_info_pair) == 24, "typeInfo Pair size");
_Static_assert(_Alignof(hxi_type_info_pair) == 8, "typeInfo Pair alignment");
_Static_assert(__builtin_offsetof(hxi_type_info_pair, tag) == 0, "typeInfo Pair tag offset");
_Static_assert(__builtin_offsetof(hxi_type_info_pair, value) == 8, "typeInfo Pair value offset");
_Static_assert(__builtin_offsetof(hxi_type_info_pair, ratio) == 16, "typeInfo Pair ratio offset");

extern int hxi_read_const(const hxi_point *value);
extern void hxi_write_out(hxi_point *value);
extern void hxi_update_inout(hxi_point *value);
extern int hxi_sum_value(hxi_point value);
extern hxi_point hxi_make_value(int seed);
extern hxi_gapped hxi_make_gapped(int seed);
