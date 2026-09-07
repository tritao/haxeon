package compiler.runtime;

import compiler.Compiler;
import compiler.Compiler.NativeFunction;
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
class RuntimeNatives {
	public static inline var VERSION:Int = 1;

	public static function register(compiler:Compiler):Void {
		for (native in configuration())
			compiler.registerNative(native.name, native.library, native.symbol, native.arguments, native.result);
	}

	/** Immutable native definitions shared by compiler snapshots and services. */
	public static function configuration():Array<NativeFunction> {
		var definitions:Array<NativeFunction> = [];
		definitions.push(native("trace", "std", "sys_print", [TString], TVoid));
		definitions.push(native("Sys.println", "std", "sys_print", [TString], TVoid));
		definitions.push(native("Sys.time", "std", "sys_time", [], TFloat));
		definitions.push(native("Sys.cpuTime", "std", "sys_cpu_time", [], TFloat));
		definitions.push(native("Sys.threadCpuTime", "std", "sys_thread_cpu_time", [], TFloat));
		definitions.push(native("Sys.processMemory", "std", "sys_process_memory", [], TFloat));
		definitions.push(native("Sys.getCwd", "std", "sys_get_cwd", [], TString));
		definitions.push(native("Sys.setCwd", "std", "sys_set_cwd", [TString], TBool));
		definitions.push(native("Sys.fullPath", "std", "sys_full_path", [TString], TString));
		definitions.push(native("Sys.executablePath", "std", "sys_exe_path", [], TString));
		definitions.push(native("Sys.getEnv", "std", "sys_get_env", [TString], TNullable(TString)));
		definitions.push(native("Sys.putEnv", "std", "sys_put_env", [TString, TString], TBool));
		definitions.push(native("Sys.exists", "std", "sys_exists", [TString], TBool));
		definitions.push(native("Sys.isDir", "std", "sys_is_dir", [TString], TBool));
		definitions.push(native("Sys.createDir", "std", "sys_create_dir", [TString, TInt], TBool));
		definitions.push(native("Sys.removeDir", "std", "sys_remove_dir", [TString], TBool));
		definitions.push(native("Sys.delete", "std", "sys_delete", [TString], TBool));
		definitions.push(native("Sys.rename", "std", "sys_rename", [TString, TString], TBool));
		definitions.push(native("Sys.readDir", "std", "sys_read_dir", [TString], TArray(TString)));
		definitions.push(native("Sys.command", "std", "sys_command", [TString], TInt));
		definitions.push(native("Sys.sleep", "std", "sys_sleep", [TFloat], TVoid));
		definitions.push(native("Sys.getPid", "std", "sys_getpid", [], TInt));
		definitions.push(native("Sys.getChar", "std", "sys_get_char", [TBool], TInt));
		definitions.push(native("Sys.args", "realtime_runtime", "__sys_args", [], TArray(TString)));
		definitions.push(native("Std.parseInt", "realtime_runtime", "__std_parse_int", [TString], TInt));
		definitions.push(native("Std.parseFloat", "realtime_runtime", "__std_parse_float", [TString], TFloat));
		definitions.push(native("__std_int_f64", "realtime_runtime", "__std_int_f64", [TFloat], TInt));
		definitions.push(native("Std.random", "realtime_runtime", "__std_random", [TInt], TInt));
		definitions.push(native("Math.isNaN", "realtime_runtime", "__math_is_nan", [TFloat], TBool));
		definitions.push(native("Std.string", "realtime_runtime", "__std_string", [TDynamic], TString));
		definitions.push(native("Reflect.compare", "realtime_runtime", "__reflect_compare", [TDynamic, TDynamic], TInt));
		definitions.push(native("StringTools.startsWith", "realtime_runtime", "__string_starts_with", [TString, TString], TBool));
		definitions.push(native("StringTools.endsWith", "realtime_runtime", "__string_ends_with", [TString, TString], TBool));
		definitions.push(native("StringTools.replace", "realtime_runtime", "__string_replace", [TString, TString, TString], TString));
		definitions.push(native("StringTools.ltrim", "realtime_runtime", "__string_ltrim", [TString], TString));
		definitions.push(native("StringTools.trim", "realtime_runtime", "__string_trim", [TString], TString));
		definitions.push(native("StringTools.isSpace", "realtime_runtime", "__string_is_space", [TString, TInt], TBool));
		definitions.push(native("__string_last_index_of", "realtime_runtime", "__string_last_index_of", [TString, TString], TInt));
		definitions.push(native("__string_index_of_from", "realtime_runtime", "__string_index_of_from", [TString, TString, TInt], TInt));
		definitions.push(native("__string_to_lower_case", "realtime_runtime", "__string_to_lower_case", [TString], TString));
		definitions.push(native("__string_split", "realtime_runtime", "__string_split", [TString, TString], TArray(TString)));
		definitions.push(native("sys.io.File.getContent", "realtime_runtime", "__file_get_content", [TString], TString));
		definitions.push(native("sys.io.File.saveContent", "realtime_runtime", "__file_save_content", [TString, TString], TVoid));
		var bytes:CompilerType = TBytes,
			input:CompilerType = TNativeAbstract("realtime_bytes_input"),
			output:CompilerType = TNativeAbstract("realtime_bytes_output");
		definitions.push(native("haxe.io.Bytes.alloc", "realtime_runtime", "__bytes_alloc", [TInt], bytes));
		definitions.push(native("haxe.io.Bytes.ofString", "realtime_runtime", "__bytes_of_string", [TString], bytes));
		definitions.push(native("__bytes_length", "realtime_runtime", "__bytes_length", [bytes], TInt));
		definitions.push(native("__bytes_get", "realtime_runtime", "__bytes_get", [bytes, TInt], TInt));
		definitions.push(native("__bytes_set", "realtime_runtime", "__bytes_set", [bytes, TInt, TInt], TVoid));
		definitions.push(native("__bytes_set_i32", "realtime_runtime", "__bytes_set_i32", [bytes, TInt, TInt], TVoid));
		definitions.push(native("__bytes_sub", "realtime_runtime", "__bytes_sub", [bytes, TInt, TInt], bytes));
		definitions.push(native("__bytes_compare", "realtime_runtime", "__bytes_compare", [bytes, bytes], TInt));
		definitions.push(native("__bytes_to_string", "realtime_runtime", "__bytes_to_string", [bytes], TString));
		definitions.push(native("__bytes_input_new", "realtime_runtime", "__bytes_input_new", [bytes], input));
		definitions.push(native("__bytes_input_position", "realtime_runtime", "__bytes_input_position", [input], TInt));
		definitions.push(native("__bytes_input_big_endian", "realtime_runtime", "__bytes_input_big_endian", [input], TBool));
		definitions.push(native("__bytes_input_set_big_endian", "realtime_runtime", "__bytes_input_set_big_endian", [input, TBool], TVoid));
		definitions.push(native("__bytes_input_read_byte", "realtime_runtime", "__bytes_input_read_byte", [input], TInt));
		definitions.push(native("__bytes_input_read_i32", "realtime_runtime", "__bytes_input_read_i32", [input], TInt));
		definitions.push(native("__bytes_input_read_f64", "realtime_runtime", "__bytes_input_read_f64", [input], TFloat));
		definitions.push(native("__bytes_input_read_string", "realtime_runtime", "__bytes_input_read_string", [input, TInt], TString));
		definitions.push(native("__bytes_input_read", "realtime_runtime", "__bytes_input_read", [input, TInt], bytes));
		definitions.push(native("__bytes_output_new", "realtime_runtime", "__bytes_output_new", [], output));
		definitions.push(native("__bytes_output_big_endian", "realtime_runtime", "__bytes_output_big_endian", [output], TBool));
		definitions.push(native("__bytes_output_set_big_endian", "realtime_runtime", "__bytes_output_set_big_endian", [output, TBool], TVoid));
		definitions.push(native("__bytes_output_write_byte", "realtime_runtime", "__bytes_output_write_byte", [output, TInt], TVoid));
		definitions.push(native("__bytes_output_write_i32", "realtime_runtime", "__bytes_output_write_i32", [output, TInt], TVoid));
		definitions.push(native("__bytes_output_write_f64", "realtime_runtime", "__bytes_output_write_f64", [output, TFloat], TVoid));
		definitions.push(native("__bytes_output_write_string", "realtime_runtime", "__bytes_output_write_string", [output, TString], TVoid));
		definitions.push(native("__bytes_output_write", "realtime_runtime", "__bytes_output_write", [output, bytes], TVoid));
		definitions.push(native("__bytes_output_get_bytes", "realtime_runtime", "__bytes_output_get_bytes", [output], bytes));
		definitions.push(native("sys.io.File.saveBytes", "realtime_runtime", "__file_save_bytes", [TString, bytes], TVoid));
		var date:CompilerType = TNativeAbstract("realtime_date");
		definitions.push(native("Date.now", "realtime_runtime", "__date_now", [], date));
		definitions.push(native("__date_get_time", "realtime_runtime", "__date_get_time", [date], TFloat));
		return definitions;
	}

	static function native(name:String, library:String, symbol:String, arguments:Array<CompilerType>, result:CompilerType):NativeFunction
		return {
			name: name,
			library: library,
			symbol: symbol,
			arguments: arguments,
			result: result
		};
}
