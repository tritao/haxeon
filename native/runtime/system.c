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
			target[index++] = realtime_string_from_platform((vbyte *)entry);
		FreeEnvironmentStringsW(environment);
	}
#else
	extern char **environ;
	int count = 0;
	for( char **entry = environ; entry != NULL && *entry != NULL; entry++ ) count++;
	varray *result = hl_alloc_array(hl_string_type,count);
	vstring **target = hl_aptr(result,vstring *);
	for( int index = 0; index < count; index++ )
		target[index] = realtime_string_from_utf8(environ[index]);
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
