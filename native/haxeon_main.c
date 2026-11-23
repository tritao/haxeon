/* The haxeon command: the HashLink VM running the Haxeon CLI (tools.HaxeonCli), with the command line after it.
 *
 * `hl module.hl` runs any module; `haxeon ...` runs the CLI's bytecode, haxeon-cli.hl beside this executable. The executable
 * is bin/haxeon in Haxeon's SDK (docs/design/SDK_LAYOUT.md), a checkout's out/sdk or an unpacked release, which it finds from
 * its own path: the SDK is bin/.., whose manifest haxeon-sdk.toml it must hold. It sets HAXEON_SDK to the SDK and
 * HAXEON_HOME to the manifest's `source`, the checkout the SDK was built from, or to the SDK when it has none (a release).
 *
 * When Haxeon is built ahead of time (AOT_EXECUTABLE in the VM's directory, build.AotCompiler), the launcher runs the CLI in it
 * instead, `haxeon-aot cli ARGUMENTS`, which starts without the JIT. Whether that executable is current, built from these
 * sources, is its own question to answer (tools.CompilerExecutable): when it is not, it runs the CLI's bytecode on the VM. To
 * run the CLI's bytecode while the executable is current, remove or rename the executable. */
/* No hl.h: its macros (_GUID) break <windows.h>, and the VM's entry point is all this needs of HashLink. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SDK_MANIFEST "haxeon-sdk.toml"
#define CLI_BYTECODE "haxeon-cli.hl"
#define AOT_EXECUTABLE "haxeon-aot"

/* The manifest's top-level `source = "PATH"`, or NULL when it has none. The manifest is the SDK's own, which CMake or the release
 * packaging writes: one key per line, values quoted without escapes. */
static char *manifest_source( FILE *manifest ) {
	char line[4096], *start, *end;
	if( manifest == NULL ) return NULL;
	while( fgets(line,sizeof(line),manifest) != NULL ) {
		if( line[0] == '[' ) break;
		if( strncmp(line,"source",6) != 0 ) continue;
		start = line + 6;
		while( *start == ' ' || *start == '\t' ) start++;
		if( *start++ != '=' ) continue;
		while( *start == ' ' || *start == '\t' ) start++;
		if( *start++ != '"' || (end = strchr(start,'"')) == NULL ) continue;
		*end = 0;
		fclose(manifest);
		return strdup(start);
	}
	fclose(manifest);
	return NULL;
}

#ifdef _WIN32
#	include <windows.h>
#	include <io.h>
#	include <wchar.h>

int hl_vm_main( int argc, wchar_t *argv[] );

/* `directory` + "/" + `name`, or NULL. */
static wchar_t *join( const wchar_t *directory, const wchar_t *name ) {
	size_t length = wcslen(directory) + wcslen(name) + 2;
	wchar_t *path = (wchar_t*)malloc(sizeof(wchar_t) * length);
	if( path != NULL ) swprintf(path,length,L"%ls/%ls",directory,name);
	return path;
}

/* The SDK this executable is in (the parent of its directory, which holds the manifest), with '/' separators as the SDK's
 * other paths have; NULL when it is in none. `bin` gets the executable's directory. */
static wchar_t *sdk_root( wchar_t **bin ) {
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
	marker = join(path,L"" SDK_MANIFEST);
	if( marker == NULL || _waccess(marker,0) != 0 ) { free(marker); free(path); return NULL; }
	free(marker);
	return path;
}

/* Runs `AOT_EXECUTABLE cli` with this command's arguments, as typed (the command line after the program's name, which Windows
 * passes unsplit), and returns its exit code; -1 when there is no such executable or it cannot start. */
static int run_ahead_of_time( const wchar_t *directory ) {
	const wchar_t *line = GetCommandLineW();
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
	wchar_t *bin = NULL, *sdk = sdk_root(&bin), *cli, *manifest;
	wchar_t **arguments = (wchar_t**)malloc(sizeof(wchar_t*) * (size_t)(argc + 2));
	char *source;
	if( sdk == NULL ) {
		fwprintf(stderr,L"This haxeon is not in a Haxeon SDK: no " L"" SDK_MANIFEST L" beside its directory\n");
		return 1;
	}
	manifest = join(sdk,L"" SDK_MANIFEST);
	source = manifest == NULL ? NULL : manifest_source(_wfopen(manifest,L"r"));
	_wputenv_s(L"HAXEON_SDK",sdk);
	if( source != NULL ) _putenv_s("HAXEON_HOME",source);
	else _wputenv_s(L"HAXEON_HOME",sdk);
	cli = join(bin,L"" CLI_BYTECODE);
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
		int status = run_ahead_of_time(bin);
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

/* The SDK this executable is in (the parent of its directory, which holds the manifest), with symbolic links resolved; NULL
 * when it is in none. `bin` gets the executable's directory. */
static char *sdk_root( char **bin ) {
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
	marker = join(path,SDK_MANIFEST);
	if( marker == NULL || access(marker,R_OK) != 0 ) { free(marker); free(path); return NULL; }
	free(marker);
	return path;
}

/* Becomes `AOT_EXECUTABLE cli ARGUMENTS` when that executable is beside the VM; returns only when it is not, or cannot start. */
static void run_ahead_of_time( const char *directory, int argc, char *argv[] ) {
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
	char *bin = NULL, *sdk = sdk_root(&bin), *manifest, *source;
	const char *cli;
	char **arguments = (char**)malloc(sizeof(char*) * (size_t)(argc + 2));
	if( sdk == NULL ) {
		fprintf(stderr,"This haxeon is not in a Haxeon SDK: no " SDK_MANIFEST " beside its directory\n");
		return 1;
	}
	manifest = join(sdk,SDK_MANIFEST);
	source = manifest == NULL ? NULL : manifest_source(fopen(manifest,"r"));
	setenv("HAXEON_SDK",sdk,1);
	setenv("HAXEON_HOME",source != NULL ? source : sdk,1);
	cli = join(bin,CLI_BYTECODE);
	if( cli == NULL || arguments == NULL ) return 1;
	/* The CLI colours diagnostics only for a terminal, which the VM cannot ask about. */
	setenv("HAXEON_STDERR_TERMINAL",isatty(STDERR_FILENO) ? "1" : "0",1);
	run_ahead_of_time(bin,argc,argv);
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
