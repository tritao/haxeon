package compiler.backend.wasm.linear;

import compiler.backend.wasm.WasmTypes.WasmFunctionType;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;
import compiler.ir.Ir.IrCNative;

/** One scalar of the C signature descriptor, and how it moves between a register and memory. */
class WasmLinearCScalar {
	public final type:WasmValueType;
	public final load:WasmInstruction;
	public final store:WasmInstruction;

	function new(type:WasmValueType, load:WasmInstruction, store:WasmInstruction) {
		this.type = type;
		this.load = load;
		this.store = store;
	}

	/** The scalar for a descriptor element code, as HxiHaxeEmitter writes them. */
	public static function ofCode(code:String):Null<WasmLinearCScalar>
		return switch code {
			case "1": new WasmLinearCScalar(I32, I32Load8S(0), I32Store8(0));
			case "2": new WasmLinearCScalar(I32, I32Load8U(0), I32Store8(0));
			case "3": new WasmLinearCScalar(I32, I32Load16S(0), I32Store16(0));
			case "4": new WasmLinearCScalar(I32, I32Load16U(0), I32Store16(0));
			case "5" | "6" | "11" | "13" | "14": new WasmLinearCScalar(I32, I32Load(0), I32Store(0));
			case "7" | "8": new WasmLinearCScalar(I64, I64Load(0), I64Store(0));
			case "9": new WasmLinearCScalar(F32, F32Load(0), F32Store(0));
			case "10": new WasmLinearCScalar(F64, F64Load(0), F64Store(0));
			case _: null;
		};
}

/**
 * How a C native's by-value records cross the Wasm32 C ABI, as clang and Emscripten lay them out.
 *
 * A record that holds a single scalar, possibly through nested records or one-element arrays, travels
 * as that scalar in both directions. Any other record argument is passed as a pointer to its bytes, and
 * any other record result is written through a pointer the caller passes before the arguments.
 */
class WasmLinearCAbi {
	/** For each argument, the scalar a by-value record travels as, or null when it is not such a record. */
	public final directArguments:Array<Null<WasmLinearCScalar>>;

	/** The scalar a record result travels as, or null when there is no record result or it is returned indirectly. */
	public final directResult:Null<WasmLinearCScalar>;

	/** The native returns a record through a pointer passed as its first argument. */
	public final indirectResult:Bool;

	function new(directArguments:Array<Null<WasmLinearCScalar>>, directResult:Null<WasmLinearCScalar>, indirectResult:Bool) {
		this.directArguments = directArguments;
		this.directResult = directResult;
		this.indirectResult = indirectResult;
	}

	public static function of(native:IrCNative):WasmLinearCAbi {
		var signature = native.signature, convention = signature.indexOf("@");
		if (convention >= 0)
			signature = signature.substr(0, convention);
		var split = topLevel(signature, ">");
		if (split.length != 2)
			throw 'C native "${native.name}" has an invalid signature "${native.signature}"';
		var argumentDescriptors = split[0].length == 0 ? [] : topLevel(split[0], ","),
			hasRecords = native.fixedResult != null;
		for (mode in native.argumentModes)
			switch mode {
				case FixedValue(_, _, _):
					hasRecords = true;
				case _:
			}
		if (!hasRecords)
			return new WasmLinearCAbi([for (_ in native.arguments) null], null, false);
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
		];
		if (native.fixedResult == null)
			return new WasmLinearCAbi(directArguments, null, false);
		var directResult = singleScalar(split[1]);
		return new WasmLinearCAbi(directArguments, directResult, directResult == null);
	}

	/** The import's Wasm parameter and result types, given the types of its IR arguments and result. */
	public function importType(parameters:Array<WasmValueType>, results:Array<WasmValueType>):WasmFunctionType {
		var lowered = [
			for (index in 0...parameters.length) {
				var direct = directArguments[index];
				direct == null ? parameters[index] : direct.type;
			}
		];
		if (indirectResult)
			return {parameters: [I32].concat(lowered), results: []};
		return {parameters: lowered, results: directResult == null ? results : [directResult.type]};
	}

	public function adjustsCall():Bool {
		if (indirectResult || directResult != null)
			return true;
		for (direct in directArguments)
			if (direct != null)
				return true;
		return false;
	}

	/** The scalar a record descriptor `{size;align;elements}` flattens to, when it has exactly one element. */
	static function singleScalar(descriptor:String):Null<WasmLinearCScalar> {
		if (!StringTools.startsWith(descriptor, "{") || !StringTools.endsWith(descriptor, "}"))
			return null;
		var parts = descriptor.substring(1, descriptor.length - 1).split(";");
		if (parts.length != 3 || parts[2].indexOf(",") >= 0 || parts[2].indexOf("{") >= 0)
			return null;
		return WasmLinearCScalar.ofCode(parts[2]);
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
