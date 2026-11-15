extern vbyte *hl_sys_get_env( vbyte *name );
extern bool hl_sys_put_env( vbyte *name, vbyte *value );
extern int hl_sys_command( vbyte *command );
extern void hl_sys_print( vbyte *value );

HL_PRIM vstring *HL_NAME(__sys_system_name)( void ) {
#if defined(_WIN32)
	return realtime_string_from_utf8("Windows");
#elif defined(__APPLE__)
	return realtime_string_from_utf8("Mac");
#elif defined(__linux__)
	return realtime_string_from_utf8("Linux");
#elif defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)
	return realtime_string_from_utf8("BSD");
#else
	return realtime_string_from_utf8("Unknown");
#endif
}

/* Byte-framed stdio protocols must bypass the Windows CRT newline translation. */
HL_PRIM void HL_NAME(__sys_binary_stdio)( void ) {
#if defined(_WIN32)
	if( _setmode(_fileno(stdin),_O_BINARY) == -1 || _setmode(_fileno(stdout),_O_BINARY) == -1 )
		hl_error("Could not switch standard streams to binary mode");
#endif
}

HL_PRIM vstring *HL_NAME(__sys_get_env)( vstring *name ) {
	char *owned;
	vbyte *argument = realtime_platform_argument(name,&owned);
	vbyte *result = hl_sys_get_env(argument);
	free(owned);
	return realtime_string_from_platform(result);
}

HL_PRIM varray *HL_NAME(__sys_environment)( void ) {
#if defined(_WIN32)
	LPWCH environment = GetEnvironmentStringsW();
	int count = 0;
	if( environment != NULL )
		for( const wchar_t *entry = environment; *entry != 0; entry += wcslen(entry) + 1 ) count++;
	varray *result = hl_alloc_array(hl_string_type,count);
	vstring **target = hl_aptr(result,vstring *);
	int index = 0;
	if( environment != NULL ) {
		for( const wchar_t *entry = environment; *entry != 0; entry += wcslen(entry) + 1 )
			hl_gc_store_ref(&target[index++],realtime_string_from_platform((vbyte *)entry),hl_string_type);
		FreeEnvironmentStringsW(environment);
	}
#else
	extern char **environ;
	int count = 0;
	for( char **entry = environ; entry != NULL && *entry != NULL; entry++ ) count++;
	varray *result = hl_alloc_array(hl_string_type,count);
	vstring **target = hl_aptr(result,vstring *);
	for( int index = 0; index < count; index++ )
		hl_gc_store_ref(&target[index],realtime_string_from_utf8(environ[index]),hl_string_type);
#endif
	return result;
}

HL_PRIM bool HL_NAME(__sys_put_env)( vstring *name, vstring *value ) {
	char *owned_name, *owned_value = NULL;
	vbyte *name_argument = realtime_platform_argument(name,&owned_name);
	vbyte *value_argument = value == NULL ? NULL : realtime_platform_argument(value,&owned_value);
	bool result = hl_sys_put_env(name_argument,value_argument);
	free(owned_name);
	free(owned_value);
	return result;
}

HL_PRIM int HL_NAME(__sys_command)( vstring *command ) {
	char *owned;
	vbyte *argument = realtime_platform_argument(command,&owned);
	int result = hl_sys_command(argument);
	free(owned);
	return result;
}

HL_PRIM void HL_NAME(__sys_print)( vstring *value ) {
	/* Unlike paths and process strings, sys_print always accepts HashLink's
	   UTF-16 string representation and performs its own console conversion. */
	hl_sys_print((vbyte *)realtime_string_data(value));
}

typedef struct realtime_file_output { FILE *stream; } realtime_file_output;
static realtime_file_output realtime_stdout = {NULL};
static realtime_file_output realtime_stderr = {NULL};

HL_PRIM realtime_file_output *HL_NAME(__sys_stdout)( void ) {
	realtime_stdout.stream = stdout;
	return &realtime_stdout;
}

typedef struct realtime_file_input { FILE *stream; } realtime_file_input;
static realtime_file_input realtime_stdin = {NULL};

HL_PRIM realtime_file_input *HL_NAME(__sys_stdin)( void ) {
	realtime_stdin.stream = stdin;
	return &realtime_stdin;
}

/* The next byte of `input`, or -1 at the end of the input. */
HL_PRIM int HL_NAME(__file_input_read_byte)( realtime_file_input *input ) {
	int code = fgetc(input->stream);
	return code == EOF ? -1 : code;
}

/* Reads up to `len` bytes into `bytes` at `pos`; returns how many, 0 only at the end of the input. */
HL_PRIM int HL_NAME(__file_input_read_bytes)( realtime_file_input *input, realtime_bytes *bytes, int pos, int len ) {
	realtime_bytes_bounds(bytes, pos, len);
	return len == 0 ? 0 : (int)fread(bytes->data + pos, 1, (size_t)len, input->stream);
}

/* The next line of `input` without its "\n" or "\r\n", or NULL at the end of the input. */
HL_PRIM vstring *HL_NAME(__file_input_read_line)( realtime_file_input *input ) {
	size_t capacity = 256, length = 0;
	char *buffer = (char *)malloc(capacity);
	int code = EOF;
	if( buffer == NULL ) hl_error("Out of memory reading a line");
	while( (code = fgetc(input->stream)) != EOF && code != '\n' ) {
		if( length + 1 >= capacity ) {
			char *grown = (char *)realloc(buffer, capacity * 2);
			if( grown == NULL ) { free(buffer); hl_error("Out of memory reading a line"); }
			buffer = grown;
			capacity *= 2;
		}
		buffer[length++] = (char)code;
	}
	if( code == EOF && length == 0 ) { free(buffer); return NULL; }
	if( length > 0 && buffer[length - 1] == '\r' ) length--;
	vstring *line = realtime_string_from_utf8_bytes((const vbyte *)buffer, (int)length);
	free(buffer);
	return line;
}

HL_PRIM realtime_file_output *HL_NAME(__sys_stderr)( void ) {
	realtime_stderr.stream = stderr;
	return &realtime_stderr;
}

HL_PRIM void HL_NAME(__file_output_write_string)( realtime_file_output *output, vstring *value ) {
	if( output == NULL || output->stream == NULL ) hl_error("Invalid file output");
	const char *utf8 = value == NULL ? "" : realtime_string_utf8(value);
	size_t length = strlen(utf8);
	if( length > 0 && fwrite(utf8,1,length,output->stream) != length ) hl_error("Could not write file output");
}

HL_PRIM void HL_NAME(__file_output_flush)( realtime_file_output *output ) {
	if( output == NULL || output->stream == NULL || fflush(output->stream) != 0 ) hl_error("Could not flush file output");
}
