package compiler.ir;

import compiler.core.InternalError;
import compiler.ir.Ir;
import compiler.ir.IrInliner.IrInlineCache;

/** A function's array factory lowering in a session: `result` is `source` lowered, `typed` whether it makes a typed reference array. */
typedef IrArrayFactoryLowering = {
	final source:IrFunction;
	final result:IrFunction;
	final typed:Bool;
}

/** Typed allocation request. Its result records the element until storage selection is complete.
 * Lane factories consume their own requests; this factory emits ordinary physical arrays afterwards.
 * There is no erased temporary or reflective descriptor in a logical allocation.
 */
class IrArrayFactory {
	public static inline final NAME = "$array:allocate";

	/** A standalone backend can receive semantic IR without the frontend's lane pipeline. */
	public static function physical(program:IrProgram):IrProgram {
		var types = IrTypeIds.ofFunctions(program.functions), name = IrSymbol.of(NAME).id, pending = false;
		for (fn in program.functions)
			if (requests(fn.bodyIn(types), name)) {
				pending = true;
				break;
			}
		if (!pending)
			return program;
		var result = new IrProgram(program.entryPoint);
		result.enums = program.enums;
		result.functions = program.functions.copy();
		result.objects = program.objects;
		result.interfaces = program.interfaces;
		result.staticFields = program.staticFields;
		result.natives = program.natives.copy();
		result.cNatives = program.cNatives;
		result.positionalFingerprints = program.positionalFingerprints;
		result.parameterDefaults = program.parameterDefaults;
		result.positionalPlaces = program.positionalPlaces;
		result.positionalSources = program.positionalSources;
		lower(result, types);
		return result;
	}

	/**
	 * Emits the remaining allocation requests of `program`'s functions, on their bodies (made with `types`, those of the program's
	 * bodies when not given). A function that changes becomes its edited body, owned by the next stage. With a session's `cache`,
	 * a function given as the same object as last compile is last compile's result, which the cache keeps frozen: the lowering
	 * reads only the function.
	 */
	public static function lower(program:IrProgram, ?types:IrTypeIds, ?scratch:IrPassScratch,
			?cache:IrInlineCache):Void {
		if (types == null)
			types = IrTypeIds.ofFunctions(program.functions);
		var builder = scratch == null ? null : scratch.bodyBuilder, name = IrSymbol.of(NAME).id, typed = false;
		var functions = program.functions,
			next:Map<String, IrArrayFactoryLowering> = [];
		for (index in 0...functions.length) {
			var fn = functions[index], known = cache == null ? null : cache.arrayFactories.get(fn.name);
			if (known != null && known.source == fn) {
				functions[index] = known.result;
				next.set(fn.name, known);
				if (known.typed)
					typed = true;
				continue;
			}
			var body = fn.bodyIn(types, builder);
			if (!requests(body, name))
				continue;
			// A session's cache keeps `fn` as its lowering's source, so the lowering is made on a copy.
			if (cache != null)
				body = fn.freezeBody(builder);
			var edited = body.forEditing(builder), typedHere = emit(edited, name);
			if (typedHere)
				typed = true;
			var result = IrFunction.ofOwnedBody(edited);
			functions[index] = result;
			if (cache != null) {
				result.freezeBody(builder);
				next.set(fn.name, {source: fn, result: result, typed: typedHere});
			}
		}
		if (cache != null)
			cache.arrayFactories = next;
		if (typed)
			IrProgramAssembler.ensureArrayRuntime(program, true, true, false);
	}

	/** Whether `body` calls the factory, whose symbol id is `name`. */
	static function requests(body:IrBody, name:Int):Bool {
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (body.opcode(row) == IrOpcode.Call && body.aux(row) == name)
					return true;
				row = body.nextRow(row);
			}
		}
		return false;
	}

	/** Replaces each factory call of `body` in place; whether one makes a typed reference array. */
	static function emit(body:IrBody, name:Int):Bool {
		var typed = false;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var following = body.nextRow(row);
				if (body.opcode(row) == IrOpcode.Call && body.aux(row) == name) {
					if (body.operandCount(row) != 1)
						throw new InternalError("Invalid array factory arguments");
					var out = body.output(row);
					var element = switch body.valueType(out) {
						case Array(element): element;
						default: throw new InternalError("Array factory must return an array");
					};
					switch element {
						case I32:
							body.setAux(row, IrSymbol.of("__array_alloc_i32").id);
						case EnumTag(_): throw new InternalError("Tag array factory was not consumed by lane selection");
						default:
							typed = true;
							var where = body.provenance(row),
								descriptor = body.newValue("$array-element", body.typeId(TypeRef)),
								raw = body.newValue("$array-storage", body.typeId(Array(Dyn))),
								erased = body.newValue("$array-erased", body.typeId(Dyn));
							body.beginRow();
							body.linkBefore(block, row,
								body.endRow(IrOpcode.TypeValue, descriptor, body.typeId(element), where));
							IrValueArrayRows.call2(body, block, row, raw, "__array_alloc_typed_ref",
								body.operand(row, 0), descriptor,
								where);
							body.beginRow();
							body.pushOperand(raw);
							body.linkBefore(block, row, body.endRow(IrOpcode.ToDyn, erased, 0, where));
							body.beginRow();
							body.pushOperand(erased);
							body.linkBefore(block, row, body.endRow(IrOpcode.SafeCast, out, 0, where));
							body.removeRow(block, row);
					}
				}
				row = following;
			}
		}
		return typed;
	}
}
