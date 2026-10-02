package compiler.backend.wasm;

import compiler.backend.wasm.WasmTypes.WasmFunctionType;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;
import compiler.ir.Ir.IrCNative;

/** One scalar of the C signature descriptor, and how it moves between a register and memory. */
class WasmCScalar {
	public final type:WasmValueType;
	public final load:WasmInstruction;
	public final store:WasmInstruction;

	function new(type:WasmValueType, load:WasmInstruction, store:WasmInstruction) {
		this.type = type;
		this.load = load;
		this.store = store;
	}

	/** The scalar for a descriptor element code, as HxiHaxeEmitter writes them. */
	public static function ofCode(code:String):Null<WasmCScalar>
		return switch code {
			case "1": new WasmCScalar(WasmValueType.I32, I32Load8S(0), I32Store8(0));
			case "2": new WasmCScalar(WasmValueType.I32, I32Load8U(0), I32Store8(0));
			case "3": new WasmCScalar(WasmValueType.I32, I32Load16S(0), I32Store16(0));
			case "4": new WasmCScalar(WasmValueType.I32, I32Load16U(0), I32Store16(0));
			case "5" | "6" | "11" | "13" | "14": new WasmCScalar(WasmValueType.I32, I32Load(0), I32Store(0));
			case "7" | "8": new WasmCScalar(WasmValueType.I64, I64Load(0), I64Store(0));
			case "9": new WasmCScalar(WasmValueType.F32, F32Load(0), F32Store(0));
			case "10": new WasmCScalar(WasmValueType.F64, F64Load(0), F64Store(0));
			case _: null;
		};
}

/**
 * How a C native's by-value records and floats cross the Wasm32 C ABI, as clang and Emscripten lay them out.
 *
 * A record that holds a single scalar, possibly through nested records or one-element arrays, travels
 * as that scalar in both directions. Any other record argument is passed as a pointer to its bytes, and
 * any other record result is written through a pointer the caller passes before the arguments. C floats
 * are f32 values at the boundary, although both Wasm backends keep Float32 values as f64.
 */
class WasmCAbi {
	/** For each argument, the scalar a by-value record travels as, or null when it is not such a record. */
	public final directArguments:Array<Null<WasmCScalar>>;

	/** The scalar a record result travels as, or null when there is no record result or it is returned indirectly. */
	public final directResult:Null<WasmCScalar>;

	/** The native returns a record through a pointer passed as its first argument. */
	public final indirectResult:Bool;

	/** Signature descriptor code of a C float. */
	static inline var FLOAT = "9";

	/** Arguments and a result that are C floats, which the Wasm backends keep as f64 values. */
	final floatArguments:Array<Bool>;

	final floatResult:Bool;

	function new(directArguments:Array<Null<WasmCScalar>>, directResult:Null<WasmCScalar>, indirectResult:Bool, floatArguments:Array<Bool>, floatResult:Bool) {
		this.directArguments = directArguments;
		this.directResult = directResult;
		this.indirectResult = indirectResult;
		this.floatArguments = floatArguments;
		this.floatResult = floatResult;
	}

	public static function of(native:IrCNative):WasmCAbi {
		var signature = native.signature, convention = signature.indexOf("@");
		if (convention >= 0)
			signature = signature.substr(0, convention);
		var split = topLevel(signature, ">");
		if (split.length != 2)
			throw 'C native "${native.name}" has an invalid signature "${native.signature}"';
		var argumentDescriptors = split[0].length == 0 ? [] : topLevel(split[0], ","),
			plain:Array<Null<WasmCScalar>> = [for (_ in native.arguments) null],
			unconverted = [for (_ in native.arguments) false],
			floatResult = split[1] == FLOAT && native.fixedResult == null,
			adjusted = native.fixedResult != null || floatResult;
		for (index in 0...native.argumentModes.length)
			switch native.argumentModes[index] {
				case FixedValue(_, _, _):
					adjusted = true;
				case Value if (index < argumentDescriptors.length && argumentDescriptors[index] == FLOAT):
					adjusted = true;
				case _:
			}
		if (!adjusted)
			return new WasmCAbi(plain, null, false, unconverted, false);
		if (argumentDescriptors.length != native.arguments.length)
			throw 'C native "${native.name}" signature has ${argumentDescriptors.length} arguments, not ${native.arguments.length}';
		var directArguments = [
			for (index in 0...argumentDescriptors.length)
				switch native.argumentModes[index] {
					case FixedValue(_, _, _):
						singleScalar(argumentDescriptors[index]);
					case _:
						null;
				}
		], floatArguments = [
			for (index in 0...argumentDescriptors.length)
				native.argumentModes[index] == Value && argumentDescriptors[index] == FLOAT
			];
		if (native.fixedResult == null)
			return new WasmCAbi(directArguments, null, false, floatArguments, floatResult);
		var directResult = singleScalar(split[1]);
		return new WasmCAbi(directArguments, directResult, directResult == null, floatArguments, false);
	}

	/** The import's Wasm parameter and result types, given the types of its IR arguments and result. */
	public function importType(parameters:Array<WasmValueType>, results:Array<WasmValueType>):WasmFunctionType {
		var lowered = [
			for (index in 0...parameters.length) {
				var direct = directArguments[index];
				direct != null ? direct.type : floatArguments[index] ? WasmValueType.F32 : parameters[index];
			}
		];
		if (indirectResult)
			return {parameters: [WasmValueType.I32].concat(lowered), results: []};
		return {parameters: lowered, results: directResult != null ? [directResult.type] : floatResult ? [WasmValueType.F32] : results};
	}

	/** Converts argument `index`, already on the stack as its Wasm value, to its C form. */
	public function lowerArgument(index:Int):Array<WasmInstruction> {
		var direct = directArguments[index];
		return direct != null ? [direct.load] : floatArguments[index] ? [F32DemoteF64] : [];
	}

	/** Converts a scalar result on the stack from its C form to its Wasm value. */
	public function raiseResult():Array<WasmInstruction>
		return floatResult ? [F64PromoteF32] : [];

	public function adjustsCall():Bool {
		if (indirectResult || directResult != null || floatResult)
			return true;
		for (index in 0...directArguments.length)
			if (directArguments[index] != null || floatArguments[index])
				return true;
		return false;
	}

	/** The scalar a record descriptor `{size;align;elements}` flattens to, when it has exactly one element. */
	static function singleScalar(descriptor:String):Null<WasmCScalar> {
		if (!StringTools.startsWith(descriptor, "{") || !StringTools.endsWith(descriptor, "}"))
			return null;
		var parts = descriptor.substring(1, descriptor.length - 1).split(";");
		if (parts.length != 3 || parts[2].indexOf(",") >= 0 || parts[2].indexOf("{") >= 0)
			return null;
		return WasmCScalar.ofCode(parts[2]);
	}

	/** Splits `text` at `separator` outside of braces. */
	static function topLevel(text:String, separator:String):Array<String> {
		var result:Array<String> = [], depth = 0, start = 0;
		for (index in 0...text.length) {
			var character = text.charAt(index);
			if (character == "{")
				depth++;
			else if (character == "}")
				depth--;
			else if (depth == 0 && character == separator) {
				result.push(text.substring(start, index));
				start = index + 1;
			}
		}
		result.push(text.substring(start));
		return result;
	}
}
