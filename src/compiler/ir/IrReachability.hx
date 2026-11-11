package compiler.ir;

import compiler.ir.Ir.IrObjectTools;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;

/**
 * Which functions of an IR program are reachable, and the natives they call.
 *
 * The one walker: the Wasm builders use it to emit only what is reachable, and HashLink prunes with it too. Roots are the entry,
 * the functions declared `@:keep` or `@:expose` (`IrFunction.retention`), the toString implementations a dynamic stringification
 * calls, and the functions native declarations generate calls to; edges are calls, closures and method calls over every class (or
 * implementor) that could receive them.
 */
class IrReachability {
	/** The functions reachable from `entry` and `additionalRoots` by calls, closures and method calls. */
	public static function functions(program:IrProgram, entry:String, ?additionalRoots:Array<String>):Map<String, Bool> {
		var walk = new IrReachabilityWalk(program);
		walk.visit(entry);
		if (additionalRoots != null)
			for (root in additionalRoots)
				walk.visit(root);
		return walk.reachable;
	}

	/**
	 * Computes reachability including calls introduced while lowering runtime natives. Those calls are not present in the source
	 * IR, so they cannot be discovered by `functions` alone. Native declarations carry these generated-function dependencies from
	 * the core runtime ABI; keep the expansion centralized so the linear and GC backends cannot drift apart. The walk continues
	 * from what it has reached whenever a new root appears, so it visits every function once.
	 */
	public static function withGeneratedRuntimeRoots(program:IrProgram, entry:String, ?additionalRoots:Array<String>,
			keepLiveClasses = false):Map<String, Bool> {
		var walk = new IrReachabilityWalk(program, keepLiveClasses);
		walk.visit(entry);
		if (additionalRoots != null)
			for (root in additionalRoots)
				walk.visit(root);
		// `@:keep` and `@:expose` functions stay even when nothing calls them.
		for (fn in program.functions)
			if (fn.retention != Reachable)
				walk.visit(fn.name);
		var stringRoots = false, dependenciesDone:Map<String, Bool> = [];
		while (true) {
			var before = walk.count;
			for (native in program.natives) {
				if (!walk.used.exists(native.name))
					continue;
				// Dynamic stringification calls each class's toString, as HashLink's `__string` proto does.
				if (native.symbol == "__std_string" && !stringRoots) {
					stringRoots = true;
					for (object in program.objects) {
						var method = stringMethod(program, object.name);
						if (method != null)
							walk.visit(method);
					}
				}
				if (native.generatedFunctionDependencies != null && !dependenciesDone.exists(native.name)) {
					dependenciesDone.set(native.name, true);
					for (dependency in native.generatedFunctionDependencies)
						walk.visit(dependency);
				}
			}
			if (walk.count == before)
				return walk.reachable;
		}
	}

	/**
	 * Removes the functions that are not in `reachable` from `program`, and their methods from its classes' tables (a class with no
	 * unreachable method is the same object). The classes themselves stay: their layouts are still the program's.
	 */
	public static function prune(program:IrProgram, reachable:Map<String, Bool>):Void {
		program.functions = [for (fn in program.functions) if (reachable.exists(fn.name)) fn];
		program.objects = [
			for (object in program.objects) {
				var kept = [for (method in object.methods) if (reachable.exists(method.functionName)) method];
				kept.length == object.methods.length ? object : IrObjectTools.withMethods(object, kept);
			}
		];
	}

	/** The toString implementation an object of exactly this class uses, if any. */
	public static function stringMethod(program:IrProgram, objectName:String):Null<String>
		return IrProgramIndex.of(program).findMethod(objectName, "__string");

	/** The names of the functions and natives called by the reachable functions (and the element reader dynamic iterators use). */
	public static function natives(program:IrProgram, reachable:Map<String, Bool>):Map<String, Bool> {
		var result:Map<String, Bool> = [];
		for (fn in program.functions)
			if (reachable.exists(fn.name))
				IrReachabilityWalk.collectCalled(fn, result);
		return result;
	}
}

/** One walk over a program that takes more roots as they appear. */
class IrReachabilityWalk {
	public final reachable:Map<String, Bool> = [];

	/** Names called or referenced as static closures by the functions reached so far. */
	public final used:Map<String, Bool> = [];

	public var count(default, null) = 0;

	final index:IrProgramIndex;
	final byName:Map<String, IrFunction> = [];
	final dispatched:Map<String, Bool> = [];
	final keepLiveClasses:Bool;
	final liveClasses:Map<String, Bool> = [];

	/**
	 * With `keepLiveClasses`, every class that a reachable function mentions by type is live, and a live class keeps all its methods
	 * and those of the classes it extends: its method table is built from them, and anything holding an instance can call them by name
	 * (`Reflect.field`). A class nothing mentions has no instance, so its methods go. Every value a function uses is defined by an
	 * argument or an instruction output, so the types of those are all the types it mentions.
	 */
	public function new(program:IrProgram, keepLiveClasses = false) {
		index = IrProgramIndex.of(program);
		this.keepLiveClasses = keepLiveClasses;
		for (fn in program.functions)
			byName.set(fn.name, fn);
	}

	public function visit(root:String):Void {
		var pending = [root];
		while (pending.length > 0) {
			var name = pending.pop();
			if (reachable.exists(name))
				continue;
			var fn = byName.get(name);
			if (fn == null)
				continue;
			reachable.set(name, true);
			count++;
			if (keepLiveClasses) {
				mention(fn.result, pending);
				for (argument in fn.arguments)
					mention(argument.type, pending);
			}
			for (block in fn.blocks)
				for (located in block.instructions) {
					if (keepLiveClasses) {
						var output = IrOperands.output(located.value);
						if (output != null)
							mention(output.type, pending);
					}
					switch located.value {
						case Call(_, target, _):
							used.set(target, true);
							pending.push(target);
						case StaticClosure(_, target):
							used.set(target, true);
							pending.push(target);
						case InstanceClosure(_, target, _):
							pending.push(target);
						// Dynamic iterators read through the Array<Dynamic> element reader.
						case IteratorNext(output, _) if ((switch (output.type) {
							case Dyn: true;
							default: false;
						})):
							used.set("__array_get_any", true);
						// With live classes a method call needs no edge: whatever it can reach belongs to a class with an instance, and that class
						// is mentioned by the function that makes the instance, so it keeps all its methods.
						case MethodCall(_, object, method, _, _) if (!keepLiveClasses):
							// Every call of a method on a type reaches the same candidates, so each pair is expanded once.
							switch object.type {
								case Obj(objectName):
									if (!dispatched.exists(objectName + "\u0001" + method)) {
										dispatched.set(objectName + "\u0001" + method, true);
										for (candidate in index.subtypesOf(objectName))
											enqueue(index.findMethod(candidate.name, method), pending);
									}
								case Virtual(interfaceName):
									if (!dispatched.exists(interfaceName + "\u0002" + method)) {
										dispatched.set(interfaceName + "\u0002" + method, true);
										for (candidate in index.implementorsOf(interfaceName))
											enqueue(index.findMethod(candidate.name, method), pending);
									}
								default:
							}
						default:
					}
				}
		}
	}

	function mention(type:IrType, pending:Array<String>):Void
		switch type {
			case Obj(name):
				var current:Null<String> = name;
				while (current != null && !liveClasses.exists(current)) {
					liveClasses.set(current, true);
					var object = index.object(current);
					if (object == null)
						break;
					for (method in object.methods)
						pending.push(method.functionName);
					current = object.base;
				}
			case Array(element), Nullable(element), Iterator(element):
				mention(element, pending);
			case Function(arguments, result):
				for (argument in arguments)
					mention(argument, pending);
				mention(result, pending);
			default:
		}

	static inline function enqueue(name:Null<String>, pending:Array<String>):Void
		if (name != null)
			pending.push(name);

	public static function collectCalled(fn:IrFunction, into:Map<String, Bool>):Void
		for (block in fn.blocks)
			for (located in block.instructions)
				switch located.value {
					case Call(_, name, _):
						into.set(name, true);
					case StaticClosure(_, name):
						into.set(name, true);
					// Dynamic iterators read through the Array<Dynamic> element reader.
					case IteratorNext(output, _) if ((switch (output.type) {
						case Dyn: true;
						default: false;
					})):
						into.set("__array_get_any", true);
					default:
				}
}
