package compiler.backend.wasm.gc;

import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.IrObjectTable;
import compiler.ir.IrValueArrayLayout;
import compiler.ir.IrValueLaneLayout.IrValueLaneTarget;
import compiler.ir.SourceProvenance.Located;

/** Facts already fixed by a typed array place, before target-specific field flattening. */
typedef WasmGcValueArrayScalarAccess = {
	final wordBits:Int;
	final strideBits:Int;
	final offsetBits:Int;
	final widthBits:Int;
	final signed:Bool;
	final hasValidity:Bool;
}

/** Specialize scalar runtime calls using their typed array and constant field operands. */
class WasmGcValueArrayAccessors {
	public final accesses:Map<String, WasmGcValueArrayScalarAccess> = [];
	public final program:IrProgram;
	final natives:Map<String, IrNative>;
	final objects:IrObjectTable;
	final layouts:Map<String, IrValueArrayLayout> = [];
	final added:Array<IrNative> = [];

	public function new(source:IrProgram) {
		natives = [for (native in source.natives) if (isScalar(native.symbol)) native.name => native];
		objects = IrObjectTable.of([for (object in source.objects) object.name => object]);
		program = new IrProgram(source.entryPoint);
		program.functions = [for (fn in source.functions) rewrite(fn)];
		program.natives = source.natives.concat(added);
		program.cNatives = source.cNatives;
		program.objects = source.objects;
		program.interfaces = source.interfaces;
		program.enums = source.enums;
		program.staticFields = source.staticFields;
		program.positionalFingerprints = source.positionalFingerprints;
		program.parameterDefaults = source.parameterDefaults;
		program.positionalPlaces = source.positionalPlaces;
		program.positionalSources = source.positionalSources;
	}

	public static function isScalar(symbol:String):Bool return switch symbol {
		case "__value_array_read_i32", "__value_array_read_i64", "__value_array_read_bool", "__value_array_read_f32", "__value_array_read_f64",
			"__value_array_write_i32", "__value_array_write_i64", "__value_array_write_bool", "__value_array_write_f32", "__value_array_write_f64",
			"__value_array_read_ptr", "__value_array_write_ptr", "__value_array_read_type", "__value_array_write_type",
			"__value_array_read_callback", "__value_array_write_callback", "__value_array_clear_scalar": true;
		default: false;
	};

	function hasAccess(fn:IrFunction):Bool {
		for (block in fn.blocks) for (located in block.instructions) switch located.value {
			case Call(_, name, _) if (natives.exists(name)): return true;
			default:
		}
		return false;
	}

	function rewrite(fn:IrFunction):IrFunction {
		if (!hasAccess(fn)) return fn;
		var constants:Map<Int, Int> = [];
		for (block in fn.blocks) for (located in block.instructions) switch located.value {
			case ConstInt(output, value): constants.set(output.id, value);
			case ConstBool(output, value): constants.set(output.id, value ? 1 : 0);
			default:
		}
		var blocks:Array<IrBlock> = [], changed = false;
		for (block in fn.blocks) {
			var target = new IrBlock(block.id);
			for (located in block.instructions) {
				var instruction = located.value;
				switch instruction {
					case Call(output, name, arguments):
						var native = natives.get(name);
						if (native != null) {
							var specialized = specialize(native, arguments, constants);
							if (specialized != null) {
								var operands = arguments.slice(0, 2);
								if (StringTools.startsWith(native.symbol, "__value_array_write_")) operands.push(arguments[arguments.length - 1]);
								instruction = Call(output, specialized, operands); changed = true;
							}
						}
					default:
				}
				target.instructions.push(new Located(instruction, located.provenance));
			}
			target.terminator = block.terminator;
			blocks.push(target);
		}
		return changed ? new IrFunction(fn.name, fn.arguments, fn.result, blocks, fn.debugBindings, fn.inlineHint, fn.retention) : fn;
	}

	function specialize(native:IrNative, arguments:Array<IrValue>, constants:Map<Int, Int>):Null<String> {
		if (arguments.length < 3) return null;
		var offset = constants.get(arguments[2].id);
		if (offset == null) return null;
		var element = switch arguments[0].type {
			case Array(element): element;
			default: return null;
		}, name = switch element { case Obj(name), Nullable(Obj(name)): name; default: return null; }, object = objects.get(name);
		if (object == null || !object.isValue) return null;
		var key = haxe.crypto.Base64.encode(compiler.ir.codec.IrTypeCodec.encode(element)), layout = layouts.get(key);
		if (layout == null) { layout = new IrValueArrayLayout(objects, element, 32, WasmGc); layouts.set(key, layout); }
		var symbol = native.symbol, clear = symbol == "__value_array_clear_scalar", write = clear || StringTools.startsWith(symbol, "__value_array_write_"),
			suffix = clear ? "clear" : symbol.substr(write ? "__value_array_write_".length : "__value_array_read_".length),
			integer = suffix == "i32" || suffix == "i64", variableWidth = integer || suffix == "ptr" || suffix == "type" || clear;
		var width = suffix == "bool" ? 8 : suffix == "f32" || suffix == "callback" ? 32 : 64, signed = false;
		if (variableWidth) {
			if (arguments.length < 4) return null;
			var value = constants.get(arguments[3].id);
			if (value == null) return null;
			width = value;
		}
		if (!write && integer) {
			if (arguments.length < 5) return null;
			var value = constants.get(arguments[4].id);
			if (value == null) return null;
			signed = value != 0;
		}
		var shape = layout.lanes;
		// Untyped native accesses retain their runtime validation, including deliberately invalid operands.
		if (offset < 0 || (offset & 7) != 0 || (width != 8 && width != 16 && width != 32 && width != 64)
				|| width > shape.scalarWordBits || offset * 1.0 + width > shape.scalarStrideBits
				|| (suffix == "i32" && width > 32) || ((suffix == "ptr" || suffix == "type") && width != 32)) return null;
		var specialized = '$$value-array:scalar:$symbol:${shape.scalarWordBits}:${shape.scalarStrideBits}:$offset:$width:$signed:${layout.hasValidity}';
		if (!accesses.exists(specialized)) {
			accesses.set(specialized, {wordBits:shape.scalarWordBits, strideBits:shape.scalarStrideBits, offsetBits:offset, widthBits:width,
				signed:signed, hasValidity:layout.hasValidity});
			var types = native.arguments.slice(0, 2);
			if (write && !clear) types.push(native.arguments[native.arguments.length - 1]);
			added.push({name:specialized, library:native.library, symbol:symbol, arguments:types, result:native.result});
		}
		return specialized;
	}
}
