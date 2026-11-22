/* The haxeon command: the HashLink VM running the Haxeon CLI (tools.HaxeonCli), with the command line after it.
 *
 * `hl module.hl` runs any module; `haxeon ...` runs the CLI's bytecode, which the native build compiles and publishes beside
 * this executable (HAXEON_CLI_BYTECODE). An executable built in a checkout belongs to it, as the shell launchers did:
 * HAXEON_HOME and HAXEON_HASHLINK_DIR name that checkout. The same executable in a release (`haxeon dev package`) is
 * bin/haxeon below a root that holds haxeon-release.txt, wherever it was unpacked: found from the executable's own path, that
 * root is HAXEON_HOME and bin the VM's directory, with the CLI's bytecode in it.
 *
 * When Haxeon is built ahead of time (AOT_EXECUTABLE in the VM's directory, build.AotCompiler), the launcher runs the CLI in it
 * instead, `haxeon-aot cli ARGUMENTS`, which starts without the JIT. Whether that executable is current, built from these
 * sources, is its own question to answer (tools.CompilerExecutable): when it is not, it runs the CLI's bytecode on the VM. To
 * run the CLI's bytecode while the executable is current, remove or rename the executable. */
/* No hl.h: its macros (_GUID) break <windows.h>, and the VM's entry point is all this needs of HashLink. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef HAXEON_SOURCE_DIR
#	error "HAXEON_SOURCE_DIR, HAXEON_HASHLINK_DIR and HAXEON_CLI_BYTECODE come from CMakeLists.txt"
#endif

#define RELEASE_MARKER "haxeon-release.txt"
#define RELEASE_CLI "haxeon-cli.hl"
#define AOT_EXECUTABLE "haxeon-aot"

#ifdef _WIN32
#	include <windows.h>
#	include <io.h>
#	include <wchar.h>

int hl_vm_main( int argc, wchar_t *argv[] );

static wchar_t *widen( const char *text ) {
	int length = MultiByteToWideChar(CP_UTF8,0,text,-1,NULL,0);
	wchar_t *wide = (wchar_t*)malloc(sizeof(wchar_t) * (size_t)length);
	if( wide == NULL ) return NULL;
	MultiByteToWideChar(CP_UTF8,0,text,-1,wide,length);
	return wide;
}

/* `directory` + "/" + `name`, or NULL. */
static wchar_t *join( const wchar_t *directory, const wchar_t *name ) {
	size_t length = wcslen(directory) + wcslen(name) + 2;
	wchar_t *path = (wchar_t*)malloc(sizeof(wchar_t) * length);
	if( path != NULL ) swprintf(path,length,L"%ls/%ls",directory,name);
	return path;
}

/* The release root this executable is in (the parent of its directory, which holds the marker), with '/' separators as a
 * checkout's paths have; NULL when this is not a release's haxeon. `bin` gets the executable's directory. */
static wchar_t *release_root( wchar_t **bin ) {
	DWORD capacity = 32768, length;
	wchar_t *path = (wchar_t*)malloc(sizeof(wchar_t) * capacity), *slash, *marker;
	if( path == NULL ) return NULL;
	length = GetModuleFileNameW(NULL,path,capacity);
	if( length == 0 || length >= capacity ) { free(path); return NULL; }
	for( wchar_t *c = path; *c; c++ ) if( *c == L'\\' ) *c = L'/';
	if( (slash = wcsrchr(path,L'/')) == NULL ) { free(path); return NULL; }
	*slash = 0;
	if( (*bin = _wcsdup(path)) == NULL || (slash = wcsrchr(path,L'/')) == NULL ) { free(path); return NULL; }
	*slash = 0;
	marker = join(path,L"" RELEASE_MARKER);
	if( marker == NULL || _waccess(marker,0) != 0 ) { free(marker); free(path); return NULL; }
	free(marker);
	return path;
}

/* Runs `AOT_EXECUTABLE cli` with this command's arguments, as typed (the command line after the program's name, which Windows
 * passes unsplit), and returns its exit code; -1 when there is no such executable or it cannot start. */
static int run_ahead_of_time( void ) {
	const wchar_t *directory = _wgetenv(L"HAXEON_HASHLINK_DIR"), *line = GetCommandLineW();
	wchar_t *program, *command;
	size_t length;
	STARTUPINFOW startup;
	PROCESS_INFORMATION process;
	DWORD status = 1;
	if( directory == NULL ) return -1;
	length = wcslen(directory) + 64;
	program = (wchar_t*)malloc(sizeof(wchar_t) * length);
	if( program == NULL ) return -1;
	swprintf(program,length,L"%ls/" L"" AOT_EXECUTABLE L".exe",directory);
	if( _waccess(program,0) != 0 ) { free(program); return -1; }
	/* The program's name ends at its closing quote when quoted, else at the first blank (the C runtime's rule for it). */
	if( *line == L'"' ) {
		line++;
		while( *line && *line != L'"' ) line++;
		if( *line ) line++;
	} else
		while( *line && *line != L' ' && *line != L'\t' ) line++;
	length = wcslen(program) + wcslen(line) + 16;
	command = (wchar_t*)malloc(sizeof(wchar_t) * length);
	if( command == NULL ) { free(program); return -1; }
	swprintf(command,length,L"\"%ls\" cli%ls",program,line);
	memset(&startup,0,sizeof(startup));
	startup.cb = sizeof(startup);
	if( !CreateProcessW(program,command,NULL,NULL,TRUE,0,NULL,NULL,&startup,&process) ) {
		free(command);
		free(program);
		return -1;
	}
	/* Ctrl+C reaches the CLI too, which decides what it means; this process only waits for it. */
	SetConsoleCtrlHandler(NULL,TRUE);
	WaitForSingleObject(process.hProcess,INFINITE);
	GetExitCodeProcess(process.hProcess,&status);
	CloseHandle(process.hThread);
	CloseHandle(process.hProcess);
	return (int)status;
}

int wmain( int argc, wchar_t *argv[] ) {
	wchar_t *bin = NULL, *root = release_root(&bin), *cli;
	wchar_t **arguments = (wchar_t**)malloc(sizeof(wchar_t*) * (size_t)(argc + 2));
	if( root != NULL ) {
		_wputenv_s(L"HAXEON_HOME",root);
		_wputenv_s(L"HAXEON_HASHLINK_DIR",bin);
		cli = join(bin,L"" RELEASE_CLI);
	} else {
		_putenv_s("HAXEON_HOME",HAXEON_SOURCE_DIR);
		_putenv_s("HAXEON_HASHLINK_DIR",HAXEON_HASHLINK_DIR);
		cli = widen(HAXEON_CLI_BYTECODE);
	}
	if( cli == NULL || arguments == NULL ) return 1;
	{
		/* The CLI colours diagnostics only for a terminal, which the VM cannot ask about; a console also needs ANSI turned on. */
		HANDLE error = GetStdHandle(STD_ERROR_HANDLE);
		DWORD mode = 0;
		int terminal = _isatty(_fileno(stderr)) && GetConsoleMode(error,&mode)
			&& SetConsoleMode(error,mode | 0x0004 /* ENABLE_VIRTUAL_TERMINAL_PROCESSING */);
		_putenv_s("HAXEON_STDERR_TERMINAL",terminal ? "1" : "0");
	}
	{
		int status = run_ahead_of_time();
		if( status >= 0 ) return status;
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
#	ifdef __APPLE__
#		include <mach-o/dyld.h>
#		include <stdint.h>
#	endif

int hl_vm_main( int argc, char *argv[] );

/* `directory` + "/" + `name`, or NULL. */
static char *join( const char *directory, const char *name ) {
	size_t length = strlen(directory) + strlen(name) + 2;
	char *path = (char*)malloc(length);
	if( path != NULL ) snprintf(path,length,"%s/%s",directory,name);
	return path;
}

/* The release root this executable is in (the parent of its directory, which holds the marker), with symbolic links resolved;
 * NULL when this is not a release's haxeon. `bin` gets the executable's directory. */
static char *release_root( char **bin ) {
	char *path = NULL, *slash, *marker;
#	if defined(__APPLE__)
	uint32_t size = 0;
	char *raw;
	_NSGetExecutablePath(NULL,&size);
	if( (raw = (char*)malloc(size)) == NULL ) return NULL;
	if( _NSGetExecutablePath(raw,&size) == 0 ) path = realpath(raw,NULL);
	free(raw);
#	elif defined(__linux__)
	path = realpath("/proc/self/exe",NULL);
#	endif
	if( path == NULL || (slash = strrchr(path,'/')) == NULL ) { free(path); return NULL; }
	*slash = 0;
	if( (*bin = strdup(path)) == NULL || (slash = strrchr(path,'/')) == NULL ) { free(path); return NULL; }
	*slash = 0;
	marker = join(path,RELEASE_MARKER);
	if( marker == NULL || access(marker,R_OK) != 0 ) { free(marker); free(path); return NULL; }
	free(marker);
	return path;
}

/* Becomes `AOT_EXECUTABLE cli ARGUMENTS` when that executable is beside the VM; returns only when it is not, or cannot start. */
static void run_ahead_of_time( int argc, char *argv[] ) {
	const char *directory = getenv("HAXEON_HASHLINK_DIR");
	char *program, **arguments;
	size_t length;
	if( directory == NULL ) return;
	length = strlen(directory) + sizeof("/" AOT_EXECUTABLE);
	program = (char*)malloc(length);
	arguments = (char**)malloc(sizeof(char*) * (size_t)(argc + 2));
	if( program != NULL && arguments != NULL ) {
		snprintf(program,length,"%s/" AOT_EXECUTABLE,directory);
		arguments[0] = program;
		arguments[1] = "cli";
		memcpy(arguments + 2,argv + 1,sizeof(char*) * (size_t)(argc - 1));
		arguments[argc + 1] = NULL;
		if( access(program,X_OK) == 0 ) execv(program,arguments);
	}
	free(arguments);
	free(program);
}

int main( int argc, char *argv[] ) {
	char *bin = NULL, *root = release_root(&bin);
	const char *cli;
	char **arguments = (char**)malloc(sizeof(char*) * (size_t)(argc + 2));
	if( root != NULL ) {
		setenv("HAXEON_HOME",root,1);
		setenv("HAXEON_HASHLINK_DIR",bin,1);
		cli = join(bin,RELEASE_CLI);
	} else {
		setenv("HAXEON_HOME",HAXEON_SOURCE_DIR,1);
		setenv("HAXEON_HASHLINK_DIR",HAXEON_HASHLINK_DIR,1);
		cli = HAXEON_CLI_BYTECODE;
	}
	if( cli == NULL || arguments == NULL ) return 1;
	/* The CLI colours diagnostics only for a terminal, which the VM cannot ask about. */
	setenv("HAXEON_STDERR_TERMINAL",isatty(STDERR_FILENO) ? "1" : "0",1);
	run_ahead_of_time(argc,argv);
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
