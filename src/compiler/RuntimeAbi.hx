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
		compiler.registerNative("trace", "std", "sys_print", [TString], TVoid);
		compiler.registerNative("Sys.println", "std", "sys_print", [TString], TVoid);
		compiler.registerNative("Sys.time", "std", "sys_time", [], TFloat);
		compiler.registerNative("Sys.cpuTime", "std", "sys_cpu_time", [], TFloat);
		compiler.registerNative("Sys.threadCpuTime", "std", "sys_thread_cpu_time", [], TFloat);
		compiler.registerNative("Sys.processMemory", "std", "sys_process_memory", [], TFloat);
		compiler.registerNative("Sys.getCwd", "std", "sys_get_cwd", [], TString);
		compiler.registerNative("Sys.setCwd", "std", "sys_set_cwd", [TString], TBool);
		compiler.registerNative("Sys.fullPath", "std", "sys_full_path", [TString], TString);
		compiler.registerNative("Sys.executablePath", "std", "sys_exe_path", [], TString);
		compiler.registerNative("Sys.getEnv", "std", "sys_get_env", [TString], TNullable(TString));
		compiler.registerNative("Sys.putEnv", "std", "sys_put_env", [TString, TString], TBool);
		compiler.registerNative("Sys.exists", "std", "sys_exists", [TString], TBool);
		compiler.registerNative("Sys.isDir", "std", "sys_is_dir", [TString], TBool);
		compiler.registerNative("Sys.createDir", "std", "sys_create_dir", [TString, TInt], TBool);
		compiler.registerNative("Sys.removeDir", "std", "sys_remove_dir", [TString], TBool);
		compiler.registerNative("Sys.delete", "std", "sys_delete", [TString], TBool);
		compiler.registerNative("Sys.rename", "std", "sys_rename", [TString, TString], TBool);
		compiler.registerNative("Sys.readDir", "std", "sys_read_dir", [TString], TArray(TString));
		compiler.registerNative("Sys.command", "std", "sys_command", [TString], TInt);
		compiler.registerNative("Sys.sleep", "std", "sys_sleep", [TFloat], TVoid);
		compiler.registerNative("Sys.getPid", "std", "sys_getpid", [], TInt);
		compiler.registerNative("Sys.getChar", "std", "sys_get_char", [TBool], TInt);
		compiler.registerNative("Sys.args", "std", "sys_args", [], TArray(TString));
		compiler.registerNative("Std.parseInt", "realtime_runtime", "__std_parse_int", [TString], TInt);
		compiler.registerNative("Std.parseFloat", "realtime_runtime", "__std_parse_float", [TString], TFloat);
		compiler.registerNative("Std.string", "realtime_runtime", "__std_string", [TDynamic], TString);
		compiler.registerNative("Reflect.compare", "realtime_runtime", "__reflect_compare", [TDynamic, TDynamic], TInt);
		compiler.registerNative("StringTools.startsWith", "realtime_runtime", "__string_starts_with", [TString, TString], TBool);
		compiler.registerNative("StringTools.endsWith", "realtime_runtime", "__string_ends_with", [TString, TString], TBool);
	}
}
