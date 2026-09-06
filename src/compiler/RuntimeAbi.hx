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
		compiler.registerNative("__std_int_f64", "realtime_runtime", "__std_int_f64", [TFloat], TInt);
		compiler.registerNative("Std.random", "realtime_runtime", "__std_random", [TInt], TInt);
		compiler.registerNative("Std.string", "realtime_runtime", "__std_string", [TDynamic], TString);
		compiler.registerNative("Reflect.compare", "realtime_runtime", "__reflect_compare", [TString, TString], TInt);
		compiler.registerNative("StringTools.startsWith", "realtime_runtime", "__string_starts_with", [TString, TString], TBool);
		compiler.registerNative("StringTools.endsWith", "realtime_runtime", "__string_ends_with", [TString, TString], TBool);
		compiler.registerNative("sys.io.File.getContent", "realtime_runtime", "__file_get_content", [TString], TString);
		var bytes:CompilerType = TBytes,
			input:CompilerType = TNativeAbstract("realtime_bytes_input"),
			output:CompilerType = TNativeAbstract("realtime_bytes_output");
		compiler.registerNative("haxe.io.Bytes.alloc", "realtime_runtime", "__bytes_alloc", [TInt], bytes);
		compiler.registerNative("haxe.io.Bytes.ofString", "realtime_runtime", "__bytes_of_string", [TString], bytes);
		compiler.registerNative("__bytes_length", "realtime_runtime", "__bytes_length", [bytes], TInt);
		compiler.registerNative("__bytes_get", "realtime_runtime", "__bytes_get", [bytes, TInt], TInt);
		compiler.registerNative("__bytes_set", "realtime_runtime", "__bytes_set", [bytes, TInt, TInt], TVoid);
		compiler.registerNative("__bytes_set_i32", "realtime_runtime", "__bytes_set_i32", [bytes, TInt, TInt], TVoid);
		compiler.registerNative("__bytes_sub", "realtime_runtime", "__bytes_sub", [bytes, TInt, TInt], bytes);
		compiler.registerNative("__bytes_compare", "realtime_runtime", "__bytes_compare", [bytes, bytes], TInt);
		compiler.registerNative("__bytes_to_string", "realtime_runtime", "__bytes_to_string", [bytes], TString);
		compiler.registerNative("__bytes_input_new", "realtime_runtime", "__bytes_input_new", [bytes], input);
		compiler.registerNative("__bytes_input_position", "realtime_runtime", "__bytes_input_position", [input], TInt);
		compiler.registerNative("__bytes_input_big_endian", "realtime_runtime", "__bytes_input_big_endian", [input], TBool);
		compiler.registerNative("__bytes_input_set_big_endian", "realtime_runtime", "__bytes_input_set_big_endian", [input, TBool], TVoid);
		compiler.registerNative("__bytes_input_read_byte", "realtime_runtime", "__bytes_input_read_byte", [input], TInt);
		compiler.registerNative("__bytes_input_read_i32", "realtime_runtime", "__bytes_input_read_i32", [input], TInt);
		compiler.registerNative("__bytes_input_read_f64", "realtime_runtime", "__bytes_input_read_f64", [input], TFloat);
		compiler.registerNative("__bytes_input_read_string", "realtime_runtime", "__bytes_input_read_string", [input, TInt], TString);
		compiler.registerNative("__bytes_input_read", "realtime_runtime", "__bytes_input_read", [input, TInt], bytes);
		compiler.registerNative("__bytes_output_new", "realtime_runtime", "__bytes_output_new", [], output);
		compiler.registerNative("__bytes_output_big_endian", "realtime_runtime", "__bytes_output_big_endian", [output], TBool);
		compiler.registerNative("__bytes_output_set_big_endian", "realtime_runtime", "__bytes_output_set_big_endian", [output, TBool], TVoid);
		compiler.registerNative("__bytes_output_write_byte", "realtime_runtime", "__bytes_output_write_byte", [output, TInt], TVoid);
		compiler.registerNative("__bytes_output_write_i32", "realtime_runtime", "__bytes_output_write_i32", [output, TInt], TVoid);
		compiler.registerNative("__bytes_output_write_f64", "realtime_runtime", "__bytes_output_write_f64", [output, TFloat], TVoid);
		compiler.registerNative("__bytes_output_write_string", "realtime_runtime", "__bytes_output_write_string", [output, TString], TVoid);
		compiler.registerNative("__bytes_output_write", "realtime_runtime", "__bytes_output_write", [output, bytes], TVoid);
		compiler.registerNative("__bytes_output_get_bytes", "realtime_runtime", "__bytes_output_get_bytes", [output], bytes);
		compiler.registerNative("sys.io.File.saveBytes", "realtime_runtime", "__file_save_bytes", [TString, bytes], TVoid);
		var date:CompilerType = TNativeAbstract("realtime_date");
		compiler.registerNative("Date.now", "realtime_runtime", "__date_now", [], date);
		compiler.registerNative("__date_get_time", "realtime_runtime", "__date_get_time", [date], TFloat);
	}
}
