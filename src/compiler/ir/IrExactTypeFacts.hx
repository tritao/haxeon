package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;

/**
 * Where a value is known to be an object of exactly one class: in every block that the true side of a branch on
 * `__object_has_exact_type(value, Obj(T))` dominates, when that side is entered only from the branch.
 *
 * The test (TEST) holds for a plain object whose class is exactly T: not a subclass, not an object wrapped in a virtual, not
 * a boxed value, not null. Where it holds, a checked cast of the value to `Obj(T)` cannot fail, so a backend may cast without
 * checking (HlLower). It is the same kind of fact as IrNonNullFacts, about one class instead of non-null. The test itself is
 * a runtime function: HashLink lowers it inline (a type load and a compare), and the Wasm targets, which have no virtuals,
 * bind it to `__std_is_exact_type`, whose meaning is the same there (IrProgramAssembler).
 */
class IrExactTypeFacts {
	public static inline final TEST = "__object_has_exact_type";

	final graph:Null<IrGraph>;
	final facts:Array<{block:Int, value:Int, type:String}> = [];

	/** `graph`, when given, is `fn`'s, shared with other analyses of the same unchanged function. */
	public function new(fn:IrFunction, ?graph:IrGraph) {
		// Only tests and the classes they name matter; most functions have no test, and then nothing else is looked at.
		var tests:Null<Map<Int, Array<IrValue>>> = null, classes:Null<Map<Int, String>> = null;
		for (block in fn.blocks)
			for (located in block.instructions)
				switch located.value {
					case Call(output, name, arguments) if (name.name == TEST && arguments.length == 2):
						if (tests == null)
							tests = [];
						tests.set(output.id, arguments);
					case TypeValue(output, Obj(type)):
						if (classes == null)
							classes = [];
						classes.set(output.id, type);
					default:
				}
		if (tests == null || classes == null) {
			this.graph = graph;
			return;
		}
		var known = graph ?? new IrGraph(fn);
		this.graph = known;
		for (block in fn.blocks)
			if (block.terminator != null)
				switch block.terminator.value {
					case Branch(condition, yes, no) if (yes != no):
						var arguments = tests.get(condition.id),
							type = arguments == null ? null : classes.get(arguments[1].id);
						if (type != null && known.predecessorCount(yes) == 1)
							facts.push({block: yes, value: arguments[0].id, type: type});
					default:
				}
	}

	/**
	 * `program` with every exact object test called `__std_is_exact_type`, for the Wasm targets: they have no virtuals, so an
	 * object's exact type test is the same test there, and their runtimes implement that name. Run before anything matches
	 * runtime names (WasmBackend's logical stages).
	 */
	public static function asStdExactTest(program:IrProgram):IrProgram {
		if (![for (native in program.natives) native.name].contains(TEST))
			return program;
		var functions:Array<IrFunction> = [];
		for (fn in program.functions) {
			var tests = false;
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case Call(_, name, _) if (name.name == TEST):
							tests = true;
						default:
					}
			if (!tests) {
				functions.push(fn);
				continue;
			}
			var blocks:Array<IrBlock> = [];
			for (block in fn.blocks) {
				var copy = new IrBlock(block.id);
				for (located in block.instructions)
					switch located.value {
						case Call(output, name, arguments) if (name.name == TEST):
							copy.instructions
								.push(new Located(Call(output, IrSymbol.of("__std_is_exact_type"), arguments),
								located.provenance));
						default:
							copy.instructions.push(located);
					}
				copy.terminator = block.terminator;
				blocks.push(copy);
			}
			functions.push(fn.withBlocks(blocks));
		}
		var natives = [for (native in program.natives) if (native.name != TEST) native];
		if (![for (native in natives) native.name].contains("__std_is_exact_type"))
			natives.push({
				name: "__std_is_exact_type",
				library: "haxeon_runtime",
				symbol: "__std_is_exact_type",
				arguments: [Dyn, TypeRef],
				result: Bool
			});
		program.functions = functions;
		program.natives = natives;
		return program;
	}

	/** The class `value` is known to have exactly in `block`, or null. */
	public function exactType(block:Int, value:Int):Null<String> {
		var known = graph;
		if (known != null)
			for (fact in facts)
				if (fact.value == value && known.dominates(fact.block, block))
					return fact.type;
		return null;
	}
}
