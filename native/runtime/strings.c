HL_PRIM vstring *HL_NAME(__string_concat)( vstring *left, vstring *right ) {
	int left_length = realtime_string_length(left);
	int right_length = realtime_string_length(right);
	uchar *output;
	vstring *result = realtime_string_alloc(left_length + right_length,&output);
	if( left_length > 0 )
		memcpy(output, left->bytes, left_length * sizeof(uchar));
	if( right_length > 0 )
		memcpy(output + left_length, right->bytes, right_length * sizeof(uchar));
	return result;
}

/* Concatenates `count` strings with a single allocation. NULL operands count as empty, like __string_concat. */
static vstring *realtime_string_concat_many( vstring **parts, int count ) {
	int total = 0;
	for( int index = 0; index < count; index++ )
		total += realtime_string_length(parts[index]);
	uchar *output;
	vstring *result = realtime_string_alloc(total,&output);
	for( int index = 0; index < count; index++ ) {
		int length = realtime_string_length(parts[index]);
		if( length > 0 ) {
			memcpy(output,parts[index]->bytes,length * sizeof(uchar));
			output += length;
		}
	}
	return result;
}

/* StringBuf: a growable buffer of UTF-16 code units. `add` copies characters in, so the pieces appended do not
   stay alive until toString the way a list of parts would. The handle is scanned (it points at its storage);
   the storage holds no pointers. */
typedef struct realtime_string_buffer {
	uchar *data;
	int length;
	int capacity;
} realtime_string_buffer;

static void realtime_string_buffer_reserve( realtime_string_buffer *buffer, int needed ) {
	if( needed <= buffer->capacity )
		return;
	int capacity = buffer->capacity < 16 ? 16 : buffer->capacity;
	while( capacity < needed ) {
		if( capacity > 0x3FFFFFFF )
			hl_error("StringBuf is too large");
		capacity *= 2;
	}
	uchar *data = (uchar *)hl_gc_alloc_noptr((size_t)capacity * sizeof(uchar));
	if( buffer->length > 0 )
		memcpy(data, buffer->data, (size_t)buffer->length * sizeof(uchar));
	buffer->data = data;
	buffer->capacity = capacity;
}

HL_PRIM realtime_string_buffer *HL_NAME(__string_buffer_new)( void ) {
	realtime_string_buffer *buffer = (realtime_string_buffer *)hl_gc_alloc_raw(sizeof(realtime_string_buffer));
	memset(buffer, 0, sizeof(realtime_string_buffer));
	return buffer;
}

HL_PRIM void HL_NAME(__string_buffer_add)( realtime_string_buffer *buffer, vstring *value ) {
	int length = realtime_string_length(value);
	if( length <= 0 )
		return;
	if( length > 0x7FFFFFFF - buffer->length )
		hl_error("StringBuf is too large");
	realtime_string_buffer_reserve(buffer, buffer->length + length);
	memcpy(buffer->data + buffer->length, value->bytes, (size_t)length * sizeof(uchar));
	buffer->length += length;
}

HL_PRIM int HL_NAME(__string_buffer_length)( realtime_string_buffer *buffer ) {
	return buffer->length;
}

HL_PRIM vstring *HL_NAME(__string_buffer_to_string)( realtime_string_buffer *buffer ) {
	uchar *output;
	vstring *result = realtime_string_alloc(buffer->length, &output);
	if( buffer->length > 0 )
		memcpy(output, buffer->data, (size_t)buffer->length * sizeof(uchar));
	return result;
}

HL_PRIM vstring *HL_NAME(__string_concat3)( vstring *s0, vstring *s1, vstring *s2 ) {
	vstring *parts[3] = { s0, s1, s2 };
	return realtime_string_concat_many(parts,3);
}

HL_PRIM vstring *HL_NAME(__string_concat4)( vstring *s0, vstring *s1, vstring *s2, vstring *s3 ) {
	vstring *parts[4] = { s0, s1, s2, s3 };
	return realtime_string_concat_many(parts,4);
}

HL_PRIM vstring *HL_NAME(__string_concat5)( vstring *s0, vstring *s1, vstring *s2, vstring *s3, vstring *s4 ) {
	vstring *parts[5] = { s0, s1, s2, s3, s4 };
	return realtime_string_concat_many(parts,5);
}

HL_PRIM vstring *HL_NAME(__string_concat6)( vstring *s0, vstring *s1, vstring *s2, vstring *s3, vstring *s4, vstring *s5 ) {
	vstring *parts[6] = { s0, s1, s2, s3, s4, s5 };
	return realtime_string_concat_many(parts,6);
}

HL_PRIM vstring *HL_NAME(__string_concat7)( vstring *s0, vstring *s1, vstring *s2, vstring *s3, vstring *s4, vstring *s5, vstring *s6 ) {
	vstring *parts[7] = { s0, s1, s2, s3, s4, s5, s6 };
	return realtime_string_concat_many(parts,7);
}

HL_PRIM vstring *HL_NAME(__string_concat8)( vstring *s0, vstring *s1, vstring *s2, vstring *s3, vstring *s4, vstring *s5, vstring *s6, vstring *s7 ) {
	vstring *parts[8] = { s0, s1, s2, s3, s4, s5, s6, s7 };
	return realtime_string_concat_many(parts,8);
}

extern int hl_format_double( uchar *output, double value );

/* Formats a Float like Std.string, without boxing it. */
HL_PRIM vstring *HL_NAME(__string_from_f64)( double value ) {
	uchar buffer[40];
	int length = hl_format_double(buffer,value);
	return realtime_string_copy(buffer,length);
}

/* Formats an Int without boxing it or going through a temporary UTF-8 buffer. */
HL_PRIM vstring *HL_NAME(__string_from_int)( int value ) {
	uchar buffer[12];
	int position = 12;
	unsigned int magnitude = value < 0 ? 0u - (unsigned int)value : (unsigned int)value;
	do {
		buffer[--position] = (uchar)('0' + magnitude % 10);
		magnitude /= 10;
	} while( magnitude != 0 );
	if( value < 0 ) buffer[--position] = (uchar)'-';
	return realtime_string_copy(buffer + position,12 - position);
}

HL_PRIM int HL_NAME(__string_length)( vstring *value ) {
	return realtime_string_length(value);
}

HL_PRIM bool HL_NAME(__string_equal)( vstring *left, vstring *right ) {
	if( left == NULL || right == NULL ) return left == right;
	return left->length == right->length
		&& (left->length == 0 || memcmp(left->bytes, right->bytes, left->length * sizeof(uchar)) == 0);
}

static int realtime_string_find( vstring *value, vstring *needle, int start ) {
	int value_length = realtime_string_length(value);
	int needle_length = realtime_string_length(needle);
	if( start < 0 ) start = 0;
	if( start > value_length ) return -1;
	if( needle_length == 0 ) return start;
	if( needle_length > value_length - start ) return -1;
	for( int i = start; i <= value_length - needle_length; i++ )
		if( memcmp(value->bytes + i, needle->bytes, needle_length * sizeof(uchar)) == 0 ) return i;
	return -1;
}

HL_PRIM int HL_NAME(__string_index_of)( vstring *value, vstring *needle ) {
	return realtime_string_find(value, needle, 0);
}

HL_PRIM int HL_NAME(__string_index_of_from)( vstring *value, vstring *needle, int start ) {
	return realtime_string_find(value, needle, start);
}

static vstring *realtime_string_slice( const uchar *value, int start, int end ) {
	return realtime_string_copy(value + start, end > start ? end - start : 0);
}

HL_PRIM varray *HL_NAME(__string_split)( vstring *value, vstring *separator ) {
	const uchar *text = realtime_string_data(value);
	const uchar *delimiter = realtime_string_data(separator);
	int text_length = realtime_string_length(value);
	int delimiter_length = realtime_string_length(separator);
	int count = 1;
	if( delimiter_length == 0 ) {
		count = text_length;
	} else {
		for( int index = 0; index <= text_length - delimiter_length; ) {
			if( memcmp(text + index,delimiter,delimiter_length * sizeof(uchar)) == 0 ) {
				count++;
				index += delimiter_length;
			} else
				index++;
		}
	}
	varray *result = hl_alloc_array(hl_string_type,count);
	vstring **parts = hl_aptr(result,vstring *);
	if( delimiter_length == 0 ) {
		for( int index = 0; index < text_length; index++ )
			parts[index] = realtime_string_slice(text,index,index + 1);
		return result;
	}
	int part = 0, start = 0;
	for( int index = 0; index <= text_length - delimiter_length; ) {
		if( memcmp(text + index,delimiter,delimiter_length * sizeof(uchar)) == 0 ) {
			parts[part++] = realtime_string_slice(text,start,index);
			index += delimiter_length;
			start = index;
		} else
			index++;
	}
	parts[part] = realtime_string_slice(text,start,text_length);
	return result;
}

HL_PRIM vstring *HL_NAME(__string_ltrim)( vstring *value ) {
	const uchar *text = realtime_string_data(value);
	int length = realtime_string_length(value), start = 0;
	while( start < length && text[start] <= 32 ) start++;
	return realtime_string_slice(text,start,length);
}

HL_PRIM vstring *HL_NAME(__string_trim)( vstring *value ) {
	const uchar *text = realtime_string_data(value);
	int length = realtime_string_length(value), start = 0, end = length;
	while( start < end && text[start] <= 32 ) start++;
	while( end > start && text[end - 1] <= 32 ) end--;
	return realtime_string_slice(text,start,end);
}

HL_PRIM vstring *HL_NAME(__string_to_lower_case)( vstring *value ) {
	const uchar *text = realtime_string_data(value);
	int length = realtime_string_length(value);
	uchar *output;
	vstring *result = realtime_string_alloc(length,&output);
	for( int index = 0; index < length; index++ ) {
		uchar code = text[index];
		output[index] = code >= 'A' && code <= 'Z' ? code + ('a' - 'A') : code;
	}
	return result;
}

HL_PRIM vstring *HL_NAME(__string_to_upper_case)( vstring *value ) {
	const uchar *text = realtime_string_data(value);
	int length = realtime_string_length(value);
	uchar *output;
	vstring *result = realtime_string_alloc(length,&output);
	for( int index = 0; index < length; index++ ) {
		uchar code = text[index];
		output[index] = code >= 'a' && code <= 'z' ? code - ('a' - 'A') : code;
	}
	return result;
}

HL_PRIM bool HL_NAME(__string_is_space)( vstring *value, int position ) {
	if( position < 0 || position >= realtime_string_length(value) ) return false;
	uchar code = value->bytes[position];
	return (code > 8 && code < 14) || code == 32;
}

HL_PRIM int HL_NAME(__string_last_index_of)( vstring *value, vstring *needle ) {
	if( value == NULL || needle == NULL ) return -1;
	int text_length = value->length, search_length = needle->length;
	if( search_length == 0 ) return text_length;
	for( int index = text_length - search_length; index >= 0; index-- )
		if( memcmp(value->bytes + index,needle->bytes,search_length * sizeof(uchar)) == 0 ) return index;
	return -1;
}

HL_PRIM int HL_NAME(__string_last_index_of_from)( vstring *value, vstring *needle, int start ) {
	if( value == NULL || needle == NULL || start < 0 ) return -1;
	int text_length = value->length, search_length = needle->length;
	if( start > text_length ) start = text_length;
	if( search_length == 0 ) return start;
	if( search_length > text_length ) return -1;
	if( start > text_length - search_length ) start = text_length - search_length;
	for( int index = start; index >= 0; index-- )
		if( memcmp(value->bytes + index,needle->bytes,search_length * sizeof(uchar)) == 0 ) return index;
	return -1;
}

/* Sort key of a UTF-16 code unit such that comparing keys orders strings by code point, as the Wasm backends do
 * over UTF-8: surrogates (code points above U+FFFF) must sort above the units U+E000..U+FFFF. */
static int realtime_unit_order( uchar unit ) {
	return unit >= 0xE000 ? unit - 0x800 : unit >= 0xD800 ? unit + 0x2000 : unit;
}

/* Orders strings by code point over the common prefix, then by length. A bytewise compare of the UTF-16 data
 * would order by the low byte of each little-endian unit first, putting U+00FF after U+0100. */
HL_PRIM int HL_NAME(__string_compare_full)( vstring *left, vstring *right ) {
	int left_length = realtime_string_length(left), right_length = realtime_string_length(right);
	int length = left_length < right_length ? left_length : right_length;
	for( int index = 0; index < length; index++ ) {
		uchar a = left->bytes[index], b = right->bytes[index];
		if( a != b ) return realtime_unit_order(a) - realtime_unit_order(b);
	}
	return left_length - right_length;
}

HL_PRIM int HL_NAME(__string_char_code_at)( vstring *value, int index ) {
	if( index < 0 || index >= realtime_string_length(value) ) return -1;
	return value->bytes[index];
}

/* One-character strings for the code units below 256 are created once and shared. Strings are never modified in
   place, so sharing is invisible, and `s.charAt(i)` in a loop stops allocating a String and its buffer per call. */
#define REALTIME_SINGLE_CHAR_CACHE 256
static vstring *realtime_single_char_cache[REALTIME_SINGLE_CHAR_CACHE];

static vstring *realtime_single_char_string( uchar unit ) {
	if( unit >= REALTIME_SINGLE_CHAR_CACHE )
		return realtime_string_copy(&unit,1);
	vstring *cached = realtime_single_char_cache[unit];
	if( cached == NULL ) {
		cached = realtime_string_copy(&unit,1);
		hl_add_root(&realtime_single_char_cache[unit]);
		realtime_single_char_cache[unit] = cached;
	}
	return cached;
}

HL_PRIM vstring *HL_NAME(__string_char_at)( vstring *value, int index ) {
	bool present = index >= 0 && index < realtime_string_length(value);
	return present ? realtime_single_char_string(value->bytes[index]) : realtime_string_copy(NULL,0);
}

HL_PRIM vstring *HL_NAME(__string_from_char_code)( int code ) {
	if( (uchar)code == 0 ) hl_error("HashLink String cannot contain NUL; use Bytes for binary data");
	return realtime_single_char_string((uchar)code);
}

HL_PRIM vstring *HL_NAME(__string_from_bytes)( vbyte *value, int length ) {
	if( length < 0 ) hl_error("Negative string length");
	if( value == NULL && length != 0 ) hl_error("Null string bytes");
	for( int index = 0; index < length; index++ )
		if( ((const uchar *)value)[index] == 0 ) hl_error("HashLink String cannot contain NUL; use Bytes for binary data");
	return realtime_string_copy((const uchar *)value,length);
}

HL_PRIM vbyte *HL_NAME(__string_bytes)( vstring *value ) {
	return (vbyte *)realtime_string_data(value);
}

HL_PRIM int HL_NAME(__std_parse_int)( vstring *value ) {
	return value == NULL ? 0 : (int)strtol(realtime_string_utf8(value), NULL, 0);
}

HL_PRIM double HL_NAME(__std_parse_float)( vstring *value ) {
	if( value == NULL ) return NAN;
	const char *text = realtime_string_utf8(value);
	char *end = NULL;
	double result = strtod(text, &end);
	return end == text ? NAN : result;
}

HL_PRIM int HL_NAME(__std_int_f64)( double value ) { return (int)value; }
HL_PRIM int HL_NAME(__std_int_dynamic)( vdynamic *value ) {
	return value == NULL ? 0 : hl_dyn_casti(&value, &hlt_dyn, &hlt_i32);
}
HL_PRIM int HL_NAME(__std_random)( int limit ) { return limit <= 0 ? 0 : rand() % limit; }

HL_PRIM vstring *HL_NAME(__std_string)( vdynamic *value ) {
	if( realtime_is_string(value) ) return (vstring *)value;
	return realtime_string_of_ustr(hl_to_string(value));
}

HL_PRIM int HL_NAME(__reflect_compare)( vdynamic *left, vdynamic *right ) {
	if( realtime_is_string(left) && realtime_is_string(right) ) {
		vstring *left_value = (vstring *)left, *right_value = (vstring *)right;
		int length = left_value->length < right_value->length ? left_value->length : right_value->length;
		for( int index = 0; index < length; index++ )
			if( left_value->bytes[index] != right_value->bytes[index] )
				return left_value->bytes[index] < right_value->bytes[index] ? -1 : 1;
		return left_value->length < right_value->length ? -1 : left_value->length > right_value->length ? 1 : 0;
	}
	return hl_dyn_compare(left,right);
}

HL_PRIM bool HL_NAME(__dynamic_equal)(vdynamic *left, vdynamic *right) {
	return HL_NAME(__reflect_compare)(left, right) == 0;
}

HL_PRIM bool HL_NAME(__string_starts_with)( vstring *value, vstring *prefix ) {
	int value_length = realtime_string_length(value);
	int prefix_length = realtime_string_length(prefix);
	return prefix_length <= value_length
		&& (prefix_length == 0 || memcmp(value->bytes, prefix->bytes, prefix_length * sizeof(uchar)) == 0);
}

HL_PRIM bool HL_NAME(__string_ends_with)( vstring *value, vstring *suffix ) {
	int value_length = realtime_string_length(value);
	int suffix_length = realtime_string_length(suffix);
	return suffix_length <= value_length
		&& (suffix_length == 0 || memcmp(value->bytes + (value_length - suffix_length), suffix->bytes, suffix_length * sizeof(uchar)) == 0);
}

HL_PRIM vstring *HL_NAME(__string_replace)( vstring *value, vstring *sub, vstring *by ) {
	const uchar *text = realtime_string_data(value);
	const uchar *search = realtime_string_data(sub);
	const uchar *replacement = realtime_string_data(by);
	int value_length = realtime_string_length(value);
	int sub_length = realtime_string_length(sub);
	int by_length = realtime_string_length(by);
	int matches = 0;
	if( sub_length == 0 ) {
		matches = value_length > 0 ? value_length - 1 : 0;
	} else {
		for( int offset = 0; offset <= value_length - sub_length; ) {
			if( memcmp(text + offset, search, sub_length * sizeof(uchar)) == 0 ) {
				matches++;
				offset += sub_length;
			} else
				offset++;
		}
	}
	uchar *output;
	vstring *result = realtime_string_alloc(value_length + matches * (by_length - sub_length),&output);
	int source_offset = 0, output_offset = 0;
	while( source_offset < value_length ) {
		bool matched = sub_length == 0 ? source_offset > 0
			: source_offset <= value_length - sub_length
				&& memcmp(text + source_offset, search, sub_length * sizeof(uchar)) == 0;
		if( matched ) {
			if( by_length > 0 )
				memcpy(output + output_offset, replacement, by_length * sizeof(uchar));
			output_offset += by_length;
			if( sub_length > 0 ) {
				source_offset += sub_length;
				continue;
			}
		}
		output[output_offset++] = text[source_offset++];
	}
	return result;
}

HL_PRIM vstring *HL_NAME(__string_substring)( vstring *value, int start, int end ) {
	int length = realtime_string_length(value);
	// Both indexes clamp into the string, then a reversed pair is swapped, as in Haxe.
	if( start < 0 ) start = 0;
	if( end < 0 ) end = 0;
	if( start > length ) start = length;
	if( end > length ) end = length;
	if( end < start ) {
		int swap = start;
		start = end;
		end = swap;
	}
	return realtime_string_slice(realtime_string_data(value), start, end);
}

extern varray *hl_exception_stack( void );

HL_PRIM varray *HL_NAME(__exception_stack)( void ) {
	return realtime_string_array(hl_exception_stack());
}
