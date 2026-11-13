package compiler.ir;

import compiler.ir.Ir.IrObject;
import compiler.ir.Ir.IrObjectTools;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;

/**
 * Which functions of an IR program are reachable, and the natives they call.
 *
 * The one walker: the Wasm builders use it to emit only what is reachable, and HashLink prunes with it too. Roots are the entry,
 * the functions declared `@:keep` or `@:expose` (`IrFunction.retention`), the toString implementations a dynamic stringification
 * calls, and the functions native declarations generate calls to; edges are calls, closures and dispatch. Dispatch (a method call
 * through a class or interface type, or reflection by field name) reaches a class's methods only once a reached function constructs
 * that class (rapid type analysis): a class nothing constructs has no instance to receive the call.
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
	public static function withGeneratedRuntimeRoots(program:IrProgram, entry:String, ?additionalRoots:Array<String>, keepLiveClasses = false):Map<String, Bool>
		return walkWithGeneratedRuntimeRoots(program, entry, additionalRoots, keepLiveClasses).reachable;

	/** `withGeneratedRuntimeRoots`, with the finished walk: what it reached, the natives it calls and the classes it mentions. */
	public static function walkWithGeneratedRuntimeRoots(program:IrProgram, entry:String, ?additionalRoots:Array<String>,
			keepLiveClasses = false):IrReachabilityWalk {
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
				if (native.generatedFunctionDependencies != null)
					for (dependency in native.generatedFunctionDependencies)
						if (!dependenciesDone.exists(dependency) && walk.layoutMayHaveInstances(native.name, dependency)) {
							dependenciesDone.set(dependency, true);
							walk.visit(dependency);
						}
			}
			if (walk.count == before)
				return walk;
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

	/**
	 * Removes from `program` the natives no reached function calls, the classes no reached function, kept declaration or kept class mentions,
	 * and the globals no reached function reads or writes, so a module is written from the reached program alone (an unused module that
	 * declares natives, classes and globals leaves no trace in it). `walk` is a walk made with `keepLiveClasses`. The enums and interfaces
	 * stay, and so does every class their types mention.
	 */
	public static function trimTables(program:IrProgram, walk:IrReachabilityWalk):Void {
		// An `Unreachable` terminator lowers to a call of the fatal native, which no `Call` instruction names.
		var fatal = false;
		for (fn in program.functions)
			for (block in fn.blocks)
				if (block.terminator != null)
					switch block.terminator.value {
						case Unreachable:
							fatal = true;
						default:
					}
		program.natives = [
			for (native in program.natives)
				if (walk.used.exists(native.name) || (fatal && native.name == "__unreachable")) native
		];
		var globals:Map<String, Bool> = [];
		for (fn in program.functions)
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case GlobalGet(_, name), GlobalSet(name, _):
							globals.set(name, true);
						default:
					}
		program.staticFields = [for (field in program.staticFields) if (globals.exists(field.name)) field];
		var kept:Map<String, Bool> = walk.liveClassNames();
		var objects:Map<String, IrObject> = [for (object in program.objects) object.name => object];
		var pending:Array<IrType> = [];
		for (field in program.staticFields)
			pending.push(field.type);
		for (declaration in program.enums)
			for (enumCase in declaration.cases)
				for (type in enumCase.params)
					pending.push(type);
		for (interfaceDecl in program.interfaces)
			for (method in interfaceDecl.methods) {
				pending.push(method.result);
				for (argument in method.arguments)
					pending.push(argument);
			}
		var classes = [for (name in kept.keys()) name];
		function mention(type:IrType):Void
			switch type {
				case Obj(name):
					if (!kept.exists(name)) {
						kept.set(name, true);
						classes.push(name);
					}
				case Array(element), Nullable(element), Iterator(element):
					mention(element);
				case Function(arguments, result):
					for (argument in arguments)
						mention(argument);
					mention(result);
				default:
			}
		for (type in pending)
			mention(type);
		var index = 0;
		while (index < classes.length) {
			var object = objects.get(classes[index++]);
			if (object == null)
				continue;
			if (object.base != null)
				mention(Obj(object.base));
			for (field in object.fields)
				mention(field.type);
		}
		program.objects = [for (object in program.objects) if (kept.exists(object.name)) object];
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

	/** The classes some reached function mentions by type (only with `keepLiveClasses`). */
	public function liveClassNames():Map<String, Bool>
		return liveClasses.copy();

	final index:IrProgramIndex;
	final byName:Map<String, IrFunction> = [];
	final dispatched:Map<String, Bool> = [];
	final keepLiveClasses:Bool;
	final liveClasses:Map<String, Bool> = [];

	/**
	 * Classes that can have instances: those a reached function constructs (`NewObject`) or a reached native returns. Value classes,
	 * anonymous records and interface boxes are created in other ways (copies, literals, boxing), so they always count.
	 */
	final instantiated:Map<String, Bool> = [];

	/** The method calls reached so far, by receiver type, so a class constructed later receives them too. */
	final dispatches:Array<{type:String, isInterface:Bool, method:String}> = [];

	/** The class each native's result is an instance of, for natives that return objects. */
	final nativeResults:Map<String, String>;

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
		nativeResults = IrConstructed.nativeResults(program);
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
					var made = IrConstructed.constructedBy(located.value, nativeResults);
					if (made != null)
						construct(made, pending);
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
							// Every call of a method on a type reaches the same candidates, so each pair is expanded once; classes constructed
							// later are matched against the recorded calls in `construct`.
							switch object.type {
								case Obj(typeName):
									dispatch(typeName, false, method, pending);
								case Virtual(interfaceName):
									dispatch(interfaceName, true, method, pending);
								default:
							}
						default:
					}
				}
		}
	}

	function dispatch(typeName:String, isInterface:Bool, method:String, pending:Array<String>):Void {
		var key = typeName + (isInterface ? "\u0002" : "\u0001") + method;
		if (dispatched.exists(key))
			return;
		dispatched.set(key, true);
		dispatches.push({type: typeName, isInterface: isInterface, method: method});
		var candidates = isInterface ? index.implementorsOf(typeName) : index.subtypesOf(typeName);
		for (candidate in candidates)
			if (hasInstances(candidate.name))
				enqueue(index.findMethod(candidate.name, method), pending);
	}

	/** Records that `typeName` has instances, and reaches the methods of it that the calls seen so far dispatch to. */
	function construct(typeName:String, pending:Array<String>):Void {
		if (instantiated.exists(typeName))
			return;
		instantiated.set(typeName, true);
		for (call in dispatches)
			if (call.isInterface ? index.implementsInterface(typeName, call.type) : index.isObjectSubtype(typeName, call.type))
				enqueue(index.findMethod(typeName, call.method), pending);
	}

	function hasInstances(typeName:String):Bool {
		if (instantiated.exists(typeName))
			return true;
		return IrConstructed.withoutConstruction(typeName, index.object(typeName));
	}

	/**
	 * Whether the per-layout function `dependency` that the reflection native `native` dispatches to (named `native.Layout`) can be
	 * given a value: a layout reflects instances of its class and of the classes extending it that have no layout of their own, so it
	 * is needed once any of those has instances. A name not of that shape stays.
	 */
	public function layoutMayHaveInstances(native:String, dependency:String):Bool {
		var prefix = native + ".";
		if (!StringTools.startsWith(dependency, prefix))
			return true;
		var layout = index.object(dependency.substr(prefix.length));
		if (layout == null)
			return true;
		for (candidate in index.subtypesOf(layout.name))
			if (hasInstances(candidate.name))
				return true;
		return false;
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
