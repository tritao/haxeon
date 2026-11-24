package compiler.ir.passes.arrays;

import compiler.core.InternalError;
import compiler.ir.model.Ir;
import compiler.ir.model.IrBody;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrPassScratch;
import compiler.ir.model.IrSymbol;
import compiler.ir.model.IrTypeIds;
import compiler.ir.pipeline.IrProgramAssembler;

/** Typed allocation request. Its result records the element until storage selection is complete.
 * Lane factories consume their own requests; this factory emits ordinary physical arrays afterwards.
 * There is no erased temporary or reflective descriptor in a logical allocation.
 */
@:nullSafety(Strict)
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
	 * bodies when not given), per function (`IrArrayFactoryPass`): with `lineage`, a function the session has at the same version is
	 * last build's lowering, unread. A function that changes becomes its edited body, owned by the next stage.
	 */
	public static function lower(program:IrProgram, ?types:IrTypeIds, ?scratch:IrPassScratch,
			?lineage:compiler.ir.reuse.IrStageMemo.IrLineage):Void {
		if (types == null)
			types = IrTypeIds.ofFunctions(program.functions);
		var builder = scratch == null ? new compiler.ir.model.IrBodyBuilder(types) : scratch.bodyBuilder;
		program.functions = compiler.ir.pipeline.IrFunctionStages.run(IrArrayFactoryPass.STAGE,
			new IrArrayFactoryPass(program, types, builder), program.functions, lineage,
			lineage != null && lineage.checks,
			builder);
	}

	/** Whether `body` calls the factory, whose symbol id is `name`. */
	public static function requests(body:IrBody, name:Int):Bool {
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
	public static function emit(body:IrBody, name:Int):Bool {
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

/**
 * The array factory lowering per function (`IrFunctionPass`): a function that calls the factory has its calls made allocations;
 * it depends on the function alone. One that makes a typed reference array asks for the array runtime (`TYPED`), which `finish`
 * adds once.
 */
class IrArrayFactoryPass implements compiler.ir.pipeline.IrFunctionPass {
	public static inline final STAGE = "array-factory";

	static inline final TYPED = 0;

	final program:IrProgram;
	final types:IrTypeIds;
	final builder:compiler.ir.model.IrBodyBuilder;
	final name = IrSymbol.of(IrArrayFactory.NAME).id;
	var typed = false;

	public function new(program:IrProgram, types:IrTypeIds, builder:compiler.ir.model.IrBodyBuilder) {
		this.program = program;
		this.types = types;
		this.builder = builder;
	}

	public function summarize(fn:IrFunction):Int
		return 0;

	public function prepare(functions:Array<IrFunction>, summaries:Array<Int>,
			names:compiler.ir.pipeline.IrFunctionIndex):Void {}

	public function fact(kind:Int, key:String):Int
		return compiler.ir.reuse.IrFacts.UNKNOWN;

	public function transform(fn:IrFunction, summary:Int, reader:compiler.ir.reuse.IrFactReader):IrFunction {
		var body = fn.bodyIn(types, builder);
		if (!IrArrayFactory.requests(body, name))
			return fn;
		var edited = body.forEditing(builder);
		if (IrArrayFactory.emit(edited, name))
			reader.request(TYPED, Void);
		return IrFunction.ofOwnedBody(edited);
	}

	public function request(kind:Int, type:IrType, name:Null<String>):Void
		typed = true;

	public function finish(functions:Array<IrFunction>):Array<IrFunction> {
		if (typed) {
			program.functions = functions;
			IrProgramAssembler.ensureArrayRuntime(program, true, true, false);
			return program.functions;
		}
		return functions;
	}
}
