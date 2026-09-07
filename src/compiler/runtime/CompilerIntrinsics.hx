package compiler.runtime;

import compiler.Compiler;
import compiler.Compiler.NativeFunction;
import compiler.types.Type.CompilerType;

/** Native operations emitted directly by primitive and language lowering. */
class CompilerIntrinsics {
	public static inline var VERSION:Int = 1;

	public static function register(compiler:Compiler):Void {
		for (native in configuration())
			compiler.registerNative(native.name, native.library, native.symbol, native.arguments, native.result);
	}

	/** Immutable native definitions shared by compiler snapshots and services. */
	public static function configuration():Array<NativeFunction> {
		var definitions:Array<NativeFunction> = [];
		// Language primitives.
		definitions.push(native("trace", "realtime_runtime", "__sys_print", [TString], TVoid));
		definitions.push(native("__std_int_f64", "realtime_runtime", "__std_int_f64", [TFloat], TInt));
		definitions.push(native("__std_string", "realtime_runtime", "__std_string", [TDynamic], TString));

		// Primitive String methods lowered directly by the typer.
		definitions.push(native("__string_compare_full", "std", "string_compare_full", [TString, TString], TInt));
		definitions.push(native("Reflect.compareMethods", "std", "fun_compare", [TDynamic, TDynamic], TBool));
		definitions.push(native("__string_last_index_of", "realtime_runtime", "__string_last_index_of", [TString, TString], TInt));
		definitions.push(native("__string_index_of_from", "realtime_runtime", "__string_index_of_from", [TString, TString, TInt], TInt));
		definitions.push(native("__string_to_lower_case", "realtime_runtime", "__string_to_lower_case", [TString], TString));
		definitions.push(native("__string_split", "realtime_runtime", "__string_split", [TString, TString], TArray(TString)));
		var bytes:CompilerType = TBytes,
			input:CompilerType = TNativeAbstract("realtime_bytes_input"),
			output:CompilerType = TNativeAbstract("realtime_bytes_output");

		// Specialized Bytes representation and instance operations.
		definitions.push(native("__bytes_length", "realtime_runtime", "__bytes_length", [bytes], TInt));
		definitions.push(native("__bytes_get_data", "realtime_runtime", "__bytes_get_data", [bytes], THlBytes));
		definitions.push(native("__bytes_get", "realtime_runtime", "__bytes_get", [bytes, TInt], TInt));
		definitions.push(native("__bytes_set", "realtime_runtime", "__bytes_set", [bytes, TInt, TInt], TVoid));
		definitions.push(native("__bytes_set_i32", "realtime_runtime", "__bytes_set_i32", [bytes, TInt, TInt], TVoid));
		definitions.push(native("__bytes_sub", "realtime_runtime", "__bytes_sub", [bytes, TInt, TInt], bytes));
		definitions.push(native("__bytes_compare", "realtime_runtime", "__bytes_compare", [bytes, bytes], TInt));
		definitions.push(native("__bytes_to_string", "realtime_runtime", "__bytes_to_string", [bytes], TString));
		definitions.push(native("__bytes_get_string", "realtime_runtime", "__bytes_get_string", [bytes, TInt, TInt], TString));

		// Specialized BytesInput representation and operations.
		definitions.push(native("__bytes_input_position", "realtime_runtime", "__bytes_input_position", [input], TInt));
		definitions.push(native("__bytes_input_big_endian", "realtime_runtime", "__bytes_input_big_endian", [input], TBool));
		definitions.push(native("__bytes_input_set_big_endian", "realtime_runtime", "__bytes_input_set_big_endian", [input, TBool], TVoid));

		// Specialized BytesOutput representation and operations.
		definitions.push(native("__bytes_output_big_endian", "realtime_runtime", "__bytes_output_big_endian", [output], TBool));
		definitions.push(native("__bytes_output_set_big_endian", "realtime_runtime", "__bytes_output_set_big_endian", [output, TBool], TVoid));
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
