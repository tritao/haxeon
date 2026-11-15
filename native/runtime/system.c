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

/*
 * A host stream for sys.io.FileInput and FileOutput: one of the process's standard streams, which the program never closes,
 * or a file it opened, which closes explicitly or when collected. The finalizer slot comes first, as
 * hl_gc_alloc_finalizer requires.
 */
typedef struct realtime_stream {
	void (*finalize)( struct realtime_stream * );
	FILE *stream;
	bool owned;
} realtime_stream;
typedef realtime_stream realtime_file_output;
typedef realtime_stream realtime_file_input;

static realtime_stream realtime_stdout = {NULL, NULL, false};
static realtime_stream realtime_stderr = {NULL, NULL, false};
static realtime_stream realtime_stdin = {NULL, NULL, false};

static void realtime_stream_finalize( realtime_stream *s ) {
	if( s->owned && s->stream != NULL ) fclose(s->stream);
	s->stream = NULL;
}

static FILE *realtime_stream_file( realtime_stream *s ) {
	if( s == NULL || s->stream == NULL ) hl_error("The file is closed");
	return s->stream;
}

static realtime_stream *realtime_stream_open( vstring *path, const char *mode ) {
#ifdef HL_WIN
	wchar_t wide_mode[4];
	int i = 0;
	for( ; mode[i] != 0 && i < 3; i++ ) wide_mode[i] = (wchar_t)mode[i];
	wide_mode[i] = 0;
	FILE *file = _wfopen((const wchar_t *)realtime_string_data(path), wide_mode);
#else
	char *path_utf8 = realtime_utf8_copy(path);
	FILE *file = fopen(path_utf8, mode);
	free(path_utf8);
#endif
	if( file == NULL ) hl_error("Could not open the file");
	realtime_stream *s = (realtime_stream *)hl_gc_alloc_finalizer(sizeof(realtime_stream));
	s->finalize = realtime_stream_finalize;
	s->stream = file;
	s->owned = true;
	return s;
}

static void realtime_stream_close( realtime_stream *s ) {
	if( s == NULL || s->stream == NULL ) return;
	if( s->owned ) {
		FILE *file = s->stream;
		s->stream = NULL;
		if( fclose(file) != 0 ) hl_error("Could not close the file");
	} else
		fflush(s->stream);
}

/* SeekBegin, SeekCur and SeekEnd are 0, 1 and 2, as in sys.io.FileSeek. */
static bool realtime_stream_seek( realtime_stream *s, int position, int kind ) {
	int whence = kind == 1 ? SEEK_CUR : kind == 2 ? SEEK_END : SEEK_SET;
	return fseek(realtime_stream_file(s), (long)position, whence) == 0;
}

HL_PRIM realtime_file_output *HL_NAME(__sys_stdout)( void ) {
	realtime_stdout.stream = stdout;
	return &realtime_stdout;
}

HL_PRIM realtime_file_output *HL_NAME(__sys_stderr)( void ) {
	realtime_stderr.stream = stderr;
	return &realtime_stderr;
}

HL_PRIM realtime_file_input *HL_NAME(__sys_stdin)( void ) {
	realtime_stdin.stream = stdin;
	return &realtime_stdin;
}

HL_PRIM realtime_file_input *HL_NAME(__file_input_open)( vstring *path, bool binary ) {
	return realtime_stream_open(path, binary ? "rb" : "r");
}

HL_PRIM realtime_file_output *HL_NAME(__file_output_open)( vstring *path, bool append, bool binary ) {
	return realtime_stream_open(path, append ? (binary ? "ab" : "a") : (binary ? "wb" : "w"));
}

/* The next byte of `input`, or -1 at the end of the input. */
HL_PRIM int HL_NAME(__file_input_read_byte)( realtime_file_input *input ) {
	int code = fgetc(realtime_stream_file(input));
	return code == EOF ? -1 : code;
}

/* Reads up to `len` bytes into `bytes` at `pos`; returns how many, 0 only at the end of the input. */
HL_PRIM int HL_NAME(__file_input_read_bytes)( realtime_file_input *input, realtime_bytes *bytes, int pos, int len ) {
	FILE *file = realtime_stream_file(input);
	realtime_bytes_bounds(bytes, pos, len);
	return len == 0 ? 0 : (int)fread(bytes->data + pos, 1, (size_t)len, file);
}

/* The next line of `input` without its "\n" or "\r\n", or NULL at the end of the input. */
HL_PRIM vstring *HL_NAME(__file_input_read_line)( realtime_file_input *input ) {
	FILE *file = realtime_stream_file(input);
	size_t capacity = 256, length = 0;
	char *buffer = (char *)malloc(capacity);
	int code = EOF;
	if( buffer == NULL ) hl_error("Out of memory reading a line");
	while( (code = fgetc(file)) != EOF && code != '\n' ) {
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

HL_PRIM bool HL_NAME(__file_input_eof)( realtime_file_input *input ) { return feof(realtime_stream_file(input)) != 0; }
HL_PRIM int HL_NAME(__file_input_tell)( realtime_file_input *input ) { return (int)ftell(realtime_stream_file(input)); }
HL_PRIM bool HL_NAME(__file_input_seek)( realtime_file_input *input, int position, int kind ) { return realtime_stream_seek(input, position, kind); }
HL_PRIM void HL_NAME(__file_input_close)( realtime_file_input *input ) { realtime_stream_close(input); }

HL_PRIM void HL_NAME(__file_output_write_byte)( realtime_file_output *output, int value ) {
	if( fputc(value & 0xFF, realtime_stream_file(output)) == EOF ) hl_error("Could not write file output");
}

/* Writes `len` bytes of `bytes` from `pos`; returns how many were written. */
HL_PRIM int HL_NAME(__file_output_write_bytes)( realtime_file_output *output, realtime_bytes *bytes, int pos, int len ) {
	FILE *file = realtime_stream_file(output);
	realtime_bytes_bounds(bytes, pos, len);
	return len == 0 ? 0 : (int)fwrite(bytes->data + pos, 1, (size_t)len, file);
}

HL_PRIM void HL_NAME(__file_output_write_string)( realtime_file_output *output, vstring *value ) {
	FILE *file = realtime_stream_file(output);
	const char *utf8 = value == NULL ? "" : realtime_string_utf8(value);
	size_t length = strlen(utf8);
	if( length > 0 && fwrite(utf8,1,length,file) != length ) hl_error("Could not write file output");
}

HL_PRIM void HL_NAME(__file_output_flush)( realtime_file_output *output ) {
	if( fflush(realtime_stream_file(output)) != 0 ) hl_error("Could not flush file output");
}

HL_PRIM int HL_NAME(__file_output_tell)( realtime_file_output *output ) { return (int)ftell(realtime_stream_file(output)); }
HL_PRIM bool HL_NAME(__file_output_seek)( realtime_file_output *output, int position, int kind ) { return realtime_stream_seek(output, position, kind); }
HL_PRIM void HL_NAME(__file_output_close)( realtime_file_output *output ) { realtime_stream_close(output); }
