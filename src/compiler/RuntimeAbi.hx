package compiler;

import compiler.modules.Compiler;
import compiler.types.Type.CompilerType;

/**
 * The small Haxe-compatible host surface that is stable across compiler
 * builds.  Keeping this registration in one place prevents each executable
 * entrypoint from inventing a different set of Sys/trace natives.
 *
 * The first version intentionally delegates to HashLink's std library.  The
 * compiler-owned realtime runtime remains reserved for ABI operations whose
 * representation or reload semantics differ from ordinary HashLink.
 */
class RuntimeAbi {
	public static inline var VERSION:Int = 1;

	public static function register(compiler:Compiler):Void {
		compiler.registerNative("trace", "std", "sys_print", [CompilerType.TString], CompilerType.TVoid);
		compiler.registerNative("Sys.time", "std", "sys_time", [], CompilerType.TFloat);
		compiler.registerNative("Sys.cpuTime", "std", "sys_cpu_time", [], CompilerType.TFloat);
		compiler.registerNative("Sys.threadCpuTime", "std", "sys_thread_cpu_time", [], CompilerType.TFloat);
		compiler.registerNative("Sys.processMemory", "std", "sys_process_memory", [], CompilerType.TFloat);
		compiler.registerNative("Sys.getCwd", "std", "sys_get_cwd", [], CompilerType.TString);
		compiler.registerNative("Sys.setCwd", "std", "sys_set_cwd", [CompilerType.TString], CompilerType.TBool);
		compiler.registerNative("Sys.fullPath", "std", "sys_full_path", [CompilerType.TString], CompilerType.TString);
		compiler.registerNative("Sys.executablePath", "std", "sys_exe_path", [], CompilerType.TString);
		compiler.registerNative("Sys.getEnv", "std", "sys_get_env", [CompilerType.TString], CompilerType.TNullable(CompilerType.TString));
		compiler.registerNative("Sys.putEnv", "std", "sys_put_env", [CompilerType.TString, CompilerType.TString], CompilerType.TBool);
		compiler.registerNative("Sys.exists", "std", "sys_exists", [CompilerType.TString], CompilerType.TBool);
		compiler.registerNative("Sys.isDir", "std", "sys_is_dir", [CompilerType.TString], CompilerType.TBool);
		compiler.registerNative("Sys.createDir", "std", "sys_create_dir", [CompilerType.TString, CompilerType.TInt], CompilerType.TBool);
		compiler.registerNative("Sys.removeDir", "std", "sys_remove_dir", [CompilerType.TString], CompilerType.TBool);
		compiler.registerNative("Sys.delete", "std", "sys_delete", [CompilerType.TString], CompilerType.TBool);
		compiler.registerNative("Sys.rename", "std", "sys_rename", [CompilerType.TString, CompilerType.TString], CompilerType.TBool);
		compiler.registerNative("Sys.readDir", "std", "sys_read_dir", [CompilerType.TString], CompilerType.TArray(CompilerType.TString));
		compiler.registerNative("Sys.command", "std", "sys_command", [CompilerType.TString], CompilerType.TInt);
		compiler.registerNative("Sys.sleep", "std", "sys_sleep", [CompilerType.TFloat], CompilerType.TVoid);
		compiler.registerNative("Sys.getPid", "std", "sys_getpid", [], CompilerType.TInt);
		compiler.registerNative("Sys.getChar", "std", "sys_get_char", [CompilerType.TBool], CompilerType.TInt);
		compiler.registerNative("Sys.args", "std", "sys_args", [], CompilerType.TArray(CompilerType.TString));
	}
}
