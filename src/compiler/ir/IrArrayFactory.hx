package compiler.ir;

import compiler.core.InternalError;
import compiler.ir.Ir;

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
	 * bodies when not given). A function that changes becomes its edited body: a frozen copy when a session keeps the stage's
	 * functions (`retained`), else the body edited in place.
	 */
	public static function lower(program:IrProgram, ?types:IrTypeIds, ?scratch:IrPassScratch, retained = true):Void {
		if (types == null)
			types = IrTypeIds.ofFunctions(program.functions);
		var builder = scratch == null ? null : scratch.bodyBuilder, name = IrSymbol.of(NAME).id, typed = false;
		var functions = program.functions;
		for (index in 0...functions.length) {
			var body = functions[index].bodyIn(types, builder, retained);
			if (!requests(body, name))
				continue;
			var edited = body.forEditing(builder);
			if (emit(edited, name))
				typed = true;
			functions[index] = retained
				? IrFunction.ofBody(edited.freeze(true, builder)) : IrFunction.ofOwnedBody(edited);
		}
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
		var typed = false, next = body.presentValueLimit();
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
								descriptor = body.newValueAt(next++, "$array-element", body.typeId(TypeRef)),
								raw = body.newValueAt(next++, "$array-storage", body.typeId(Array(Dyn))),
								erased = body.newValueAt(next++, "$array-erased", body.typeId(Dyn));
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
