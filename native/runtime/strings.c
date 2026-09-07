HL_PRIM vbyte *HL_NAME(__string_concat)( vbyte *left, vbyte *right ) {
	int left_length = left == NULL ? 0 : (int)ustrlen((const uchar *)left);
	int right_length = right == NULL ? 0 : (int)ustrlen((const uchar *)right);
	vbyte *result = hl_alloc_bytes((left_length + right_length + 1) * (int)sizeof(uchar));
	if (left_length > 0)
		memcpy(result, left, left_length * sizeof(uchar));
	if (right_length > 0)
		memcpy(result + left_length * sizeof(uchar), right, right_length * sizeof(uchar));
	((uchar *)result)[left_length + right_length] = 0;
	return result;
}

HL_PRIM int HL_NAME(__string_length)( vbyte *value ) {
	return value == NULL ? 0 : (int)ustrlen((const uchar *)value);
}

HL_PRIM bool HL_NAME(__string_equal)( vbyte *left, vbyte *right ) {
	int left_length = left == NULL ? 0 : (int)ustrlen((const uchar *)left);
	int right_length = right == NULL ? 0 : (int)ustrlen((const uchar *)right);
	return left_length == right_length
		&& (left_length == 0 || memcmp(left, right, left_length * (int)sizeof(uchar)) == 0);
}

HL_PRIM int HL_NAME(__string_index_of)( vbyte *value, vbyte *needle ) {
	int value_length = value == NULL ? 0 : (int)ustrlen((const uchar *)value);
	int needle_length = needle == NULL ? 0 : (int)ustrlen((const uchar *)needle);
	if( needle_length == 0 ) return 0;
	if( needle_length > value_length ) return -1;
	for( int i = 0; i <= value_length - needle_length; i++ )
		if( memcmp(value + i * sizeof(uchar), needle, needle_length * sizeof(uchar)) == 0 ) return i;
	return -1;
}

HL_PRIM int HL_NAME(__string_index_of_from)( vbyte *value, vbyte *needle, int start ) {
	int value_length = value == NULL ? 0 : (int)ustrlen((const uchar *)value);
	int needle_length = needle == NULL ? 0 : (int)ustrlen((const uchar *)needle);
	if( start < 0 ) start = 0;
	if( start > value_length ) return -1;
	if( needle_length == 0 ) return start;
	if( needle_length > value_length - start ) return -1;
	for( int i = start; i <= value_length - needle_length; i++ )
		if( memcmp(value + i * sizeof(uchar), needle, needle_length * sizeof(uchar)) == 0 ) return i;
	return -1;
}

static vbyte *realtime_string_slice( const uchar *value, int start, int end );

HL_PRIM varray *HL_NAME(__string_split)( vbyte *value, vbyte *separator ) {
	const uchar *text = (const uchar *)value;
	const uchar *delimiter = (const uchar *)separator;
	int text_length = text == NULL ? 0 : (int)ustrlen(text);
	int delimiter_length = delimiter == NULL ? 0 : (int)ustrlen(delimiter);
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
	varray *result = hl_alloc_array(&hlt_bytes,count);
	vbyte **parts = hl_aptr(result,vbyte *);
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

static vbyte *realtime_string_slice( const uchar *value, int start, int end ) {
	vbyte *result = hl_alloc_bytes((end - start + 1) * (int)sizeof(uchar));
	if( end > start ) memcpy(result,value + start,(end - start) * sizeof(uchar));
	((uchar *)result)[end - start] = 0;
	return result;
}

HL_PRIM vbyte *HL_NAME(__string_ltrim)( vbyte *value ) {
	const uchar *text = (const uchar *)value;
	int length = value == NULL ? 0 : (int)ustrlen(text), start = 0;
	while( start < length && text[start] <= 32 ) start++;
	return realtime_string_slice(text,start,length);
}

HL_PRIM vbyte *HL_NAME(__string_trim)( vbyte *value ) {
	const uchar *text = (const uchar *)value;
	int length = value == NULL ? 0 : (int)ustrlen(text), start = 0, end = length;
	while( start < end && text[start] <= 32 ) start++;
	while( end > start && text[end - 1] <= 32 ) end--;
	return realtime_string_slice(text,start,end);
}

HL_PRIM vbyte *HL_NAME(__string_to_lower_case)( vbyte *value ) {
	const uchar *text = (const uchar *)value;
	int length = value == NULL ? 0 : (int)ustrlen(text);
	vbyte *result = hl_alloc_bytes((length + 1) * (int)sizeof(uchar));
	uchar *output = (uchar *)result;
	for( int index = 0; index < length; index++ ) {
		uchar code = text[index];
		output[index] = code >= 'A' && code <= 'Z' ? code + ('a' - 'A') : code;
	}
	output[length] = 0;
	return result;
}

HL_PRIM bool HL_NAME(__string_is_space)( vbyte *value, int position ) {
	int length = value == NULL ? 0 : (int)ustrlen((const uchar *)value);
	if( position < 0 || position >= length ) return false;
	uchar code = ((const uchar *)value)[position];
	return (code > 8 && code < 14) || code == 32;
}

HL_PRIM int HL_NAME(__string_last_index_of)( vbyte *value, vbyte *needle ) {
	if( value == NULL || needle == NULL ) return -1;
	const uchar *text = (const uchar *)value, *search = (const uchar *)needle;
	int text_length = (int)ustrlen(text), search_length = (int)ustrlen(search);
	if( search_length == 0 ) return text_length;
	for( int index = text_length - search_length; index >= 0; index-- )
		if( memcmp(text + index,search,search_length * sizeof(uchar)) == 0 ) return index;
	return -1;
}

HL_PRIM int HL_NAME(__string_char_code_at)( vbyte *value, int index ) {
	int length = value == NULL ? 0 : (int)ustrlen((const uchar *)value);
	if( index < 0 || index >= length ) return -1;
	return ((const uchar *)value)[index];
}

HL_PRIM vbyte *HL_NAME(__string_char_at)( vbyte *value, int index ) {
	int length = value == NULL ? 0 : (int)ustrlen((const uchar *)value);
	bool present = index >= 0 && index < length;
	vbyte *result = hl_alloc_bytes((present ? 2 : 1) * (int)sizeof(uchar));
	if( present ) ((uchar *)result)[0] = ((const uchar *)value)[index];
	((uchar *)result)[present ? 1 : 0] = 0;
	return result;
}

HL_PRIM vbyte *HL_NAME(__string_from_char_code)( int code ) {
	vbyte *result = hl_alloc_bytes(2 * (int)sizeof(uchar));
	((uchar *)result)[0] = (uchar)code;
	((uchar *)result)[1] = 0;
	return result;
}

HL_PRIM vbyte *HL_NAME(__string_from_bytes)( vbyte *value, int length ) {
	if( length < 0 ) hl_error("Negative string length");
	if( value == NULL && length != 0 ) hl_error("Null string bytes");
	vbyte *result = hl_alloc_bytes((length + 1) * (int)sizeof(uchar));
	if( length > 0 ) memcpy(result,value,length * sizeof(uchar));
	((uchar *)result)[length] = 0;
	return result;
}

HL_PRIM vbyte *HL_NAME(__string_bytes)( vbyte *value ) {
	return value;
}

HL_PRIM int HL_NAME(__std_parse_int)( vbyte *value ) {
	return value == NULL ? 0 : (int)strtol(hl_to_utf8((const uchar *)value), NULL, 0);
}

HL_PRIM double HL_NAME(__std_parse_float)( vbyte *value ) {
	return value == NULL ? 0.0 : strtod(hl_to_utf8((const uchar *)value), NULL);
}

HL_PRIM int HL_NAME(__std_int_f64)( double value ) { return (int)value; }
HL_PRIM int HL_NAME(__std_random)( int limit ) { return limit <= 0 ? 0 : rand() % limit; }

HL_PRIM vbyte *HL_NAME(__std_string)( vdynamic *value ) {
	return (vbyte *)hl_to_string(value);
}

HL_PRIM int HL_NAME(__reflect_compare)( vdynamic *left, vdynamic *right ) {
	if( left != NULL && right != NULL && left->t->kind == HBYTES && right->t->kind == HBYTES ) {
		const uchar *left_value = (const uchar *)left->v.ptr;
		const uchar *right_value = (const uchar *)right->v.ptr;
		if( left_value == right_value ) return 0;
		if( left_value == NULL ) return -1;
		if( right_value == NULL ) return 1;
		while( *left_value != 0 && *left_value == *right_value ) {
			left_value++;
			right_value++;
		}
		return *left_value < *right_value ? -1 : *left_value > *right_value ? 1 : 0;
	}
	return hl_dyn_compare(left,right);
}

HL_PRIM bool HL_NAME(__string_starts_with)( vbyte *value, vbyte *prefix ) {
	int value_length = value == NULL ? 0 : (int)ustrlen((const uchar *)value);
	int prefix_length = prefix == NULL ? 0 : (int)ustrlen((const uchar *)prefix);
	return prefix_length <= value_length && memcmp(value, prefix, prefix_length * sizeof(uchar)) == 0;
}

HL_PRIM bool HL_NAME(__string_ends_with)( vbyte *value, vbyte *suffix ) {
	int value_length = value == NULL ? 0 : (int)ustrlen((const uchar *)value);
	int suffix_length = suffix == NULL ? 0 : (int)ustrlen((const uchar *)suffix);
	return suffix_length <= value_length
		&& memcmp(value + (value_length - suffix_length) * sizeof(uchar), suffix, suffix_length * sizeof(uchar)) == 0;
}

HL_PRIM vbyte *HL_NAME(__string_replace)( vbyte *value, vbyte *sub, vbyte *by ) {
	int value_length = value == NULL ? 0 : (int)ustrlen((const uchar *)value);
	int sub_length = sub == NULL ? 0 : (int)ustrlen((const uchar *)sub);
	int by_length = by == NULL ? 0 : (int)ustrlen((const uchar *)by);
	int matches = 0;
	if( sub_length == 0 ) {
		matches = value_length > 0 ? value_length - 1 : 0;
	} else {
		for( int offset = 0; offset <= value_length - sub_length; ) {
			if( memcmp(value + offset * sizeof(uchar), sub, sub_length * sizeof(uchar)) == 0 ) {
				matches++;
				offset += sub_length;
			} else
				offset++;
		}
	}
	int result_length = value_length + matches * (by_length - sub_length);
	vbyte *result = hl_alloc_bytes((result_length + 1) * (int)sizeof(uchar));
	uchar *output = (uchar *)result;
	int source_offset = 0, output_offset = 0;
	while( source_offset < value_length ) {
		bool matched = sub_length == 0 ? source_offset > 0
			: source_offset <= value_length - sub_length
				&& memcmp(value + source_offset * sizeof(uchar), sub, sub_length * sizeof(uchar)) == 0;
		if( matched ) {
			if( by_length > 0 )
				memcpy(output + output_offset, by, by_length * sizeof(uchar));
			output_offset += by_length;
			if( sub_length > 0 ) {
				source_offset += sub_length;
				continue;
			}
		}
		output[output_offset++] = ((const uchar *)value)[source_offset++];
	}
	output[output_offset] = 0;
	return result;
}

HL_PRIM vbyte *HL_NAME(__string_substring)( vbyte *value, int start, int end ) {
	int length = value == NULL ? 0 : (int)ustrlen((const uchar *)value);
	if( start < 0 ) start = 0;
	if( end < start ) end = start;
	if( start > length ) start = length;
	if( end > length ) end = length;
	int count = end - start;
	vbyte *result = hl_alloc_bytes((count + 1) * (int)sizeof(uchar));
	if( count > 0 )
		memcpy(result, value + start * sizeof(uchar), count * sizeof(uchar));
	((uchar *)result)[count] = 0;
	return result;
}
