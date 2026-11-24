package compiler.ir.analysis;

import compiler.ir.model.IrBody;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrOperands;
import compiler.ir.model.IrProgramIndex;
import compiler.ir.model.IrTypeIds;
import compiler.ir.reuse.IrFunctionMemo;

import compiler.core.InternalError;
import compiler.ir.model.Ir.IrIntrinsic;
import compiler.ir.model.Ir.IrObject;
import compiler.ir.model.Ir.IrObjectTools;
import compiler.ir.model.Ir.IrProgram;
import compiler.ir.model.Ir.IrType;
import compiler.ir.model.Ir;
import compiler.ir.passes.values.IrValueInterfaceBoxes;
import compiler.semantic.SemanticSignature;

/**
 * Which functions of an IR program are reachable, and the natives they call.
 *
 * The one walker: the Wasm builders use it to emit only what is reachable, and HashLink prunes with it too. Roots are the entry,
 * the functions declared `@:keep` or `@:expose` (`IrFunction.retention`), the toString implementations a dynamic stringification
 * calls, and the functions native declarations generate calls to; edges are calls, closures and dispatch. Dispatch (a method call
 * through a class or interface type, or reflection by field name) reaches a class's methods only once a reached function constructs
 * that class (rapid type analysis): a class nothing constructs has no instance to receive the call.
 */
@:nullSafety(Strict)
class IrReachability {
	/** The functions reachable from `entry` and `additionalRoots` by calls, closures and method calls. */
	public static function functions(program:IrProgram, entry:String,
			?additionalRoots:Array<String>):Map<String, Bool> {
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
			keepLiveClasses = false):Map<String, Bool>
		return walkWithGeneratedRuntimeRoots(program, entry, additionalRoots, keepLiveClasses).reachable;

	/** `withGeneratedRuntimeRoots`, with the finished walk: what it reached, the natives it calls and the classes it mentions. */
	public static function walkWithGeneratedRuntimeRoots(program:IrProgram, entry:String,
			?additionalRoots:Array<String>,
			keepLiveClasses = false, ?memo:IrFunctionMemo<IrBodyEdges>):IrReachabilityWalk {
		var walk = new IrReachabilityWalk(program, keepLiveClasses, memo);
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
						if (!dependenciesDone.exists(dependency)
							&& walk.layoutMayHaveInstances(native.name, dependency)) {
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
		program.objects = [for (object in program.objects) {
			var kept = [for (method in object.methods) if (reachable.exists(method.functionName.name)) method];
			kept.length == object.methods.length ? object : IrObjectTools.withMethods(object, kept);
		}];
	}

	/**
	 * Removes from `program` the natives no reached function calls, the classes no reached function, kept declaration or kept class mentions,
	 * and the globals no reached function reads or writes, so a module is written from the reached program alone (an unused module that
	 * declares natives, classes and globals leaves no trace in it). `walk` is a walk made with `keepLiveClasses`. The enums and interfaces
	 * stay, and so does every class their types mention.
	 */
	public static function trimTables(program:IrProgram, walk:IrReachabilityWalk,
			?memo:IrFunctionMemo<IrBodyEdges>):Void {
		var fatal = false, globals:Map<String, Bool> = [];
		var objects:Map<String, IrObject> = [for (object in program.objects) object.name => object];
		var kept:Map<String, Bool> = [], classes:Array<String> = [];
		function keep(name:String):Void
			if (!kept.exists(name)) {
				kept.set(name, true);
				classes.push(name);
			}
		function mention(type:IrType):Void
			namedClasses(type, keep);
		for (fn in program.functions) {
			var summary = memo == null ? IrBodyEdges.trimmed(fn) : memo.get(fn);
			if (summary == null && memo != null) {
				summary = IrBodyEdges.of(fn);
				memo.set(fn, summary);
			}
			if (summary == null)
				continue;
			if (summary.fatal)
				fatal = true;
			for (name in summary.globals)
				globals.set(name, true);
			for (name in summary.classes)
				keep(name);
		}
		program.natives = [
			for (native in program.natives)
				if (walk.used.exists(native.name) || (fatal && native.name == "__unreachable")) native
		];
		program.staticFields = [for (field in program.staticFields) if (globals.exists(field.name)) field];
		// The classes the written program names, and what those classes hold: `functionTypes` and `tableTypes` are the one list of where a
		// program names a type, shared with `checkTables`, so what the trim keeps and what the check demands cannot drift apart.
		tableTypes(program, (_, type) -> mention(type));
		var index = 0;
		while (index < classes.length) {
			var object = objects.get(classes[index++]);
			if (object != null)
				objectTypes(object, (_, type) -> mention(type));
		}
		program.objects = [for (object in program.objects) if (kept.exists(object.name)) object];
	}

	/** Calls `keep` with every class `type` names. */
	public static function namedClasses(type:IrType, keep:String->Void):Void
		switch type {
			case Obj(name):
				keep(name);
			case Array(element), Nullable(element), Iterator(element):
				namedClasses(element, keep);
			case Function(arguments, result):
				for (argument in arguments)
					namedClasses(argument, keep);
				namedClasses(result, keep);
			default:
		}

	/**
	 * Every type the functions and tables of `program` name, as `visit(owner, type)`: the types of a function's arguments, result and instruction outputs;
	 * the types an instruction names without producing a value of them (a type value, the type operand of an enum intrinsic); the signatures of the
	 * natives and C natives; the globals; the payloads of the enums; the interface method signatures. The classes of `program.objects` are not listed
	 * (`objectTypes`): the trim follows them from the classes named here, the check looks at every one.
	 */
	public static function namedTypes(program:IrProgram, visit:(String, IrType) -> Void):Void {
		for (fn in program.functions)
			functionTypes(fn, visit);
		tableTypes(program, visit);
	}

	/** The types function `fn` names (see `namedTypes`). */
	public static function functionTypes(fn:IrFunction, visit:(String, IrType) -> Void):Void {
		visit(fn.name, fn.result);
		for (argument in fn.arguments)
			visit(fn.name, argument.type);
		var body = fn.body;
		if (body != null) {
			for (block in 0...body.blockCount()) {
				var row = body.firstRow(block), terminator = body.terminatorRow(block);
				while (row >= 0 && row != terminator) {
					var output = body.output(row);
					if (output.exists())
						visit(fn.name, body.valueType(output));
					switch body.opcode(row) {
						case IrOpcode.TypeValue, IrOpcode.EnumDynamicBox, IrOpcode.EnumDynamicView,
							IrOpcode.EnumTagBox,
							IrOpcode.EnumTagUnbox, IrOpcode.InlineEnumBox, IrOpcode.InlineEnumUnbox:
							visit(fn.name, body.typeOperand(row));
						default:
					}
					row = body.nextRow(row);
				}
			}
			return;
		}
		for (block in fn.blocks)
			for (located in block.instructions) {
				var output = IrOperands.output(located.value);
				if (output != null)
					visit(fn.name, output.type);
				switch located.value {
					case TypeValue(_, type):
						visit(fn.name, type);
					case Intrinsic(_, operation, _):
						visit(fn.name, intrinsicType(operation));
					default:
				}
			}
	}

	/** The types the tables of `program` name, its functions aside (see `namedTypes`). */
	public static function tableTypes(program:IrProgram, visit:(String, IrType) -> Void):Void {
		for (native in program.natives) {
			for (argument in native.arguments)
				visit("native " + native.name, argument);
			visit("native " + native.name, native.result);
		}
		for (native in program.cNatives) {
			for (argument in native.arguments)
				visit("native " + native.name, argument);
			visit("native " + native.name, native.result);
		}
		for (field in program.staticFields)
			visit("global " + field.name, field.type);
		for (declaration in program.enums)
			for (enumCase in declaration.cases)
				for (type in enumCase.params)
					visit("enum " + declaration.name, type);
		for (interfaceDecl in program.interfaces)
			for (method in interfaceDecl.methods) {
				visit("interface " + interfaceDecl.name, method.result);
				for (argument in method.arguments)
					visit("interface " + interfaceDecl.name, argument);
			}
	}

	/** The types a class names: the one it extends and the types of its fields. */
	public static function objectTypes(object:IrObject, visit:(String, IrType) -> Void):Void {
		if (object.base != null)
			visit("class " + object.name, Obj(object.base));
		for (field in object.fields)
			visit("class " + object.name, field.type);
	}

	static function intrinsicType(operation:IrIntrinsic):IrType
		return switch operation {
			case EnumDynamicBox(type), EnumDynamicView(type), EnumTagBox(type), EnumTagUnbox(type), InlineEnumBox(type),
				InlineEnumUnbox(type): type;
		};

	/**
	 * Check mode, after `trimTables`: every class the written program names (`namedTypes`, `objectTypes`) is in its class table. Without it a missing class
	 * surfaces as a lowering failure in the backend ("Object type must be registered before use"); this names the function or table that mentions it.
	 */
	public static function checkTables(program:IrProgram):Void {
		var present:Map<String, Bool> = [for (object in program.objects) object.name => true];
		function check(owner:String, type:IrType):Void
			switch type {
				case Obj(name):
					if (!present.exists(name))
						throw new InternalError('trimmed tables: "$owner" names class "$name", which the module written for this build does not have');
				case Array(element), Nullable(element), Iterator(element):
					check(owner, element);
				case Function(arguments, result):
					for (argument in arguments)
						check(owner, argument);
					check(owner, result);
				default:
			}
		namedTypes(program, check);
		for (object in program.objects)
			objectTypes(object, check);
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

/**
 * What a plain build's reachability walk (`IrReachabilityWalk`) and its trim (`IrReachability.trimTables`) read of one function. The
 * walk's part is the body in row order, which the walk replays instead of reading the rows, so a session that keeps it while the
 * function is the same object (`IrFunctionMemo`) reads only the bodies an edit made; a function in blocks has none (the walk reads
 * its blocks). A type mentioned again, a class constructed again and a dispatch made again change nothing in a walk, so each is
 * listed once. The trim's part is whether a block ends unreachable and the globals and classes the function names.
 */
@:nullSafety(Strict)
class IrBodyEdges {
	public static inline final MENTION = 0;
	public static inline final CONSTRUCT = 1;
	public static inline final CALL = 2;
	public static inline final STATIC_CLOSURE = 3;
	public static inline final INSTANCE_CLOSURE = 4;
	public static inline final DYNAMIC_ITERATION = 5;
	public static inline final CLASS_DISPATCH = 6;
	public static inline final INTERFACE_DISPATCH = 7;

	/** Each event's kind. */
	public final kinds:Array<Int> = [];

	/** Each event's name: the function, class or receiver type; "" for a mention or a dynamic iteration. */
	public final names:Array<String> = [];

	/** A mention's type, a dispatch's method name (as `IrType.Obj`); null otherwise. */
	public final details:Array<Null<IrType>> = [];

	/** Whether a block ends unreachable: that terminator lowers to a call of the fatal native, which no `Call` instruction names. */
	public var fatal(default, null) = false;

	/** The globals the function reads or writes, and the classes its types name, each once. */
	public final globals:Array<String> = [];

	public final classes:Array<String> = [];

	function new() {}

	/** What `fn` gives the walk and the trim. */
	public static function of(fn:IrFunction):IrBodyEdges {
		var summary = new IrBodyEdges(), body = fn.body;
		if (body != null)
			summary.readEdges(body);
		summary.readTrim(fn);
		return summary;
	}

	/** The trim's part alone, for a build that keeps no summaries: its walk reads the bodies. */
	public static function trimmed(fn:IrFunction):IrBodyEdges {
		var summary = new IrBodyEdges();
		summary.readTrim(fn);
		return summary;
	}

	function readEdges(body:IrBody):Void {
		var summary = this, seen:Map<String, Bool> = [], mentioned:Map<Int, Bool> = [];
		function add(kind:Int, name:String, detail:Null<IrType>):Void {
			summary.kinds.push(kind);
			summary.names.push(name);
			summary.details.push(detail);
		}
		function once(key:String):Bool {
			if (seen.exists(key))
				return false;
			seen.set(key, true);
			return true;
		}
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block), terminator = body.terminatorRow(block);
			while (row >= 0 && row != terminator) {
				var output = body.output(row), opcode = body.opcode(row);
				if (output.exists()) {
					var type = body.valueTypeId(output);
					if (!mentioned.exists(type)) {
						mentioned.set(type, true);
						add(MENTION, "", IrTypeIds.type(type));
					}
				}
				switch opcode {
					case IrOpcode.NewObject:
						var name = body.symbol(row).name;
						if (once("new " + name))
							add(CONSTRUCT, name, null);
					case IrOpcode.Call:
						add(CALL, body.symbol(row).name, null);
					case IrOpcode.StaticClosure:
						add(STATIC_CLOSURE, body.symbol(row).name, null);
					case IrOpcode.InstanceClosure:
						add(INSTANCE_CLOSURE, body.symbol(row).name, null);
					case IrOpcode.IteratorNext if ((switch (body.valueType(output)) {
						case Dyn: true;
						default: false;
					})): add(DYNAMIC_ITERATION, "", null);
					case IrOpcode.MethodCall:
						var method = body.symbol(row).name;
						switch body.valueType(body.operand(row, 0)) {
							case Obj(typeName):
								if (once(typeName + "\u0001" + method))
									add(CLASS_DISPATCH, typeName, Obj(method));
							case Virtual(interfaceName):
								if (once(interfaceName + "\u0002" + method))
									add(INTERFACE_DISPATCH, interfaceName, Obj(method));
							default:
						}
					default:
				}
				row = body.nextRow(row);
			}
		}
	}

	function readTrim(fn:IrFunction):Void {
		var seenGlobals:Map<String, Bool> = [], seenClasses:Map<String, Bool> = [];
		function global(name:String):Void
			if (!seenGlobals.exists(name)) {
				seenGlobals.set(name, true);
				globals.push(name);
			}
		function keep(name:String):Void
			if (!seenClasses.exists(name)) {
				seenClasses.set(name, true);
				classes.push(name);
			}
		var body = fn.body;
		if (body != null) {
			for (block in 0...body.blockCount()) {
				var terminator = body.terminatorRow(block);
				if (terminator >= 0 && body.opcode(terminator) == IrOpcode.Unreachable)
					fatal = true;
				var row = body.firstRow(block);
				while (row >= 0) {
					var opcode = body.opcode(row);
					if (opcode == IrOpcode.GlobalGet || opcode == IrOpcode.GlobalSet)
						global(body.symbol(row).name);
					row = body.nextRow(row);
				}
			}
		} else
			for (block in fn.blocks) {
				if (block.terminator != null)
					switch block.terminator.value {
						case Unreachable:
							fatal = true;
						default:
					}
				for (located in block.instructions)
					switch located.value {
						case GlobalGet(_, name), GlobalSet(name, _):
							global(name);
						default:
					}
			}
		IrReachability.functionTypes(fn, (_, type) -> IrReachability.namedClasses(type, keep));
	}

	/** Whether two functions give the walk and the trim the same. */
	public static function same(left:IrBodyEdges, right:IrBodyEdges):Bool {
		if (left == right)
			return true;
		var count = left.kinds.length;
		if (count != right.kinds.length || left.fatal != right.fatal
			|| !IrObjectTools.sameNames(left.globals, right.globals)
			|| !IrObjectTools.sameNames(left.classes, right.classes))
			return false;
		for (index in 0...count) {
			if (left.kinds[index] != right.kinds[index] || left.names[index] != right.names[index])
				return false;
			var a = left.details[index], b = right.details[index];
			if (a == null || b == null) {
				if (a != null || b != null)
					return false;
			} else if (!compiler.ir.model.IrTypeIdentity.same(a, b))
				return false;
		}
		return true;
	}
}

/** One walk over a program that takes more roots as they appear. */
@:nullSafety(Strict)
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
	/** The walk summaries of the bodies, kept by a session while each function is the same object; null to read every body. */
	final memo:Null<IrFunctionMemo<IrBodyEdges>>;

	public function new(program:IrProgram, keepLiveClasses = false, ?memo:IrFunctionMemo<IrBodyEdges>) {
		index = IrProgramIndex.of(program);
		this.keepLiveClasses = keepLiveClasses;
		this.memo = memo;
		for (fn in program.functions)
			byName.set(fn.name, fn);
		nativeResults = IrConstructed.nativeResults(program);
	}

	public function visit(root:String):Void {
		var pending = [root];
		while (pending.length > 0) {
			var name = pending.pop();
			if (name == null)
				break;
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
			var body = fn.body;
			if (body != null) {
				var known = memo;
				if (known == null) {
					visitBody(body, pending);
					continue;
				}
				var summary = known.get(fn);
				if (summary == null) {
					summary = IrBodyEdges.of(fn);
					known.set(fn, summary);
				}
				replay(summary, pending);
				continue;
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
							used.set(target.name, true);
							pending.push(target.name);
						case StaticClosure(_, target):
							used.set(target.name, true);
							pending.push(target.name);
						case InstanceClosure(_, target, _):
							pending.push(target.name);
						// Dynamic iterators read through the Array<Dynamic> element reader.
						case IteratorNext(output, _) if ((switch (output.type) {
							case Dyn: true;
							default: false;
						})): used.set("__array_get_any", true);
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

	/** `visit`'s walk of a reached function that is its body (the inliner's output): what its rows call, make and mention. */
	function visitBody(body:IrBody, pending:Array<String>):Void
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block), terminator = body.terminatorRow(block);
			while (row >= 0 && row != terminator) {
				var output = body.output(row), opcode = body.opcode(row);
				if (keepLiveClasses && output.exists())
					mention(body.valueType(output), pending);
				switch opcode {
					case IrOpcode.NewObject:
						construct(body.symbol(row).name, pending);
					case IrOpcode.Call:
						var target = body.symbol(row).name, made = nativeResults.get(target);
						if (made != null)
							construct(made, pending);
						used.set(target, true);
						pending.push(target);
					case IrOpcode.StaticClosure:
						var target = body.symbol(row).name;
						used.set(target, true);
						pending.push(target);
					case IrOpcode.InstanceClosure:
						pending.push(body.symbol(row).name);
					// Dynamic iterators read through the Array<Dynamic> element reader.
					case IrOpcode.IteratorNext if ((switch (body.valueType(output)) {
						case Dyn: true;
						default: false;
					})): used.set("__array_get_any", true);
					case IrOpcode.MethodCall if (!keepLiveClasses):
						switch body.valueType(body.operand(row, 0)) {
							case Obj(typeName):
								dispatch(typeName, false, body.symbol(row).name, pending);
							case Virtual(interfaceName):
								dispatch(interfaceName, true, body.symbol(row).name, pending);
							default:
						}
					default:
				}
				row = body.nextRow(row);
			}
		}

	/** `visitBody` from a body's summary: the same steps in the same order. */
	function replay(summary:IrBodyEdges, pending:Array<String>):Void {
		var kinds = summary.kinds, names = summary.names, details = summary.details;
		for (index in 0...kinds.length) {
			var name = names[index];
			switch kinds[index] {
				case IrBodyEdges.MENTION:
					var type = details[index];
					if (keepLiveClasses && type != null)
						mention(type, pending);
				case IrBodyEdges.CONSTRUCT:
					construct(name, pending);
				case IrBodyEdges.CALL:
					var made = nativeResults.get(name);
					if (made != null)
						construct(made, pending);
					used.set(name, true);
					pending.push(name);
				case IrBodyEdges.STATIC_CLOSURE:
					used.set(name, true);
					pending.push(name);
				case IrBodyEdges.INSTANCE_CLOSURE:
					pending.push(name);
				case IrBodyEdges.DYNAMIC_ITERATION:
					used.set("__array_get_any", true);
				case IrBodyEdges.CLASS_DISPATCH | IrBodyEdges.INTERFACE_DISPATCH:
					if (!keepLiveClasses)
						switch details[index] {
							case Obj(method):
								dispatch(name, kinds[index] == IrBodyEdges.INTERFACE_DISPATCH, method, pending);
							default:
						}
				default:
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
			if (call.isInterface ? index.implementsInterface(typeName, call.type) : index.isObjectSubtype(typeName,
				call.type))
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
						pending.push(method.functionName.name);
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
						into.set(name.name, true);
					case StaticClosure(_, name):
						into.set(name.name, true);
					// Dynamic iterators read through the Array<Dynamic> element reader.
					case IteratorNext(output, _) if ((switch (output.type) {
						case Dyn: true;
						default: false;
					})): into.set("__array_get_any", true);
					default:
				}
}

/**
 * What it means for a class to have instances: the one definition both reachability walks use (`IrReachabilityWalk`, the rapid type analysis
 * the Wasm builders run, and `IrTypeAwareWalk`, the prune). A class has instances once a reached function constructs it (`NewObject`) or a
 * reached native returns it; value classes, anonymous records and interface boxes are made in other ways (copies, literals, boxing), so they
 * always have; a name in no object table is a type only native code knows, which has instances too. `IrTypeAwareWalk` adds over-approximations
 * on top (a class it converts to Dynamic, a class in a signature).
 *
 * **The native contract.** A native constructs exactly the class its declaration returns, and no other: not a subclass of it, and not an argument's
 * class (an argument was constructed by its caller, which a walk sees). Native code that builds an instance of a class chosen at run time has to
 * be given that class, as a `Class<T>` or a type argument, which is a typed reference a walk counts as created. Audited on 2026-11-12: no runtime
 * native, std native or FFI native bound by the project allocates an object of a class its declaration does not name (`__reflect_copy` copies an
 * instance of its argument's own class, which its caller already constructed).
 */
@:nullSafety(Strict)
class IrConstructed {
	/** Whether the class has instances without any function constructing them. `object` is its table entry, or null when there is none. */
	public static function withoutConstruction(typeName:String, object:Null<IrObject>):Bool
		return object == null
			|| object.isValue
			|| StringTools.startsWith(typeName, IrValueInterfaceBoxes.BOX_PREFIX)
			|| SemanticSignature.isAnonymousName(typeName);

	/** The class a native's result type names (an optional one too), or null when the result is not an object. */
	public static function resultClass(type:IrType):Null<String>
		return switch type {
			case Obj(name): name;
			case Nullable(inner): resultClass(inner);
			default: null;
		};

	/** The class each native, `IrNative` or `IrCNative`, returns an instance of, by native name. */
	public static function nativeResults(program:IrProgram):Map<String, String> {
		var results:Map<String, String> = [];
		for (native in program.natives) {
			var result = resultClass(native.result);
			if (result != null)
				results.set(native.name, result);
		}
		for (native in program.cNatives) {
			var result = resultClass(native.result);
			if (result != null)
				results.set(native.name, result);
		}
		return results;
	}

	/** The class this instruction makes an instance of: a `NewObject`, or a call of a native that returns an object. */
	public static function constructedBy(instruction:IrInstruction, nativeResults:Map<String, String>):Null<String>
		return switch instruction {
			case NewObject(_, typeName): typeName;
			case Call(_, target, _): nativeResults.get(target.name);
			default: null;
		};
}

/**
 * HAXEON_REACHABILITY_REPORT=<file>: appends, for the program at a named point of the pipeline, the counts of today's walk against the
 * type-aware walk (`IrTypeAwareWalk.compare`). The step 1 diagnostic of `docs/design/REACHABILITY_WALK.md`: it changes nothing and is off unless the
 * variable is set. The roots are the entry and every `@:keep` / `@:expose` function.
 */
@:nullSafety(Strict)
class IrReachabilityReport {
	public static function enabled():Bool {
		var path = Sys.getEnv("HAXEON_REACHABILITY_REPORT");
		return path != null && path != "";
	}

	public static function report(point:String, program:IrProgram):Void {
		var path = Sys.getEnv("HAXEON_REACHABILITY_REPORT");
		if (path == null || path == "")
			return;
		var entries = [program.entryPoint];
		for (fn in program.functions)
			if (fn.retention != Reachable)
				entries.push(fn.name);
		var lines = IrTypeAwareWalk.compare(program, {functions: entries, types: []});
		var text = point + ", entry " + program.entryPoint + " (" + entries.length + " roots)\n  " + lines.join("\n  ")
			+ "\n";
		sys.io.File.saveContent(path, (sys.FileSystem.exists(path) ? sys.io.File.getContent(path) : "") + text);
	}
}
