package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.IrTypeAwareWalk.IrClassDependencies;

/**
 * The prune of ADR 0003 §13 at the 3a point of `IrProgramAssembler.assemble` (docs/REACHABILITY_WALK.md): after the enum providers are
 * synthesized and before every later pass, a plain HashLink build drops the functions nothing reaches from the entry, so the passes
 * run on the reachable program. The walk is `IrTypeAwareWalk` (whole created classes); the backend's own prune after assembly
 * (`IrReachability.withGeneratedRuntimeRoots`) still runs and keeps a mentioned class's methods, so it removes nothing more of what this one kept.
 *
 * A later pass that calls a function this prune removed would produce a program that does not link (the failure of 2026-11-10), so
 * with HAXEON_CHECK_REUSE=1 `checkRemoved` runs after the passes and names the pass, the caller and the removed function.
 */
class IrEntryPrune {
	/**
	 * On for plain HashLink builds. HAXEON_EARLY_PRUNE=0 is a migration reference, not a product option: it exists so the driver can build
	 * every program both ways while the prune is new, and it is deleted with the driver's unpruned run (docs/REACHABILITY_WALK.md, "Removal").
	 */
	public static function enabled():Bool
		return Sys.getEnv("HAXEON_EARLY_PRUNE") != "0";

	public static function checking():Bool
		return Sys.getEnv("HAXEON_CHECK_REUSE") == "1";

	/** Prunes `program` to what `roots` (the entry's function, the static initializers, the exported functions) and `@:keep` reach. */
	public static function run(program:IrProgram, roots:Array<String>, ?classDependencies:IrClassDependencies):Map<String, Bool> {
		var removedMethods:Map<String, Bool> = [];
		// The type-aware walk alone: a class that is only mentioned, never created, keeps none of its methods. Its reach beyond what the old walk
		// keeps are the provider rows a dynamic site reaches over the created types (the equality helper of a struct that only `__dynamic_equal`
		// uses), which nothing calls by name until a later pass writes the call.
		var entries = roots.copy();
		for (fn in program.functions)
			if (fn.retention != Reachable)
				entries.push(fn.name);
		var walked = IrTypeAwareWalk.run(program, {functions: entries, types: []}, null, false, true, classDependencies);
		var reachable = walked.reached;
		// A method named by a reachable call on a class that cannot have an instance keeps its class-table entry and loses its body: the
		// verifier resolves the call against the table, but nothing can receive it, so the body is a stub that throws (the way an interface
		// method without an implementation is). A body that calls natives or other functions no longer keeps them.
		var stubbed = 0;
		for (index in 0...program.functions.length) {
			var fn = program.functions[index];
			if (walked.declarationOnly.exists(fn.name) && !reachable.exists(fn.name)) {
				program.functions[index] = declarationStub(fn);
				reachable.set(fn.name, true);
				stubbed++;
			}
		}
		var removed:Map<String, Bool> = [];
		for (fn in program.functions)
			if (!reachable.exists(fn.name))
				removed.set(fn.name, true);
		for (object in program.objects)
			for (method in object.methods)
				if (!reachable.exists(method.functionName))
					removedMethods.set(object.name + "\u0001" + method.name, true);
		IrReachability.prune(program, reachable);
		prunedMethods = removedMethods;
		return removed;
	}

	/** The function with the same name and signature and a body that throws: the declaration of a method nothing can call. */
	static function declarationStub(fn:IrFunction):IrFunction {
		var builder = new IrBuilder();
		for (argument in fn.arguments)
			builder.argument(argument.name, argument.type);
		builder.unreachable();
		return new IrFunction(fn.name, builder.arguments, fn.result, builder.blocks, fn.kind);
	}

	static var watched:Null<Map<String, Bool>> = null;

	/** The (class, method) table entries the last `run` removed, as `class\u0001method`: a lookup that visits one of them is a decision made on a method that is gone. */
	static var prunedMethods:Map<String, Bool> = [];

	/** Check mode: the names `run` removed, until `unwatch`; a lookup of one through `IrFunctionIndex` throws. */
	public static function watch(removed:Null<Map<String, Bool>>):Void
		watched = removed;

	public static function unwatch():Void
		watched = null;

	/** A method-table lookup of `method` is visiting `className`: in check mode it must not be an entry the prune removed. */
	public static function noteMethodLookup(className:String, method:String):Void
		if (watched != null && prunedMethods.exists(className + "\u0001" + method))
			throw 'early prune: a lookup of method "$method" visited class "$className", whose entry the prune removed';

	public static function noteLookup(pass:String, name:String):Void {
		var removed = watched;
		if (removed != null && removed.exists(name))
			throw 'early prune: pass "$pass" looked up function "$name", which the prune removed';
	}

	/** After `pass`: no function calls or closes over a function that `run` removed and no pass created again. */
	public static function checkRemoved(pass:String, functions:Array<IrFunction>, removed:Map<String, Bool>):Void {
		var present:Map<String, Bool> = [];
		for (fn in functions)
			present.set(fn.name, true);
		function require(caller:String, callee:String):Void
			if (removed.exists(callee) && !present.exists(callee))
				throw 'early prune: after "$pass", "$caller" calls "$callee", which the prune removed';
		for (fn in functions)
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case Call(_, target, _), StaticClosure(_, target), InstanceClosure(_, target, _):
							require(fn.name, target);
						default:
					}
	}
}
