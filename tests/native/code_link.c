#include <hlmodule.h>
#include "../include/lz4/lz4.h"
#include <stdarg.h>
#include <stdio.h>

/*
	The HLB 9 section linker (vendor/hashlink/src/link.c, docs/design/MODULE_SECTIONS.md). The compiler does not write
	sectioned files yet, so these tests build them here, with a writer for both encodings: a program split into sections
	links into the tables a dense HLB 8 file of the same program reads into, and runs. Every load error is checked to name
	the section and the key involved. Patches made of sections (HLP 12) link against the state a patchable load keeps
	(`hl_module_link_patch`); they are checked to apply, to compile only what changed, and to leave the module as it was when
	refused.

	`code_link --write FILE` writes the program as an HLB 9 file. `code_link --bench RUNS [dense.hl]` links a synthetic image
	sized like the compiler server and reports the time, with the dense read of the given file for comparison.
*/

// ---- bytes

typedef struct {
	unsigned char *d;
	int len, cap;
} buf;

static void b_raw( buf *b, const void *data, int len ) {
	if( b->len + len > b->cap ) {
		while( b->len + len > b->cap ) b->cap = b->cap ? b->cap * 2 : 256;
		b->d = (unsigned char*)realloc(b->d, b->cap);
	}
	if( len ) memcpy(b->d + b->len, data, len);
	b->len += len;
}

static void b_byte( buf *b, int v ) {
	unsigned char c = (unsigned char)v;
	b_raw(b, &c, 1);
}

/* HashLink's index encoding: 7 bits, then 13 bits with a sign, then 29 bits with a sign. */
static void b_index( buf *b, int v ) {
	int neg = v < 0, a = neg ? -v : v;
	if( !neg && a < 0x80 )
		b_byte(b, a);
	else if( a < 0x2000 ) {
		b_byte(b, 0x80 | (neg ? 0x20 : 0) | (a >> 8));
		b_byte(b, a & 0xFF);
	} else {
		b_byte(b, 0xC0 | (neg ? 0x20 : 0) | (a >> 24));
		b_byte(b, (a >> 16) & 0xFF);
		b_byte(b, (a >> 8) & 0xFF);
		b_byte(b, a & 0xFF);
	}
}

static void b_i32( buf *b, int v ) {
	b_byte(b, v & 0xFF);
	b_byte(b, (v >> 8) & 0xFF);
	b_byte(b, (v >> 16) & 0xFF);
	b_byte(b, (v >> 24) & 0xFF);
}

static void b_text( buf *b, const char *s ) {
	int len = (int)strlen(s);
	b_index(b, len);
	b_raw(b, s, len);
}

static void b_buf( buf *b, buf *from ) {
	b_raw(b, from->d, from->len);
}

typedef struct {
	const char **items;
	int count, cap;
} strlist;

static int list_find( strlist *l, const char *s ) {
	for(int i=0;i<l->count;i++) if( strcmp(l->items[i], s) == 0 ) return i;
	return -1;
}

static int list_add( strlist *l, const char *s ) {
	if( l->count == l->cap ) {
		l->cap = l->cap ? l->cap * 2 : 16;
		l->items = (const char**)realloc((void*)l->items, sizeof(char*) * l->cap);
	}
	l->items[l->count] = s;
	return l->count++;
}

static int list_intern( strlist *l, const char *s ) {
	int i = list_find(l, s);
	return i >= 0 ? i : list_add(l, s);
}

/* A string table as HLB 8 encodes one. */
static void b_strings( buf *b, strlist *l ) {
	int size = 0;
	for(int i=0;i<l->count;i++) size += (int)strlen(l->items[i]) + 1;
	b_i32(b, size);
	for(int i=0;i<l->count;i++) b_raw(b, l->items[i], (int)strlen(l->items[i]) + 1);
	for(int i=0;i<l->count;i++) b_index(b, (int)strlen(l->items[i]));
}

// ---- units: one section, or a whole dense program

typedef struct {
	int key;
	int type;
	int nregs;
	int regs[32];
	buf ops;
	int nops;
	buf debug;
	int file, line;
	buf assigns;
	int nassigns;
} unit_fn;

enum { STRUCTURAL = 0, OWNED = 1, SHARED = 2 };

typedef struct {
	const char *path;
	bool debug;
	strlist names, strings, files;
	int nfimports, ngimports, ntimports, nnatives, ntypes, nglobals, nconstants, nints, nfloats, nbytes;
	buf fimports, gimports, timports, natives, type_heads, global_heads;
	buf ints, floats, bytes, types, constants;
	/* Dense programs only: global types, and natives with their function index. */
	buf dense_globals, dense_natives;
	unit_fn fns[64];
	int nfns;
	/* Debug sub-sections after the functions: kind, version, flags, size and payload each. */
	buf debug_sections;
	int ndebug_sections;
} unit;

static unit *unit_new( const char *path, bool debug ) {
	unit *u = (unit*)calloc(1, sizeof(unit));
	u->path = path;
	u->debug = debug;
	return u;
}

static int nm( unit *u, const char *s ) { return list_intern(&u->names, s); }
static int str( unit *u, const char *s ) { return list_intern(&u->strings, s); }

static int lit_int( unit *u, int v ) { b_i32(&u->ints, v); return u->nints++; }
static int lit_float( unit *u, double v ) { b_raw(&u->floats, &v, 8); return u->nfloats++; }
static int lit_bytes( unit *u, const char *data, int len ) { b_index(&u->bytes, len); b_raw(&u->bytes, data, len); return u->nbytes++; }
static int debug_file( unit *u, const char *path ) { return list_intern(&u->files, path); }

/* Imports come before the tables they share an index space with. */
static int import_fn( unit *u, const char *module, const char *member, int type ) {
	b_index(&u->fimports, nm(u, module)); b_index(&u->fimports, nm(u, member)); b_index(&u->fimports, type);
	return u->nfimports++;
}
static int import_global( unit *u, const char *module, const char *member, int type ) {
	b_index(&u->gimports, nm(u, module)); b_index(&u->gimports, nm(u, member)); b_index(&u->gimports, type);
	return u->ngimports++;
}
static int import_type( unit *u, const char *module, const char *member, int kind ) {
	b_index(&u->timports, nm(u, module)); b_index(&u->timports, nm(u, member)); b_byte(&u->timports, kind);
	return u->ntimports++;
}
/* A native: its function index follows the imported functions, so a section declares those first. */
static int native( unit *u, const char *lib, const char *name, int type ) {
	b_index(&u->natives, nm(u, lib)); b_index(&u->natives, nm(u, name)); b_index(&u->natives, type);
	return u->nfimports + u->nnatives++;
}
static int dense_native( unit *u, const char *lib, const char *name, int type, int findex ) {
	b_index(&u->dense_natives, str(u, lib)); b_index(&u->dense_natives, str(u, name)); b_index(&u->dense_natives, type);
	b_index(&u->dense_natives, findex);
	return u->nnatives++;
}

static void type_head( unit *u, int role, int kind, const char *key ) {
	b_byte(&u->type_heads, role);
	b_byte(&u->type_heads, kind);
	if( role != STRUCTURAL ) b_index(&u->type_heads, nm(u, key));
}

static int type_done( unit *u ) { return u->ntimports + u->ntypes++; }

static int t_prim( unit *u, int kind ) {
	type_head(u, STRUCTURAL, kind, NULL);
	b_byte(&u->types, kind);
	return type_done(u);
}

static int t_fun( unit *u, int nargs, const int *args, int ret ) {
	type_head(u, STRUCTURAL, HFUN, NULL);
	b_byte(&u->types, HFUN);
	b_byte(&u->types, nargs);
	for(int i=0;i<nargs;i++) b_index(&u->types, args[i]);
	b_index(&u->types, ret);
	return type_done(u);
}

static int t_param( unit *u, int kind, int child ) {
	type_head(u, STRUCTURAL, kind, NULL);
	b_byte(&u->types, kind);
	b_index(&u->types, child);
	return type_done(u);
}

typedef struct {
	int role;
	const char *key;
	int kind;
	const char *name;
	int super;
	int global;
	int nfields;
	const char *field_names[8];
	int field_types[8];
	int nproto;
	const char *proto_names[4];
	int proto_functions[4];
} obj_def;

static int t_obj( unit *u, const obj_def *o ) {
	type_head(u, o->role, o->kind, o->key);
	b_byte(&u->types, o->kind);
	b_index(&u->types, str(u, o->name));
	b_index(&u->types, o->super);
	b_index(&u->types, o->global);
	b_index(&u->types, o->nfields);
	b_index(&u->types, o->nproto);
	b_index(&u->types, 0);
	for(int i=0;i<o->nfields;i++) { b_index(&u->types, str(u, o->field_names[i])); b_index(&u->types, o->field_types[i]); }
	for(int i=0;i<o->nproto;i++) { b_index(&u->types, str(u, o->proto_names[i])); b_index(&u->types, o->proto_functions[i]); b_index(&u->types, -1); }
	return type_done(u);
}

/* A virtual: structural (no key) or nominal. */
static int t_virtual( unit *u, int role, const char *key, const char *identity, int nfields, const char **names, const int *types ) {
	type_head(u, role, HVIRTUAL, key);
	b_byte(&u->types, HVIRTUAL);
	b_index(&u->types, str(u, identity));
	b_index(&u->types, nfields);
	for(int i=0;i<nfields;i++) { b_index(&u->types, str(u, names[i])); b_index(&u->types, types[i]); }
	return type_done(u);
}

static int t_enum( unit *u, int role, const char *key, const char *name, int nconstructs, const char **names, const int *param ) {
	type_head(u, role, HENUM, key);
	b_byte(&u->types, HENUM);
	b_index(&u->types, str(u, name));
	b_index(&u->types, 0);
	b_index(&u->types, nconstructs);
	for(int i=0;i<nconstructs;i++) {
		b_index(&u->types, str(u, names[i]));
		b_index(&u->types, param[i] < 0 ? 0 : 1);
		if( param[i] >= 0 ) b_index(&u->types, param[i]);
	}
	return type_done(u);
}

/* An owned global of a section, or a global of a dense program (key NULL). */
static int global( unit *u, const char *key, int type ) {
	if( key ) { b_index(&u->global_heads, nm(u, key)); b_index(&u->global_heads, type); }
	else b_index(&u->dense_globals, type);
	return u->ngimports + u->nglobals++;
}

/* A literal constant: a section names its type and the loader gives it a global; a dense program names its global. */
static int constant( unit *u, int type_or_global, int nfields, const int *fields ) {
	b_index(&u->constants, type_or_global);
	b_index(&u->constants, nfields);
	for(int i=0;i<nfields;i++) b_index(&u->constants, fields[i]);
	return u->ngimports + u->nglobals + u->nconstants++;
}

static unit_fn *fn_begin( unit *u, const char *key, int type, int nregs, const int *regs ) {
	unit_fn *f = u->fns + u->nfns++;
	memset(f, 0, sizeof(*f));
	f->key = key ? nm(u, key) : -1;
	f->type = type;
	f->nregs = nregs;
	memcpy(f->regs, regs, sizeof(int) * nregs);
	f->file = -1;
	return f;
}

/* An opcode at a line of a file; operands as the reader reads them. */
static long operand_count = 0;

static void op( unit *u, unit_fn *f, int file, int line, int code, int n, ... ) {
	va_list args;
	operand_count += n;
	b_byte(&f->ops, code);
	va_start(args, n);
	for(int i=0;i<n;i++) b_index(&f->ops, va_arg(args, int));
	va_end(args);
	f->nops++;
	if( !u->debug ) return;
	if( file != f->file ) {
		b_byte(&f->debug, ((file >> 8) << 1) | 1);
		b_byte(&f->debug, file & 0xFF);
		f->file = file;
	}
	b_byte(&f->debug, (line & 31) << 3);
	b_byte(&f->debug, (line >> 5) & 0xFF);
	b_byte(&f->debug, line >> 13);
}

static void fn_assign( unit_fn *f, int name, int pos ) {
	b_index(&f->assigns, name);
	b_index(&f->assigns, pos + 1);
	b_index(&f->assigns, 0);
	f->nassigns++;
}

static void fn_body( unit *u, buf *b, unit_fn *f ) {
	b_index(b, f->nregs);
	b_index(b, f->nops);
	for(int i=0;i<f->nregs;i++) b_index(b, f->regs[i]);
	b_buf(b, &f->ops);
	if( u->debug ) {
		b_buf(b, &f->debug);
		b_index(b, f->nassigns);
		b_buf(b, &f->assigns);
	}
}

/* A section's payload, after its kind, version and flags. */
static void section_payload( unit *u, buf *b ) {
	int counts[] = { u->names.count, u->nfimports, u->ngimports, u->ntimports, u->nnatives, u->ntypes, u->nglobals, u->nfns,
		u->nints, u->nfloats, u->strings.count, u->nbytes, u->nconstants, u->files.count };
	for(int i=0;i<14;i++) b_index(b, counts[i]);
	b_strings(b, &u->names);
	b_buf(b, &u->fimports);
	b_buf(b, &u->gimports);
	b_buf(b, &u->timports);
	b_buf(b, &u->natives);
	b_buf(b, &u->type_heads);
	b_buf(b, &u->global_heads);
	for(int i=0;i<u->nfns;i++) { b_index(b, u->fns[i].key); b_index(b, u->fns[i].type); }
	b_buf(b, &u->ints);
	b_buf(b, &u->floats);
	b_strings(b, &u->strings);
	b_buf(b, &u->bytes);
	b_strings(b, &u->files);
	b_buf(b, &u->types);
	b_buf(b, &u->constants);
	for(int i=0;i<u->nfns;i++) fn_body(u, b, u->fns + i);
	b_index(b, u->ndebug_sections);
	b_buf(b, &u->debug_sections);
}

static void debug_section( unit *u, int kind, int flags, const char *payload ) {
	b_index(&u->debug_sections, kind);
	b_index(&u->debug_sections, 1);
	b_index(&u->debug_sections, flags);
	b_index(&u->debug_sections, (int)strlen(payload));
	b_raw(&u->debug_sections, payload, (int)strlen(payload));
	u->ndebug_sections++;
}

static void section_bytes( unit *u, buf *b, bool lz4 ) {
	buf payload = { 0 };
	section_payload(u, &payload);
	b_index(b, 1);
	b_index(b, 1);
	b_index(b, lz4 ? 1 : 0);
	if( lz4 ) {
		int bound = LZ4_compressBound(payload.len);
		char *packed = (char*)malloc(bound);
		int size = LZ4_compress_default((const char*)payload.d, packed, payload.len, bound);
		b_index(b, payload.len);
		b_raw(b, packed, size);
		free(packed);
	} else
		b_buf(b, &payload);
	free(payload.d);
}

/* An HLB 9 file of `units`: header, directory, program record, then the sections. */
static buf image( unit **units, int n, bool debug, const char *entry_module, const char *entry_member, bool lz4 ) {
	buf out = { 0 }, area = { 0 };
	int *offsets = (int*)malloc(sizeof(int) * (n + 1)), *sizes = (int*)malloc(sizeof(int) * (n + 1));
	for(int i=0;i<n;i++) {
		offsets[i] = area.len;
		section_bytes(units[i], &area, lz4);
		sizes[i] = area.len - offsets[i];
	}
	b_raw(&out, "HLB", 3);
	b_byte(&out, 9);
	b_index(&out, debug ? 1 : 0);
	b_index(&out, n);
	for(int i=0;i<n;i++) {
		b_text(&out, units[i]->path);
		b_i32(&out, offsets[i]);
		b_i32(&out, sizes[i]);
		b_i32(&out, 0x12345678);
		b_i32(&out, i);
	}
	b_text(&out, entry_module);
	b_text(&out, entry_member);
	b_buf(&out, &area);
	free(area.d);
	free(offsets);
	free(sizes);
	return out;
}

/* An HLB 8 file of the dense program `u`; its function keys are unused and its findexes follow declaration order. */
static buf dense_image( unit *u, int ntypes, int entry ) {
	buf out = { 0 };
	b_raw(&out, "HLB", 3);
	b_byte(&out, 8);
	b_index(&out, u->debug ? 1 : 0);
	b_index(&out, u->nints);
	b_index(&out, u->nfloats);
	b_index(&out, u->strings.count);
	b_index(&out, u->nbytes);
	b_index(&out, ntypes);
	b_index(&out, u->nglobals + u->nconstants);
	b_index(&out, u->nnatives);
	b_index(&out, u->nfns);
	b_index(&out, u->nconstants);
	b_index(&out, entry);
	b_buf(&out, &u->ints);
	b_buf(&out, &u->floats);
	b_strings(&out, &u->strings);
	{
		// HLB 8 keeps bytes as one blob with each entry's offset.
		buf blob = { 0 }, positions = { 0 };
		int pos = 0;
		while( pos < u->bytes.len ) {
			int len = u->bytes.d[pos++];
			b_index(&positions, blob.len);
			b_raw(&blob, u->bytes.d + pos, len);
			pos += len;
		}
		b_i32(&out, blob.len);
		b_buf(&out, &blob);
		b_buf(&out, &positions);
		free(blob.d);
		free(positions.d);
	}
	if( u->debug ) {
		b_index(&out, u->files.count);
		b_strings(&out, &u->files);
	}
	b_buf(&out, &u->types);
	b_buf(&out, &u->dense_globals);
	b_buf(&out, &u->dense_natives);
	for(int i=0;i<u->nfns;i++) {
		b_index(&out, u->fns[i].type);
		b_index(&out, i);
		fn_body(u, &out, u->fns + i);
	}
	b_buf(&out, &u->constants);
	b_index(&out, 0);
	return out;
}

// ---- checks

static int failures = 0;

static void check( bool ok, const char *what, ... ) {
	va_list args;
	if( ok ) return;
	failures++;
	fprintf(stderr, "FAIL: ");
	va_start(args, what);
	vfprintf(stderr, what, args);
	va_end(args);
	fprintf(stderr, "\n");
}

static hl_code *link_image( buf b, char **error ) {
	*error = NULL;
	return hl_code_read(b.d, b.len, error);
}

#define T(code,t) ((int)((t) - (code)->types))

static bool same_type_refs( hl_code *a, hl_type *x, hl_code *b, hl_type *y ) {
	return (x == NULL && y == NULL) || (x != NULL && y != NULL && T(a, x) == T(b, y));
}

static bool same_ustr( const uchar *a, const uchar *b ) {
	if( a == NULL || b == NULL ) return a == b;
	while( *a && *a == *b ) { a++; b++; }
	return *a == *b;
}

static bool same_fields( hl_code *a, hl_obj_field *x, hl_code *b, hl_obj_field *y, int n ) {
	for(int i=0;i<n;i++)
		if( !same_ustr(x[i].name, y[i].name) || !same_type_refs(a, x[i].t, b, y[i].t) ) return false;
	return true;
}

static bool same_type( hl_code *a, hl_type *x, hl_code *b, hl_type *y ) {
	if( x->kind != y->kind ) return false;
	switch( x->kind ) {
	case HFUN: case HMETHOD:
		if( x->fun->nargs != y->fun->nargs || !same_type_refs(a, x->fun->ret, b, y->fun->ret) ) return false;
		for(int i=0;i<x->fun->nargs;i++) if( !same_type_refs(a, x->fun->args[i], b, y->fun->args[i]) ) return false;
		return true;
	case HOBJ: case HSTRUCT:
		if( !same_ustr(x->obj->name, y->obj->name) || !same_type_refs(a, x->obj->super, b, y->obj->super)
			|| x->obj->global_value != y->obj->global_value || x->obj->nfields != y->obj->nfields || x->obj->nproto != y->obj->nproto
			|| x->obj->nbindings != y->obj->nbindings || !same_fields(a, x->obj->fields, b, y->obj->fields, x->obj->nfields) )
			return false;
		for(int i=0;i<x->obj->nproto;i++)
			if( !same_ustr(x->obj->proto[i].name, y->obj->proto[i].name) || x->obj->proto[i].findex != y->obj->proto[i].findex
				|| x->obj->proto[i].pindex != y->obj->proto[i].pindex ) return false;
		return memcmp(x->obj->bindings, y->obj->bindings, sizeof(int) * 2 * x->obj->nbindings) == 0;
	case HVIRTUAL:
		return same_ustr(x->virt->nominal_identity, y->virt->nominal_identity) && x->virt->nfields == y->virt->nfields
			&& same_fields(a, x->virt->fields, b, y->virt->fields, x->virt->nfields);
	case HENUM:
		if( !same_ustr(x->tenum->name, y->tenum->name) || x->tenum->nconstructs != y->tenum->nconstructs
			|| x->tenum->global_value != y->tenum->global_value ) return false;
		for(int i=0;i<x->tenum->nconstructs;i++) {
			hl_enum_construct *p = x->tenum->constructs + i, *q = y->tenum->constructs + i;
			if( !same_ustr(p->name, q->name) || p->nparams != q->nparams ) return false;
			for(int k=0;k<p->nparams;k++) if( !same_type_refs(a, p->params[k], b, q->params[k]) ) return false;
		}
		return true;
	case HREF: case HNULL: case HPACKED:
		return same_type_refs(a, x->tparam, b, y->tparam);
	case HABSTRACT:
		return same_ustr(x->abs_name, y->abs_name);
	default:
		return true;
	}
}

#define OP(_,_a,_b,_c) (_b == AR ? _c : (_c == X ? (_b == X ? (_a == X ? 0 : 1) : 2) : 3)),
#define OP_BEGIN static int op_nargs[] = {
#define OP_END };
#include "opcodes.h"

/* Whether two opcodes are equal in the operands their shape uses; the dense reader leaves the others undefined. */
static bool same_operands( hl_opcode *p, hl_opcode *q ) {
	int n = op_nargs[p->op];
	if( p->op != q->op ) return false;
	if( n < 0 || n > 3 ) n = 3;
	return (n < 1 || p->p1 == q->p1) && (n < 2 || p->p2 == q->p2) && (n < 3 || p->p3 == q->p3);
}

/* The operand count of an opcode with extra operands, as the reader stores them. */
static int extra_count( hl_opcode *o ) {
	switch( o->op ) {
	case OCallN: case OCallClosure: case OCallMethod: case OCallThis: case OMakeEnum: return o->p3;
	case OSwitch: return o->p2;
	case OCall3: return 2;
	case OCall4: return 3;
	default: return 0;
	}
}

/* Linked and dense code hold the same tables. The dense file also lists its natives' names as strings, after the others;
   the linked code keeps them out of the string table. */
static void same_code( const char *what, hl_code *l, hl_code *d ) {
	int before = failures;
	check(l->nints == d->nints && memcmp(l->ints, d->ints, sizeof(int) * l->nints) == 0, "%s: ints", what);
	check(l->nfloats == d->nfloats && memcmp(l->floats, d->floats, sizeof(double) * l->nfloats) == 0, "%s: floats", what);
	check(l->nstrings + 2 * d->nnatives >= d->nstrings && l->nstrings <= d->nstrings, "%s: string count %d vs %d", what, l->nstrings, d->nstrings);
	for(int i=0;i<l->nstrings && i<d->nstrings;i++) check(strcmp(l->strings[i], d->strings[i]) == 0, "%s: string %d", what, i);
	check(l->nbytes == d->nbytes, "%s: bytes count", what);
	for(int i=0;i<l->nbytes && i<d->nbytes;i++) check(memcmp(l->bytes + l->bytes_pos[i], d->bytes + d->bytes_pos[i], 2) == 0, "%s: bytes %d", what, i);
	check(l->hasdebug == d->hasdebug && l->ndebugfiles == d->ndebugfiles, "%s: debug files", what);
	for(int i=0;i<l->ndebugfiles && i<d->ndebugfiles;i++) check(strcmp(l->debugfiles[i], d->debugfiles[i]) == 0, "%s: debug file %d", what, i);
	check(l->ntypes == d->ntypes, "%s: type count %d vs %d", what, l->ntypes, d->ntypes);
	for(int i=0;i<l->ntypes && i<d->ntypes;i++) check(same_type(l, l->types + i, d, d->types + i), "%s: type %d", what, i);
	check(l->nglobals == d->nglobals, "%s: global count %d vs %d", what, l->nglobals, d->nglobals);
	for(int i=0;i<l->nglobals && i<d->nglobals;i++) check(T(l, l->globals[i]) == T(d, d->globals[i]), "%s: global %d", what, i);
	check(l->nconstants == d->nconstants, "%s: constant count", what);
	for(int i=0;i<l->nconstants && i<d->nconstants;i++)
		check(l->constants[i].global == d->constants[i].global && l->constants[i].nfields == d->constants[i].nfields
			&& memcmp(l->constants[i].fields, d->constants[i].fields, sizeof(int) * l->constants[i].nfields) == 0, "%s: constant %d", what, i);
	check(l->nnatives == d->nnatives, "%s: native count", what);
	for(int i=0;i<l->nnatives && i<d->nnatives;i++)
		check(strcmp(l->natives[i].lib, d->natives[i].lib) == 0 && strcmp(l->natives[i].name, d->natives[i].name) == 0
			&& T(l, l->natives[i].t) == T(d, d->natives[i].t) && l->natives[i].findex == d->natives[i].findex, "%s: native %d", what, i);
	check(l->nfunctions == d->nfunctions && l->entrypoint == d->entrypoint, "%s: functions and entry", what);
	for(int i=0;i<l->nfunctions && i<d->nfunctions;i++) {
		hl_function *x = l->functions + i, *y = d->functions + i;
		bool ok = x->findex == y->findex && T(l, x->type) == T(d, y->type) && x->nregs == y->nregs && x->nops == y->nops
			&& x->nassigns == y->nassigns;
		for(int k=0;ok && k<x->nregs;k++) ok = T(l, x->regs[k]) == T(d, y->regs[k]);
		for(int k=0;ok && k<x->nops;k++) {
			hl_opcode *p = x->ops + k, *q = y->ops + k;
			ok = same_operands(p, q);
			if( ok && extra_count(p) ) ok = memcmp(p->extra, q->extra, sizeof(int) * extra_count(p)) == 0;
			else if( ok && p->op == OCall2 ) ok = p->extra == q->extra;
		}
		if( ok && l->hasdebug ) ok = memcmp(x->debug, y->debug, sizeof(int) * 2 * x->nops) == 0
			&& memcmp(x->assigns, y->assigns, sizeof(int) * 3 * x->nassigns) == 0;
		check(ok, "%s: function %d", what, i);
	}
	if( failures == before ) printf("ok: %s\n", what);
}

static bool read_file( const char *path, buf *b ) {
	FILE *f = fopen(path, "rb");
	char chunk[65536];
	size_t n;
	if( f == NULL ) return false;
	while( (n = fread(chunk, 1, sizeof(chunk), f)) > 0 ) b_raw(b, chunk, (int)n);
	fclose(f);
	return true;
}

/*
	`--compare SECTIONED DENSE`: the loader's link of an HLB 9 file holds the same tables, functions and function names as the
	HLB 8 file the compiler's static link (`haxeon dev hl-link`) makes of it.
*/
static int compare_files( const char *sectioned, const char *dense ) {
	buf a = { 0 }, b = { 0 };
	char *error = NULL;
	hl_code *l, *d;
	if( !read_file(sectioned, &a) || !read_file(dense, &b) ) { fprintf(stderr, "compare: cannot read the files\n"); return 1; }
	l = hl_code_read(a.d, a.len, &error);
	if( l == NULL ) { fprintf(stderr, "compare: %s does not link: %s\n", sectioned, error ? error : ""); return 1; }
	d = hl_code_read(b.d, b.len, &error);
	if( d == NULL ) { fprintf(stderr, "compare: %s does not read: %s\n", dense, error ? error : ""); return 1; }
	check(l->version == 9 && d->version == 8, "compare: an HLB 9 file and an HLB 8 file");
	same_code("the loader's link equals the static link", l, d);
	for(int i=0;i<l->nfunctions && i<d->nfunctions;i++)
		check(l->function_names[i] && d->function_names[i] && strcmp(l->function_names[i], d->function_names[i]) == 0
			&& l->function_stable_ids[i] == d->function_stable_ids[i], "function %d's name and stable id", i);
	printf("%s: %d functions, %d types, %d globals, %d strings\n", failures ? "FAIL" : "PASS", l->nfunctions, l->ntypes, l->nglobals, l->nstrings);
	return failures ? 1 : 0;
}

// ---- the program: app.Main calls lib.Point and a shared helper; both define String and use the same literals

/* The program's native, which the module finds in this executable ("builtin"). */
static int round_half_up( double d ) { return (int)(d + 0.5); }
HL_EXTERN_C HL_EXPORT void *hlp_code_link_round( const char **sign ) {
	*sign = NULL;
	return (void*)round_half_up;
}

static const int no_args[1] = { 0 };

/* Main.main: Point.make(3, 4) into Point.origin, Point.sum, the shared `twice`, the native round(2.6) and the length of
   the String constant "hi": 19. */
static unit *main_section( void ) {
	unit *u = unit_new("app.Main", true);
	int point = import_type(u, "lib.Point", "Point", HOBJ);
	int i32 = t_prim(u, HI32), bytes = t_prim(u, HBYTES);
	obj_def string = { SHARED, "String", HOBJ, "String", -1, 0, 2, { "bytes", "length" }, { bytes, i32 } };
	int tstring = t_obj(u, &string);
	int make_args[] = { i32, i32 };
	int tmake = t_fun(u, 2, make_args, point);
	int tsum = t_fun(u, 1, &point, i32);
	int tmain = t_fun(u, 0, no_args, i32);
	int f64 = t_prim(u, HF64);
	int tround = t_fun(u, 1, &f64, i32);
	int ttwice = t_fun(u, 1, &i32, i32);
	int ttype = t_prim(u, HTYPE);
	int make = import_fn(u, "lib.Point", "Point.make", tmake);
	int sum = import_fn(u, "lib.Point", "Point.sum", tsum);
	int twice = import_fn(u, "shared", "twice", ttwice);
	int origin = import_global(u, "lib.Point", "Point.origin", point);
	int round = native(u, "builtin", "code_link_round", tround);
	int three = lit_int(u, 3), four = lit_int(u, 4), two = lit_int(u, 2);
	int fields[] = { str(u, "hi"), two };
	int hi = constant(u, tstring, 2, fields);
	int file = debug_file(u, "app/Main.hx");
	int regs[] = { i32, i32, point, i32, f64, tstring, bytes, ttype };
	unit_fn *f = fn_begin(u, "Main.main", tmain, 8, regs);
	op(u, f, file, 10, OInt, 2, 0, three);
	op(u, f, file, 11, OInt, 2, 1, four);
	op(u, f, file, 12, OCall2, 4, 2, make, 0, 1);
	op(u, f, file, 12, OSetGlobal, 2, origin, 2);
	op(u, f, file, 13, OCall1, 3, 3, sum, 2);
	op(u, f, file, 14, OCall1, 3, 3, twice, 3);
	op(u, f, file, 15, OFloat, 2, 4, lit_float(u, 2.6));
	op(u, f, file, 15, OCall1, 3, 0, round, 4);
	op(u, f, file, 16, OAdd, 3, 3, 3, 0);
	op(u, f, file, 17, OGetGlobal, 2, 5, hi);
	op(u, f, file, 17, OField, 3, 0, 5, 1);
	op(u, f, file, 18, OAdd, 3, 3, 3, 0);
	op(u, f, file, 19, OString, 2, 6, str(u, "hi"));
	op(u, f, file, 20, OBytes, 2, 6, lit_bytes(u, "\x01\x02", 2));
	op(u, f, file, 21, OType, 2, 7, point);
	op(u, f, file, 22, ORet, 1, 3);
	fn_assign(f, str(u, "p"), 2);
	return u;
}

static unit *point_section( void ) {
	unit *u = unit_new("lib.Point", true);
	int i32 = t_prim(u, HI32);
	int twice_type = 0, tpoint, tmake, tsum, bytes, tstring;
	obj_def point = { OWNED, "Point", HOBJ, "lib.Point", -1, 0, 2, { "x", "y" }, { i32, i32 }, 1, { "sum" } };
	// Point's prototype names Point.sum, whose local index follows the one import.
	point.proto_functions[0] = 2;
	tpoint = t_obj(u, &point);
	{
		int args[] = { i32, i32 };
		tmake = t_fun(u, 2, args, tpoint);
	}
	tsum = t_fun(u, 1, &tpoint, i32);
	bytes = t_prim(u, HBYTES);
	{
		obj_def string = { SHARED, "String", HOBJ, "String", -1, 0, 2, { "bytes", "length" }, { bytes, i32 } };
		tstring = t_obj(u, &string);
	}
	twice_type = t_fun(u, 1, &i32, i32);
	import_fn(u, "shared", "twice", twice_type);
	global(u, "Point.origin", tpoint);
	{
		int two = lit_int(u, 2);
		int hi_fields[] = { str(u, "hi"), two };
		int pt_fields[] = { str(u, "pt"), two };
		constant(u, tstring, 2, hi_fields);
		constant(u, tstring, 2, pt_fields);
	}
	{
		int file = debug_file(u, "lib/Point.hx");
		int regs[] = { i32, i32, tpoint };
		unit_fn *f = fn_begin(u, "Point.make", tmake, 3, regs);
		op(u, f, file, 5, ONew, 1, 2);
		op(u, f, file, 6, OSetField, 3, 2, 0, 0);
		op(u, f, file, 7, OSetField, 3, 2, 1, 1);
		op(u, f, file, 8, ORet, 1, 2);
	}
	{
		int file = debug_file(u, "lib/Point.hx");
		int regs[] = { tpoint, i32, i32, tstring };
		unit_fn *f = fn_begin(u, "Point.sum", tsum, 4, regs);
		op(u, f, file, 10, OField, 3, 1, 0, 0);
		op(u, f, file, 10, OField, 3, 2, 0, 1);
		op(u, f, file, 11, OAdd, 3, 1, 1, 2);
		op(u, f, file, 12, OGetGlobal, 2, 3, 2);
		op(u, f, file, 13, ORet, 1, 1);
	}
	return u;
}

static unit *shared_section( void ) {
	unit *u = unit_new("shared", true);
	int i32 = t_prim(u, HI32);
	int ttwice = t_fun(u, 1, &i32, i32);
	int file = debug_file(u, "lib/Point.hx");
	int regs[] = { i32 };
	unit_fn *f = fn_begin(u, "twice", ttwice, 1, regs);
	op(u, f, file, 30, OAdd, 3, 0, 0, 0);
	op(u, f, file, 31, ORet, 1, 0);
	// Tools read a section's debug sub-sections; the loader steps over them, known kind or not.
	debug_section(u, 3, 0, "snapshot");
	debug_section(u, 99, 0, "unknown");
	return u;
}

/* The same program as one dense HLB 8 file, numbered as the linker numbers it: owned and shared types in section order,
   then the structural ones as they first appear; functions in section order, natives after them; owned globals, then
   constants as they first appear. */
static buf dense_program( void ) {
	unit *u = unit_new("dense", true);
	const int STRING = 0, POINT = 1, I32 = 2, BYTES = 3, MAKE = 4, SUM = 5, MAIN = 6, F64 = 7, ROUND = 8, TWICE = 9, TYPE = 10;
	buf out;
	int s_hi, s_pt, two, main_file, point_file;
	// Strings in first-use order: app.Main's, then lib.Point's new ones.
	str(u, "String"); str(u, "bytes"); str(u, "length"); s_hi = str(u, "hi"); str(u, "p");
	str(u, "lib.Point"); str(u, "x"); str(u, "y"); str(u, "sum"); s_pt = str(u, "pt");
	{
		obj_def string = { SHARED, "String", HOBJ, "String", -1, 0, 2, { "bytes", "length" }, { BYTES, I32 } };
		obj_def point = { OWNED, "Point", HOBJ, "lib.Point", -1, 0, 2, { "x", "y" }, { I32, I32 }, 1, { "sum" }, { 2 } };
		int make_args[] = { I32, I32 };
		t_obj(u, &string);
		t_obj(u, &point);
		t_prim(u, HI32);
		t_prim(u, HBYTES);
		t_fun(u, 2, make_args, POINT);
		t_fun(u, 1, &POINT, I32);
		t_fun(u, 0, no_args, I32);
		t_prim(u, HF64);
		t_fun(u, 1, &F64, I32);
		t_fun(u, 1, &I32, I32);
		t_prim(u, HTYPE);
	}
	lit_int(u, 3); lit_int(u, 4); two = lit_int(u, 2);
	lit_float(u, 2.6);
	lit_bytes(u, "\x01\x02", 2);
	main_file = debug_file(u, "app/Main.hx");
	point_file = debug_file(u, "lib/Point.hx");
	global(u, NULL, POINT);
	global(u, NULL, STRING);
	global(u, NULL, STRING);
	{
		int hi_fields[] = { s_hi, two }, pt_fields[] = { s_pt, two };
		u->nglobals = 1;
		constant(u, 1, 2, hi_fields);
		constant(u, 2, 2, pt_fields);
	}
	dense_native(u, "builtin", "code_link_round", ROUND, 4);
	{
		int regs[] = { I32, I32, POINT, I32, F64, STRING, BYTES, TYPE };
		unit_fn *f = fn_begin(u, NULL, MAIN, 8, regs);
		op(u, f, main_file, 10, OInt, 2, 0, 0);
		op(u, f, main_file, 11, OInt, 2, 1, 1);
		op(u, f, main_file, 12, OCall2, 4, 2, 1, 0, 1);
		op(u, f, main_file, 12, OSetGlobal, 2, 0, 2);
		op(u, f, main_file, 13, OCall1, 3, 3, 2, 2);
		op(u, f, main_file, 14, OCall1, 3, 3, 3, 3);
		op(u, f, main_file, 15, OFloat, 2, 4, 0);
		op(u, f, main_file, 15, OCall1, 3, 0, 4, 4);
		op(u, f, main_file, 16, OAdd, 3, 3, 3, 0);
		op(u, f, main_file, 17, OGetGlobal, 2, 5, 1);
		op(u, f, main_file, 17, OField, 3, 0, 5, 1);
		op(u, f, main_file, 18, OAdd, 3, 3, 3, 0);
		op(u, f, main_file, 19, OString, 2, 6, s_hi);
		op(u, f, main_file, 20, OBytes, 2, 6, 0);
		op(u, f, main_file, 21, OType, 2, 7, POINT);
		op(u, f, main_file, 22, ORet, 1, 3);
		fn_assign(f, 4, 2);
	}
	{
		int regs[] = { I32, I32, POINT };
		unit_fn *f = fn_begin(u, NULL, MAKE, 3, regs);
		op(u, f, point_file, 5, ONew, 1, 2);
		op(u, f, point_file, 6, OSetField, 3, 2, 0, 0);
		op(u, f, point_file, 7, OSetField, 3, 2, 1, 1);
		op(u, f, point_file, 8, ORet, 1, 2);
	}
	{
		int regs[] = { POINT, I32, I32, STRING };
		unit_fn *f = fn_begin(u, NULL, SUM, 4, regs);
		op(u, f, point_file, 10, OField, 3, 1, 0, 0);
		op(u, f, point_file, 10, OField, 3, 2, 0, 1);
		op(u, f, point_file, 11, OAdd, 3, 1, 1, 2);
		op(u, f, point_file, 12, OGetGlobal, 2, 3, 2);
		op(u, f, point_file, 13, ORet, 1, 1);
	}
	{
		int regs[] = { I32 };
		unit_fn *f = fn_begin(u, NULL, TWICE, 1, regs);
		op(u, f, point_file, 30, OAdd, 3, 0, 0, 0);
		op(u, f, point_file, 31, ORet, 1, 0);
	}
	out = dense_image(u, 11, 0);
	return out;
}

static buf program_image( bool lz4 ) {
	unit *units[] = { main_section(), point_section(), shared_section() };
	return image(units, 3, true, "app.Main", "Main.main", lz4);
}

/* Loads linked code as hl does and runs its entry, which returns 19. */
static void run_linked( hl_code *code ) {
	hl_module *m = hl_module_alloc(code);
	vclosure cl;
	vdynamic *ret;
	bool exc = false;
	check(m != NULL && hl_module_init(m, 0), "the linked module initializes");
	if( failures ) return;
	hl_code_free_function_data(code);
	cl.t = code->functions[m->functions_indexes[code->entrypoint]].type;
	cl.fun = m->functions_ptrs[code->entrypoint];
	cl.hasValue = 0;
	ret = hl_dyn_call_safe(&cl, NULL, 0, &exc);
	check(!exc && ret != NULL && ret->v.i == 19, "the linked program returns 19 (got %d)", ret && !exc ? ret->v.i : -1);
	if( !exc && ret && ret->v.i == 19 ) printf("ok: the linked program runs\n");
}

static void test_program( void ) {
	char *error;
	buf linked = program_image(false), packed = program_image(true), dense = dense_program();
	hl_code *l = link_image(linked, &error), *z, *d;
	check(l != NULL, "the program links: %s", error ? error : "");
	d = link_image(dense, &error);
	check(d != NULL, "the dense program reads: %s", error ? error : "");
	if( l == NULL || d == NULL ) return;
	same_code("linked tables equal the dense program's", l, d);
	check(strcmp(l->function_names[0], "Main.main") == 0 && strcmp(l->function_names[3], "twice") == 0, "function names come from the keys");
	check(l->functions[1].type == l->types + 4 && l->natives[0].t == l->types + 8, "imports resolve to the definitions' types");
	z = link_image(packed, &error);
	check(z != NULL, "LZ4 sections link: %s", error ? error : "");
	if( z ) same_code("LZ4 sections link to the same tables", z, d);
	run_linked(l);
	free(linked.d);
	free(packed.d);
	free(dense.d);
}

static void test_single_section( void ) {
	char *error;
	unit *u = unit_new("Main", false);
	int i32 = t_prim(u, HI32);
	int tmain = t_fun(u, 0, no_args, i32);
	int regs[] = { i32 };
	unit_fn *f = fn_begin(u, "main", tmain, 1, regs);
	buf b;
	hl_code *c;
	op(u, f, 0, 0, OInt, 2, 0, lit_int(u, 42));
	op(u, f, 0, 0, ORet, 1, 0);
	b = image(&u, 1, false, "Main", "main", false);
	c = link_image(b, &error);
	check(c != NULL && c->nfunctions == 1 && c->ntypes == 2 && c->nints == 1 && c->ints[0] == 42 && c->entrypoint == 0
		&& !c->hasdebug && c->version == 9, "a single section links: %s", error ? error : "");
	if( c ) {
		printf("ok: a single section links\n");
		hl_code_destroy(c);
	}
	free(b.d);
}

/* Structural types defined by several sections are one type; so are equal literals, debug files and constants. */
static void test_unification( void ) {
	char *error;
	unit *units[3];
	buf b;
	hl_code *c;
	for(int i=0;i<3;i++) {
		static const char *paths[] = { "a", "b", "c" };
		unit *u = unit_new(paths[i], true);
		int i32 = t_prim(u, HI32), dyn = t_prim(u, HDYN);
		int nul = t_param(u, HNULL, i32);
		int ref = t_param(u, HREF, nul);
		int args[] = { ref, dyn };
		int fun = t_fun(u, 2, args, i32);
		const char *names[] = { "x", "f" };
		int vtypes[] = { i32, fun };
		int virt = t_virtual(u, STRUCTURAL, NULL, "", 2, names, vtypes);
		const char *cnames[] = { "A", "B" };
		int params[] = { -1, i32 };
		int en = t_enum(u, OWNED, "E", "E", 2, cnames, params);
		obj_def anon = { SHARED, "$anon:x", HOBJ, "$anon:x", -1, 0, 1, { "x" }, { virt } };
		int shared = t_obj(u, &anon);
		int tret = t_fun(u, 0, no_args, i32);
		// A virtual that refers to itself through a structural type is a shared definition: a structural type may refer
		// to any definition, here one declared after it.
		int node_index = u->ntimports + u->ntypes + 1;
		int visit = t_fun(u, 1, &node_index, i32);
		const char *node_names[] = { "next", "visit" };
		int node_types[] = { node_index, visit };
		int node = t_virtual(u, SHARED, "$anon:Node", "", 2, node_names, node_types);
		int regs[] = { i32, virt, shared, en, nul, node };
		unit_fn *f = fn_begin(u, "f", tret, 6, regs);
		op(u, f, debug_file(u, "same.hx"), 1, OInt, 2, 0, lit_int(u, 7));
		op(u, f, 0, 1, OFloat, 2, 0, lit_float(u, 1.5));
		op(u, f, 0, 1, OString, 2, 0, str(u, "same"));
		op(u, f, 0, 1, OBytes, 2, 0, lit_bytes(u, "\x05\x06", 2));
		op(u, f, 0, 2, ORet, 1, 0);
		units[i] = u;
	}
	b = image(units, 3, true, "a", "f", false);
	c = link_image(b, &error);
	check(c != NULL, "unification: links: %s", error ? error : "");
	if( c == NULL ) return;
	// Three owned enums and two shared definitions take the first slots; then i32, dyn, null, ref, fun, virtual and the
	// two function types, once each.
	check(c->ntypes == 5 + 8, "structural types unify: %d types", c->ntypes);
	{
		hl_type *node = c->functions[0].regs[5];
		check(node == c->functions[2].regs[5] && node->kind == HVIRTUAL && node->virt->fields[0].t == node
			&& node->virt->fields[1].t->fun->args[0] == node, "a recursive shared virtual is one type and refers to itself");
	}
	check(c->functions[0].regs[1] == c->functions[1].regs[1] && c->functions[1].regs[1] == c->functions[2].regs[1],
		"a structural virtual is one type in every section");
	check(c->functions[0].regs[2] == c->functions[2].regs[2], "a shared definition is one type in every section");
	check(c->functions[0].regs[3] != c->functions[1].regs[3], "owned enums of the same name stay distinct types");
	check(c->nints == 1 && c->nfloats == 1 && c->nbytes == 1 && c->ndebugfiles == 1, "literals and debug files deduplicate");
	check(c->functions[2].ops[2].p2 == c->functions[0].ops[2].p2 && strcmp(c->strings[c->functions[2].ops[2].p2], "same") == 0,
		"strings deduplicate");
	if( failures == 0 ) printf("ok: structural types, shared definitions and literals unify\n");
	hl_code_destroy(c);
	free(b.d);
}

// ---- errors

/* Links `n` sections and expects a failure whose message contains each of `parts`. */
static void expect_error( const char *what, unit **units, int n, const char *entry_module, const char *entry_member, const char **parts ) {
	char *error;
	buf b = image(units, n, false, entry_module, entry_member, false);
	hl_code *c = link_image(b, &error);
	check(c == NULL, "%s: the load fails", what);
	if( c == NULL ) {
		bool all = error != NULL;
		for(int i=0;all && parts[i];i++) all = strstr(error, parts[i]) != NULL;
		check(all, "%s: the message names the section and key: %s", what, error ? error : "(none)");
		if( all ) printf("ok: %s: %s\n", what, error);
	} else
		hl_code_destroy(c);
	free(b.d);
}

static unit *simple( const char *path ) {
	return unit_new(path, false);
}

/* A function `key` that returns null as `ret_type`. */
static void simple_fn( unit *u, const char *key, int ret_type ) {
	int tret = t_fun(u, 0, no_args, ret_type);
	int regs[] = { ret_type };
	unit_fn *f = fn_begin(u, key, tret, 1, regs);
	op(u, f, 0, 0, ONull, 1, 0);
	op(u, f, 0, 0, ORet, 1, 0);
}

static void test_errors( void ) {
	{
		unit *a = simple("a.A");
		int dyn = t_prim(a, HDYN);
		import_fn(a, "b.B", "missing", t_fun(a, 0, no_args, dyn));
		simple_fn(a, "f", dyn);
		const char *parts[] = { "`a.A`", "function", "`b.B.missing`", "no section defines", NULL };
		expect_error("missing function import", &a, 1, "a.A", "f", parts);
	}
	{
		unit *a = simple("a.A");
		int dyn = t_prim(a, HDYN);
		import_global(a, "b.B", "g", dyn);
		simple_fn(a, "f", dyn);
		const char *parts[] = { "`a.A`", "global", "`b.B.g`", "no section defines", NULL };
		expect_error("missing global import", &a, 1, "a.A", "f", parts);
	}
	{
		unit *a = simple("a.A");
		import_type(a, "b.B", "T", HOBJ);
		simple_fn(a, "f", t_prim(a, HDYN));
		const char *parts[] = { "`a.A`", "type", "`b.B.T`", "no section defines", NULL };
		expect_error("missing type import", &a, 1, "a.A", "f", parts);
	}
	{
		unit *a = simple("a.A");
		int dyn = t_prim(a, HDYN);
		simple_fn(a, "f", dyn);
		simple_fn(a, "f", dyn);
		const char *parts[] = { "`a.A`", "exports function `a.A.f` twice", NULL };
		expect_error("duplicate function export", &a, 1, "a.A", "f", parts);
	}
	{
		unit *a = simple("a.A");
		int dyn = t_prim(a, HDYN);
		global(a, "g", dyn);
		global(a, "g", dyn);
		simple_fn(a, "f", dyn);
		const char *parts[] = { "`a.A`", "exports global `a.A.g` twice", NULL };
		expect_error("duplicate global export", &a, 1, "a.A", "f", parts);
	}
	{
		unit *a = simple("a.A");
		obj_def t = { OWNED, "T", HOBJ, "T", -1, 0, 0 };
		t_obj(a, &t);
		t_obj(a, &t);
		simple_fn(a, "f", t_prim(a, HDYN));
		const char *parts[] = { "`a.A`", "exports type `a.A.T` twice", NULL };
		expect_error("duplicate type export", &a, 1, "a.A", "f", parts);
	}
	{
		unit *units[] = { simple("a.A"), simple("a.A") };
		simple_fn(units[0], "f", t_prim(units[0], HDYN));
		simple_fn(units[1], "g", t_prim(units[1], HDYN));
		const char *parts[] = { "Two sections", "`a.A`", NULL };
		expect_error("two sections of one module", units, 2, "a.A", "f", parts);
	}
	{
		unit *units[] = { simple("a.A"), simple("b.B") };
		for(int i=0;i<2;i++) {
			int i32 = t_prim(units[i], HI32);
			obj_def anon = { SHARED, "$anon:x", HOBJ, "$anon:x", -1, 0, 1, { i == 0 ? "x" : "y" }, { i32 } };
			t_obj(units[i], &anon);
			simple_fn(units[i], "f", i32);
		}
		const char *parts[] = { "`b.B`", "shared type `$anon:x`", "differently from `a.A`", NULL };
		expect_error("conflicting shared definition", units, 2, "a.A", "f", parts);
	}
	{
		unit *units[] = { simple("a.A"), simple("b.B") };
		const char *names[] = { "x" };
		int i32 = t_prim(units[0], HI32);
		obj_def anon = { SHARED, "$anon:x", HOBJ, "$anon:x", -1, 0, 1, { "x" }, { i32 } };
		t_obj(units[0], &anon);
		simple_fn(units[0], "f", i32);
		i32 = t_prim(units[1], HI32);
		t_virtual(units[1], SHARED, "$anon:x", "", 1, names, &i32);
		simple_fn(units[1], "f", i32);
		const char *parts[] = { "`b.B`", "shared type `$anon:x`", "differently from `a.A`", NULL };
		expect_error("a shared definition of another kind", units, 2, "a.A", "f", parts);
	}
	{
		unit *units[] = { simple("a.A"), simple("b.B") };
		int i32 = t_prim(units[0], HI32), dyn = t_prim(units[0], HDYN);
		import_fn(units[0], "b.B", "f", t_fun(units[0], 0, no_args, dyn));
		simple_fn(units[0], "main", i32);
		simple_fn(units[1], "f", t_prim(units[1], HI32));
		const char *parts[] = { "`a.A`", "imports function `b.B.f`", "another type than `b.B`", NULL };
		expect_error("function import of another type", units, 2, "a.A", "main", parts);
	}
	{
		unit *units[] = { simple("a.A"), simple("b.B") };
		int dyn = t_prim(units[0], HDYN);
		import_global(units[0], "b.B", "g", t_prim(units[0], HI32));
		simple_fn(units[0], "main", dyn);
		global(units[1], "g", t_prim(units[1], HF64));
		simple_fn(units[1], "f", t_prim(units[1], HDYN));
		const char *parts[] = { "`a.A`", "imports global `b.B.g`", "another type than `b.B`", NULL };
		expect_error("global import of another type", units, 2, "a.A", "main", parts);
	}
	{
		unit *units[] = { simple("a.A"), simple("b.B") };
		obj_def t = { OWNED, "T", HSTRUCT, "T", -1, 0, 0 };
		import_type(units[0], "b.B", "T", HOBJ);
		simple_fn(units[0], "main", t_prim(units[0], HDYN));
		t_obj(units[1], &t);
		simple_fn(units[1], "f", t_prim(units[1], HDYN));
		const char *parts[] = { "`a.A`", "imports type `b.B.T`", "another kind than `b.B`", NULL };
		expect_error("type import of another kind", units, 2, "a.A", "main", parts);
	}
	{
		unit *units[] = { simple("a.A"), simple("b.B") };
		for(int i=0;i<2;i++) {
			int i32 = t_prim(units[i], HI32);
			int arg = t_prim(units[i], i == 0 ? HF64 : HI32);
			native(units[i], "std", "math_round", t_fun(units[i], 1, &arg, i32));
			simple_fn(units[i], "f", i32);
		}
		const char *parts[] = { "`b.B`", "native `std@math_round`", "another type than `a.A`", NULL };
		expect_error("native of another type", units, 2, "a.A", "f", parts);
	}
	{
		unit *a = simple("a.A");
		simple_fn(a, "f", t_prim(a, HDYN));
		const char *parts[] = { "entry function `a.A.main`", "not defined", NULL };
		expect_error("missing entry function", &a, 1, "a.A", "main", parts);
	}
	{
		unit *a = simple("a.A");
		int dyn = t_prim(a, HDYN);
		int tret = t_fun(a, 0, no_args, dyn);
		int regs[] = { dyn };
		unit_fn *f = fn_begin(a, "f", tret, 1, regs);
		op(a, f, 0, 0, OString, 2, 0, 5);
		op(a, f, 0, 0, ORet, 1, 0);
		const char *parts[] = { "Malformed section `a.A`", "string index", NULL };
		expect_error("an operand past its table", &a, 1, "a.A", "f", parts);
	}
	{
		unit *a = simple("a.A");
		int dyn = t_prim(a, HDYN);
		int tret = t_fun(a, 0, no_args, dyn);
		int regs[] = { dyn };
		unit_fn *f = fn_begin(a, "f", tret, 1, regs);
		op(a, f, 0, 0, OJAlways, 1, 5);
		op(a, f, 0, 0, ORet, 1, 0);
		const char *parts[] = { "Malformed section `a.A`", "function `a.A.f`", "jump target", NULL };
		expect_error("a jump outside its function", &a, 1, "a.A", "f", parts);
	}
	{
		// A structural type may only refer to the entries before it.
		unit *a = simple("a.A");
		int fun;
		type_head(a, STRUCTURAL, HNULL, NULL);
		b_byte(&a->types, HNULL);
		b_index(&a->types, 1);
		type_done(a);
		t_prim(a, HI32);
		fun = t_fun(a, 0, no_args, 1);
		{
			int regs[] = { 1 };
			unit_fn *f = fn_begin(a, "f", fun, 1, regs);
			op(a, f, 0, 0, ORet, 1, 0);
		}
		const char *parts[] = { "Malformed section `a.A`", "refers to a later one", NULL };
		expect_error("a structural type referring forward", &a, 1, "a.A", "f", parts);
	}
	{
		unit *a = simple("a.A");
		type_head(a, STRUCTURAL, HOBJ, NULL);
		b_byte(&a->types, HOBJ);
		type_done(a);
		const char *parts[] = { "Malformed section `a.A`", "nominal type without a key", NULL };
		expect_error("a nominal type without a key", &a, 1, "a.A", "f", parts);
	}
	{
		// Truncated: the section ends inside its function.
		unit *a = simple("a.A");
		char *error;
		buf b;
		hl_code *c;
		simple_fn(a, "f", t_prim(a, HDYN));
		b = image(&a, 1, false, "a.A", "f", false);
		// Drop the last byte from both the file and the section's length in the directory.
		b.len--;
		{
			int at = 3 + 1 + 1 + 1 + 1 + 3 + 4; // HLB 9, flags, count, path "a.A", offset; then the length
			int len = b.d[at] | (b.d[at + 1] << 8);
			b.d[at] = (len - 1) & 0xFF;
			b.d[at + 1] = ((len - 1) >> 8) & 0xFF;
		}
		c = link_image(b, &error);
		check(c == NULL && error && strstr(error, "Malformed section `a.A`") && strstr(error, "no more data"), "a truncated section: %s", error ? error : "");
		if( c == NULL && error ) printf("ok: a truncated section: %s\n", error);
		free(b.d);
	}
	{
		unit *a = simple("a.A");
		char *error;
		buf b;
		hl_code *c;
		simple_fn(a, "f", t_prim(a, HDYN));
		b = image(&a, 1, false, "a.A", "f", false);
		b.d[3 + 1 + 1 + 1 + 1 + 3] = 0x7F; // the offset puts the section past the end of the file
		c = link_image(b, &error);
		check(c == NULL && error && strstr(error, "lies outside the file"), "a section outside the file: %s", error ? error : "");
		if( c == NULL && error ) printf("ok: a section outside the file: %s\n", error);
		free(b.d);
	}
	{
		unit *a = simple("a.A");
		char *error;
		buf b;
		hl_code *c;
		simple_fn(a, "f", t_prim(a, HDYN));
		b = image(&a, 1, false, "a.A", "f", true);
		// Cut the compressed block short, in the file and in the directory.
		b.len -= 4;
		b.d[3 + 1 + 1 + 1 + 1 + 3 + 4] -= 4;
		c = link_image(b, &error);
		check(c == NULL && error && strstr(error, "Malformed section `a.A`"), "a corrupt LZ4 section: %s", error ? error : "");
		if( c == NULL && error ) printf("ok: a corrupt LZ4 section: %s\n", error);
		free(b.d);
	}
	{
		unit *a = simple("a.A");
		char *error;
		buf b;
		hl_code *c;
		simple_fn(a, "f", t_prim(a, HDYN));
		b = image(&a, 1, false, "a.A", "f", false);
		b_byte(&b, 0);
		{
			int at = 3 + 1 + 1 + 1 + 1 + 3 + 4;
			b.d[at]++;
		}
		c = link_image(b, &error);
		check(c == NULL && error && strstr(error, "trailing data"), "trailing data in a section: %s", error ? error : "");
		if( c == NULL && error ) printf("ok: trailing data in a section: %s\n", error);
		free(b.d);
	}
	{
		unit *a = simple("a.A");
		char *error;
		buf b;
		hl_code *c;
		simple_fn(a, "f", t_prim(a, HDYN));
		debug_section(a, 2, 1, "packed");
		b = image(&a, 1, false, "a.A", "f", false);
		c = link_image(b, &error);
		check(c == NULL && error && strstr(error, "a compressed debug section"), "a compressed debug sub-section: %s", error ? error : "");
		if( c == NULL && error ) printf("ok: a compressed debug sub-section: %s\n", error);
		free(b.d);
	}
}

/* Every cut of the program and every byte changed in it either links or fails with a message; none reads outside the file. */
static void test_corruption( void ) {
	buf b = program_image(false), copy = { 0 };
	unsigned int seed = 1;
	int failed = 0, linked = 0;
	for(int len=4;len<b.len;len++) {
		char *error = NULL;
		hl_code *c = hl_code_read(b.d, len, &error);
		if( c ) { hl_code_destroy(c); linked++; } else failed += error != NULL;
	}
	check(failed == b.len - 4, "every cut of the program fails with a message (%d of %d)", failed, b.len - 4);
	b_raw(&copy, b.d, b.len);
	for(int i=0;i<4000;i++) {
		char *error = NULL;
		hl_code *c;
		int at;
		memcpy(copy.d, b.d, b.len);
		seed = seed * 1103515245u + 12345u;
		at = 4 + (int)((seed >> 8) % (unsigned int)(b.len - 4));
		copy.d[at] ^= (unsigned char)(1 + (seed >> 24) % 255);
		c = hl_code_read(copy.d, copy.len, &error);
		if( c ) { hl_code_destroy(c); linked++; }
		else { check(error != NULL, "a changed byte at %d fails with a message", at); failed++; }
	}
	printf("ok: cut and changed programs fail cleanly (%d failed, %d still linked)\n", failed, linked);
	free(b.d);
	free(copy.d);
}

// ---- the benchmark

HL_API double hl_sys_time( void );

/*
	A synthetic image with the compiler server's tables: 458 sections, 7,860 functions, 8,848 types (6,190 function types,
	1,847 objects, 79 enums, 293 refs, 11 virtuals, primitives), about 16 k imports (3,713 functions, 6,783 natives, 1,242
	globals, 4,272 types), 2,242 owned globals and 12,742 constants of which 8,018 distinct, 17,806 strings and about
	2.3 M operands.
*/
static buf bench_image( void ) {
	enum { SECTIONS = 458, FUNCTIONS = 7860, OBJECTS = 1847, ENUMS = 79, GLOBALS = 2242, NATIVES = 335 };
	unit **units = (unit**)malloc(sizeof(unit*) * SECTIONS);
	char (*names)[24] = malloc(24 * 200 * SECTIONS);
	int nnames = 0, total_ops = 0;
	long imports = 0;
	unsigned int seed = 12345;
	char paths[SECTIONS][16];
	buf out;
#	define RAND() (seed = seed * 1103515245u + 12345u, (int)((seed >> 8) & 0xFFFFFF))
#	define NAME(fmt, v) (sprintf(names[nnames], fmt, v), names[nnames++])
	for(int s=0;s<SECTIONS;s++) sprintf(paths[s], "m%04d", s);
	for(int s=0;s<SECTIONS;s++) {
		unit *u = unit_new(paths[s], true);
		int nfun = FUNCTIONS / SECTIONS + (s < FUNCTIONS % SECTIONS ? 1 : 0);
		int nobj = OBJECTS / SECTIONS + (s < OBJECTS % SECTIONS ? 1 : 0);
		int nglob = GLOBALS / SECTIONS + (s < GLOBALS % SECTIONS ? 1 : 0);
		int timp[10], prim[8], objs[8], refs[2], tf;
		int fimp[9], nfimp = 0, gimp[3], nat[15];
		int consts[28], strs[40], file;
		// Imports: types of the four sections before, globals of the one before, functions of any earlier one.
		for(int k=0;k<9;k++) {
			int owner = (s + SECTIONS - 1 - k % 4) % SECTIONS;
			timp[k] = s > 0 ? import_type(u, paths[owner], NAME("T%d", owner * 4 + k / 4 % 4), HOBJ) : -1;
		}
		prim[0] = t_prim(u, HI32); prim[1] = t_prim(u, HF64); prim[2] = t_prim(u, HBOOL); prim[3] = t_prim(u, HDYN);
		prim[4] = t_prim(u, HBYTES); prim[5] = t_prim(u, HVOID); prim[6] = t_prim(u, HTYPE); prim[7] = t_prim(u, HARRAY);
		for(int k=0;k<nobj;k++) {
			obj_def o = { OWNED, NULL, HOBJ, NULL, -1, 0, 3, { "a", "b", "c" }, { prim[0], prim[1], prim[3] } };
			o.key = NAME("T%d", s * 4 + k);
			o.name = o.key;
			objs[k] = t_obj(u, &o);
		}
		if( s < ENUMS ) {
			const char *cn[] = { "A", "B", "C" };
			int params[] = { -1, prim[0], prim[3] };
			t_enum(u, OWNED, NAME("E%d", s), "E", 3, cn, params);
		}
		refs[0] = t_param(u, HREF, prim[0]);
		refs[1] = t_param(u, HNULL, prim[0]);
		if( s < 11 ) {
			const char *vn[] = { "x", "y" };
			int vt[] = { prim[0], prim[3] };
			t_virtual(u, STRUCTURAL, NULL, "", 2, vn, vt);
		}
		{
			obj_def string = { SHARED, "String", HOBJ, "String", -1, 0, 2, { "bytes", "length" }, { prim[4], prim[0] } };
			objs[nobj] = t_obj(u, &string);
		}
		// Function types: shapes shared across sections, some of them of this section's own objects.
		for(int k=0;k<24;k++) {
			int args[3];
			int shape = RAND() % 900;
			int pool[] = { prim[0], prim[1], prim[2], prim[3], prim[4], refs[0], refs[1], s > 0 ? timp[k % 9] : prim[3] };
			args[0] = pool[shape % 8];
			args[1] = pool[shape / 8 % 8];
			args[2] = k < 14 ? objs[k % (nobj + 1)] : pool[shape / 64 % 8];
			t_fun(u, k % 4, args, k % 3 == 0 ? prim[5] : pool[(shape / 512) % 8]);
		}
		{
			// Every function and native has this type, so the imports agree with the definitions.
			int args[] = { prim[0], prim[3] };
			tf = t_fun(u, 2, args, prim[3]);
		}
		for(int k=0;k<8 && s > 0;k++) {
			int target = (s + SECTIONS - 1 - k * 37 % (s > 1 ? s : 1)) % s;
			fimp[nfimp++] = import_fn(u, paths[target], NAME("f%d", target * 100), tf);
		}
		for(int k=0;k<3 && s > 0;k++) gimp[k] = import_global(u, paths[s - 1], NAME("g%d", (s - 1) * 10 + k % (GLOBALS / SECTIONS)), prim[3]);
		for(int k=0;k<15;k++) {
			int which = (s * 15 + k) % NATIVES;
			const char *lib = NAME("lib%d", which % 6);
			nat[k] = native(u, lib, NAME("n%d", which), tf);
		}
		for(int k=0;k<nglob;k++) global(u, NAME("g%d", s * 10 + k), prim[3]);
		for(int k=0;k<40;k++) strs[k] = str(u, NAME("string %d", k < 20 ? s * 20 + k : RAND() % 17806));
		for(int k=0;k<28;k++) {
			int fields[] = { strs[k], lit_int(u, (int)strlen(u->strings.items[strs[k]])) };
			consts[k] = constant(u, objs[nobj], 2, fields);
		}
		for(int k=0;k<8;k++) lit_int(u, RAND() % 1000);
		for(int k=0;k<4;k++) lit_float(u, (RAND() % 1000) / 8.0);
		file = debug_file(u, NAME("src/m%d.hx", s));
		for(int k=0;k<nfun;k++) {
			int regs[] = { prim[0], prim[1], prim[3], prim[4], objs[0], prim[0], prim[0], prim[3] };
			unit_fn *f = fn_begin(u, NAME("f%d", s * 100 + k), tf, 8, regs);
			int line = 10;
			// About 290 operands a function: a mix of table and register operands.
			for(int i=0;i<14;i++) {
				op(u, f, file, line++, OInt, 2, 0, i % u->nints);
				op(u, f, file, line++, OString, 2, 3, strs[i % 40]);
				op(u, f, file, line++, OGetGlobal, 2, 2, consts[i % 28]);
				op(u, f, file, line++, OCall2, 4, 2, nfimp ? fimp[i % nfimp] : nat[i % 15], 0, 2);
				op(u, f, file, line++, OCall1, 3, 2, nat[i % 15], 2);
				op(u, f, file, line++, OAdd, 3, 0, 0, 5);
				op(u, f, file, line++, OField, 3, 1, 4, 1);
				op(u, f, file, line++, OMov, 2, 6, 0);
			}
			if( s > 0 ) op(u, f, file, line++, OSetGlobal, 2, gimp[k % 3], 2);
			op(u, f, file, line++, ONull, 1, 2);
			op(u, f, file, line++, ORet, 1, 2);
			total_ops += f->nops;
		}
		imports += u->nfimports + u->ngimports + u->ntimports + u->nnatives;
		units[s] = u;
	}
	out = image(units, SECTIONS, true, paths[0], "f0", false);
	printf("bench: %d sections, %ld imports, %d opcodes, %ld operands, %d bytes\n", SECTIONS, imports, total_ops, operand_count, out.len);
	return out;
#	undef RAND
#	undef NAME
}

/* Loads `b` `runs` times; reports the first load, when the process touches the memory for the first time as hl does, and the
   best one. */
static void time_loads( const char *what, buf b, int runs ) {
	double first = 0, best = 1e9;
	long ops = 0;
	for(int i=0;i<runs;i++) {
		char *error = NULL;
		double t0 = hl_sys_time();
		hl_code *c = hl_code_read(b.d, b.len, &error);
		double t = hl_sys_time() - t0;
		if( c == NULL ) { fprintf(stderr, "bench: %s\n", error ? error : "load failed"); exit(1); }
		if( i == 0 ) {
			first = t;
			for(int k=0;k<c->nfunctions;k++) ops += c->functions[k].nops;
			printf("bench: %s: %d functions, %d natives, %d types, %d globals (%d constants), %d strings, %ld opcodes\n", what,
				c->nfunctions, c->nnatives, c->ntypes, c->nglobals, c->nconstants, c->nstrings, ops);
		}
		if( t < best ) best = t;
		hl_code_destroy(c);
	}
	printf("bench: %s: first load %.1f ms, best of %d %.1f ms\n", what, first * 1000, runs, best * 1000);
}

// ---- patches of sections (HLP 12)

/*
	A module of two sections, app.Main and lib.Point, loaded to take patches. Main.main returns Point.value(); each patch
	replaces lib.Point (and app.Main where it must) with another Point.value, and the module then returns what the new code
	returns. Point.other never changes, so its code is never compiled again.
*/
static const unsigned char patch_module_id[16] = { 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16 };

enum {
	POINT_BASE, POINT_BODY, POINT_ADDED, POINT_CLASS, POINT_FIELD, POINT_RENAMED, POINT_GUARDED,
	POINT_MISSING_IMPORT, POINT_NATIVE, POINT_SIGNATURE, POINT_ENUM, POINT_LAYOUT, POINT_TYPE_RENAMED
};

static unit *patch_main_section( void ) {
	unit *u = unit_new("app.Main", true);
	int i32 = t_prim(u, HI32);
	int tvalue = t_fun(u, 0, no_args, i32);
	int value = import_fn(u, "lib.Point", "Point.value", tvalue);
	int file = debug_file(u, "app/Main.hx");
	int regs[] = { i32 };
	unit_fn *f = fn_begin(u, "Main.main", tvalue, 1, regs);
	op(u, f, file, 3, OCall0, 2, 0, value);
	op(u, f, file, 4, ORet, 1, 0);
	return u;
}

static unit *patch_point_section( int variant ) {
	unit *u = unit_new("lib.Point", true);
	int i32 = t_prim(u, HI32), dyn = t_prim(u, HDYN), f64 = t_prim(u, HF64);
	obj_def point = { OWNED, "Point", HOBJ, "lib.Point", -1, 0, 2, { "x", "" }, { i32, dyn } };
	obj_def extra = { OWNED, "Extra", HOBJ, "lib.Extra", -1, 0, 1, { "v" }, { i32 } };
	int tpoint, tvalue, file, ttake, textra = -1;
	if( variant == POINT_FIELD ) { point.field_names[1] = "y"; point.field_types[1] = i32; }
	if( variant == POINT_LAYOUT ) point.field_types[0] = f64;
	tvalue = t_fun(u, 0, no_args, i32);
	ttake = t_fun(u, 1, &i32, i32);
	if( variant == POINT_CLASS ) textra = t_obj(u, &extra);
	if( variant == POINT_TYPE_RENAMED ) {
		// Point is keyed by another name now, with its definition as it was; the key it freed names a new class.
		obj_def fresh = { OWNED, "Point", HOBJ, "lib.Fresh", -1, 0, 1, { "v" }, { i32 } };
		point.key = "Moved";
		tpoint = t_obj(u, &point);
		textra = t_obj(u, &fresh);
	} else
		tpoint = t_obj(u, &point);
	if( variant == POINT_ENUM ) {
		const char *names[] = { "A" };
		int params[] = { -1 };
		t_enum(u, OWNED, "Kind", "lib.Kind", 1, names, params);
	}
	file = debug_file(u, "lib/Point.hx");
	{
		// A rename keeps the old body in the old slot under the retired key; the new Point.value comes last, in a new slot.
		int regs[] = { i32, variant == POINT_CLASS || variant == POINT_TYPE_RENAMED ? textra : tpoint };
		unit_fn *f = fn_begin(u, variant == POINT_RENAMED ? "Point.value~retired" : "Point.value", tvalue, 2, regs);
		switch( variant ) {
		case POINT_BODY:
			op(u, f, file, 10, OInt, 2, 0, lit_int(u, 2));
			break;
		case POINT_GUARDED:
			op(u, f, file, 10, OInt, 2, 0, lit_int(u, 3));
			break;
		case POINT_ADDED:
			// Point.helper is the third owned function, in a debug file the module does not have.
			op(u, f, file, 10, OCall0, 2, 0, 2);
			break;
		case POINT_CLASS:
		case POINT_TYPE_RENAMED:
			op(u, f, file, 10, ONew, 1, 1);
			op(u, f, file, 11, OInt, 2, 0, lit_int(u, 7));
			op(u, f, file, 12, OSetField, 3, 1, 0, 0);
			op(u, f, file, 13, OField, 3, 0, 1, 0);
			break;
		case POINT_FIELD:
			op(u, f, file, 10, ONew, 1, 1);
			op(u, f, file, 11, OInt, 2, 0, lit_int(u, 9));
			op(u, f, file, 12, OSetField, 3, 1, 1, 0);
			op(u, f, file, 13, OField, 3, 0, 1, 1);
			break;
		case POINT_MISSING_IMPORT:
			op(u, f, file, 10, OInt, 2, 0, lit_int(u, 2));
			op(u, f, file, 11, OCall0, 2, 0, import_fn(u, "lib.Missing", "nothing", tvalue));
			break;
		case POINT_NATIVE:
			op(u, f, file, 10, OCall1, 3, 0, native(u, "builtin", "code_link_round", t_fun(u, 1, &f64, i32)), 0);
			break;
		default:
			op(u, f, file, 10, OInt, 2, 0, lit_int(u, 1));
			break;
		}
		op(u, f, file, 14, ORet, 1, 0);
	}
	{
		int regs[] = { i32 };
		unit_fn *f = fn_begin(u, "Point.other", variant == POINT_SIGNATURE ? ttake : tvalue, 1, regs);
		op(u, f, file, 20, OInt, 2, 0, lit_int(u, 1));
		op(u, f, file, 21, ORet, 1, 0);
	}
	if( variant == POINT_ADDED ) {
		int regs[] = { i32 };
		unit_fn *f = fn_begin(u, "Point.helper", tvalue, 1, regs);
		int helper_file = debug_file(u, "lib/Helper.hx");
		op(u, f, helper_file, 5, OInt, 2, 0, lit_int(u, 5));
		op(u, f, helper_file, 6, ORet, 1, 0);
	}
	if( variant == POINT_RENAMED ) {
		int regs[] = { i32 };
		unit_fn *f = fn_begin(u, "Point.value", tvalue, 1, regs);
		op(u, f, file, 30, OInt, 2, 0, lit_int(u, 11));
		op(u, f, file, 31, ORet, 1, 0);
	}
	return u;
}

typedef struct {
	const char *module, *from, *to;
} test_rename;

/* An HLP 12 patch from `base` to `revision` that replaces the sections of `units`. */
static buf patch_image( int base, int revision, unit **units, int n, const test_rename *renames, int nrenames, const char *guard ) {
	buf out = { 0 };
	b_raw(&out, "HLP", 3);
	b_byte(&out, 12);
	b_raw(&out, patch_module_id, 16);
	b_index(&out, base);
	b_index(&out, revision);
	b_index(&out, n);
	for(int i=0;i<n;i++) {
		buf section = { 0 };
		section_bytes(units[i], &section, i % 2 == 1);
		b_text(&out, units[i]->path);
		b_i32(&out, section.len);
		b_buf(&out, &section);
		free(section.d);
	}
	b_index(&out, 0);
	b_index(&out, nrenames);
	for(int i=0;i<nrenames;i++) { b_text(&out, renames[i].module); b_text(&out, renames[i].from); b_text(&out, renames[i].to); }
	b_index(&out, guard ? 1 : 0);
	if( guard ) { b_text(&out, "lib.Point"); b_text(&out, guard); b_text(&out, "a removed function"); }
	b_index(&out, 0);
	return out;
}

static hl_module *patch_load( void ) {
	unit *units[] = { patch_main_section(), patch_point_section(POINT_BASE) };
	buf b = image(units, 2, true, "app.Main", "Main.main", false);
	char *error = NULL;
	hl_code *code = hl_code_read_patchable(b.d, b.len, &error);
	hl_module *m;
	free(b.d);
	check(code != NULL && code->link_state != NULL, "a patchable load keeps the link state: %s", error ? error : "");
	if( code == NULL ) return NULL;
	m = hl_module_alloc(code);
	check(m != NULL && hl_module_init(m, HL_MODULE_PATCHABLE), "the patchable module initializes");
	if( m == NULL ) return NULL;
	hl_code_free_function_data(code);
	m->revision = 0;
	return m;
}

static int patch_call( hl_module *m, int slot ) {
	vclosure cl;
	vdynamic *ret;
	bool exc = false;
	cl.t = m->ctx.functions_types[slot];
	cl.fun = m->functions_ptrs[slot];
	cl.hasValue = 0;
	ret = hl_dyn_call_safe(&cl, NULL, 0, &exc);
	return exc || ret == NULL ? -1 : ret->v.i;
}

/* Applies a patch of `units`; NULL when it applied, else the message. */
static const char *patch_apply( hl_module *m, int base, int revision, unit **units, int n, const test_rename *renames, int nrenames, const char *guard ) {
	buf b = patch_image(base, revision, units, n, renames, nrenames, guard);
	const char *error = NULL;
	hl_patch *patch = hl_patch_read(b.d, b.len, &error);
	static char message[1024];
	hl_patch_migration_report report;
	free(b.d);
	if( patch == NULL ) return error ? error : "unreadable";
	if( !hl_module_apply_patch(m, patch, &report, &error) ) {
		snprintf(message, sizeof(message), "%s", error ? error : "refused");
		hl_patch_free(patch);
		return message;
	}
	hl_patch_free(patch);
	return NULL;
}

static int slot_named( hl_module *m, const char *name ) {
	hl_code *c = m->code;
	for(int i=0;i<c->nfunctions + c->npatchfunctions;i++)
		if( c->function_names[i] && strcmp(c->function_names[i], name) == 0 ) return c->function_stable_ids[i];
	return -1;
}

static void test_patch_edits( void ) {
	hl_module *m = patch_load();
	unit *point;
	const char *error;
	int jit, files;
	if( m == NULL ) return;
	check(patch_call(m, 0) == 1, "the base module returns 1");
	point = patch_point_section(POINT_BODY);
	jit = m->patch_jit_count;
	error = patch_apply(m, 0, 1, &point, 1, NULL, 0, NULL);
	check(error == NULL, "a body edit patches: %s", error ? error : "");
	check(patch_call(m, 0) == 2 && m->revision == 1, "the patched module returns 2 (got %d)", patch_call(m, 0));
	check(m->patch_jit_count - jit == 1, "only the edited function is compiled again (%d)", m->patch_jit_count - jit);
	// The same section again changes no code.
	point = patch_point_section(POINT_BODY);
	jit = m->patch_jit_count;
	error = patch_apply(m, 1, 2, &point, 1, NULL, 0, NULL);
	check(error == NULL && m->patch_jit_count == jit && m->revision == 2, "an unchanged section compiles nothing: %s", error ? error : "");
	// An added function takes the next slot, in a debug file the module did not have.
	point = patch_point_section(POINT_ADDED);
	files = m->code->ndebugfiles;
	error = patch_apply(m, 2, 3, &point, 1, NULL, 0, NULL);
	check(error == NULL, "an added function patches: %s", error ? error : "");
	check(patch_call(m, 0) == 5, "the module calls the added function (got %d)", patch_call(m, 0));
	check(slot_named(m, "Point.helper") == 3 && m->code->npatchfunctions == 1, "the added function's stable id is its slot (%d)", slot_named(m, "Point.helper"));
	check(m->code->ndebugfiles == files + 1 && strcmp(m->code->debugfiles[files], "lib/Helper.hx") == 0, "the patch adds its debug file");
	// A class the module does not have.
	point = patch_point_section(POINT_CLASS);
	error = patch_apply(m, 3, 4, &point, 1, NULL, 0, NULL);
	check(error == NULL, "an added class patches: %s", error ? error : "");
	check(patch_call(m, 0) == 7, "the module makes the added class (got %d)", patch_call(m, 0));
	// A reserved slot of Point named and typed.
	point = patch_point_section(POINT_FIELD);
	error = patch_apply(m, 4, 5, &point, 1, NULL, 0, NULL);
	check(error == NULL, "a field in a reserved slot patches: %s", error ? error : "");
	check(patch_call(m, 0) == 9, "the module reads the added field (got %d)", patch_call(m, 0));
	{
		hl_type *t = NULL;
		for(int i=0;i<m->code->ntypes;i++)
			if( m->code->types[i].kind == HOBJ && same_ustr(m->code->types[i].obj->name, USTR("lib.Point")) ) t = m->code->types + i;
		check(t != NULL && t->obj->fields[1].name[0] == 'y', "the reserved slot is named");
	}
	if( failures == 0 ) printf("ok: patches of sections: a body edit, an unchanged section, an added function, class and field\n");
}

static void test_patch_rename( void ) {
	hl_module *m = patch_load();
	unit *units[2];
	test_rename rename = { "lib.Point", "Point.value", "Point.value~retired" };
	const char *error;
	int jit;
	if( m == NULL ) return;
	units[0] = patch_main_section();
	units[1] = patch_point_section(POINT_RENAMED);
	jit = m->patch_jit_count;
	error = patch_apply(m, 0, 1, units, 2, &rename, 1, NULL);
	check(error == NULL, "a renamed slot patches: %s", error ? error : "");
	check(patch_call(m, 0) == 11, "the caller reaches the new function (got %d)", patch_call(m, 0));
	check(slot_named(m, "Point.value") == 3, "the new function takes a new slot (%d)", slot_named(m, "Point.value"));
	check(patch_call(m, 1) == 1, "the retired slot keeps its code");
	// The retired function's code is the running one's: only the caller and the new function are compiled.
	check(m->patch_jit_count - jit == 2, "a rename compiles the caller and the new function (%d)", m->patch_jit_count - jit);
	if( failures == 0 ) printf("ok: patches of sections: a renamed slot keeps its code\n");
}

/* A type key renamed, as a lambda's environment is with its lambda: the type keeps its slot, and the key it freed is a new class. */
static void test_patch_type_rename( void ) {
	hl_module *m = patch_load();
	unit *point;
	test_rename rename = { "lib.Point", "Point", "Moved" }, unknown = { "lib.Point", "Nothing", "Something" };
	const char *error;
	int types;
	if( m == NULL ) return;
	types = m->code->ntypes;
	point = patch_point_section(POINT_TYPE_RENAMED);
	error = patch_apply(m, 0, 1, &point, 1, &rename, 1, NULL);
	check(error == NULL, "a renamed type patches: %s", error ? error : "");
	check(patch_call(m, 0) == 7, "the module makes the class under the freed key (got %d)", patch_call(m, 0));
	check(m->code->ntypes == types + 1, "the renamed type keeps its slot and only the new class is added (%d types, was %d)", m->code->ntypes, types);
	// A rename of a key the module does not have is refused.
	point = patch_point_section(POINT_BODY);
	error = patch_apply(m, 1, 2, &point, 1, &unknown, 1, NULL);
	check(error != NULL && strstr(error, "no function, type or global keyed by") != NULL, "an unknown rename is refused: %s", error ? error : "");
	if( failures == 0 ) printf("ok: patches of sections: a renamed type keeps its slot\n");
}

static void test_patch_refusals( void ) {
	hl_module *m = patch_load();
	struct { int variant; const char *parts[3]; } cases[] = {
		{ POINT_MISSING_IMPORT, { "lib.Missing.nothing", "lib.Point", NULL } },
		{ POINT_NATIVE, { "builtin@code_link_round", "reload", NULL } },
		{ POINT_SIGNATURE, { "Point.other", "another type", NULL } },
		{ POINT_ENUM, { "adds enum", "lib.Point.Kind", NULL } },
		{ POINT_LAYOUT, { "redefines type", "lib.Point.Point", NULL } },
	};
	const char *error;
	unit *point;
	if( m == NULL ) return;
	for(int i=0;i<(int)(sizeof(cases)/sizeof(cases[0]));i++) {
		bool all;
		point = patch_point_section(cases[i].variant);
		error = patch_apply(m, 0, 1, &point, 1, NULL, 0, NULL);
		all = error != NULL;
		for(int k=0;all && cases[i].parts[k];k++) all = strstr(error, cases[i].parts[k]) != NULL;
		check(all, "patch refusal %d names the key: %s", i, error ? error : "(applied)");
		if( all ) printf("ok: refused: %s\n", error);
		check(m->revision == 0 && patch_call(m, 0) == 1, "a refused patch leaves the module as it was");
	}
	// What the refused patches staged is gone: the int 2 they staged is the next patch's own.
	point = patch_point_section(POINT_BODY);
	error = patch_apply(m, 0, 1, &point, 1, NULL, 0, NULL);
	check(error == NULL && patch_call(m, 0) == 2, "a patch after refused ones applies: %s", error ? error : "");
	// A guard by key, with no stored closure, does not stop the patch.
	point = patch_point_section(POINT_GUARDED);
	error = patch_apply(m, 1, 2, &point, 1, NULL, 0, "Point.other");
	check(error == NULL, "a guard by key resolves: %s", error ? error : "");
	point = patch_point_section(POINT_BODY);
	error = patch_apply(m, 2, 3, &point, 1, NULL, 0, "Point.gone");
	check(error != NULL && strstr(error, "Point.gone") != NULL, "a guard of a key the module lacks is refused: %s", error ? error : "(applied)");
	if( failures == 0 ) printf("ok: patches of sections: refusals name the key, and leave the module and its link state as they were\n");
}

/* The runtime's loader with an HLI 4 identity: stable ids are slots, found by name, and patches apply through it. */
static void test_patch_runtime( void ) {
	unit *units[] = { patch_main_section(), patch_point_section(POINT_BASE) };
	buf b = image(units, 2, true, "app.Main", "Main.main", false), identity = { 0 }, patch;
	hl_runtime_module *runtime = NULL;
	hl_runtime_status status;
	unit *point;
	int result = -1, main_id, value_id;
	vdynamic *exception = NULL;
	b_raw(&identity, "HLI", 3);
	b_byte(&identity, 4);
	b_raw(&identity, patch_module_id, 16);
	b_i32(&identity, 0);
	b_i32(&identity, 0);
	// HLI 4 is the only identity: one of another version, which listed stable ids, is refused.
	identity.d[3] = 3;
	status = hl_runtime_module_load(b.d, b.len, identity.d, identity.len, &runtime);
	check(status == HL_RUNTIME_BAD_FORMAT && runtime == NULL, "an identity of another version is refused (%d)", status);
	identity.d[3] = 4;
	status = hl_runtime_module_load(b.d, b.len, identity.d, identity.len, &runtime);
	check(status == HL_RUNTIME_OK, "an HLI 4 module loads (%d)", status);
	if( status != HL_RUNTIME_OK ) return;
	main_id = hl_runtime_module_function_id(runtime, "Main.main");
	value_id = hl_runtime_module_function_id(runtime, "Point.value");
	check(main_id == 0 && value_id == 1 && hl_runtime_module_function_id(runtime, "nothing") == -1, "functions are found by name");
	status = hl_runtime_module_call_i32(runtime, main_id, &result, &exception);
	check(status == HL_RUNTIME_OK && result == 1, "the runtime calls by stable id");
	point = patch_point_section(POINT_ADDED);
	patch = patch_image(0, 1, &point, 1, NULL, 0, NULL);
	status = hl_runtime_module_apply_hlp(runtime, patch.d, patch.len);
	check(status == HL_RUNTIME_OK, "the runtime applies a patch of sections (%d)", status);
	// HLP 12 is the only patch: one of another version is refused before it is linked.
	patch.d[3] = 11;
	check(hl_runtime_module_apply_hlp(runtime, patch.d, patch.len) == HL_RUNTIME_BAD_FORMAT, "a patch of another version is refused");
	patch.d[3] = 12;
	status = hl_runtime_module_call_i32(runtime, main_id, &result, &exception);
	check(status == HL_RUNTIME_OK && result == 5, "the patched module returns 5 (got %d)", result);
	check(hl_runtime_module_function_id(runtime, "Point.helper") == 3, "an added function is found by name");
	status = hl_runtime_module_call_i32(runtime, 3, &result, &exception);
	check(status == HL_RUNTIME_OK && result == 5, "the runtime calls an added function by its minted id");
	free(patch.d);
	point = patch_point_section(POINT_MISSING_IMPORT);
	patch = patch_image(1, 2, &point, 1, NULL, 0, NULL);
	status = hl_runtime_module_apply_hlp(runtime, patch.d, patch.len);
	check(status == HL_RUNTIME_INCOMPATIBLE && hl_runtime_module_patch_message(runtime) != NULL, "a refused patch says why (%d)", status);
	free(patch.d);
	free(b.d);
	free(identity.d);
	if( failures == 0 ) printf("ok: patches of sections through the runtime, with an HLI 4 identity\n");
}


/* `--bench RUNS [dense.hl]`: RUNS links of the synthetic image, then as many reads of the dense file. */
static int bench( int argc, char **argv ) {
	int runs = argc > 2 ? atoi(argv[2]) : 10;
	buf b = bench_image();
	time_loads("hl_code_link of the synthetic image", b, runs);
	if( argc > 3 ) {
		FILE *f = fopen(argv[3], "rb");
		buf d = { 0 };
		char chunk[65536];
		size_t n;
		if( f == NULL ) { fprintf(stderr, "bench: cannot open %s\n", argv[3]); return 1; }
		while( (n = fread(chunk, 1, sizeof(chunk), f)) > 0 ) b_raw(&d, chunk, (int)n);
		fclose(f);
		time_loads("hl_code_read of the dense file", d, runs);
	}
	return 0;
}

int main( int argc, char **argv ) {
	int marker = 0;
	hl_global_init();
	hl_sys_init();
	hl_register_thread(&marker);
	if( argc > 1 && strcmp(argv[1], "--bench") == 0 ) return bench(argc, argv);
	if( argc > 3 && strcmp(argv[1], "--compare") == 0 ) return compare_files(argv[2], argv[3]);
	if( argc > 2 && strcmp(argv[1], "--write") == 0 ) {
		// The test program as an HLB 9 file, for the tools that read bytecode (hldump).
		buf b = program_image(false);
		FILE *f = fopen(argv[2], "wb");
		if( f == NULL || fwrite(b.d, 1, b.len, f) != (size_t)b.len ) return 1;
		fclose(f);
		return 0;
	}
	test_single_section();
	test_program();
	test_unification();
	test_errors();
	test_corruption();
	test_patch_edits();
	test_patch_rename();
	test_patch_type_rename();
	test_patch_refusals();
	test_patch_runtime();
	if( failures ) {
		fprintf(stderr, "%d failures\n", failures);
		return 1;
	}
	printf("PASS: HLB 9 sections link into the dense tables\n");
	return 0;
}
