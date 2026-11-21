/* The haxeon command: the HashLink VM running the Haxeon CLI (tools.HaxeonCli), with the command line after it.
 *
 * `hl module.hl` runs any module; `haxeon ...` runs the CLI's bytecode, which the native build compiles and publishes beside
 * this executable (HAXEON_CLI_BYTECODE). An executable built in a checkout belongs to it, as the shell launchers did:
 * HAXEON_HOME and HAXEON_HASHLINK_DIR name that checkout. HAXEON_CLI_HL runs other CLI bytecode instead. */
/* No hl.h: its macros (_GUID) break <windows.h>, and the VM's entry point is all this needs of HashLink. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef HAXEON_SOURCE_DIR
#	error "HAXEON_SOURCE_DIR, HAXEON_HASHLINK_DIR and HAXEON_CLI_BYTECODE come from CMakeLists.txt"
#endif

#ifdef _WIN32
#	include <windows.h>
#	include <io.h>

int hl_vm_main( int argc, wchar_t *argv[] );

static wchar_t *widen( const char *text ) {
	int length = MultiByteToWideChar(CP_UTF8,0,text,-1,NULL,0);
	wchar_t *wide = (wchar_t*)malloc(sizeof(wchar_t) * (size_t)length);
	if( wide == NULL ) return NULL;
	MultiByteToWideChar(CP_UTF8,0,text,-1,wide,length);
	return wide;
}

int wmain( int argc, wchar_t *argv[] ) {
	const wchar_t *override = _wgetenv(L"HAXEON_CLI_HL");
	wchar_t *cli = override != NULL && *override ? (wchar_t*)override : widen(HAXEON_CLI_BYTECODE);
	wchar_t **arguments = (wchar_t**)malloc(sizeof(wchar_t*) * (size_t)(argc + 2));
	if( cli == NULL || arguments == NULL ) return 1;
	_putenv_s("HAXEON_HOME",HAXEON_SOURCE_DIR);
	_putenv_s("HAXEON_HASHLINK_DIR",HAXEON_HASHLINK_DIR);
	{
		/* The CLI colours diagnostics only for a terminal, which the VM cannot ask about; a console also needs ANSI turned on. */
		HANDLE error = GetStdHandle(STD_ERROR_HANDLE);
		DWORD mode = 0;
		int terminal = _isatty(_fileno(stderr)) && GetConsoleMode(error,&mode)
			&& SetConsoleMode(error,mode | 0x0004 /* ENABLE_VIRTUAL_TERMINAL_PROCESSING */);
		_putenv_s("HAXEON_STDERR_TERMINAL",terminal ? "1" : "0");
	}
	if( _waccess(cli,0) != 0 ) {
		fwprintf(stderr,L"Missing the Haxeon CLI bytecode %ls; build the native runtime (scripts\\build-native.ps1)\n",cli);
		return 1;
	}
	arguments[0] = argv[0];
	arguments[1] = cli;
	memcpy(arguments + 2,argv + 1,sizeof(wchar_t*) * (size_t)(argc - 1));
	arguments[argc + 1] = NULL;
	return hl_vm_main(argc + 1,arguments);
}
#else
#	include <unistd.h>

int hl_vm_main( int argc, char *argv[] );

int main( int argc, char *argv[] ) {
	const char *override = getenv("HAXEON_CLI_HL");
	const char *cli = override != NULL && *override ? override : HAXEON_CLI_BYTECODE;
	char **arguments = (char**)malloc(sizeof(char*) * (size_t)(argc + 2));
	if( arguments == NULL ) return 1;
	setenv("HAXEON_HOME",HAXEON_SOURCE_DIR,1);
	setenv("HAXEON_HASHLINK_DIR",HAXEON_HASHLINK_DIR,1);
	/* The CLI colours diagnostics only for a terminal, which the VM cannot ask about. */
	setenv("HAXEON_STDERR_TERMINAL",isatty(STDERR_FILENO) ? "1" : "0",1);
	if( access(cli,R_OK) != 0 ) {
		fprintf(stderr,"Missing the Haxeon CLI bytecode %s; build the native runtime (scripts/build-native.sh)\n",cli);
		return 1;
	}
	arguments[0] = argv[0];
	arguments[1] = (char*)cli;
	memcpy(arguments + 2,argv + 1,sizeof(char*) * (size_t)(argc - 1));
	arguments[argc + 1] = NULL;
	return hl_vm_main(argc + 1,arguments);
}
#endif
