#include <hl.h>
#include <stdio.h>

/* A String type that declares an unnamed third field (vstring.hash) keeps the hash string maps compute for it: a key is
   hashed once, and a lookup with another String of the same text finds it and fills its own. A String of another type, as
   stock Haxe output declares it, is hashed every time and never written. The `_s` and `_n` entry points agree on every key. */

extern void *hl_hballoc( void );

static hl_type hashed_type, stock_type;
static hl_obj_field hashed_fields[3], stock_fields[2], misnamed_fields[3];
static hl_type_obj hashed_object, stock_object, misnamed_object;
static hl_type misnamed_type;
static uchar text_abc[] = { 'a', 'b', 'c', 0 }, text_abc_copy[] = { 'a', 'b', 'c', 0 }, text_abd[] = { 'a', 'b', 'd', 0 };
static void *map;

static int check( bool condition, const char *what ) {
	if( !condition ) fprintf(stderr,"FAIL: %s\n",what);
	return condition;
}

static void string_type( hl_type *t, hl_type_obj *o, hl_obj_field *fields, int nfields, const uchar *third ) {
	fields[0].name = USTR("bytes");
	fields[0].t = &hlt_bytes;
	fields[1].name = USTR("length");
	fields[1].t = &hlt_i32;
	if( nfields == 3 ) {
		fields[2].name = third;
		fields[2].t = &hlt_i32;
	}
	o->nfields = nfields;
	o->name = USTR("String");
	o->fields = fields;
	t->kind = HOBJ;
	t->obj = o;
}

static vstring string_of( hl_type *t, uchar *text ) {
	vstring s = { t, text, 3, 0 };
	return s;
}

int main( void ) {
	int marker = 0, ok = 1;
	hl_global_init();
	hl_register_thread(&marker);
	string_type(&hashed_type,&hashed_object,hashed_fields,3,USTR(""));
	string_type(&stock_type,&stock_object,stock_fields,2,NULL);
	string_type(&misnamed_type,&misnamed_object,misnamed_fields,3,USTR("hash"));
	ok &= check(hl_is_string_type(&stock_type),"a String of two fields is a String");
	ok &= check(hl_is_string_type(&hashed_type),"a String with an unnamed third field is a String");
	ok &= check(!hl_is_string_type(&misnamed_type),"a named third field makes no String");
	hl_register_string_type(&hashed_type);
	ok &= check(hl_string_hashes(),"the registered String type keeps hashes");

	map = hl_hballoc();
	hl_add_root(&map);
	vdynamic *one = hl_make_dyn(&(int){1},&hlt_i32);
	vstring key = string_of(&hashed_type,text_abc), same = string_of(&hashed_type,text_abc_copy),
		other = string_of(&hashed_type,text_abd);
	hl_hbset_s(map,&key,one);
	ok &= check(key.hash != 0,"setting a key keeps its hash");
	ok &= check(same.hash == 0 && hl_hbget_s(map,&same) == one,"another String of the same text finds the entry");
	ok &= check(same.hash == key.hash,"and keeps the same hash");
	ok &= check(!hl_hbexists_s(map,&other),"a String of other text finds nothing");
	ok &= check(hl_hbget_n(map,text_abc_copy,3) == one,"the length-given entry point finds a String key");
	hl_hbset_n(map,text_abd,3,one);
	ok &= check(hl_hbexists_s(map,&other),"a String finds a key set by length");

	vstring stock = string_of(&stock_type,text_abc_copy);
	ok &= check(hl_hbget_s(map,&stock) == one && stock.hash == 0,"a String of another type is found and not written");

	ok &= check(hl_hbremove_s(map,&same) && !hl_hbexists_s(map,&key),"removing by an equal String removes the key");
	if( ok ) printf("PASS: Strings keep their string-map hash; other String types are hashed each time\n");
	return ok ? 0 : 1;
}
