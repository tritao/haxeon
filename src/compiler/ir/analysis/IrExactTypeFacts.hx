package compiler.ir.analysis;

import compiler.ir.cfg.IrBodyGraph;
import compiler.ir.model.IrBody;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrSymbol;
import compiler.ir.model.IrValueId;

import compiler.ir.model.Ir;
import compiler.ir.model.SourceProvenance.Located;

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
@:nullSafety(Strict)
class IrExactTypeFacts {
	public static inline final TEST = "__object_has_exact_type";

	/** The body's graph, while it has facts. */
	var graph:Null<IrBodyGraph> = null;

	/** The facts: in block `factBlocks[i]` and those it dominates, value `factValues[i]` is an object of class `factTypes[i]`. */
	final factBlocks:Array<Int> = [];

	final factValues:Array<Int> = [];
	final factTypes:Array<String> = [];

	/** The rows of the body that test a class, and that name a class (`TypeValue` of an object type). */
	final testRows:Array<Int> = [];

	final classRows:Array<Int> = [];

	/** Empty: `reset` makes it the facts of one body after another. */
	public function new() {}

	/** Makes these the facts of `body`, whose graph is `graph` (shared with other analyses of the same body). */
	public function reset(body:IrBody, graph:IrBodyGraph):IrExactTypeFacts {
		this.graph = null;
		factBlocks.resize(0);
		factValues.resize(0);
		factTypes.resize(0);
		testRows.resize(0);
		classRows.resize(0);
		// Only tests and the classes they name matter; most functions have no test, and then nothing else is looked at.
		var test = IrSymbol.of(TEST).id;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				switch body.opcode(row) {
					case IrOpcode.Call if (body.aux(row) == test && body.operandCount(row) == 2):
						testRows.push(row);
					case IrOpcode.TypeValue if (namesClass(body.typeOperand(row))):
						classRows.push(row);
					default:
				}
				row = body.nextRow(row);
			}
		}
		if (testRows.length == 0 || classRows.length == 0)
			return this;
		this.graph = graph;
		for (block in 0...body.blockCount()) {
			var terminator = body.terminatorRow(block);
			if (terminator < 0 || body.opcode(terminator) != IrOpcode.Branch)
				continue;
			var yes = body.auxInt(terminator, 0), no = body.auxInt(terminator, 1);
			if (yes == no)
				continue;
			var test = definedBy(body, testRows, body.operand(terminator, 0));
			if (test < 0)
				continue;
			var named = definedBy(body, classRows, body.operand(test, 1));
			if (named >= 0 && graph.predecessorCount(yes) == 1)
				switch body.typeOperand(named) {
					case Obj(type):
						factBlocks.push(yes);
						factValues.push(body.operand(test, 0));
						factTypes.push(type);
					default:
				}
		}
		return this;
	}

	static function namesClass(type:IrType):Bool
		return switch type {
			case Obj(_): true;
			default: false;
		};

	/** The one of `rows` that defines `value`, or -1. */
	static function definedBy(body:IrBody, rows:Array<Int>, value:IrValueId):Int {
		for (row in rows)
			if ((body.output(row):Int) == (value:Int))
				return row;
		return -1;
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
			for (index in 0...factBlocks.length)
				if (factValues[index] == value && known.dominates(factBlocks[index], block))
					return factTypes[index];
		return null;
	}
}
