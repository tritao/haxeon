package compiler.ir.analysis;

import compiler.ir.model.IrBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrOpcode;

import compiler.core.InternalError;
import compiler.ir.analysis.IrTypeAwareWalk.IrClassDependencies;
import compiler.ir.analysis.IrTypeAwareWalk.IrWalkResult;
import compiler.ir.analysis.IrTypeAwareWalk.IrWalkRoots;
import compiler.ir.model.Ir;

/**
 * The prune of ADR 0003 §13 at the 3a point of `IrProgramAssembler.assemble` (docs/design/REACHABILITY_WALK.md): after the enum providers are
 * synthesized and before every later pass, a plain HashLink build drops the functions nothing reaches from the entry, so the passes
 * run on the reachable program. The walk is `IrTypeAwareWalk` (whole created classes); the backend's own prune after assembly
 * (`IrReachability.withGeneratedRuntimeRoots`) still runs and keeps a mentioned class's methods, so it removes nothing more of what this one kept.
 *
 * A later pass that calls a function this prune removed would produce a program that does not link (the failure of 2026-11-10), so
 * with `--check-reuse` `checkRemoved` runs after the passes and names the pass, the caller and the removed function.
 */
/** What the prune removed, and the natives reached code calls. */
typedef IrPruneResult = {
	final removed:Map<String, Bool>;

	/** The (class, method) table entries removed, as `class\u0001method`. */
	final removedMethods:Map<String, Bool>;

	final calledNatives:Map<String, Bool>;

	/** The functions the prune gave a declaration stub in place of their body (`declarationStub`). */
	final stubbed:Map<String, Bool>;
}

/**
 * What the early prune removed, which check mode (`--check-reuse`) watches the passes after it for: a lookup of a removed function, or
 * a method lookup that visits a removed table entry, is a decision made on something that is gone.
 */
@:nullSafety(Strict)
class IrPruneWatch {
	final functions:Map<String, Bool>;
	final methods:Map<String, Bool>;

	public function new(functions:Map<String, Bool>, methods:Map<String, Bool>) {
		this.functions = functions;
		this.methods = methods;
	}

	public function noteLookup(pass:String, name:String):Void
		if (functions.exists(name))
			throw new InternalError('early prune: pass "$pass" looked up function "$name", which the prune removed');

	public function noteMethodLookup(className:String, method:String):Void
		if (methods.exists(className + "\u0001" + method))
			throw new InternalError('early prune: a lookup of method "$method" visited class "$className", whose entry the prune removed');
}

@:nullSafety(Strict)
class IrEntryPrune {
	/** The walk of the dispatch decisions, a session's walk (`IrTypeAwareWalk.runKept`). */
	public static inline final DISPATCH_WALK = "dispatch-walk";

	/** The walk the prune removes by. */
	public static inline final PRUNE_WALK = "entry-prune-walk";

	/**
	 * The walk `run` prunes by, without removing anything: what `roots` (and `@:keep`) reach in `program`. In a session the walk is
	 * the session's walk `name`; the result is the caller's to change.
	 */
	public static function walk(program:IrProgram, roots:Array<String>, name:String,
			?classDependencies:IrClassDependencies,
			?stageMemos:compiler.ir.reuse.IrStageMemos):IrWalkResult {
		var entries = roots.copy();
		for (fn in program.functions)
			if (fn.retention != Reachable)
				entries.push(fn.name);
		var walkRoots:IrWalkRoots = {functions: entries, types: []};
		if (stageMemos == null)
			return IrTypeAwareWalk.run(program, walkRoots, null, false, true, classDependencies);
		return IrTypeAwareWalk.runKept(name, program, walkRoots, true, classDependencies, stageMemos);
	}

	/**
	 * Prunes `program` to what `roots` (the entry's function, the static initializers, the exported functions) and `@:keep` reach.
	 * With `declaredMethods`, for a live layout, every method of every class keeps its table entry: one nothing reaches gets a
	 * declaration stub, so the method a later edit reaches takes a body in the slot it has (docs/design/LIVE_PRUNING.md).
	 */
	public static function run(program:IrProgram, roots:Array<String>,
			?classDependencies:IrClassDependencies,
			?stageMemos:compiler.ir.reuse.IrStageMemos, declaredMethods:Bool = false):IrPruneResult {
		var removedMethods:Map<String, Bool> = [];
		// The type-aware walk alone: a class that is only mentioned, never created, keeps none of its methods. Its reach beyond what the old walk
		// keeps are the provider rows a dynamic site reaches over the created types (the equality helper of a struct that only `__dynamic_equal`
		// uses), which nothing calls by name until a later pass writes the call.
		var walked = walk(program, roots, PRUNE_WALK, classDependencies, stageMemos);
		var reachable = walked.reached;
		// A method named by a reachable call on a class that cannot have an instance keeps its class-table entry and loses its body: the
		// verifier resolves the call against the table, but nothing can receive it, so the body is a stub that throws (the way an interface
		// method without an implementation is). A body that calls natives or other functions no longer keeps them.
		var declared:Map<String, Bool> = [];
		if (declaredMethods)
			for (object in program.objects)
				for (method in object.methods)
					declared.set(method.functionName.name, true);
		var stubbed:Map<String, Bool> = [];
		for (index in 0...program.functions.length) {
			var fn = program.functions[index];
			if ((walked.declarationOnly.exists(fn.name) || declared.exists(fn.name)) && !reachable.exists(fn.name)) {
				program.functions[index] = declarationStub(fn, stageMemos);
				reachable.set(fn.name, true);
				stubbed.set(fn.name, true);
			}
		}
		var removed:Map<String, Bool> = [];
		for (fn in program.functions)
			if (!reachable.exists(fn.name))
				removed.set(fn.name, true);
		for (object in program.objects)
			for (method in object.methods)
				if (!reachable.exists(method.functionName.name))
					removedMethods.set(object.name + "\u0001" + method.name, true);
		IrReachability.prune(program, reachable);
		return {
			removed: removed,
			removedMethods: removedMethods,
			calledNatives: walked.calledNatives,
			stubbed: stubbed
		};
	}

	/**
	 * The function with the same name and signature and a body that throws: the declaration of a method nothing can call. A stub
	 * is made of its declaration's signature alone, so in a session last build's stands while the signature is the same.
	 */
	static function declarationStub(fn:IrFunction, stageMemos:Null<compiler.ir.reuse.IrStageMemos>):IrFunction {
		var kept = stageMemos == null ? null : stageMemos.helper(fn.name);
		if (kept != null && sameDeclaration(kept, fn))
			return kept;
		var builder = new IrBuilder();
		for (argument in fn.arguments)
			builder.argument(argument.name, argument.type);
		builder.unreachable();
		var stub = new IrFunction(fn.name, builder.arguments, fn.result, builder.blocks, fn.kind);
		if (stageMemos != null)
			stageMemos.keepHelper(stub);
		return stub;
	}

	static function sameDeclaration(stub:IrFunction, fn:IrFunction):Bool {
		if (!stub.kind.match(Ordinary) || !fn.kind.match(Ordinary) || stub.arguments.length != fn.arguments.length
			|| compiler.ir.model.IrTypeIdentity.text(stub.result) != compiler.ir.model.IrTypeIdentity.text(fn.result))
			return false;
		for (index in 0...fn.arguments.length) {
			var a = stub.arguments[index], b = fn.arguments[index];
			if (a.name != b.name
				|| compiler.ir.model.IrTypeIdentity.text(a.type) != compiler.ir.model.IrTypeIdentity.text(b.type))
				return false;
		}
		return true;
	}

	/**
	 * The watch of the pipeline run on this thread, between the prune and the end of the stage list (`watching`): thread-scoped, so a
	 * compile only ever sees its own, and cleared when the list ends, also when a pass throws.
	 */
	@:threadScoped("the check-mode watch of the pipeline run on this thread, cleared when its stage list ends")
	static final current = new sys.thread.Tls<Null<IrPruneWatch>>();

	/** Watches the passes on this thread for lookups of what the prune removed, until `watching(null)`. */
	public static function watching(watch:Null<IrPruneWatch>):Void
		current.value = watch;

	/** A method-table lookup of `method` is visiting `className`: in check mode it must not be an entry the prune removed. */
	public static function noteMethodLookup(className:String, method:String):Void {
		var watch = current.value;
		if (watch != null)
			watch.noteMethodLookup(className, method);
	}

	public static function noteLookup(pass:String, name:String):Void {
		var watch = current.value;
		if (watch != null)
			watch.noteLookup(pass, name);
	}

	/** After `pass`: no function calls or closes over a function that `run` removed and no pass created again. */
	public static function checkRemoved(pass:String, functions:Array<IrFunction>, removed:Map<String, Bool>):Void {
		var present:Map<String, Bool> = [];
		for (fn in functions)
			present.set(fn.name, true);
		function require(caller:String, callee:String):Void
			if (removed.exists(callee) && !present.exists(callee))
				throw new InternalError('early prune: after "$pass", "$caller" calls "$callee", which the prune removed');
		// A function past the encode point is read as its body; one before it, as its objects.
		for (fn in functions) {
			var body = fn.body;
			if (body == null) {
				for (block in fn.blocks)
					for (located in block.instructions)
						switch located.value {
							case Call(_, target, _), StaticClosure(_, target), InstanceClosure(_, target, _):
								require(fn.name, target.name);
							default:
						}
				continue;
			}
			for (block in 0...body.blockCount()) {
				var row = body.firstRow(block);
				while (row >= 0) {
					switch body.opcode(row) {
						case IrOpcode.Call, IrOpcode.StaticClosure, IrOpcode.InstanceClosure:
							require(fn.name, body.symbol(row).name);
						default:
					}
					row = body.nextRow(row);
				}
			}
		}
	}
}
