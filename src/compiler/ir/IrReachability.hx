package compiler.ir;

import compiler.ir.Ir.IrProgram;

/**
 * Which functions of an IR program are reachable, and the natives they call.
 *
 * The one walker: the Wasm builders use it to emit only what is reachable, and the other targets can prune with it too. Roots are
 * the entry, the functions declared `@:keep` or `@:expose` (`IrFunction.retention`), the toString implementations a dynamic
 * stringification calls, and the functions native declarations generate calls to; edges are calls, closures and method calls over
 * every class (or implementor) that could receive them.
 */
class IrReachability {
	public static function functions(program:IrProgram, entry:String, ?additionalRoots:Array<String>):Map<String, Bool> {
		var index = IrProgramIndex.of(program),
			byName:Map<String, IrFunction> = [],
			reachable:Map<String, Bool> = [],
			pending:Array<String> = [entry];
		if (additionalRoots != null)
			for (root in additionalRoots)
				pending.push(root);
		for (fn in program.functions)
			byName.set(fn.name, fn);
		while (pending.length > 0) {
			var name = pending.pop();
			if (reachable.exists(name) || !byName.exists(name))
				continue;
			reachable.set(name, true);
			var fn = byName.get(name);
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case Call(_, target, _):
							enqueueFunction(target, byName, pending);
						case StaticClosure(_, target), InstanceClosure(_, target, _):
							enqueueFunction(target, byName, pending);
						case MethodCall(_, object, method, _, _):
							switch object.type {
								case Obj(objectName):
									for (candidate in index.subtypesOf(objectName))
										enqueueFunction(index.findMethod(candidate.name, method), byName, pending);
								case Virtual(interfaceName):
									for (candidate in index.implementorsOf(interfaceName))
										enqueueFunction(index.findMethod(candidate.name, method), byName, pending);
								default:
							}
						default:
					}
		}
		return reachable;
	}

	/**
	 * Computes Wasm reachability including calls introduced while lowering
	 * runtime natives. Those calls are not present in the source IR, so they
	 * cannot be discovered by `functions` alone. Native declarations
	 * carry these generated-function dependencies from the core runtime ABI;
	 * keep the expansion centralized so the linear and GC backends cannot drift
	 * apart.
	 */
	public static function withGeneratedRuntimeRoots(program:IrProgram, entry:String, ?additionalRoots:Array<String>):Map<String, Bool> {
		var roots:Array<String> = additionalRoots == null ? [] : additionalRoots.copy();
		// `@:keep` and `@:expose` functions stay even when nothing calls them.
		for (fn in program.functions)
			if (fn.retention != Reachable && roots.indexOf(fn.name) < 0)
				roots.push(fn.name);
		var reachable = functions(program, entry, roots);
		while (true) {
			var added = false, usedNatives = natives(program, reachable);
			// Dynamic stringification calls each class's toString, as HashLink's `__string` proto does.
			for (native in program.natives)
				if (usedNatives.exists(native.name) && native.symbol == "__std_string")
					for (object in program.objects) {
						var method = stringMethod(program, object.name);
						if (method != null && roots.indexOf(method) < 0) {
							roots.push(method);
							added = true;
						}
					}
			for (native in program.natives)
				if (usedNatives.exists(native.name) && native.generatedFunctionDependencies != null)
					for (dependency in native.generatedFunctionDependencies)
						if (roots.indexOf(dependency) < 0) {
							roots.push(dependency);
							added = true;
						}

			if (!added)
				return reachable;
			reachable = functions(program, entry, roots);
		}
	}

	static function enqueueFunction(name:Null<String>, byName:Map<String, IrFunction>, pending:Array<String>):Void
		if (name != null && byName.exists(name))
			pending.push(name);

	/** The toString implementation an object of exactly this class uses, if any. */
	public static function stringMethod(program:IrProgram, objectName:String):Null<String>
		return findMethod(program, objectName, "__string");

	static function findMethod(program:IrProgram, objectName:String, methodName:String):Null<String>
		return IrProgramIndex.of(program).findMethod(objectName, methodName);

	public static function natives(program:IrProgram, reachable:Map<String, Bool>):Map<String, Bool> {
		var result:Map<String, Bool> = [];
		for (fn in program.functions)
			if (reachable.exists(fn.name))
				for (block in fn.blocks)
					for (located in block.instructions)
						switch located.value {
							case Call(_, name, _):
								result.set(name, true);
							case StaticClosure(_, name):
								result.set(name, true);
							// Dynamic iterators read through the Array<Dynamic> element reader.
							case IteratorNext(output, _) if ((switch (output.type) { case Dyn: true; default: false; })):
								result.set("__array_get_any", true);
							default:
						}
		return result;
	}
}
