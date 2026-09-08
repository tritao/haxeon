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
