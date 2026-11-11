package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;

/** Typed allocation request. Its result records the element until storage selection is complete.
 * Lane factories consume their own requests; this factory emits ordinary physical arrays afterwards.
 * There is no erased temporary or reflective descriptor in a logical allocation.
 */
class IrArrayFactory {
	public static inline final NAME = "$array:allocate";

	/** A standalone backend can receive semantic IR without the frontend's lane pipeline. */
	public static function physical(program:IrProgram):IrProgram {
		var pending = false;
		for (fn in program.functions)
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case Call(_, NAME, _):
							pending = true;
						default:
					}
		if (!pending)
			return program;
		var result = new IrProgram(program.entryPoint);
		result.enums = program.enums;
		result.functions = program.functions;
		result.objects = program.objects;
		result.interfaces = program.interfaces;
		result.staticFields = program.staticFields;
		result.natives = program.natives.copy();
		result.cNatives = program.cNatives;
		result.positionalFingerprints = program.positionalFingerprints;
		result.parameterDefaults = program.parameterDefaults;
		result.positionalPlaces = program.positionalPlaces;
		result.positionalSources = program.positionalSources;
		lower(result);
		return result;
	}

	var typed = false;

	function new() {}

	public static function lower(program:IrProgram):Void {
		var factory = new IrArrayFactory();
		program.functions = [for (fn in program.functions) factory.emit(fn)];
		if (factory.typed)
			IrProgramAssembler.ensureArrayRuntime(program, true, true, false);
	}

	function emit(fn:IrFunction):IrFunction {
		var requested = false;
		for (block in fn.blocks)
			for (located in block.instructions)
				switch located.value {
					case Call(_, NAME, _):
						requested = true;
					default:
				}
		if (!requested)
			return fn;

		var changed = false, next = 0;
		for (argument in fn.arguments)
			if (argument.id >= next)
				next = argument.id + 1;
		for (block in fn.blocks)
			for (located in block.instructions) {
				var output = IrOperands.output(located.value);
				if (output != null && output.id >= next)
					next = output.id + 1;
			}
		var blocks:Array<IrBlock> = [];
		for (block in fn.blocks) {
			var target = new IrBlock(block.id);
			for (located in block.instructions)
				switch located.value {
					case Call(out, NAME, arguments):
						if (arguments.length != 1)
							throw "Invalid array factory arguments";
						var element = switch out.type {
							case Array(element): element;
							default: throw "Array factory must return an array";
						};
						changed = true;
						switch element {
							case I32:
								target.instructions.push(new Located(Call(out, "__array_alloc_i32", arguments), located.provenance));
							case EnumTag(_): throw "Tag array factory was not consumed by lane selection";
							default:
								typed = true;
								var descriptor = new IrValue(next++, "$array-element", TypeRef),
									raw = new IrValue(next++, "$array-storage", Array(Dyn)),
									erased = new IrValue(next++, "$array-erased", Dyn);
								target.instructions.push(new Located(TypeValue(descriptor, element), located.provenance));
								target.instructions.push(new Located(Call(raw, "__array_alloc_typed_ref", [arguments[0], descriptor]), located.provenance));
								target.instructions.push(new Located(ToDyn(erased, raw), located.provenance));
								target.instructions.push(new Located(SafeCast(out, erased), located.provenance));
						}
					default:
						target.instructions.push(located);
				}
			target.terminator = block.terminator;
			blocks.push(target);
		}
		return changed ? fn.withBlocks(blocks) : fn;
	}
}
