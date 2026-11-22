/* Haxe stack traces for a program Haxeon compiled to C (docs/design/AOT_BACKEND.md). The generated functions are in their own
 * section (`hlc_text` in ELF, `.text$hlc.2` in PE), so a captured frame is the program's exactly when its return address is in
 * that section, as a JIT frame is when it is in the module's code. A frame is named as the JIT names it: the function's identity
 * from the module image, and the Haxe file and line the C compiler's line table gives for the call (`#line` in the generated
 * code). The line table is read from the executable's own DWARF `.debug_line` the first time a frame is resolved (inflated
 * first where a release build compressed its DWARF, SHF_COMPRESSED with zlib): an ELF
 * executable's on Linux, or a PE executable's that MinGW built on Windows (GCC writes DWARF there too; the return addresses come
 * from the system unwinder, which reads the SEH unwind tables GCC writes for every function). Where the C compiler inlined
 * generated functions into each other (release builds; development builds define HLC_EXACT_FRAMES and inline none), the DWARF
 * inline records restore their frames. With MSVC's compilers (cl, clang-cl) the line tables and inline records are in the PDB
 * beside the executable, read through DbgHelp. */
#include <hl.h>
#include <hlmodule.h>

void hlc_stack_init( hl_module *m, void **functions, int count );

/* The names of the generated functions, sorted, with their slots (image.c): an inlined scope is a frame when its function is one. */
typedef struct {
	const char *name;
	int slot;
} hlc_function_name;
extern const hlc_function_name hlc_function_names[];
extern const int hlc_function_name_count;

#if defined(__linux__) && defined(__ELF__)
#define HLC_STACK_ELF
#elif defined(_WIN32) && defined(__GNUC__)
#define HLC_STACK_PE
#elif defined(_WIN32) && defined(_MSC_VER)
#define HLC_STACK_PDB
#endif
#if defined(HLC_STACK_ELF) || defined(HLC_STACK_PE)
#define HLC_STACK_DWARF
#endif

#if defined(HLC_STACK_DWARF) || defined(HLC_STACK_PDB)
#ifdef HLC_STACK_ELF
#include <elf.h>
#include <execinfo.h>
#include <fcntl.h>
#include <link.h>
#include <pthread.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#define Z_PREFIX
#include <zlib.h>

extern char __start_hlc_text[], __stop_hlc_text[];
#define hlc_text_begin __start_hlc_text
#define hlc_text_end __stop_hlc_text
#else
#include <windows.h>

/* The generated code's section is `.text$hlc.2`; the linker sorts `.text$` sections by the name after `$` (GNU ld's
 * SORT(.text$*), as link.exe groups them), so these two bound it. `.` is in no C symbol name, so no COMDAT section of a
 * function sorts between them. */
#ifdef HLC_STACK_PE
__attribute__((section(".text$hlc.1"), used, noinline)) void hlc_text_first( void ) {}
__attribute__((section(".text$hlc.3"), used, noinline)) void hlc_text_last( void ) {}
#else
#include <dbghelp.h>
// The link folds no identical functions (`/OPT:NOICF`, HlcBuild), so the two stay apart.
__declspec(code_seg(".text$hlc.1")) __declspec(noinline) void hlc_text_first( void ) {}
__declspec(code_seg(".text$hlc.3")) __declspec(noinline) void hlc_text_last( void ) {}
#endif
#define hlc_text_begin ((char*)hlc_text_first)
#define hlc_text_end ((char*)hlc_text_last)
#endif

typedef struct {
	uintptr_t start;
	int slot;
} hlc_function_start;

static hl_module *hlc_module;
static hlc_function_start *hlc_starts;
static int hlc_start_count;

static bool hlc_in_text( void *address ) {
	char *a = (char*)address - 1; // a return address can be just past a call that does not return
	return a >= hlc_text_begin && a < hlc_text_end;
}

static int hlc_compare_starts( const void *a, const void *b ) {
	uintptr_t x = ((const hlc_function_start*)a)->start, y = ((const hlc_function_start*)b)->start;
	return x < y ? -1 : x > y ? 1 : 0;
}

/* The slot of the generated function whose code holds the call before return address `address`, or -1. */
static int hlc_function_at( void *address ) {
	uintptr_t target = (uintptr_t)address - 1;
	int low = 0, high = hlc_start_count - 1, found = -1;
	while( low <= high ) {
		int middle = (low + high) >> 1;
		if( hlc_starts[middle].start <= target ) { found = middle; low = middle + 1; } else high = middle - 1;
	}
	return found < 0 ? -1 : hlc_starts[found].slot;
}

#if !defined(HLC_EXACT_FRAMES) || defined(HLC_STACK_PDB)
/* The slot of the generated function of C name `name`, or -1. */
static int hlc_function_named( const char *name ) {
	int low = 0, high = hlc_function_name_count - 1;
	while( low <= high ) {
		int middle = (low + high) >> 1, order = strcmp(hlc_function_names[middle].name, name);
		if( order == 0 ) return hlc_function_names[middle].slot;
		if( order < 0 ) low = middle + 1; else high = middle - 1;
	}
	return -1;
}
#endif

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

static void hlc_push_frame( void **stack, int size, int *count, void *frame ) {
	if( stack && *count < size ) stack[*count] = frame;
	(*count)++;
}

#ifdef HLC_STACK_DWARF
typedef struct {
	uintptr_t address;
	int file; // index in hlc_files; -1 ends a sequence
	int line;
} hlc_line_row;

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

static int hlc_compare_rows( const void *a, const void *b ) {
	const hlc_line_row *x = (const hlc_line_row*)a, *y = (const hlc_line_row*)b;
	if( x->address != y->address ) return x->address < y->address ? -1 : 1;
	// At one address a sequence's end goes before the next sequence's start.
	return (x->file >= 0) - (y->file >= 0);
}

/* Sorts the line rows by address, keeping the program order of rows at one address (the last of them is the address's line):
 * qsort is not stable everywhere (it is not in Windows' C runtime), so this is a merge sort. */
static void hlc_sort_rows( hlc_line_row *rows, int count ) {
	hlc_line_row *buffer = (hlc_line_row*)malloc(sizeof(hlc_line_row) * (count ? count : 1)), *from = rows, *to = buffer;
	for(int width=1;width<count;width*=2) {
		for(int low=0;low<count;low+=2*width) {
			int middle = low + width < count ? low + width : count, high = low + 2 * width < count ? low + 2 * width : count;
			int a = low, b = middle, k = low;
			while( a < middle && b < high ) to[k++] = hlc_compare_rows(from + b, from + a) < 0 ? from[b++] : from[a++];
			while( a < middle ) to[k++] = from[a++];
			while( b < high ) to[k++] = from[b++];
		}
		hlc_line_row *swap = from; from = to; to = swap;
	}
	if( from != rows ) memcpy(rows, from, sizeof(hlc_line_row) * count);
	free(buffer);
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
	if( address < (uintptr_t)hlc_text_begin || address > (uintptr_t)hlc_text_end ) return;
	if( hlc_row_count == hlc_row_capacity ) {
		hlc_row_capacity = hlc_row_capacity ? hlc_row_capacity * 2 : 4096;
		hlc_rows = (hlc_line_row*)realloc(hlc_rows, sizeof(hlc_line_row) * hlc_row_capacity);
	}
	hlc_rows[hlc_row_count].address = address;
	hlc_rows[hlc_row_count].file = file;
	hlc_rows[hlc_row_count].line = line;
	hlc_row_count++;
}

/* The source paths the generated `#line` directives name, as written (image.c). */
extern const char *const hlc_source_paths[];
extern const int hlc_source_path_count;

typedef struct {
	char *absolute;
	const char *path;
} hlc_source_path;

static hlc_source_path *hlc_sources;
static char *hlc_sources_base;

static bool hlc_absolute( const char *path ) {
#ifdef HLC_STACK_PE
	if( path[0] == '\\' || (path[0] && path[1] == ':') ) return true;
#endif
	return path[0] == '/';
}

/* A copy of `path` to compare with others: on Windows, either separator is `/`. */
static char *hlc_comparable( char *path ) {
#ifdef HLC_STACK_PE
	for(char *c = path;*c;c++) if( *c == '\\' ) *c = '/';
#endif
	return path;
}

static char *hlc_join( const char *a, const char *b ) {
	size_t la = strlen(a), lb = strlen(b);
	char *r = (char*)malloc(la + lb + 2);
	memcpy(r, a, la);
	r[la] = '/';
	memcpy(r + la + 1, b, lb + 1);
	return r;
}

static int hlc_compare_sources( const void *a, const void *b ) {
	return strcmp(((const hlc_source_path*)a)->absolute, ((const hlc_source_path*)b)->absolute);
}

/* The path a `#line` directive wrote, for a file of a line table. The C compiler splits it into a directory and a name, and
 * keeps a path under its working directory (directory 0, `base`) relative to it, so `/work/Main.hx` and `Main.hx` read the
 * same: the file's absolute path is matched against the directives' paths made absolute from `base`. */
static const char *hlc_source_name( const char *base, const char *dir, int dir_index, const char *name ) {
	if( !name ) return NULL;
	const char *written = dir_index == 0 || !dir || hlc_absolute(name) ? name : hlc_join(dir, name);
	if( !base || !hlc_absolute(base) ) return written;
	if( !hlc_sources_base || strcmp(hlc_sources_base, base) != 0 ) {
		if( !hlc_sources ) hlc_sources = (hlc_source_path*)malloc(sizeof(hlc_source_path) * (hlc_source_path_count ? hlc_source_path_count : 1));
		else for(int i=0;i<hlc_source_path_count;i++) free(hlc_sources[i].absolute);
		free(hlc_sources_base);
		hlc_sources_base = strdup(base);
		for(int i=0;i<hlc_source_path_count;i++) {
			const char *path = hlc_source_paths[i];
			hlc_sources[i].absolute = hlc_comparable(hlc_absolute(path) ? strdup(path) : hlc_join(base, path));
			hlc_sources[i].path = path;
		}
		qsort(hlc_sources, hlc_source_path_count, sizeof(hlc_source_path), hlc_compare_sources);
	}
	hlc_source_path key;
	key.absolute = hlc_comparable(hlc_absolute(written) ? strdup(written) : hlc_join(base, written));
	hlc_source_path *found = (hlc_source_path*)bsearch(&key, hlc_sources, hlc_source_path_count, sizeof(hlc_source_path), hlc_compare_sources);
	free(key.absolute);
	return found ? found->path : written;
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
		const char *dirs[256];
		int ndirs = 0;
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
					int dir = 0;
					for(int i=0;i<nformats && i<16;i++) {
						const char *text; uint64 number;
						if( !hlc_read_form(&p, unit_end, forms[i], offset_size, strings, &text, &number) ) { free(files); return; }
						if( types[i] == 1 ) name = text; // DW_LNCT_path
						else if( types[i] == 2 ) dir = (int)number; // DW_LNCT_directory_index
					}
					if( table == 0 ) { if( ndirs < 256 ) dirs[ndirs++] = name; }
					else files[nfiles++] = hlc_add_file(hlc_source_name(ndirs ? dirs[0] : NULL, dir < ndirs ? dirs[dir] : NULL, dir, name));
				}
			}
		} else {
			dirs[ndirs++] = NULL; // directory 0 is the compilation's, not in the table
			while( p < unit_end && *p ) {
				if( ndirs < 256 ) dirs[ndirs++] = (const char*)p;
				while( p < unit_end && *p ) p++;
				p++;
			}
			p++;
			files = (int*)malloc(sizeof(int) * 256);
			int capacity = 256;
			files[nfiles++] = hlc_add_file(NULL); // file numbers start at 1
			while( p < unit_end && *p ) {
				const char *name = (const char*)p;
				while( p < unit_end && *p ) p++;
				p++;
				int dir = (int)hlc_uleb(&p, unit_end);
				hlc_uleb(&p, unit_end); hlc_uleb(&p, unit_end);
				if( nfiles == capacity ) { capacity *= 2; files = (int*)realloc(files, sizeof(int) * capacity); }
				files[nfiles++] = hlc_add_file(hlc_source_name(NULL, dir < ndirs ? dirs[dir] : NULL, dir, name));
			}
		}
		p = program;
		uint64 address = 0;
		// The file register starts at 1 in every version: in DWARF 5, whose file numbers start at 0, file 1 is the first file the
		// compiler entered, not always the unit's own (file 0), as when the first row comes after a `#line`.
		int file = 1, line = 1;
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
					address = 0; file = 1; line = 1;
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

typedef struct {
	const unsigned char *line,
		*info, *abbrev, *rnglists, *ranges, *addr, *str, *str_offsets, *line_str;
	size_t line_size, info_size, abbrev_size, rnglists_size, ranges_size, addr_size, str_size, str_offsets_size, line_str_size;
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

static hlc_debug_sections hlc_debug;
#ifdef HLC_STACK_ELF
static const unsigned char *hlc_line_compressed; // a compressed .debug_line, inflated the first time a frame is named
static size_t hlc_line_compressed_size;
#endif
static uintptr_t hlc_bias;
static int hlc_image_state; // 0 not mapped, 1 mapped, -1 unavailable

/* The slot of debug section `name` if the stack traces read it, else NULL. */
static const unsigned char **hlc_debug_slot( const char *name, size_t **size ) {
	hlc_debug_sections *d = &hlc_debug;
#define HLC_SECTION(text, field) if( strcmp(name, text) == 0 ) { *size = &d->field##_size; return &d->field; }
	HLC_SECTION(".debug_line", line)
	HLC_SECTION(".debug_line_str", line_str)
	HLC_SECTION(".debug_str", str)
	HLC_SECTION(".debug_info", info)
	HLC_SECTION(".debug_abbrev", abbrev)
	HLC_SECTION(".debug_rnglists", rnglists)
	HLC_SECTION(".debug_ranges", ranges)
	HLC_SECTION(".debug_addr", addr)
	HLC_SECTION(".debug_str_offsets", str_offsets)
#undef HLC_SECTION
	return NULL;
}

/* Keeps a debug section the stack traces read. */
static void hlc_debug_section( const char *name, const unsigned char *data, size_t size ) {
	size_t *size_slot;
	const unsigned char **slot = hlc_debug_slot(name, &size_slot);
	if( slot ) { *slot = data; *size_slot = size; }
}

#ifdef HLC_STACK_ELF
static int hlc_find_bias( struct dl_phdr_info *info, size_t size, void *data ) {
	(void)size;
	*(uintptr_t*)data = (uintptr_t)info->dlpi_addr;
	return 1; // the first object is the executable
}

/* A compressed debug section's contents (SHF_COMPRESSED: an Elf64_Chdr, then the data), inflated with the zlib libhl carries; null
 * for another codec or a damaged section. Release builds compress their DWARF (`HlcBuild`), as gdb, perf and addr2line read it. */
static unsigned char *hlc_inflate_section( const unsigned char *data, size_t size, size_t *out_size ) {
	if( size < sizeof(Elf64_Chdr) ) return NULL;
	const Elf64_Chdr *header = (const Elf64_Chdr*)data;
	if( header->ch_type != ELFCOMPRESS_ZLIB || header->ch_size == 0 ) return NULL;
	unsigned char *out = (unsigned char*)malloc(header->ch_size);
	if( out == NULL ) return NULL;
	z_stream z;
	memset(&z, 0, sizeof(z));
	z.next_in = (Bytef*)(data + sizeof(Elf64_Chdr));
	z.avail_in = (uInt)(size - sizeof(Elf64_Chdr));
	z.next_out = out;
	z.avail_out = (uInt)header->ch_size;
	bool done = inflateInit(&z) == Z_OK && inflate(&z, Z_FINISH) == Z_STREAM_END && z.total_out == header->ch_size;
	inflateEnd(&z);
	if( !done ) { free(out); return NULL; }
	*out_size = header->ch_size;
	return out;
}

/* Maps the executable and finds its debug sections, inflating the compressed ones; nothing is read until a frame needs it. */
static bool hlc_open_image( void ) {
	if( hlc_image_state ) return hlc_image_state > 0;
	hlc_image_state = -1;
	int fd = open("/proc/self/exe", O_RDONLY);
	if( fd < 0 ) return false;
	struct stat st;
	if( fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(Elf64_Ehdr) ) { close(fd); return false; }
	const unsigned char *image = (const unsigned char*)mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
	close(fd);
	if( image == MAP_FAILED ) return false;
	const Elf64_Ehdr *header = (const Elf64_Ehdr*)image;
	if( memcmp(header->e_ident, ELFMAG, SELFMAG) != 0 || header->e_ident[EI_CLASS] != ELFCLASS64 ) return false;
	const Elf64_Shdr *sections = (const Elf64_Shdr*)(image + header->e_shoff);
	const char *names = (const char*)image + sections[header->e_shstrndx].sh_offset;
	for(int i=0;i<header->e_shnum;i++) {
		const unsigned char *data = image + sections[i].sh_offset;
		size_t size = sections[i].sh_size;
		const char *name = names + sections[i].sh_name;
		if( sections[i].sh_flags & SHF_COMPRESSED ) {
			// Only the sections the traces read are inflated; one that cannot be leaves frames without lines. The line table, the
			// largest, waits until a frame is named, as an uncompressed one is read then.
			size_t *unused;
			if( hlc_debug_slot(name, &unused) == NULL ) continue;
			if( strcmp(name, ".debug_line") == 0 ) { hlc_line_compressed = data; hlc_line_compressed_size = size; continue; }
			data = hlc_inflate_section(data, size, &size);
			if( data == NULL ) continue;
		}
		hlc_debug_section(name, data, size);
	}
	dl_iterate_phdr(hlc_find_bias, &hlc_bias);
	hlc_image_state = 1; // the mapping stays: file and function names point into it
	return true;
}
#else
/* Maps the executable's file and finds its debug sections. Their names are longer than a PE section name's 8 bytes, so they are
 * `/N`: offset N in the COFF string table, after the symbol table. DWARF addresses are virtual addresses at the image's
 * preferred base; the bias is where the loader put it instead. */
static bool hlc_open_image( void ) {
	if( hlc_image_state ) return hlc_image_state > 0;
	hlc_image_state = -1;
	wchar_t path[MAX_PATH * 4];
	DWORD length = GetModuleFileNameW(NULL, path, MAX_PATH * 4);
	if( length == 0 || length >= MAX_PATH * 4 ) return false;
	HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, 0, NULL);
	if( file == INVALID_HANDLE_VALUE ) return false;
	LARGE_INTEGER size;
	HANDLE mapping = GetFileSizeEx(file, &size) ? CreateFileMappingW(file, NULL, PAGE_READONLY, 0, 0, NULL) : NULL;
	CloseHandle(file);
	if( !mapping ) return false;
	const unsigned char *image = (const unsigned char*)MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, 0);
	CloseHandle(mapping);
	if( !image ) return false;
	const IMAGE_DOS_HEADER *dos = (const IMAGE_DOS_HEADER*)image;
	if( dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew <= 0 || dos->e_lfanew > size.QuadPart - (LONGLONG)sizeof(IMAGE_NT_HEADERS64) ) return false;
	const IMAGE_NT_HEADERS64 *nt = (const IMAGE_NT_HEADERS64*)(image + dos->e_lfanew);
	if( nt->Signature != IMAGE_NT_SIGNATURE || nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC ) return false;
	const IMAGE_SECTION_HEADER *sections = IMAGE_FIRST_SECTION(nt);
	const char *strings = nt->FileHeader.PointerToSymbolTable
		? (const char*)image + nt->FileHeader.PointerToSymbolTable + nt->FileHeader.NumberOfSymbols * 18 : NULL;
	for(int i=0;i<nt->FileHeader.NumberOfSections;i++) {
		char shortName[IMAGE_SIZEOF_SHORT_NAME + 1];
		const char *name = shortName;
		memcpy(shortName, sections[i].Name, IMAGE_SIZEOF_SHORT_NAME);
		shortName[IMAGE_SIZEOF_SHORT_NAME] = 0;
		if( shortName[0] == '/' ) {
			if( !strings ) continue;
			name = strings + atoi(shortName + 1);
		}
		DWORD raw = sections[i].SizeOfRawData, virtualSize = sections[i].Misc.VirtualSize;
		if( (LONGLONG)sections[i].PointerToRawData + raw > size.QuadPart ) continue;
		// The raw size is rounded up to the file alignment; the virtual size is the section's own.
		hlc_debug_section(name, image + sections[i].PointerToRawData, virtualSize && virtualSize < raw ? virtualSize : raw);
	}
	hlc_bias = (uintptr_t)GetModuleHandleW(NULL) - (uintptr_t)nt->OptionalHeader.ImageBase;
	hlc_image_state = 1; // the mapping stays: file and function names point into it
	return true;
}
#endif

/* Reads the executable's line table, the first time a frame is named. */
static void hlc_read_lines( void ) {
	hlc_lines_state = -1;
	if( !hlc_open_image() ) return;
#ifdef HLC_STACK_ELF
	if( !hlc_debug.line && hlc_line_compressed )
		hlc_debug.line = hlc_inflate_section(hlc_line_compressed, hlc_line_compressed_size, &hlc_debug.line_size);
#endif
	if( !hlc_debug.line ) return;
	hlc_strings strings = { hlc_debug.line_str, hlc_debug.str, hlc_debug.line_str_size, hlc_debug.str_size };
	hlc_read_line_programs(hlc_debug.line, hlc_debug.line_size, &strings, hlc_bias);
	hlc_sort_rows(hlc_rows, hlc_row_count);
	hlc_lines_state = 1;
}

/* The Haxe file and line of the call before return address `address`. */
static bool hlc_line_of( void *address, const char **file, int *line ) {
	if( hlc_lines_state == 0 ) hlc_read_lines();
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

#ifndef HLC_EXACT_FRAMES
/* Inlined frames. Where the C compiler inlined a generated function into another, the return address of a frame lies in the
 * inlined code, and the DWARF inline records (`.debug_info`: DW_TAG_inlined_subroutine, with the call's file and line) restore
 * the frames the inlining removed. Each record is a scope: a function body at some address ranges, inside its caller's scope;
 * a subprogram's scope is the outermost. A compilation unit's scopes are read the first time a frame is in it (an index of the
 * units by address is read the first time any frame is captured), kept in DIE order, each with the index past its subtree, so
 * a lookup descends from the subprogram of an address through the children whose ranges hold it. Scopes are stored in chunks
 * that never move, so a captured frame can point at one. */
typedef struct {
	int parent; // -1 for a subprogram
	int next; // the index past this scope's subtree
	int first_range, range_count;
	const char *name; // the C name of the function this is the body of
	uint64 stmt_list; // the unit's line program, whose file table call_file indexes
	int call_file, call_line; // where the parent calls it, for an inlined scope
	int slot; // the generated function's slot, -1 if it is not one, -2 not looked up yet
} hlc_scope;

typedef struct {
	uintptr_t low, high;
	int tag; // a scope, or a unit
} hlc_range;

typedef struct {
	hlc_range *items;
	int count, capacity;
} hlc_ranges;

typedef struct {
	const unsigned char *header; // in .debug_info
	bool read;
	hlc_ranges subprograms; // its subprograms' ranges, sorted, once read
} hlc_unit_entry;

#define HLC_SCOPE_CHUNK 4096
static hlc_scope **hlc_scope_chunks;
static int hlc_scope_count, hlc_scope_chunk_count;
static hlc_ranges hlc_scope_ranges; // each scope's ranges, by first_range
static hlc_unit_entry *hlc_units;
static int hlc_unit_count;
static hlc_ranges hlc_unit_ranges; // the units' ranges in the generated code, sorted
static int hlc_units_state; // 0 not indexed, 1 indexed, -1 unavailable

#define HLC_SCOPE(i) (hlc_scope_chunks[(i) / HLC_SCOPE_CHUNK] + (i) % HLC_SCOPE_CHUNK)

typedef struct {
	const unsigned char *start, *end; // the unit, header included
	const unsigned char *first; // its first DIE
	int version, offset_size, address_size;
	hlc_abbrev *abbrevs;
	int abbrev_count;
	uint64 addr_base, rnglists_base, str_offsets_base, low_pc, stmt_list;
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

static void hlc_push_range( hlc_ranges *v, uintptr_t low, uintptr_t high, int tag ) {
	if( high <= low ) return;
	if( v->count == v->capacity ) {
		v->capacity = v->capacity ? v->capacity * 2 : 64;
		v->items = (hlc_range*)realloc(v->items, sizeof(hlc_range) * v->capacity);
	}
	v->items[v->count].low = low;
	v->items[v->count].high = high;
	v->items[v->count].tag = tag;
	v->count++;
}

/* Adds the address ranges of a DIE to `out`, moved by the executable's bias and tagged `tag`. */
static void hlc_die_ranges( hlc_unit *u, const hlc_debug_sections *d, hlc_die *die, hlc_ranges *out, int tag ) {
	uintptr_t bias = hlc_bias;
	if( die->has_low && die->has_high ) {
		uint64 low = die->low.kind == HLC_VALUE_ADDRX ? hlc_address(u, d, die->low.number) : die->low.number;
		uint64 high = die->high.kind == HLC_VALUE_ADDRX ? hlc_address(u, d, die->high.number)
			: die->high.kind == HLC_VALUE_ADDRESS ? die->high.number : low + die->high.number;
		hlc_push_range(out, (uintptr_t)low + bias, (uintptr_t)high + bias, tag);
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
				hlc_push_range(out, (uintptr_t)a + bias, (uintptr_t)b + bias, tag); break;
			case 3: a = hlc_address(u, d, hlc_uleb(&p, end)); b = a + hlc_uleb(&p, end);
				hlc_push_range(out, (uintptr_t)a + bias, (uintptr_t)b + bias, tag); break;
			case 4: a = base + hlc_uleb(&p, end); b = base + hlc_uleb(&p, end);
				hlc_push_range(out, (uintptr_t)a + bias, (uintptr_t)b + bias, tag); break;
			case 5: base = hlc_fixed(&p, u->address_size); break;
			case 6: a = hlc_fixed(&p, u->address_size); b = hlc_fixed(&p, u->address_size);
				hlc_push_range(out, (uintptr_t)a + bias, (uintptr_t)b + bias, tag); break;
			case 7: a = hlc_fixed(&p, u->address_size); b = a + hlc_uleb(&p, end);
				hlc_push_range(out, (uintptr_t)a + bias, (uintptr_t)b + bias, tag); break;
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
			hlc_push_range(out, (uintptr_t)(base + a) + bias, (uintptr_t)(base + b) + bias, tag);
		}
	}
}

static int hlc_new_scope( int parent ) {
	if( hlc_scope_count == hlc_scope_chunk_count * HLC_SCOPE_CHUNK ) {
		hlc_scope_chunks = (hlc_scope**)realloc(hlc_scope_chunks, sizeof(hlc_scope*) * (hlc_scope_chunk_count + 1));
		hlc_scope_chunks[hlc_scope_chunk_count++] = (hlc_scope*)malloc(sizeof(hlc_scope) * HLC_SCOPE_CHUNK);
	}
	hlc_scope *s = HLC_SCOPE(hlc_scope_count);
	memset(s, 0, sizeof(*s));
	s->parent = parent;
	s->next = hlc_scope_count + 1;
	s->first_range = hlc_scope_ranges.count;
	s->slot = -2;
	return hlc_scope_count++;
}

/* Reads a unit's header at `p`; false for a unit this reader does not read (type and split units, unknown versions). */
static bool hlc_read_unit_header( const unsigned char *p, hlc_unit *u ) {
	const hlc_debug_sections *d = &hlc_debug;
	const unsigned char *end = d->info + d->info_size;
	memset(u, 0, sizeof(*u));
	u->start = p;
	u->offset_size = 4;
	uint64 length = hlc_fixed(&p, 4);
	if( length == 0xffffffff ) { length = hlc_fixed(&p, 8); u->offset_size = 8; }
	u->end = p + length;
	if( u->end > end || length < 2 ) { u->end = end; return false; }
	u->version = (int)hlc_fixed(&p, 2);
	uint64 abbrev_offset;
	int unit_type = 1;
	if( u->version >= 5 ) {
		unit_type = *p++;
		u->address_size = *p++;
		abbrev_offset = hlc_fixed(&p, u->offset_size);
		if( unit_type == 2 || unit_type == 6 ) p += 8 + u->offset_size; // type units: signature and type offset
		else if( unit_type == 4 || unit_type == 5 ) p += 8; // skeleton and split units: the DWO id
	} else {
		abbrev_offset = hlc_fixed(&p, u->offset_size);
		u->address_size = *p++;
	}
	if( (unit_type != 1 && unit_type != 3) || abbrev_offset >= d->abbrev_size || u->version < 2 || u->version > 5 ) return false;
	u->first = p;
	u->abbrevs = hlc_read_abbrevs(d, abbrev_offset, &u->abbrev_count);
	return true;
}

static void hlc_free_unit( hlc_unit *u ) {
	for(int i=0;i<u->abbrev_count;i++) free(u->abbrevs[i].attrs);
	free(u->abbrevs);
}

/* Reads a unit's own DIE, the first; returns it in `die`. */
static bool hlc_read_unit_die( hlc_unit *u, hlc_die *die, const unsigned char **next ) {
	const unsigned char *p = u->first;
	hlc_abbrev *a = hlc_find_abbrev(u, hlc_uleb(&p, u->end));
	if( !a || a->tag != 0x11 || !hlc_read_die(&p, u->end, u, &hlc_debug, a, die) ) return false; // DW_TAG_compile_unit
	u->low_pc = die->has_low ? (die->low.kind == HLC_VALUE_ADDRX ? hlc_address(u, &hlc_debug, die->low.number) : die->low.number) : 0;
	u->stmt_list = die->stmt_list;
	*next = p;
	return a->children;
}

static int hlc_compare_ranges( const void *a, const void *b ) {
	uintptr_t x = ((const hlc_range*)a)->low, y = ((const hlc_range*)b)->low;
	return x < y ? -1 : x > y ? 1 : 0;
}

/* The index of the units by the addresses of the generated code they hold: one DIE of each. */
static void hlc_index_units( void ) {
	hlc_units_state = -1;
	if( !hlc_open_image() || !hlc_debug.info || !hlc_debug.abbrev ) return;
	const unsigned char *p = hlc_debug.info, *end = p + hlc_debug.info_size;
	int capacity = 0;
	while( p + 4 <= end ) {
		hlc_unit u;
		bool readable = hlc_read_unit_header(p, &u);
		hlc_die die;
		const unsigned char *next;
		if( readable && hlc_read_unit_die(&u, &die, &next) ) {
			int first = hlc_unit_ranges.count;
			hlc_die_ranges(&u, &hlc_debug, &die, &hlc_unit_ranges, hlc_unit_count);
			int kept = first;
			for(int i=first;i<hlc_unit_ranges.count;i++) {
				hlc_range *r = hlc_unit_ranges.items + i;
				if( r->high > (uintptr_t)hlc_text_begin && r->low < (uintptr_t)hlc_text_end ) hlc_unit_ranges.items[kept++] = *r;
			}
			hlc_unit_ranges.count = kept;
			if( kept > first ) {
				if( hlc_unit_count == capacity ) {
					capacity = capacity ? capacity * 2 : 256;
					hlc_units = (hlc_unit_entry*)realloc(hlc_units, sizeof(hlc_unit_entry) * capacity);
				}
				memset(hlc_units + hlc_unit_count, 0, sizeof(hlc_unit_entry));
				hlc_units[hlc_unit_count++].header = u.start;
			}
		}
		if( readable ) hlc_free_unit(&u);
		p = u.end;
	}
	qsort(hlc_unit_ranges.items, hlc_unit_ranges.count, sizeof(hlc_range), hlc_compare_ranges);
	hlc_units_state = 1;
}

/* Reads the scopes of a unit: its subprograms in the generated code and the bodies inlined within them. */
static void hlc_read_unit_scopes( hlc_unit_entry *entry ) {
	enum { MAX_DEPTH = 256 };
	entry->read = true;
	hlc_unit unit, *u = &unit;
	const hlc_debug_sections *d = &hlc_debug;
	hlc_die die;
	const unsigned char *p;
	if( !hlc_read_unit_header(entry->header, u) ) return;
	if( !hlc_read_unit_die(u, &die, &p) ) { hlc_free_unit(u); return; }
	int scope_at[MAX_DEPTH]; // the scope a DIE at each depth is in; -2 inside a subprogram outside the generated code
	int opened[MAX_DEPTH]; // the scope a DIE with children opened at each depth, or -1
	int depth = 1;
	scope_at[1] = -1;
	opened[0] = opened[1] = -1;
	while( p < u->end && depth > 0 ) {
		uint64 code = hlc_uleb(&p, u->end);
		if( code == 0 ) {
			depth--;
			if( opened[depth] >= 0 ) HLC_SCOPE(opened[depth])->next = hlc_scope_count;
			continue;
		}
		hlc_abbrev *a = hlc_find_abbrev(u, code);
		if( !a || !hlc_read_die(&p, u->end, u, d, a, &die) ) break;
		int current = scope_at[depth], made = -1, inner = current;
		if( a->tag == 0x2e && current == -1 && (die.has_low || die.has_ranges) ) { // DW_TAG_subprogram
			made = hlc_new_scope(-1);
			hlc_die_ranges(u, d, &die, &hlc_scope_ranges, made);
			hlc_scope *s = HLC_SCOPE(made);
			s->range_count = hlc_scope_ranges.count - s->first_range;
			bool generated = false;
			for(int i=0;i<s->range_count;i++) {
				hlc_range *r = hlc_scope_ranges.items + s->first_range + i;
				if( r->low >= (uintptr_t)hlc_text_begin && r->low < (uintptr_t)hlc_text_end ) generated = true;
			}
			if( generated ) {
				s->name = hlc_die_name(u, d, &die);
				for(int i=0;i<s->range_count;i++)
					hlc_push_range(&entry->subprograms, hlc_scope_ranges.items[s->first_range + i].low,
						hlc_scope_ranges.items[s->first_range + i].high, made);
				inner = made;
			} else {
				hlc_scope_ranges.count = s->first_range;
				hlc_scope_count--;
				made = -1;
				inner = -2;
			}
		} else if( a->tag == 0x1d && current >= 0 ) { // DW_TAG_inlined_subroutine
			made = hlc_new_scope(current);
			hlc_die_ranges(u, d, &die, &hlc_scope_ranges, made);
			hlc_scope *s = HLC_SCOPE(made);
			s->range_count = hlc_scope_ranges.count - s->first_range;
			s->name = hlc_die_name(u, d, &die);
			s->stmt_list = u->stmt_list;
			s->call_file = die.has_call ? (int)die.call_file.number : -1;
			s->call_line = (int)die.call_line.number;
			inner = made;
		}
		if( a->children ) {
			if( depth + 1 >= MAX_DEPTH ) break;
			opened[depth] = made;
			depth++;
			scope_at[depth] = inner;
			opened[depth] = -1;
		}
	}
	// A unit cut short leaves its open scopes ending at the last one read.
	for(int i=depth;i>=0;i--) if( opened[i] >= 0 ) HLC_SCOPE(opened[i])->next = hlc_scope_count;
	qsort(entry->subprograms.items, entry->subprograms.count, sizeof(hlc_range), hlc_compare_ranges);
	hlc_free_unit(u);
}

static const hlc_range *hlc_range_at( const hlc_ranges *v, uintptr_t target ) {
	int low = 0, high = v->count - 1, found = -1;
	while( low <= high ) {
		int middle = (low + high) >> 1;
		if( v->items[middle].low <= target ) { found = middle; low = middle + 1; } else high = middle - 1;
	}
	return found < 0 || target >= v->items[found].high ? NULL : v->items + found;
}

static bool hlc_scope_holds( int scope, uintptr_t target ) {
	hlc_scope *s = HLC_SCOPE(scope);
	for(int i=0;i<s->range_count;i++) {
		hlc_range *r = hlc_scope_ranges.items + s->first_range + i;
		if( target >= r->low && target < r->high ) return true;
	}
	return false;
}

/* The innermost scope at the call before return address `address`, or -1. */
static int hlc_scope_at( void *address ) {
	if( hlc_units_state == 0 ) hlc_index_units();
	if( hlc_units_state < 0 ) return -1;
	uintptr_t target = (uintptr_t)address - 1;
	const hlc_range *unit = hlc_range_at(&hlc_unit_ranges, target);
	if( !unit ) return -1;
	hlc_unit_entry *entry = hlc_units + unit->tag;
	if( !entry->read ) hlc_read_unit_scopes(entry);
	const hlc_range *subprogram = hlc_range_at(&entry->subprograms, target);
	if( !subprogram ) return -1;
	int scope = subprogram->tag;
	for(;;) {
		int child = scope + 1, inner = -1;
		while( child < HLC_SCOPE(scope)->next ) {
			if( hlc_scope_holds(child, target) ) { inner = child; break; }
			child = HLC_SCOPE(child)->next;
		}
		if( inner < 0 ) return scope;
		scope = inner;
	}
}

/* The scope a captured frame points at, or -1 for a return address. */
static int hlc_scope_of_frame( void *address ) {
	for(int i=0;i<hlc_scope_chunk_count;i++) {
		hlc_scope *chunk = hlc_scope_chunks[i];
		if( (hlc_scope*)address >= chunk && (hlc_scope*)address < chunk + HLC_SCOPE_CHUNK ) return i * HLC_SCOPE_CHUNK + (int)((hlc_scope*)address - chunk);
	}
	return -1;
}

/* The slot of the generated function a scope is a body of, or -1 for any other (an inlined runtime helper). */
static int hlc_scope_slot( int scope ) {
	hlc_scope *s = HLC_SCOPE(scope);
	if( s->slot == -2 ) s->slot = s->name ? hlc_function_named(s->name) : -1;
	return s->slot;
}

/* The file of the call of an inlined scope. */
static const char *hlc_call_file( hlc_scope *s ) {
	if( hlc_lines_state == 0 ) hlc_read_lines();
	if( s->call_file < 0 ) return NULL;
	for(int i=0;i<hlc_line_unit_count;i++)
		if( hlc_line_units[i].offset == s->stmt_list )
			return s->call_file < hlc_line_units[i].count ? hlc_files[hlc_line_units[i].files[s->call_file]] : NULL;
	return NULL;
}
#endif

/* Names a frame `hlc_capture_stack` captured, under the lock: a return address names the innermost generated function at the call, with the
 * line of the call; an inlined scope names its caller, with the line where the caller calls it. */
static uchar *hlc_resolve_symbol_unlocked( void *address, uchar *out, int *outSize ) {
	if( !out ) return NULL;
#ifndef HLC_EXACT_FRAMES
	int inlined = hlc_scope_of_frame(address);
	if( inlined >= 0 ) {
		hlc_scope *s = HLC_SCOPE(inlined);
		int slot = hlc_scope_slot(s->parent);
		return slot < 0 ? NULL : hlc_frame_name(slot, hlc_call_file(s), s->call_line, out, outSize);
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

/* The program's frames on the stack, innermost first, as the JIT captures its own: the return address of each generated
 * function's frame, preceded by the frames of the generated functions the C compiler inlined at the call (their scopes). */
static int hlc_capture_stack_unlocked( void **stack, int size ) {
	void *frames[HL_EXC_MAX_STACK + 64];
#ifdef HLC_STACK_ELF
	int captured = backtrace(frames, HL_EXC_MAX_STACK + 64), count = 0;
#else
	int captured = RtlCaptureStackBackTrace(0, HL_EXC_MAX_STACK + 64, frames, NULL), count = 0;
#endif
	for(int i=0;i<captured;i++) {
		if( !hlc_in_text(frames[i]) ) continue;
#ifndef HLC_EXACT_FRAMES
		int chain[64], depth = 0, pushed = 0;
		for(int scope = hlc_scope_at(frames[i]);scope >= 0 && depth < 64;scope = HLC_SCOPE(scope)->parent)
			chain[depth++] = scope;
		// A level that is not a generated function (an inlined runtime helper) has no frame of its own: the generated level
		// around it is named at the line where it calls the helper.
		for(int level=0;level<depth;level++)
			if( hlc_scope_slot(chain[level]) >= 0 ) {
				hlc_push_frame(stack, size, &count, level == 0 ? frames[i] : (void*)HLC_SCOPE(chain[level - 1]));
				pushed++;
			}
		if( pushed ) continue;
#endif
		hlc_push_frame(stack, size, &count, frames[i]);
	}
	return stack && count > size ? size : count;
}

/* The DWARF tables are read on first use, and units and scopes as frames in them are first met, into shared arrays; threads
 * capture and name frames concurrently (every thrown exception captures its stack), so one lock serializes both, as the lock
 * around DbgHelp does with MSVC. */
#ifdef HLC_STACK_ELF
static pthread_mutex_t hlc_dwarf_lock = PTHREAD_MUTEX_INITIALIZER;
#	define HLC_DWARF_LOCK() pthread_mutex_lock(&hlc_dwarf_lock)
#	define HLC_DWARF_UNLOCK() pthread_mutex_unlock(&hlc_dwarf_lock)
#else
static SRWLOCK hlc_dwarf_lock = SRWLOCK_INIT;
#	define HLC_DWARF_LOCK() AcquireSRWLockExclusive(&hlc_dwarf_lock)
#	define HLC_DWARF_UNLOCK() ReleaseSRWLockExclusive(&hlc_dwarf_lock)
#endif

static uchar *hlc_resolve_symbol( void *address, uchar *out, int *outSize ) {
	HLC_DWARF_LOCK();
	uchar *name = hlc_resolve_symbol_unlocked(address, out, outSize);
	HLC_DWARF_UNLOCK();
	return name;
}

static int hlc_capture_stack( void **stack, int size ) {
	HLC_DWARF_LOCK();
	int count = hlc_capture_stack_unlocked(stack, size);
	HLC_DWARF_UNLOCK();
	return count;
}
#endif

#ifdef HLC_STACK_PDB
/* MSVC writes no DWARF: the line tables and inline records are in the PDB the link writes beside the executable, read through
 * DbgHelp. It is initialized when first needed (a release build's first capture, a development build's first named frame), and
 * finds the PDB by the path the link recorded or in the executable's directory; without it, frames are named from the module
 * image alone (no file and line, no inlined frames). DbgHelp is single-threaded, so every use holds a lock. */
extern const char *const hlc_source_paths[];
extern const int hlc_source_path_count;

static SRWLOCK hlc_dbghelp_lock = SRWLOCK_INIT;
static HANDLE hlc_process;
static int hlc_dbghelp_state; // 0 not initialized, 1 initialized, -1 unavailable

/* A frame of a function inlined at a return address is that address with its depth in the inline chain (1 for the innermost
 * inlined function's caller, and so on) in the top byte, which no user-space address has. */
#define HLC_DEPTH_SHIFT 56
#define HLC_ADDRESS_MASK (((uintptr_t)1 << HLC_DEPTH_SHIFT) - 1)

static bool hlc_dbghelp( void ) {
	if( hlc_dbghelp_state ) return hlc_dbghelp_state > 0;
	hlc_dbghelp_state = -1;
	wchar_t directory[MAX_PATH * 4];
	DWORD length = GetModuleFileNameW(NULL, directory, MAX_PATH * 4);
	if( length == 0 || length >= MAX_PATH * 4 ) return false;
	wchar_t *slash = wcsrchr(directory, L'\\');
	if( slash ) *slash = 0;
	hlc_process = GetCurrentProcess();
	SymSetOptions(SymGetOptions() | SYMOPT_DEFERRED_LOADS | SYMOPT_LOAD_LINES | SYMOPT_FAIL_CRITICAL_ERRORS | SYMOPT_NO_PROMPTS);
	if( !SymInitializeW(hlc_process, directory, TRUE) ) return false;
	hlc_dbghelp_state = 1;
	return true;
}

/* How many functions are inlined at the call before return address `pc` + 1, and the inline context of the innermost: the
 * contexts of the chain are consecutive, from the innermost inlined function out to the function the code is in. */
static DWORD hlc_inline_chain( DWORD64 pc, DWORD *context ) {
	*context = 0;
#ifdef HLC_EXACT_FRAMES
	(void)pc;
	return 0;
#else
	DWORD inlined = SymAddrIncludeInlineTrace(hlc_process, pc), index = 0;
	if( inlined == 0 || !SymQueryInlineTrace(hlc_process, pc, 0, pc, pc, context, &index) ) return 0;
	return inlined;
#endif
}

/* The slot of the generated function at level `depth` of the inline chain at `pc` (0 the innermost), or -1 for any other (an
 * inlined runtime helper, or no symbol). */
static int hlc_slot_in_chain( DWORD64 pc, DWORD inlined, DWORD context, DWORD depth ) {
	struct { SYMBOL_INFO info; char name[256]; } symbol;
	DWORD64 displacement = 0;
	memset(&symbol, 0, sizeof(symbol.info));
	symbol.info.SizeOfStruct = sizeof(symbol.info);
	symbol.info.MaxNameLen = sizeof(symbol.name);
	BOOL found = inlined ? SymFromInlineContext(hlc_process, pc, context + depth, &displacement, &symbol.info)
		: SymFromAddr(hlc_process, pc, &displacement, &symbol.info);
	return found ? hlc_function_named(symbol.info.Name) : -1;
}

/* The `#line` path that the PDB's `path` records: the compiler may have made a relative one absolute from its working
 * directory, so the longest directive path that ends it, by component, with either separator and in any case, as Windows
 * paths compare. */
static const char *hlc_directive_path( const char *path ) {
	size_t length = strlen(path), best = 0;
	const char *found = NULL;
	for(int i=0;i<hlc_source_path_count;i++) {
		const char *candidate = hlc_source_paths[i];
		size_t n = strlen(candidate);
		if( n > length || n <= best ) continue;
		const char *tail = path + length - n;
		if( tail != path && tail[-1] != '/' && tail[-1] != '\\' ) continue;
		bool same = true;
		for(size_t k=0;k<n && same;k++) {
			char a = tail[k], b = candidate[k];
			if( a == '\\' ) a = '/';
			if( b == '\\' ) b = '/';
			if( a >= 'A' && a <= 'Z' ) a += 'a' - 'A';
			if( b >= 'A' && b <= 'Z' ) b += 'a' - 'A';
			same = a == b;
		}
		if( same ) { best = n; found = candidate; }
	}
	return found;
}

/* The file and line at level `depth` of the inline chain at `pc`: where the code is for the innermost level, else where the
 * level calls the one inside it. The file is the `#line` path, or NULL. */
static const char *hlc_line_in_chain( DWORD64 pc, DWORD inlined, DWORD context, DWORD depth, int *line ) {
	IMAGEHLP_LINEW64 record;
	DWORD displacement = 0;
	memset(&record, 0, sizeof(record));
	record.SizeOfStruct = sizeof(record);
	BOOL found = inlined ? SymGetLineFromInlineContextW(hlc_process, pc, context + depth, 0, &displacement, &record)
		: SymGetLineFromAddrW64(hlc_process, pc, &displacement, &record);
	if( !found || !record.FileName ) return NULL;
	char path[MAX_PATH * 4];
	if( !WideCharToMultiByte(CP_UTF8, 0, record.FileName, -1, path, sizeof(path), NULL, NULL) ) return NULL;
	*line = (int)record.LineNumber;
	return hlc_directive_path(path);
}

/* Names a frame `hlc_capture_stack` captured: the generated function at its depth in the inline chain of its return address,
 * with the line of the call. */
static uchar *hlc_resolve_symbol( void *frame, uchar *out, int *outSize ) {
	if( !out ) return NULL;
	void *address = (void*)((uintptr_t)frame & HLC_ADDRESS_MASK);
	DWORD depth = (DWORD)((uintptr_t)frame >> HLC_DEPTH_SHIFT);
	if( !hlc_in_text(address) ) return NULL;
	DWORD64 pc = (DWORD64)(uintptr_t)address - 1;
	const char *file = NULL;
	int line = 0, slot = -1;
	AcquireSRWLockExclusive(&hlc_dbghelp_lock);
	if( hlc_dbghelp() ) {
		DWORD context, inlined = hlc_inline_chain(pc, &context);
		if( depth <= inlined ) {
			slot = hlc_slot_in_chain(pc, inlined, context, depth);
			file = hlc_line_in_chain(pc, inlined, context, depth, &line);
		}
	}
	ReleaseSRWLockExclusive(&hlc_dbghelp_lock);
	if( slot < 0 && depth == 0 ) slot = hlc_function_at(address);
	if( slot < 0 ) return NULL;
	return hlc_frame_name(slot, file, line, out, outSize);
}

/* The program's frames on the stack, innermost first, as the JIT captures its own: the return address of each generated
 * function's frame, preceded by the frames of the generated functions the C compiler inlined at the call. A level of the chain
 * that is not a generated function (an inlined runtime helper) has no frame of its own. */
static int hlc_capture_stack( void **stack, int size ) {
	void *frames[HL_EXC_MAX_STACK + 64];
	int captured = RtlCaptureStackBackTrace(0, HL_EXC_MAX_STACK + 64, frames, NULL), count = 0;
#ifndef HLC_EXACT_FRAMES
	AcquireSRWLockExclusive(&hlc_dbghelp_lock);
	bool symbols = hlc_dbghelp();
#endif
	for(int i=0;i<captured;i++) {
		if( !hlc_in_text(frames[i]) ) continue;
#ifndef HLC_EXACT_FRAMES
		DWORD64 pc = (DWORD64)(uintptr_t)frames[i] - 1;
		DWORD context, inlined = symbols ? hlc_inline_chain(pc, &context) : 0;
		int pushed = 0;
		for(DWORD depth=0;inlined && depth<=inlined && depth<64;depth++)
			if( hlc_slot_in_chain(pc, inlined, context, depth) >= 0 ) {
				hlc_push_frame(stack, size, &count, (void*)((uintptr_t)frames[i] | ((uintptr_t)depth << HLC_DEPTH_SHIFT)));
				pushed++;
			}
		if( pushed ) continue;
#endif
		hlc_push_frame(stack, size, &count, frames[i]);
	}
#ifndef HLC_EXACT_FRAMES
	ReleaseSRWLockExclusive(&hlc_dbghelp_lock);
#endif
	return stack && count > size ? size : count;
}
#endif

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

/* Elsewhere frames are not captured yet: exceptions carry no stack (macOS: see docs/design/AOT_BACKEND.md). */
void hlc_stack_init( hl_module *m, void **functions, int count ) {
	(void)m; (void)functions; (void)count;
	hl_setup.resolve_symbol = hlc_resolve_symbol;
	hl_setup.capture_stack = hlc_capture_stack;
}

#endif
