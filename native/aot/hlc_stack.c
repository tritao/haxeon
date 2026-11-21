/* Haxe stack traces for a program Haxeon compiled to C (docs/design/AOT_BACKEND.md). The generated functions are in their own
 * section (`hlc_text`), so a captured frame is the program's exactly when its return address is in that section, as a JIT frame
 * is when it is in the module's code. A frame is named as the JIT names it: the function's identity from the module image, and
 * the Haxe file and line the C compiler's line table gives for the call (`#line` in the generated code). The line table is read
 * from the executable's own DWARF `.debug_line` the first time a frame is resolved. */
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
		free(files);
		p = unit_end;
	}
}

static int hlc_find_bias( struct dl_phdr_info *info, size_t size, void *data ) {
	(void)size;
	*(uintptr_t*)data = (uintptr_t)info->dlpi_addr;
	return 1; // the first object is the executable
}

static void hlc_read_lines( void ) {
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
	for(int i=0;i<header->e_shnum;i++) {
		const char *name = names + sections[i].sh_name;
		// Compressed debug sections are not read: frames then have no line.
		if( sections[i].sh_flags & SHF_COMPRESSED ) continue;
		const unsigned char *data = image + sections[i].sh_offset;
		if( strcmp(name, ".debug_line") == 0 ) { lines = data; lines_size = sections[i].sh_size; }
		else if( strcmp(name, ".debug_line_str") == 0 ) { strings.line_str = data; strings.line_str_size = sections[i].sh_size; }
		else if( strcmp(name, ".debug_str") == 0 ) { strings.str = data; strings.str_size = sections[i].sh_size; }
	}
	if( !lines ) return;
	uintptr_t bias = 0;
	dl_iterate_phdr(hlc_find_bias, &bias);
	hlc_read_line_programs(lines, lines_size, &strings, bias);
	qsort(hlc_rows, hlc_row_count, sizeof(hlc_line_row), hlc_compare_rows);
	hlc_lines_state = 1; // the mapping stays: file names point into it
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

static int hlc_function_at( void *address ) {
	uintptr_t target = (uintptr_t)address - 1;
	int low = 0, high = hlc_start_count - 1, found = -1;
	while( low <= high ) {
		int middle = (low + high) >> 1;
		if( hlc_starts[middle].start <= target ) { found = middle; low = middle + 1; } else high = middle - 1;
	}
	return found < 0 ? -1 : hlc_starts[found].slot;
}

static uchar *hlc_resolve_symbol( void *address, uchar *out, int *outSize ) {
	if( !hlc_in_text(address) ) return NULL;
	int slot = hlc_function_at(address);
	if( slot < 0 || !out ) return NULL;
	hl_code *code = hlc_module->code;
	hl_function *f = code->functions + hlc_module->functions_indexes[slot];
	const char *qualified = hl_code_function_name(code, f);
	const char *file = NULL;
	int line = 0, size = *outSize, pos = 0;
	if( qualified ) pos += hl_from_utf8(out, size, qualified);
	else if( f->obj ) pos += usprintf(out, size, USTR("%s.%s"), f->obj->name, f->field.name);
	else pos += usprintf(out, size, USTR("fun$%d"), f->findex);
	if( hlc_line_of(address, &file, &line) ) {
		pos += usprintf(out + pos, size - pos, USTR("("));
		pos += hl_from_utf8(out + pos, size - pos, file);
		pos += usprintf(out + pos, size - pos, USTR(":%d)"), line);
	}
	*outSize = pos;
	return out;
}

/* The return addresses of the program's frames on the stack, innermost first, as the JIT captures its own. */
static int hlc_capture_stack( void **stack, int size ) {
	void *frames[HL_EXC_MAX_STACK + 64];
	int captured = backtrace(frames, HL_EXC_MAX_STACK + 64), count = 0;
	for(int i=0;i<captured;i++)
		if( hlc_in_text(frames[i]) ) {
			if( stack && count < size ) stack[count] = frames[i];
			count++;
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
