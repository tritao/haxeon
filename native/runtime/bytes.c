static void realtime_bytes_finalize( void *value ) {
	realtime_bytes *bytes = (realtime_bytes *)value;
	free(bytes->data);
	bytes->data = NULL;
}

static void realtime_bytes_output_finalize( void *value ) {
	realtime_bytes_output *output = (realtime_bytes_output *)value;
	free(output->data);
	output->data = NULL;
}

static void realtime_bytes_input_finalize( void *value ) {
	realtime_bytes_input *input = (realtime_bytes_input *)value;
	free(input->data);
	input->data = NULL;
}

static realtime_bytes *realtime_bytes_make( int length ) {
	if( length < 0 ) hl_error("Negative byte length");
	realtime_bytes *bytes = (realtime_bytes *)hl_gc_alloc_finalizer(sizeof(realtime_bytes));
	bytes->finalize = realtime_bytes_finalize;
	bytes->length = length;
	bytes->data = length == 0 ? NULL : (vbyte *)calloc((size_t)length, 1);
	if( length > 0 && bytes->data == NULL ) hl_error("Could not allocate bytes");
	return bytes;
}

static void realtime_bytes_bounds( realtime_bytes *bytes, int position, int length ) {
	if( bytes == NULL || position < 0 || length < 0 || position > bytes->length - length )
		hl_error("Bytes access out of bounds");
}

static void realtime_bytes_output_reserve( realtime_bytes_output *output, int extra ) {
	if( extra < 0 || output->length > 0x7FFFFFFF - extra ) hl_error("Byte output is too large");
	int required = output->length + extra;
	if( required <= output->capacity ) return;
	int capacity = output->capacity == 0 ? 64 : output->capacity;
	while( capacity < required ) {
		if( capacity > 0x3FFFFFFF ) { capacity = required; break; }
		capacity *= 2;
	}
	vbyte *data = (vbyte *)realloc(output->data, (size_t)capacity);
	if( data == NULL ) hl_error("Could not grow byte output");
	output->data = data;
	output->capacity = capacity;
}

HL_PRIM realtime_bytes *HL_NAME(__bytes_alloc)( int length ) {
	return realtime_bytes_make(length);
}

HL_PRIM realtime_bytes *HL_NAME(__bytes_of_string)( vbyte *value ) {
	const char *utf8 = value == NULL ? "" : hl_to_utf8((const uchar *)value);
	int length = (int)strlen(utf8);
	realtime_bytes *bytes = realtime_bytes_make(length);
	if( length > 0 ) memcpy(bytes->data, utf8, (size_t)length);
	return bytes;
}

HL_PRIM int HL_NAME(__bytes_length)( realtime_bytes *bytes ) { return bytes == NULL ? 0 : bytes->length; }
HL_PRIM vbyte *HL_NAME(__bytes_get_data)( realtime_bytes *bytes ) { return bytes == NULL ? NULL : bytes->data; }
HL_PRIM int HL_NAME(__bytes_get)( realtime_bytes *bytes, int position ) {
	realtime_bytes_bounds(bytes, position, 1);
	return bytes->data[position];
}

HL_PRIM int HL_NAME(getI8)( realtime_bytes *bytes, int offset ) { int8_t value; realtime_bytes_bounds(bytes,offset,sizeof(value)); memcpy(&value,bytes->data + offset,sizeof(value)); return value; }
HL_PRIM int HL_NAME(getU8)( realtime_bytes *bytes, int offset ) { uint8_t value; realtime_bytes_bounds(bytes,offset,sizeof(value)); memcpy(&value,bytes->data + offset,sizeof(value)); return value; }
HL_PRIM int HL_NAME(getI16)( realtime_bytes *bytes, int offset ) { int16_t value; realtime_bytes_bounds(bytes,offset,sizeof(value)); memcpy(&value,bytes->data + offset,sizeof(value)); return value; }
HL_PRIM int HL_NAME(getU16)( realtime_bytes *bytes, int offset ) { uint16_t value; realtime_bytes_bounds(bytes,offset,sizeof(value)); memcpy(&value,bytes->data + offset,sizeof(value)); return value; }
HL_PRIM int HL_NAME(getI32)( realtime_bytes *bytes, int offset ) { int32_t value; realtime_bytes_bounds(bytes,offset,sizeof(value)); memcpy(&value,bytes->data + offset,sizeof(value)); return value; }
HL_PRIM int64_t HL_NAME(getI64)( realtime_bytes *bytes, int offset ) { int64_t value; realtime_bytes_bounds(bytes,offset,sizeof(value)); memcpy(&value,bytes->data + offset,sizeof(value)); return value; }
HL_PRIM double HL_NAME(getF32)( realtime_bytes *bytes, int offset ) { float value; realtime_bytes_bounds(bytes,offset,sizeof(value)); memcpy(&value,bytes->data + offset,sizeof(value)); return value; }
HL_PRIM double HL_NAME(getF64)( realtime_bytes *bytes, int offset ) { double value; realtime_bytes_bounds(bytes,offset,sizeof(value)); memcpy(&value,bytes->data + offset,sizeof(value)); return value; }

#define HAXEON_STRUCT_SET_INT(NAME,TYPE) HL_PRIM void HL_NAME(NAME)( realtime_bytes *bytes, int offset, int value ) { TYPE converted = (TYPE)value; realtime_bytes_bounds(bytes,offset,sizeof(converted)); memcpy(bytes->data + offset,&converted,sizeof(converted)); }
HAXEON_STRUCT_SET_INT(setI8,int8_t)
HAXEON_STRUCT_SET_INT(setU8,uint8_t)
HAXEON_STRUCT_SET_INT(setI16,int16_t)
HAXEON_STRUCT_SET_INT(setU16,uint16_t)
HAXEON_STRUCT_SET_INT(setI32,int32_t)
HL_PRIM void HL_NAME(setI64)( realtime_bytes *bytes, int offset, int64_t value ) { realtime_bytes_bounds(bytes,offset,sizeof(value)); memcpy(bytes->data + offset,&value,sizeof(value)); }
HL_PRIM void HL_NAME(setF32)( realtime_bytes *bytes, int offset, double value ) { float converted = (float)value; realtime_bytes_bounds(bytes,offset,sizeof(converted)); memcpy(bytes->data + offset,&converted,sizeof(converted)); }
HL_PRIM void HL_NAME(setF64)( realtime_bytes *bytes, int offset, double value ) { realtime_bytes_bounds(bytes,offset,sizeof(value)); memcpy(bytes->data + offset,&value,sizeof(value)); }

HL_PRIM int HL_NAME(__bytes_get_i32)( realtime_bytes *bytes, int position ) {
	realtime_bytes_bounds(bytes, position, 4);
	return (int)((unsigned int)bytes->data[position]
		| ((unsigned int)bytes->data[position + 1] << 8)
		| ((unsigned int)bytes->data[position + 2] << 16)
		| ((unsigned int)bytes->data[position + 3] << 24));
}
HL_PRIM void HL_NAME(__bytes_set)( realtime_bytes *bytes, int position, int value ) {
	realtime_bytes_bounds(bytes, position, 1);
	bytes->data[position] = (vbyte)value;
}
HL_PRIM void HL_NAME(__bytes_set_i32)( realtime_bytes *bytes, int position, int value ) {
	realtime_bytes_bounds(bytes, position, 4);
	for( int i = 0; i < 4; i++ ) bytes->data[position + i] = (vbyte)(value >> (i * 8));
}
HL_PRIM realtime_bytes *HL_NAME(__bytes_sub)( realtime_bytes *bytes, int position, int length ) {
	realtime_bytes_bounds(bytes, position, length);
	realtime_bytes *result = realtime_bytes_make(length);
	if( length > 0 ) memcpy(result->data, bytes->data + position, (size_t)length);
	return result;
}

HL_PRIM realtime_bytes *HL_NAME(structSlice)( realtime_bytes *bytes, int offset, int length ) {
	realtime_bytes_bounds(bytes,offset,length);
	realtime_bytes *result = realtime_bytes_make(length);
	if( length > 0 ) memcpy(result->data,bytes->data + offset,(size_t)length);
	return result;
}

HL_PRIM void HL_NAME(structCopy)( realtime_bytes *bytes, int offset, realtime_bytes *value, int length ) {
	realtime_bytes_bounds(bytes,offset,length);
	realtime_bytes_bounds(value,0,length);
	if( length > 0 ) memcpy(bytes->data + offset,value->data,(size_t)length);
}

HL_PRIM realtime_bytes *HL_NAME(structCopyPointer)( realtime_bytes *bytes, int pointer_offset, int length_offset, int length_bytes ) {
	realtime_bytes_bounds(bytes,pointer_offset,sizeof(void *));
	realtime_bytes_bounds(bytes,length_offset,length_bytes);
	void *pointer = NULL;
	uint64_t length = 0;
	memcpy(&pointer,bytes->data + pointer_offset,sizeof(pointer));
	if( length_bytes == 4 ) {
		uint32_t value;
		memcpy(&value,bytes->data + length_offset,sizeof(value));
		length = value;
	} else if( length_bytes == 8 ) {
		memcpy(&length,bytes->data + length_offset,sizeof(length));
	} else {
		hl_error("HXI borrowed buffer length must be 32 or 64 bits");
	}
	if( length > 268435456 ) hl_error("HXI borrowed buffer exceeds the safety limit");
	if( pointer == NULL && length != 0 ) hl_error("HXI borrowed buffer contains NULL with a non-zero length");
	realtime_bytes *result = realtime_bytes_make((int)length);
	if( length != 0 ) memcpy(result->data,pointer,(size_t)length);
	return result;
}
HL_PRIM int HL_NAME(__bytes_compare)( realtime_bytes *left, realtime_bytes *right ) {
	int common = left->length < right->length ? left->length : right->length;
	int compared = common == 0 ? 0 : memcmp(left->data, right->data, (size_t)common);
	return compared != 0 ? compared : left->length - right->length;
}
HL_PRIM vbyte *HL_NAME(__bytes_to_string)( realtime_bytes *bytes ) {
	char *utf8 = (char *)malloc((size_t)bytes->length + 1);
	if( utf8 == NULL ) hl_error("Could not allocate byte string");
	if( bytes->length > 0 ) memcpy(utf8, bytes->data, (size_t)bytes->length);
	utf8[bytes->length] = 0;
	int chars = hl_utf8_length((vbyte *)utf8, 0);
	uchar *result = (uchar *)hl_alloc_bytes((chars + 1) * (int)sizeof(uchar));
	hl_from_utf8(result, chars, utf8);
	result[chars] = 0;
	free(utf8);
	return (vbyte *)result;
}

HL_PRIM vbyte *HL_NAME(__bytes_get_string)( realtime_bytes *bytes, int position, int length ) {
	realtime_bytes_bounds(bytes, position, length);
	char *utf8 = (char *)malloc((size_t)length + 1);
	if( utf8 == NULL ) hl_error("Could not allocate byte string");
	if( length > 0 ) memcpy(utf8, bytes->data + position, (size_t)length);
	utf8[length] = 0;
	int chars = hl_utf8_length((vbyte *)utf8, 0);
	uchar *result = (uchar *)hl_alloc_bytes((chars + 1) * (int)sizeof(uchar));
	hl_from_utf8(result, chars, utf8);
	result[chars] = 0;
	free(utf8);
	return (vbyte *)result;
}

static vbyte *realtime_string_from_utf8( const char *utf8 ) {
	int chars = hl_utf8_length((const vbyte *)utf8, 0);
	uchar *result = (uchar *)hl_alloc_bytes((chars + 1) * (int)sizeof(uchar));
	hl_from_utf8(result, chars, utf8);
	result[chars] = 0;
	return (vbyte *)result;
}

HL_PRIM varray *HL_NAME(__sys_args)( void ) {
	varray *result = hl_alloc_array(&hlt_bytes, hl_setup.sys_nargs);
	vbyte **arguments = hl_aptr(result, vbyte *);
	for( int index = 0; index < hl_setup.sys_nargs; index++ ) {
#ifdef HL_WIN
		arguments[index] = (vbyte *)hl_setup.sys_args[index];
#else
		arguments[index] = realtime_string_from_utf8(hl_setup.sys_args[index]);
#endif
	}
	return result;
}

HL_PRIM realtime_bytes_input *HL_NAME(__bytes_input_new)( realtime_bytes *bytes ) {
	realtime_bytes_input *input = (realtime_bytes_input *)hl_gc_alloc_finalizer(sizeof(realtime_bytes_input));
	input->finalize = realtime_bytes_input_finalize;
	input->length = bytes->length;
	input->data = bytes->length == 0 ? NULL : (vbyte *)malloc((size_t)bytes->length);
	if( bytes->length > 0 && input->data == NULL ) hl_error("Could not allocate byte input");
	if( bytes->length > 0 ) memcpy(input->data, bytes->data, (size_t)bytes->length);
	input->position = 0;
	input->big_endian = true;
	return input;
}
HL_PRIM int HL_NAME(__bytes_input_position)( realtime_bytes_input *input ) { return input->position; }
HL_PRIM bool HL_NAME(__bytes_input_big_endian)( realtime_bytes_input *input ) { return input->big_endian; }
HL_PRIM void HL_NAME(__bytes_input_set_big_endian)( realtime_bytes_input *input, bool value ) { input->big_endian = value; }
HL_PRIM int HL_NAME(__bytes_input_read_byte)( realtime_bytes_input *input ) {
	if( input->position < 0 || input->position >= input->length ) hl_error("Byte input is truncated");
	return input->data[input->position++];
}
HL_PRIM int HL_NAME(__bytes_input_read_i32)( realtime_bytes_input *input ) {
	if( input->position < 0 || input->position > input->length - 4 ) hl_error("Byte input is truncated");
	vbyte *data = input->data + input->position;
	input->position += 4;
	if( input->big_endian ) return (data[0] << 24) | (data[1] << 16) | (data[2] << 8) | data[3];
	return data[0] | (data[1] << 8) | (data[2] << 16) | (data[3] << 24);
}
HL_PRIM double HL_NAME(__bytes_input_read_f64)( realtime_bytes_input *input ) {
	union { double value; vbyte bytes[8]; } decoded;
	if( input->position < 0 || input->position > input->length - 8 ) hl_error("Byte input is truncated");
	for( int i = 0; i < 8; i++ ) decoded.bytes[i] = input->data[input->position + (input->big_endian ? 7 - i : i)];
	input->position += 8;
	return decoded.value;
}
HL_PRIM vbyte *HL_NAME(__bytes_input_read_string)( realtime_bytes_input *input, int length ) {
	if( length < 0 || input->position < 0 || input->position > input->length - length ) hl_error("Byte input is truncated");
	char *utf8 = (char *)malloc((size_t)length + 1);
	if( utf8 == NULL ) hl_error("Could not allocate string input");
	memcpy(utf8, input->data + input->position, (size_t)length);
	utf8[length] = 0;
	input->position += length;
	int chars = hl_utf8_length((vbyte *)utf8, 0);
	uchar *result = (uchar *)hl_alloc_bytes((chars + 1) * (int)sizeof(uchar));
	hl_from_utf8(result, chars, utf8);
	result[chars] = 0;
	free(utf8);
	return (vbyte *)result;
}
HL_PRIM realtime_bytes *HL_NAME(__bytes_input_read)( realtime_bytes_input *input, int length ) {
	if( length < 0 || input->position < 0 || input->position > input->length - length ) hl_error("Byte input is truncated");
	realtime_bytes *result = realtime_bytes_make(length);
	if( length > 0 ) memcpy(result->data, input->data + input->position, (size_t)length);
	input->position += length;
	return result;
}

HL_PRIM realtime_bytes_output *HL_NAME(__bytes_output_new)( void ) {
	realtime_bytes_output *output = (realtime_bytes_output *)hl_gc_alloc_finalizer(sizeof(realtime_bytes_output));
	output->finalize = realtime_bytes_output_finalize;
	output->data = NULL;
	output->length = 0;
	output->capacity = 0;
	output->big_endian = true;
	return output;
}
HL_PRIM bool HL_NAME(__bytes_output_big_endian)( realtime_bytes_output *output ) { return output->big_endian; }
HL_PRIM void HL_NAME(__bytes_output_set_big_endian)( realtime_bytes_output *output, bool value ) { output->big_endian = value; }
HL_PRIM void HL_NAME(__bytes_output_write_byte)( realtime_bytes_output *output, int value ) {
	realtime_bytes_output_reserve(output, 1);
	output->data[output->length++] = (vbyte)value;
}
HL_PRIM void HL_NAME(__bytes_output_write_i32)( realtime_bytes_output *output, int value ) {
	realtime_bytes_output_reserve(output, 4);
	for( int i = 0; i < 4; i++ ) output->data[output->length + i] = (vbyte)(value >> (output->big_endian ? 24 - i * 8 : i * 8));
	output->length += 4;
}
HL_PRIM void HL_NAME(__bytes_output_write_f64)( realtime_bytes_output *output, double value ) {
	union { double value; vbyte bytes[8]; } encoded;
	encoded.value = value;
	realtime_bytes_output_reserve(output, 8);
	for( int i = 0; i < 8; i++ ) output->data[output->length + i] = encoded.bytes[output->big_endian ? 7 - i : i];
	output->length += 8;
}
HL_PRIM void HL_NAME(__bytes_output_write_string)( realtime_bytes_output *output, vbyte *value ) {
	const char *utf8 = value == NULL ? "" : hl_to_utf8((const uchar *)value);
	int length = (int)strlen(utf8);
	realtime_bytes_output_reserve(output, length);
	if( length > 0 ) memcpy(output->data + output->length, utf8, (size_t)length);
	output->length += length;
}
HL_PRIM void HL_NAME(__bytes_output_write)( realtime_bytes_output *output, realtime_bytes *bytes ) {
	realtime_bytes_output_reserve(output, bytes->length);
	if( bytes->length > 0 ) memcpy(output->data + output->length, bytes->data, (size_t)bytes->length);
	output->length += bytes->length;
}
HL_PRIM realtime_bytes *HL_NAME(__bytes_output_get_bytes)( realtime_bytes_output *output ) {
	realtime_bytes *bytes = realtime_bytes_make(output->length);
	if( output->length > 0 ) memcpy(bytes->data, output->data, (size_t)output->length);
	return bytes;
}
