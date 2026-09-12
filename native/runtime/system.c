extern vbyte *hl_sys_get_env( vbyte *name );
extern bool hl_sys_put_env( vbyte *name, vbyte *value );
extern int hl_sys_command( vbyte *command );
extern void hl_sys_print( vbyte *value );

HL_PRIM vbyte *HL_NAME(__sys_system_name)( void ) {
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

HL_PRIM vbyte *HL_NAME(__sys_get_env)( vbyte *name ) {
	char *owned;
	vbyte *argument = realtime_platform_argument(name,&owned);
	vbyte *result = hl_sys_get_env(argument);
	free(owned);
	return realtime_string_from_platform(result);
}

HL_PRIM bool HL_NAME(__sys_put_env)( vbyte *name, vbyte *value ) {
	char *owned_name, *owned_value;
	vbyte *name_argument = realtime_platform_argument(name,&owned_name);
	vbyte *value_argument = realtime_platform_argument(value,&owned_value);
	bool result = hl_sys_put_env(name_argument,value_argument);
	free(owned_name);
	free(owned_value);
	return result;
}

HL_PRIM int HL_NAME(__sys_command)( vbyte *command ) {
	char *owned;
	vbyte *argument = realtime_platform_argument(command,&owned);
	int result = hl_sys_command(argument);
	free(owned);
	return result;
}

HL_PRIM void HL_NAME(__sys_print)( vbyte *value ) {
	/* Unlike paths and process strings, sys_print always accepts HashLink's
	   UTF-16 string representation and performs its own console conversion. */
	hl_sys_print(value);
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

HL_PRIM void HL_NAME(__file_output_write_string)( realtime_file_output *output, vbyte *value ) {
	if( output == NULL || output->stream == NULL ) hl_error("Invalid file output");
	const char *utf8 = value == NULL ? "" : hl_to_utf8((const uchar *)value);
	size_t length = strlen(utf8);
	if( length > 0 && fwrite(utf8,1,length,output->stream) != length ) hl_error("Could not write file output");
}

HL_PRIM void HL_NAME(__file_output_flush)( realtime_file_output *output ) {
	if( output == NULL || output->stream == NULL || fflush(output->stream) != 0 ) hl_error("Could not flush file output");
}
