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
		definitions.push(native("trace", "haxeon_runtime", "__sys_print", [TString], TVoid));
		definitions.push(native("__std_int_f64", "haxeon_runtime", "__std_int_f64", [TFloat], TInt));
		definitions.push(native("__std_int_dynamic", "haxeon_runtime", "__std_int_dynamic", [TDynamic], TInt));
		definitions.push(native("__std_string", "haxeon_runtime", "__std_string", [TDynamic], TString));
		definitions.push(native("__dynamic_equal", "haxeon_runtime", "__dynamic_equal", [TDynamic, TDynamic], TBool));
		definitions.push(native("__reflect_is_object", "haxeon_runtime", "__reflect_is_object", [TDynamic], TBool));
		definitions.push(native("__math_ceil", "haxeon_runtime", "__math_ceil", [TFloat], TInt));
		definitions.push(native("__math_fmod", "haxeon_runtime", "__math_fmod", [TFloat, TFloat], TFloat));

		// Primitive String methods lowered directly by the typer.
		definitions.push(native("__string_compare_full", "std", "string_compare_full", [TString, TString], TInt));
		definitions.push(native("__string_last_index_of", "haxeon_runtime", "__string_last_index_of", [TString, TString], TInt));
		definitions.push(native("__string_index_of_from", "haxeon_runtime", "__string_index_of_from", [TString, TString, TInt], TInt));
		definitions.push(native("__string_to_lower_case", "haxeon_runtime", "__string_to_lower_case", [TString], TString));
		definitions.push(native("__string_to_upper_case", "haxeon_runtime", "__string_to_upper_case", [TString], TString));
		definitions.push(native("__string_split", "haxeon_runtime", "__string_split", [TString, TString], TArray(TString)));
		definitions.push(native("__string_from_bytes", "haxeon_runtime", "__string_from_bytes", [THlBytes, TInt], TString));
		definitions.push(native("__string_bytes", "haxeon_runtime", "__string_bytes", [TString], THlBytes));
		definitions.push(native("__hl_bytes_ucs2_length", "std", "ucs2length", [THlBytes, TInt], TInt));
		var bytes:CompilerType = TBytes,
			input:CompilerType = TNativeAbstract("realtime_bytes_input"),
			output:CompilerType = TNativeAbstract("realtime_bytes_output");

		// Specialized Bytes representation and instance operations.
		definitions.push(native("__bytes_length", "haxeon_runtime", "__bytes_length", [bytes], TInt));
		definitions.push(native("__bytes_get_data", "haxeon_runtime", "__bytes_get_data", [bytes], THlBytes));
		definitions.push(native("__bytes_get", "haxeon_runtime", "__bytes_get", [bytes, TInt], TInt));
		definitions.push(native("__bytes_get_i32", "haxeon_runtime", "__bytes_get_i32", [bytes, TInt], TInt));
		definitions.push(native("__bytes_set", "haxeon_runtime", "__bytes_set", [bytes, TInt, TInt], TVoid));
		definitions.push(native("__bytes_set_i32", "haxeon_runtime", "__bytes_set_i32", [bytes, TInt, TInt], TVoid));
		definitions.push(native("__bytes_set_float", "haxeon_runtime", "setF32", [bytes, TInt, TFloat], TVoid));
		definitions.push(native("__bytes_set_double", "haxeon_runtime", "setF64", [bytes, TInt, TFloat], TVoid));
		definitions.push(native("__bytes_sub", "haxeon_runtime", "__bytes_sub", [bytes, TInt, TInt], bytes));
		definitions.push(native("__bytes_compare", "haxeon_runtime", "__bytes_compare", [bytes, bytes], TInt));
		definitions.push(native("__bytes_to_string", "haxeon_runtime", "__bytes_to_string", [bytes], TString));
		definitions.push(native("__bytes_get_string", "haxeon_runtime", "__bytes_get_string", [bytes, TInt, TInt], TString));

		// Specialized BytesInput representation and operations.
		definitions.push(native("__bytes_input_position", "haxeon_runtime", "__bytes_input_position", [input], TInt));
		definitions.push(native("__bytes_input_big_endian", "haxeon_runtime", "__bytes_input_big_endian", [input], TBool));
		definitions.push(native("__bytes_input_set_big_endian", "haxeon_runtime", "__bytes_input_set_big_endian", [input, TBool], TVoid));

		// Specialized BytesOutput representation and operations.
		definitions.push(native("__bytes_output_big_endian", "haxeon_runtime", "__bytes_output_big_endian", [output], TBool));
		definitions.push(native("__bytes_output_set_big_endian", "haxeon_runtime", "__bytes_output_set_big_endian", [output, TBool], TVoid));
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
