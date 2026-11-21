/* Haxe stack traces for a program Haxeon compiled to C (docs/design/AOT_BACKEND.md). The generated functions are in their own
 * section (`hlc_text`), so a captured frame is the program's exactly when its return address is in that section, as a JIT frame
 * is when it is in the module's code. A frame is named as the JIT names it: the function's identity from the module image, and
 * the Haxe file and line the C compiler's line table gives for the call (`#line` in the generated code). The line table is read
 * from the executable's own DWARF `.debug_line` the first time a frame is resolved. Where the C compiler inlined generated functions
 * into each other (release builds; development builds define HLC_EXACT_FRAMES and inline none), the DWARF inline records restore
 * their frames. */
#include <hl.h>
#include <hlmodule.h>

void hlc_stack_init( hl_module *m, void **functions, int count );

#if defined(__linux__) && defined(__ELF__)
#include <dlfcn.h>
#include <elf.h>
#include <execinfo.h>
#include <fcntl.h>
#include <link.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

extern char __start_hlc_text[], __stop_hlc_text[];

typedef struct {
	uintptr_t start;
	int slot;
} hlc_function_start;

typedef struct {
	uintptr_t address;
	int file; // index in hlc_files; -1 ends a sequence
	int line;
} hlc_line_row;

static hl_module *hlc_module;
static hlc_function_start *hlc_starts;
static int hlc_start_count;
static hlc_line_row *hlc_rows;
static int hlc_row_count, hlc_row_capacity;
static const char **hlc_files;
static int hlc_file_count, hlc_file_capacity;
static int hlc_lines_state; // 0 not read, 1 read, -1 unavailable

/* A line program's file table, by the program's offset in `.debug_line` (a unit's DW_AT_stmt_list), for DW_AT_call_file. */
typedef struct {
	uint64 offset;
	int *files;
	int count;
} hlc_line_unit;

static hlc_line_unit *hlc_line_units;
static int hlc_line_unit_count, hlc_line_unit_capacity;

static bool hlc_in_text( void *address ) {
	char *a = (char*)address - 1; // a return address can be just past a call that does not return
	return a >= __start_hlc_text && a < __stop_hlc_text;
}

static int hlc_compare_starts( const void *a, const void *b ) {
	uintptr_t x = ((const hlc_function_start*)a)->start, y = ((const hlc_function_start*)b)->start;
	return x < y ? -1 : x > y ? 1 : 0;
}

static int hlc_compare_rows( const void *a, const void *b ) {
	const hlc_line_row *x = (const hlc_line_row*)a, *y = (const hlc_line_row*)b;
	if( x->address != y->address ) return x->address < y->address ? -1 : 1;
	// At one address a sequence's end goes before the next sequence's start.
	return (x->file >= 0) - (y->file >= 0);
}

static uint64 hlc_uleb( const unsigned char **p, const unsigned char *end ) {
	uint64 value = 0;
	int shift = 0;
	while( *p < end ) {
		unsigned char byte = *(*p)++;
		if( shift < 64 ) value |= (uint64)(byte & 0x7F) << shift;
		shift += 7;
		if( !(byte & 0x80) ) break;
	}
	return value;
}

static int64 hlc_sleb( const unsigned char **p, const unsigned char *end ) {
	int64 value = 0;
	int shift = 0;
	unsigned char byte = 0;
	while( *p < end ) {
		byte = *(*p)++;
		if( shift < 64 ) value |= (int64)(byte & 0x7F) << shift;
		shift += 7;
		if( !(byte & 0x80) ) break;
	}
	if( shift < 64 && (byte & 0x40) ) value |= -((int64)1 << shift);
	return value;
}

static uint64 hlc_fixed( const unsigned char **p, int size ) {
	uint64 value = 0;
	for(int i=0;i<size;i++) value |= (uint64)(*p)[i] << (8 * i);
	*p += size;
	return value;
}

typedef struct {
	const unsigned char *line_str, *str;
	size_t line_str_size, str_size;
} hlc_strings;

static const char *hlc_section_string( const unsigned char *section, size_t size, uint64 offset ) {
	return section && offset < size ? (const char*)section + offset : NULL;
}

/* Reads one attribute of a version 5 directory or file entry: a string for DW_LNCT_path, a number for the others. */
static bool hlc_read_form( const unsigned char **p, const unsigned char *end, int form, int offset_size, hlc_strings *s,
	const char **text, uint64 *number ) {
	*text = NULL;
	*number = 0;
	switch( form ) {
	case 0x08: /* DW_FORM_string */
		*text = (const char*)*p;
		while( *p < end && **p ) (*p)++;
		(*p)++;
		return true;
	case 0x1f: /* DW_FORM_line_strp */
		*text = hlc_section_string(s->line_str, s->line_str_size, hlc_fixed(p, offset_size));
		return true;
	case 0x0e: /* DW_FORM_strp */
		*text = hlc_section_string(s->str, s->str_size, hlc_fixed(p, offset_size));
		return true;
	case 0x0f: *number = hlc_uleb(p, end); return true; /* DW_FORM_udata */
	case 0x0b: *number = hlc_fixed(p, 1); return true; /* DW_FORM_data1 */
	case 0x05: *number = hlc_fixed(p, 2); return true; /* DW_FORM_data2 */
	case 0x06: *number = hlc_fixed(p, 4); return true; /* DW_FORM_data4 */
	case 0x07: *number = hlc_fixed(p, 8); return true; /* DW_FORM_data8 */
	case 0x1e: *p += 16; return true; /* DW_FORM_data16 */
	case 0x09: { uint64 length = hlc_uleb(p, end); *p += length; return true; } /* DW_FORM_block */
	default: return false;
	}
}

static int hlc_add_file( const char *name ) {
	if( hlc_file_count == hlc_file_capacity ) {
		hlc_file_capacity = hlc_file_capacity ? hlc_file_capacity * 2 : 64;
		hlc_files = (const char**)realloc(hlc_files, sizeof(char*) * hlc_file_capacity);
	}
	hlc_files[hlc_file_count] = name ? name : "?";
	return hlc_file_count++;
}

static void hlc_add_row( uintptr_t address, int file, int line ) {
	if( address < (uintptr_t)__start_hlc_text || address > (uintptr_t)__stop_hlc_text ) return;
	if( hlc_row_count == hlc_row_capacity ) {
		hlc_row_capacity = hlc_row_capacity ? hlc_row_capacity * 2 : 4096;
		hlc_rows = (hlc_line_row*)realloc(hlc_rows, sizeof(hlc_line_row) * hlc_row_capacity);
	}
	hlc_rows[hlc_row_count].address = address;
	hlc_rows[hlc_row_count].file = file;
	hlc_rows[hlc_row_count].line = line;
	hlc_row_count++;
}

/* Decodes every line program of `.debug_line` (DWARF 2 to 5), keeping the rows of the generated code, moved by `bias`. */
static void hlc_read_line_programs( const unsigned char *data, size_t size, hlc_strings *strings, uintptr_t bias ) {
	const unsigned char *p = data, *end = data + size;
	while( p + 4 <= end ) {
		uint64 unit_offset = (uint64)(p - data);
		int offset_size = 4;
		uint64 length = hlc_fixed(&p, 4);
		if( length == 0xffffffff ) { length = hlc_fixed(&p, 8); offset_size = 8; }
		const unsigned char *unit_end = p + length;
		if( unit_end > end || length < 2 ) return;
		int version = (int)hlc_fixed(&p, 2);
		int address_size = 8;
		if( version >= 5 ) { address_size = *p++; p++; }
		uint64 header_length = hlc_fixed(&p, offset_size);
		const unsigned char *program = p + header_length;
		int min_inst = *p++;
		if( version >= 4 ) p++; // maximum operations per instruction: 1 on the targets this reads
		int default_is_stmt = *p++;
		int line_base = (signed char)*p++;
		int line_range = *p++;
		int opcode_base = *p++;
		const unsigned char *opcode_lengths = p;
		p += opcode_base - 1;
		int *files = NULL, nfiles = 0;
		if( version >= 5 ) {
			for(int table=0;table<2;table++) {
				int nformats = *p++, types[16], forms[16];
				for(int i=0;i<nformats;i++) {
					uint64 type = hlc_uleb(&p, unit_end), form = hlc_uleb(&p, unit_end);
					if( i < 16 ) { types[i] = (int)type; forms[i] = (int)form; }
				}
				uint64 count = hlc_uleb(&p, unit_end);
				if( table == 1 ) files = (int*)malloc(sizeof(int) * (count ? count : 1));
				for(uint64 e=0;e<count;e++) {
					const char *name = NULL;
					for(int i=0;i<nformats && i<16;i++) {
						const char *text; uint64 number;
						if( !hlc_read_form(&p, unit_end, forms[i], offset_size, strings, &text, &number) ) { free(files); return; }
						if( types[i] == 1 ) name = text;
					}
					if( table == 1 ) files[nfiles++] = hlc_add_file(name);
				}
			}
		} else {
			while( p < unit_end && *p ) { while( p < unit_end && *p ) p++; p++; }
			p++;
			files = (int*)malloc(sizeof(int) * 256);
			int capacity = 256;
			files[nfiles++] = hlc_add_file(NULL); // file numbers start at 1
			while( p < unit_end && *p ) {
				const char *name = (const char*)p;
				while( p < unit_end && *p ) p++;
				p++;
				hlc_uleb(&p, unit_end); hlc_uleb(&p, unit_end); hlc_uleb(&p, unit_end);
				if( nfiles == capacity ) { capacity *= 2; files = (int*)realloc(files, sizeof(int) * capacity); }
				files[nfiles++] = hlc_add_file(name);
			}
		}
		p = program;
		uint64 address = 0;
		int file = version >= 5 ? 0 : 1, line = 1;
		(void)default_is_stmt;
#define HLC_FILE (file >= 0 && file < nfiles ? files[file] : -1)
		while( p < unit_end ) {
			int op = *p++;
			if( op >= opcode_base ) {
				int adjusted = op - opcode_base;
				address += (uint64)(adjusted / line_range) * min_inst;
				line += line_base + adjusted % line_range;
				hlc_add_row((uintptr_t)address + bias, HLC_FILE, line);
				continue;
			}
			switch( op ) {
			case 0: {
				uint64 len = hlc_uleb(&p, unit_end);
				const unsigned char *next = p + len;
				int sub = len ? *p++ : 0;
				if( sub == 1 ) {
					hlc_add_row((uintptr_t)address + bias, -1, 0);
					address = 0; file = version >= 5 ? 0 : 1; line = 1;
				} else if( sub == 2 )
					address = hlc_fixed(&p, address_size);
				p = next;
				break;
			}
			case 1: hlc_add_row((uintptr_t)address + bias, HLC_FILE, line); break;
			case 2: address += hlc_uleb(&p, unit_end) * min_inst; break;
			case 3: line += (int)hlc_sleb(&p, unit_end); break;
			case 4: file = (int)hlc_uleb(&p, unit_end); break;
			case 8: address += (uint64)((255 - opcode_base) / line_range) * min_inst; break;
			case 9: address += hlc_fixed(&p, 2); break;
			default:
				for(int i=0;i<opcode_lengths[op - 1];i++) hlc_uleb(&p, unit_end);
				break;
			}
		}
#undef HLC_FILE
		if( hlc_line_unit_count == hlc_line_unit_capacity ) {
			hlc_line_unit_capacity = hlc_line_unit_capacity ? hlc_line_unit_capacity * 2 : 64;
			hlc_line_units = (hlc_line_unit*)realloc(hlc_line_units, sizeof(hlc_line_unit) * hlc_line_unit_capacity);
		}
		hlc_line_units[hlc_line_unit_count].offset = unit_offset;
		hlc_line_units[hlc_line_unit_count].files = files;
		hlc_line_units[hlc_line_unit_count].count = nfiles;
		hlc_line_unit_count++;
		p = unit_end;
	}
}

static int hlc_function_at( void *address ) {
	uintptr_t target = (uintptr_t)address - 1;
	int low = 0, high = hlc_start_count - 1, found = -1;
	while( low <= high ) {
		int middle = (low + high) >> 1;
		if( hlc_starts[middle].start <= target ) { found = middle; low = middle + 1; } else high = middle - 1;
	}
	return found < 0 ? -1 : hlc_starts[found].slot;
}

#ifndef HLC_EXACT_FRAMES
/* Inlined frames. Where the C compiler inlined a generated function into another, the return address of a frame lies in the
 * inlined code, and the DWARF inline records (`.debug_info`: DW_TAG_inlined_subroutine, with the call's file and line) restore
 * the frames the inlining removed. Each record is a scope: a function body at some address ranges, inside its caller's scope;
 * a subprogram's scope is the outermost. Scopes are kept in DIE order, each with the index past its subtree, so a lookup
 * descends from the subprogram of an address through the children whose ranges hold it. */
typedef struct {
	int parent; // -1 for a subprogram
	int next; // the index past this scope's subtree
	int first_range, range_count;
	const char *name; // the C name of the function this is the body of
	const char *call_file; // where the parent calls it, for an inlined scope
	int call_line;
	int slot; // the generated function's slot, -1 if it is not one, -2 not looked up yet
} hlc_scope;

typedef struct {
	uintptr_t low, high;
	int scope;
} hlc_range;

static hlc_scope *hlc_scopes;
static int hlc_scope_count, hlc_scope_capacity;
static hlc_range *hlc_scope_ranges; // each scope's ranges, by first_range
static int hlc_scope_range_count, hlc_scope_range_capacity;
static hlc_range *hlc_subprograms; // the subprograms' ranges, sorted by address
static int hlc_subprogram_count;

typedef struct {
	const unsigned char *info, *abbrev, *rnglists, *ranges, *addr, *str, *str_offsets, *line_str;
	size_t info_size, abbrev_size, rnglists_size, ranges_size, addr_size, str_size, str_offsets_size, line_str_size;
} hlc_debug_sections;

typedef struct {
	uint64 name, form;
	int64 implicit;
} hlc_abbrev_attr;

typedef struct {
	uint64 code, tag;
	bool children;
	hlc_abbrev_attr *attrs;
	int count;
} hlc_abbrev;

typedef struct {
	const unsigned char *start, *end; // the unit, header included
	int version, offset_size, address_size;
	hlc_abbrev *abbrevs;
	int abbrev_count;
	uint64 addr_base, rnglists_base, str_offsets_base, low_pc;
	hlc_line_unit *lines;
} hlc_unit;

enum { HLC_VALUE_NONE, HLC_VALUE_NUMBER, HLC_VALUE_ADDRESS, HLC_VALUE_ADDRX, HLC_VALUE_STRING, HLC_VALUE_STRX, HLC_VALUE_REF,
	HLC_VALUE_RNGLISTX, HLC_VALUE_OFFSET };

typedef struct {
	int kind;
	uint64 number;
	const char *text;
} hlc_value;

static hlc_abbrev *hlc_read_abbrevs( const hlc_debug_sections *d, uint64 offset, int *count ) {
	const unsigned char *p = d->abbrev + offset, *end = d->abbrev + d->abbrev_size;
	int capacity = 64;
	hlc_abbrev *abbrevs = (hlc_abbrev*)malloc(sizeof(hlc_abbrev) * capacity);
	*count = 0;
	while( p < end ) {
		uint64 code = hlc_uleb(&p, end);
		if( code == 0 ) break;
		if( *count == capacity ) { capacity *= 2; abbrevs = (hlc_abbrev*)realloc(abbrevs, sizeof(hlc_abbrev) * capacity); }
		hlc_abbrev *a = abbrevs + (*count)++;
		a->code = code;
		a->tag = hlc_uleb(&p, end);
		a->children = *p++ != 0;
		int attr_capacity = 8;
		a->attrs = (hlc_abbrev_attr*)malloc(sizeof(hlc_abbrev_attr) * attr_capacity);
		a->count = 0;
		while( p < end ) {
			uint64 name = hlc_uleb(&p, end), form = hlc_uleb(&p, end);
			int64 implicit = form == 0x21 ? hlc_sleb(&p, end) : 0;
			if( name == 0 && form == 0 ) break;
			if( a->count == attr_capacity ) { attr_capacity *= 2; a->attrs = (hlc_abbrev_attr*)realloc(a->attrs, sizeof(hlc_abbrev_attr) * attr_capacity); }
			a->attrs[a->count].name = name;
			a->attrs[a->count].form = form;
			a->attrs[a->count].implicit = implicit;
			a->count++;
		}
	}
	return abbrevs;
}

static hlc_abbrev *hlc_find_abbrev( hlc_unit *u, uint64 code ) {
	// Codes are usually numbered from 1 in order.
	if( code >= 1 && code <= (uint64)u->abbrev_count && u->abbrevs[code - 1].code == code ) return u->abbrevs + code - 1;
	for(int i=0;i<u->abbrev_count;i++) if( u->abbrevs[i].code == code ) return u->abbrevs + i;
	return NULL;
}

/* Reads one attribute value of form `form`; false for a form this reader does not know, which ends the unit. */
static bool hlc_read_value( const unsigned char **p, const unsigned char *end, hlc_unit *u, const hlc_debug_sections *d, uint64 form,
	int64 implicit, hlc_value *v ) {
	v->kind = HLC_VALUE_NONE;
	v->number = 0;
	v->text = NULL;
	switch( form ) {
	case 0x01: v->kind = HLC_VALUE_ADDRESS; v->number = hlc_fixed(p, u->address_size); return true;
	case 0x03: *p += hlc_fixed(p, 2); return true;
	case 0x04: *p += hlc_fixed(p, 4); return true;
	case 0x05: v->kind = HLC_VALUE_NUMBER; v->number = hlc_fixed(p, 2); return true;
	case 0x06: v->kind = HLC_VALUE_NUMBER; v->number = hlc_fixed(p, 4); return true;
	case 0x07: v->kind = HLC_VALUE_NUMBER; v->number = hlc_fixed(p, 8); return true;
	case 0x08: v->kind = HLC_VALUE_STRING; v->text = (const char*)*p; while( *p < end && **p ) (*p)++; (*p)++; return true;
	case 0x09: case 0x18: { uint64 length = hlc_uleb(p, end); *p += length; return true; }
	case 0x0a: *p += hlc_fixed(p, 1); return true;
	case 0x0b: v->kind = HLC_VALUE_NUMBER; v->number = hlc_fixed(p, 1); return true;
	case 0x0c: *p += 1; return true;
	case 0x0d: v->kind = HLC_VALUE_NUMBER; v->number = (uint64)hlc_sleb(p, end); return true;
	case 0x0e: v->kind = HLC_VALUE_STRING; v->text = hlc_section_string(d->str, d->str_size, hlc_fixed(p, u->offset_size)); return true;
	case 0x0f: v->kind = HLC_VALUE_NUMBER; v->number = hlc_uleb(p, end); return true;
	case 0x10: *p += u->version <= 2 ? u->address_size : u->offset_size; return true; // ref_addr: another unit's, not followed
	case 0x11: v->kind = HLC_VALUE_REF; v->number = hlc_fixed(p, 1); return true;
	case 0x12: v->kind = HLC_VALUE_REF; v->number = hlc_fixed(p, 2); return true;
	case 0x13: v->kind = HLC_VALUE_REF; v->number = hlc_fixed(p, 4); return true;
	case 0x14: v->kind = HLC_VALUE_REF; v->number = hlc_fixed(p, 8); return true;
	case 0x15: v->kind = HLC_VALUE_REF; v->number = hlc_uleb(p, end); return true;
	case 0x16: { uint64 actual = hlc_uleb(p, end); return hlc_read_value(p, end, u, d, actual, implicit, v); }
	case 0x17: v->kind = HLC_VALUE_OFFSET; v->number = hlc_fixed(p, u->offset_size); return true;
	case 0x19: return true;
	case 0x1a: case 0x1f02: v->kind = HLC_VALUE_STRX; v->number = hlc_uleb(p, end); return true;
	case 0x1b: case 0x1f01: v->kind = HLC_VALUE_ADDRX; v->number = hlc_uleb(p, end); return true;
	case 0x1c: *p += 4; return true;
	case 0x1d: case 0x1f20: case 0x1f21: *p += u->offset_size; return true;
	case 0x1e: *p += 16; return true;
	case 0x1f: v->kind = HLC_VALUE_STRING; v->text = hlc_section_string(d->line_str, d->line_str_size, hlc_fixed(p, u->offset_size)); return true;
	case 0x20: *p += 8; return true;
	case 0x21: v->kind = HLC_VALUE_NUMBER; v->number = (uint64)implicit; return true;
	case 0x22: hlc_uleb(p, end); return true;
	case 0x23: v->kind = HLC_VALUE_RNGLISTX; v->number = hlc_uleb(p, end); return true;
	case 0x24: *p += 8; return true;
	case 0x25: v->kind = HLC_VALUE_STRX; v->number = hlc_fixed(p, 1); return true;
	case 0x26: v->kind = HLC_VALUE_STRX; v->number = hlc_fixed(p, 2); return true;
	case 0x27: v->kind = HLC_VALUE_STRX; v->number = hlc_fixed(p, 3); return true;
	case 0x28: v->kind = HLC_VALUE_STRX; v->number = hlc_fixed(p, 4); return true;
	case 0x29: v->kind = HLC_VALUE_ADDRX; v->number = hlc_fixed(p, 1); return true;
	case 0x2a: v->kind = HLC_VALUE_ADDRX; v->number = hlc_fixed(p, 2); return true;
	case 0x2b: v->kind = HLC_VALUE_ADDRX; v->number = hlc_fixed(p, 3); return true;
	case 0x2c: v->kind = HLC_VALUE_ADDRX; v->number = hlc_fixed(p, 4); return true;
	default: return false;
	}
}

static uint64 hlc_address( hlc_unit *u, const hlc_debug_sections *d, uint64 index ) {
	uint64 offset = u->addr_base + index * u->address_size;
	if( !d->addr || offset + u->address_size > d->addr_size ) return 0;
	const unsigned char *p = d->addr + offset;
	return hlc_fixed(&p, u->address_size);
}

static const char *hlc_string( hlc_unit *u, const hlc_debug_sections *d, const hlc_value *v ) {
	if( v->kind == HLC_VALUE_STRING ) return v->text;
	if( v->kind != HLC_VALUE_STRX || !d->str_offsets ) return NULL;
	uint64 offset = u->str_offsets_base + v->number * u->offset_size;
	if( offset + u->offset_size > d->str_offsets_size ) return NULL;
	const unsigned char *p = d->str_offsets + offset;
	return hlc_section_string(d->str, d->str_size, hlc_fixed(&p, u->offset_size));
}

/* The attributes of a DIE this reader uses. */
typedef struct {
	hlc_value name, low, high, ranges, origin, call_file, call_line;
	bool has_name, has_low, has_high, has_ranges, has_origin, has_call;
	uint64 stmt_list;
	bool has_stmt_list;
} hlc_die;

/* Reads the DIE at `*p` with abbreviation `a`; false when a form is unknown. */
static bool hlc_read_die( const unsigned char **p, const unsigned char *end, hlc_unit *u, const hlc_debug_sections *d, hlc_abbrev *a,
	hlc_die *die ) {
	memset(die, 0, sizeof(*die));
	for(int i=0;i<a->count;i++) {
		hlc_value v;
		if( !hlc_read_value(p, end, u, d, a->attrs[i].form, a->attrs[i].implicit, &v) ) return false;
		switch( a->attrs[i].name ) {
		case 0x03: die->name = v; die->has_name = true; break; // DW_AT_name
		case 0x6e: case 0x2007: if( !die->has_name ) { die->name = v; die->has_name = true; } break; // linkage names
		case 0x11: die->low = v; die->has_low = true; break;
		case 0x12: die->high = v; die->has_high = true; break;
		case 0x55: die->ranges = v; die->has_ranges = true; break;
		case 0x31: case 0x47: if( v.kind == HLC_VALUE_REF ) { die->origin = v; die->has_origin = true; } break; // abstract_origin, specification
		case 0x58: die->call_file = v; die->has_call = true; break;
		case 0x59: die->call_line = v; break;
		case 0x10: die->stmt_list = v.number; die->has_stmt_list = true; break;
		case 0x73: u->addr_base = v.number; break;
		case 0x74: u->rnglists_base = v.number; break;
		case 0x72: u->str_offsets_base = v.number; break;
		}
	}
	return true;
}

/* The name of the function a DIE is a body of: its own, or its abstract origin's or specification's, in the same unit. */
static const char *hlc_die_name( hlc_unit *u, const hlc_debug_sections *d, const hlc_die *die ) {
	hlc_die current = *die;
	for(int depth=0;depth<4;depth++) {
		if( current.has_name ) return hlc_string(u, d, &current.name);
		if( !current.has_origin ) return NULL;
		const unsigned char *p = u->start + current.origin.number, *end = u->end;
		if( p >= end ) return NULL;
		hlc_abbrev *a = hlc_find_abbrev(u, hlc_uleb(&p, end));
		if( !a || !hlc_read_die(&p, end, u, d, a, &current) ) return NULL;
	}
	return NULL;
}

static void hlc_add_scope_range( int scope, uintptr_t low, uintptr_t high ) {
	if( high <= low ) return;
	if( hlc_scope_range_count == hlc_scope_range_capacity ) {
		hlc_scope_range_capacity = hlc_scope_range_capacity ? hlc_scope_range_capacity * 2 : 4096;
		hlc_scope_ranges = (hlc_range*)realloc(hlc_scope_ranges, sizeof(hlc_range) * hlc_scope_range_capacity);
	}
	hlc_scope_ranges[hlc_scope_range_count].low = low;
	hlc_scope_ranges[hlc_scope_range_count].high = high;
	hlc_scope_ranges[hlc_scope_range_count].scope = scope;
	hlc_scope_range_count++;
	hlc_scopes[scope].range_count++;
}

/* Adds the address ranges of a DIE to scope `scope`, moved by `bias`. */
static void hlc_die_ranges( hlc_unit *u, const hlc_debug_sections *d, hlc_die *die, int scope, uintptr_t bias ) {
	if( die->has_low && die->has_high ) {
		uint64 low = die->low.kind == HLC_VALUE_ADDRX ? hlc_address(u, d, die->low.number) : die->low.number;
		uint64 high = die->high.kind == HLC_VALUE_ADDRX ? hlc_address(u, d, die->high.number)
			: die->high.kind == HLC_VALUE_ADDRESS ? die->high.number : low + die->high.number;
		hlc_add_scope_range(scope, (uintptr_t)low + bias, (uintptr_t)high + bias);
		return;
	}
	if( !die->has_ranges ) return;
	uint64 base = u->low_pc;
	if( u->version >= 5 ) {
		uint64 offset = die->ranges.number;
		if( die->ranges.kind == HLC_VALUE_RNGLISTX ) {
			const unsigned char *q = d->rnglists + u->rnglists_base + offset * u->offset_size;
			if( !d->rnglists || q + u->offset_size > d->rnglists + d->rnglists_size ) return;
			offset = u->rnglists_base + hlc_fixed(&q, u->offset_size);
		}
		if( !d->rnglists || offset >= d->rnglists_size ) return;
		const unsigned char *p = d->rnglists + offset, *end = d->rnglists + d->rnglists_size;
		while( p < end ) {
			int kind = *p++;
			uint64 a, b;
			switch( kind ) {
			case 0: return; // DW_RLE_end_of_list
			case 1: base = hlc_address(u, d, hlc_uleb(&p, end)); break;
			case 2: a = hlc_address(u, d, hlc_uleb(&p, end)); b = hlc_address(u, d, hlc_uleb(&p, end));
				hlc_add_scope_range(scope, (uintptr_t)a + bias, (uintptr_t)b + bias); break;
			case 3: a = hlc_address(u, d, hlc_uleb(&p, end)); b = a + hlc_uleb(&p, end);
				hlc_add_scope_range(scope, (uintptr_t)a + bias, (uintptr_t)b + bias); break;
			case 4: a = base + hlc_uleb(&p, end); b = base + hlc_uleb(&p, end);
				hlc_add_scope_range(scope, (uintptr_t)a + bias, (uintptr_t)b + bias); break;
			case 5: base = hlc_fixed(&p, u->address_size); break;
			case 6: a = hlc_fixed(&p, u->address_size); b = hlc_fixed(&p, u->address_size);
				hlc_add_scope_range(scope, (uintptr_t)a + bias, (uintptr_t)b + bias); break;
			case 7: a = hlc_fixed(&p, u->address_size); b = a + hlc_uleb(&p, end);
				hlc_add_scope_range(scope, (uintptr_t)a + bias, (uintptr_t)b + bias); break;
			default: return;
			}
		}
	} else {
		if( !d->ranges || die->ranges.number >= d->ranges_size ) return;
		const unsigned char *p = d->ranges + die->ranges.number, *end = d->ranges + d->ranges_size;
		uint64 all = u->address_size == 8 ? ~(uint64)0 : 0xffffffffu;
		while( p + 2 * u->address_size <= end ) {
			uint64 a = hlc_fixed(&p, u->address_size), b = hlc_fixed(&p, u->address_size);
			if( a == 0 && b == 0 ) return;
			if( a == all ) { base = b; continue; }
			hlc_add_scope_range(scope, (uintptr_t)(base + a) + bias, (uintptr_t)(base + b) + bias);
		}
	}
}

static int hlc_new_scope( int parent ) {
	if( hlc_scope_count == hlc_scope_capacity ) {
		hlc_scope_capacity = hlc_scope_capacity ? hlc_scope_capacity * 2 : 4096;
		hlc_scopes = (hlc_scope*)realloc(hlc_scopes, sizeof(hlc_scope) * hlc_scope_capacity);
	}
	hlc_scope *s = hlc_scopes + hlc_scope_count;
	memset(s, 0, sizeof(*s));
	s->parent = parent;
	s->next = hlc_scope_count + 1;
	s->first_range = hlc_scope_range_count;
	s->slot = -2;
	return hlc_scope_count++;
}

static hlc_line_unit *hlc_lines_at( uint64 offset ) {
	for(int i=0;i<hlc_line_unit_count;i++) if( hlc_line_units[i].offset == offset ) return hlc_line_units + i;
	return NULL;
}

/* Reads the scopes of one unit's DIE tree, keeping the subprograms in the generated code and the inlined bodies within them. */
static void hlc_read_unit_scopes( hlc_unit *u, const unsigned char *p, const hlc_debug_sections *d, uintptr_t bias ) {
	enum { MAX_DEPTH = 256 };
	int scope_at[MAX_DEPTH]; // the scope a DIE at each depth is in; -2 inside a subprogram outside the generated code
	int opened[MAX_DEPTH]; // the scope a DIE with children opened at each depth, or -1
	int depth = 0;
	scope_at[0] = -1;
	opened[0] = -1;
	while( p < u->end ) {
		uint64 code = hlc_uleb(&p, u->end);
		if( code == 0 ) {
			if( depth == 0 ) return;
			depth--;
			if( opened[depth] >= 0 ) hlc_scopes[opened[depth]].next = hlc_scope_count;
			continue;
		}
		hlc_abbrev *a = hlc_find_abbrev(u, code);
		hlc_die die;
		if( !a || !hlc_read_die(&p, u->end, u, d, a, &die) ) return;
		int current = scope_at[depth], made = -1, inner = current;
		if( a->tag == 0x11 ) { // DW_TAG_compile_unit
			u->low_pc = die.has_low ? (die.low.kind == HLC_VALUE_ADDRX ? hlc_address(u, d, die.low.number) : die.low.number) : 0;
			if( die.has_stmt_list ) u->lines = hlc_lines_at(die.stmt_list);
		} else if( a->tag == 0x2e && current == -1 && (die.has_low || die.has_ranges) ) { // DW_TAG_subprogram
			made = hlc_new_scope(-1);
			hlc_die_ranges(u, d, &die, made, bias);
			bool generated = false;
			for(int i=0;i<hlc_scopes[made].range_count;i++) {
				hlc_range *r = hlc_scope_ranges + hlc_scopes[made].first_range + i;
				if( r->low >= (uintptr_t)__start_hlc_text && r->low < (uintptr_t)__stop_hlc_text ) generated = true;
			}
			if( generated ) {
				hlc_scopes[made].name = hlc_die_name(u, d, &die);
				inner = made;
			} else {
				hlc_scope_range_count = hlc_scopes[made].first_range;
				hlc_scope_count--;
				made = -1;
				inner = -2;
			}
		} else if( a->tag == 0x1d && current >= 0 ) { // DW_TAG_inlined_subroutine
			made = hlc_new_scope(current);
			hlc_die_ranges(u, d, &die, made, bias);
			hlc_scope *s = hlc_scopes + made;
			s->name = hlc_die_name(u, d, &die);
			if( die.has_call && u->lines && die.call_file.number < (uint64)u->lines->count && u->lines->files[die.call_file.number] >= 0 )
				s->call_file = hlc_files[u->lines->files[die.call_file.number]];
			s->call_line = (int)die.call_line.number;
			inner = made;
		}
		if( a->children ) {
			if( depth + 1 >= MAX_DEPTH ) return;
			opened[depth] = made;
			depth++;
			scope_at[depth] = inner;
			opened[depth] = -1;
		}
	}
}

static int hlc_compare_ranges( const void *a, const void *b ) {
	uintptr_t x = ((const hlc_range*)a)->low, y = ((const hlc_range*)b)->low;
	return x < y ? -1 : x > y ? 1 : 0;
}

static void hlc_read_scopes( const hlc_debug_sections *d, uintptr_t bias ) {
	const unsigned char *p = d->info, *end = d->info + d->info_size;
	while( p + 4 <= end ) {
		hlc_unit u;
		memset(&u, 0, sizeof(u));
		u.start = p;
		u.offset_size = 4;
		uint64 length = hlc_fixed(&p, 4);
		if( length == 0xffffffff ) { length = hlc_fixed(&p, 8); u.offset_size = 8; }
		u.end = p + length;
		if( u.end > end || length < 2 ) break;
		u.version = (int)hlc_fixed(&p, 2);
		uint64 abbrev_offset;
		int unit_type = 1;
		if( u.version >= 5 ) {
			unit_type = *p++;
			u.address_size = *p++;
			abbrev_offset = hlc_fixed(&p, u.offset_size);
			if( unit_type == 2 || unit_type == 6 ) p += 8 + u.offset_size; // type units: signature and type offset
			else if( unit_type == 4 || unit_type == 5 ) p += 8; // skeleton and split units: the DWO id
		} else {
			abbrev_offset = hlc_fixed(&p, u.offset_size);
			u.address_size = *p++;
		}
		if( (unit_type == 1 || unit_type == 3) && abbrev_offset < d->abbrev_size && u.version >= 2 && u.version <= 5 ) {
			u.abbrevs = hlc_read_abbrevs(d, abbrev_offset, &u.abbrev_count);
			hlc_read_unit_scopes(&u, p, d, bias);
			for(int i=0;i<u.abbrev_count;i++) free(u.abbrevs[i].attrs);
			free(u.abbrevs);
		}
		p = u.end;
	}
	int count = 0;
	for(int i=0;i<hlc_scope_count;i++) if( hlc_scopes[i].parent < 0 ) count += hlc_scopes[i].range_count;
	hlc_subprograms = (hlc_range*)malloc(sizeof(hlc_range) * (count ? count : 1));
	for(int i=0;i<hlc_scope_count;i++)
		if( hlc_scopes[i].parent < 0 )
			for(int r=0;r<hlc_scopes[i].range_count;r++) hlc_subprograms[hlc_subprogram_count++] = hlc_scope_ranges[hlc_scopes[i].first_range + r];
	qsort(hlc_subprograms, hlc_subprogram_count, sizeof(hlc_range), hlc_compare_ranges);
}

static bool hlc_scope_holds( int scope, uintptr_t target ) {
	hlc_scope *s = hlc_scopes + scope;
	for(int i=0;i<s->range_count;i++) {
		hlc_range *r = hlc_scope_ranges + s->first_range + i;
		if( target >= r->low && target < r->high ) return true;
	}
	return false;
}

/* The innermost scope at the call before return address `address`, or -1. */
static int hlc_scope_at( void *address ) {
	uintptr_t target = (uintptr_t)address - 1;
	int low = 0, high = hlc_subprogram_count - 1, found = -1;
	while( low <= high ) {
		int middle = (low + high) >> 1;
		if( hlc_subprograms[middle].low <= target ) { found = middle; low = middle + 1; } else high = middle - 1;
	}
	if( found < 0 || target >= hlc_subprograms[found].high ) return -1;
	int scope = hlc_subprograms[found].scope;
	for(;;) {
		int child = scope + 1, inner = -1;
		while( child < hlc_scopes[scope].next ) {
			if( hlc_scope_holds(child, target) ) { inner = child; break; }
			child = hlc_scopes[child].next;
		}
		if( inner < 0 ) return scope;
		scope = inner;
	}
}

/* The slot of the generated function that starts at `address`, or -1. */
static int hlc_function_starting( uintptr_t address ) {
	int low = 0, high = hlc_start_count - 1;
	while( low <= high ) {
		int middle = (low + high) >> 1;
		if( hlc_starts[middle].start == address ) return hlc_starts[middle].slot;
		if( hlc_starts[middle].start < address ) low = middle + 1; else high = middle - 1;
	}
	return -1;
}

/* The slot of the generated function a scope is a body of, or -1 for any other (an inlined runtime helper). */
static int hlc_scope_slot( int scope ) {
	hlc_scope *s = hlc_scopes + scope;
	if( s->slot == -2 ) {
		void *f = s->name ? dlsym(RTLD_DEFAULT, s->name) : NULL;
		s->slot = f ? hlc_function_starting((uintptr_t)f) : -1;
	}
	return s->slot;
}
#endif

static int hlc_find_bias( struct dl_phdr_info *info, size_t size, void *data ) {
	(void)size;
	*(uintptr_t*)data = (uintptr_t)info->dlpi_addr;
	return 1; // the first object is the executable
}

/* Reads the executable's line table and, unless frames are exact, its inline records (`hlc_read_scopes`). */
static void hlc_read_debug( void ) {
	hlc_lines_state = -1;
	int fd = open("/proc/self/exe", O_RDONLY);
	if( fd < 0 ) return;
	struct stat st;
	if( fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(Elf64_Ehdr) ) { close(fd); return; }
	const unsigned char *image = (const unsigned char*)mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
	close(fd);
	if( image == MAP_FAILED ) return;
	const Elf64_Ehdr *header = (const Elf64_Ehdr*)image;
	if( memcmp(header->e_ident, ELFMAG, SELFMAG) != 0 || header->e_ident[EI_CLASS] != ELFCLASS64 ) return;
	const Elf64_Shdr *sections = (const Elf64_Shdr*)(image + header->e_shoff);
	const char *names = (const char*)image + sections[header->e_shstrndx].sh_offset;
	const unsigned char *lines = NULL;
	size_t lines_size = 0;
	hlc_strings strings = { NULL, NULL, 0, 0 };
#ifndef HLC_EXACT_FRAMES
	hlc_debug_sections d;
	memset(&d, 0, sizeof(d));
#endif
	for(int i=0;i<header->e_shnum;i++) {
		const char *name = names + sections[i].sh_name;
		// Compressed debug sections are not read: frames then have no line.
		if( sections[i].sh_flags & SHF_COMPRESSED ) continue;
		const unsigned char *data = image + sections[i].sh_offset;
		size_t size = sections[i].sh_size;
		if( strcmp(name, ".debug_line") == 0 ) { lines = data; lines_size = size; }
		else if( strcmp(name, ".debug_line_str") == 0 ) { strings.line_str = data; strings.line_str_size = size; }
		else if( strcmp(name, ".debug_str") == 0 ) { strings.str = data; strings.str_size = size; }
#ifndef HLC_EXACT_FRAMES
		else if( strcmp(name, ".debug_info") == 0 ) { d.info = data; d.info_size = size; }
		else if( strcmp(name, ".debug_abbrev") == 0 ) { d.abbrev = data; d.abbrev_size = size; }
		else if( strcmp(name, ".debug_rnglists") == 0 ) { d.rnglists = data; d.rnglists_size = size; }
		else if( strcmp(name, ".debug_ranges") == 0 ) { d.ranges = data; d.ranges_size = size; }
		else if( strcmp(name, ".debug_addr") == 0 ) { d.addr = data; d.addr_size = size; }
		else if( strcmp(name, ".debug_str_offsets") == 0 ) { d.str_offsets = data; d.str_offsets_size = size; }
#endif
	}
	if( !lines ) return;
	uintptr_t bias = 0;
	dl_iterate_phdr(hlc_find_bias, &bias);
	hlc_read_line_programs(lines, lines_size, &strings, bias);
	qsort(hlc_rows, hlc_row_count, sizeof(hlc_line_row), hlc_compare_rows);
#ifndef HLC_EXACT_FRAMES
	d.str = strings.str; d.str_size = strings.str_size;
	d.line_str = strings.line_str; d.line_str_size = strings.line_str_size;
	if( d.info && d.abbrev ) hlc_read_scopes(&d, bias);
#endif
	hlc_lines_state = 1; // the mapping stays: file and function names point into it
}

/* The Haxe file and line of the call before return address `address`. */
static bool hlc_line_of( void *address, const char **file, int *line ) {
	if( hlc_lines_state == 0 ) hlc_read_debug();
	if( hlc_lines_state < 0 ) return false;
	uintptr_t target = (uintptr_t)address - 1;
	int low = 0, high = hlc_row_count - 1, found = -1;
	while( low <= high ) {
		int middle = (low + high) >> 1;
		if( hlc_rows[middle].address <= target ) { found = middle; low = middle + 1; } else high = middle - 1;
	}
	if( found < 0 || hlc_rows[found].file < 0 ) return false;
	*file = hlc_files[hlc_rows[found].file];
	*line = hlc_rows[found].line;
	return true;
}

static uchar *hlc_frame_name( int slot, const char *file, int line, uchar *out, int *outSize ) {
	hl_code *code = hlc_module->code;
	hl_function *f = code->functions + hlc_module->functions_indexes[slot];
	const char *qualified = hl_code_function_name(code, f);
	int size = *outSize, pos = 0;
	if( qualified ) pos += hl_from_utf8(out, size, qualified);
	else if( f->obj ) pos += usprintf(out, size, USTR("%s.%s"), f->obj->name, f->field.name);
	else pos += usprintf(out, size, USTR("fun$%d"), f->findex);
	if( file ) {
		pos += usprintf(out + pos, size - pos, USTR("("));
		pos += hl_from_utf8(out + pos, size - pos, file);
		pos += usprintf(out + pos, size - pos, USTR(":%d)"), line);
	}
	*outSize = pos;
	return out;
}

/* Names a frame `hlc_capture_stack` captured: a return address names the innermost generated function at the call, with the
 * line of the call; an inlined scope names its caller, with the line where the caller calls it. */
static uchar *hlc_resolve_symbol( void *address, uchar *out, int *outSize ) {
	if( !out ) return NULL;
#ifndef HLC_EXACT_FRAMES
	if( hlc_scope_count && (hlc_scope*)address >= hlc_scopes && (hlc_scope*)address < hlc_scopes + hlc_scope_count ) {
		hlc_scope *s = (hlc_scope*)address;
		int slot = hlc_scope_slot(s->parent);
		return slot < 0 ? NULL : hlc_frame_name(slot, s->call_file, s->call_line, out, outSize);
	}
#endif
	if( !hlc_in_text(address) ) return NULL;
	const char *file = NULL;
	int line = 0;
	if( !hlc_line_of(address, &file, &line) ) file = NULL;
	int slot = -1;
#ifndef HLC_EXACT_FRAMES
	int scope = hlc_scope_at(address);
	if( scope >= 0 ) slot = hlc_scope_slot(scope);
#endif
	if( slot < 0 ) slot = hlc_function_at(address);
	if( slot < 0 ) return NULL;
	return hlc_frame_name(slot, file, line, out, outSize);
}

static void hlc_push_frame( void **stack, int size, int *count, void *frame ) {
	if( stack && *count < size ) stack[*count] = frame;
	(*count)++;
}

/* The program's frames on the stack, innermost first, as the JIT captures its own: the return address of each generated
 * function's frame, preceded by the frames of the generated functions the C compiler inlined at the call (their scopes). */
static int hlc_capture_stack( void **stack, int size ) {
	void *frames[HL_EXC_MAX_STACK + 64];
	int captured = backtrace(frames, HL_EXC_MAX_STACK + 64), count = 0;
#ifndef HLC_EXACT_FRAMES
	if( hlc_lines_state == 0 ) hlc_read_debug();
#endif
	for(int i=0;i<captured;i++) {
		if( !hlc_in_text(frames[i]) ) continue;
#ifndef HLC_EXACT_FRAMES
		int chain[64], depth = 0, pushed = 0;
		for(int scope = hlc_scope_count ? hlc_scope_at(frames[i]) : -1;scope >= 0 && depth < 64;scope = hlc_scopes[scope].parent)
			chain[depth++] = scope;
		// A level that is not a generated function (an inlined runtime helper) has no frame of its own: the generated level
		// around it is named at the line where it calls the helper.
		for(int level=0;level<depth;level++)
			if( hlc_scope_slot(chain[level]) >= 0 ) {
				hlc_push_frame(stack, size, &count, level == 0 ? frames[i] : (void*)(hlc_scopes + chain[level - 1]));
				pushed++;
			}
		if( pushed ) continue;
#endif
		hlc_push_frame(stack, size, &count, frames[i]);
	}
	return stack && count > size ? size : count;
}

void hlc_stack_init( hl_module *m, void **functions, int count ) {
	hlc_module = m;
	hlc_starts = (hlc_function_start*)malloc(sizeof(hlc_function_start) * (count ? count : 1));
	for(int i=0;i<count;i++)
		if( functions[i] ) {
			hlc_starts[hlc_start_count].start = (uintptr_t)functions[i];
			hlc_starts[hlc_start_count].slot = i;
			hlc_start_count++;
		}
	qsort(hlc_starts, hlc_start_count, sizeof(hlc_function_start), hlc_compare_starts);
	hl_setup.resolve_symbol = hlc_resolve_symbol;
	hl_setup.capture_stack = hlc_capture_stack;
}

#else

static uchar *hlc_resolve_symbol( void *address, uchar *out, int *outSize ) {
	(void)address; (void)out; (void)outSize;
	return NULL;
}

static int hlc_capture_stack( void **stack, int size ) {
	(void)stack; (void)size;
	return 0;
}

/* Elsewhere frames are not captured yet: exceptions carry no stack. */
void hlc_stack_init( hl_module *m, void **functions, int count ) {
	(void)m; (void)functions; (void)count;
	hl_setup.resolve_symbol = hlc_resolve_symbol;
	hl_setup.capture_stack = hlc_capture_stack;
}

#endif
