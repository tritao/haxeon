package compiler.ir;

import compiler.core.Provides.ProviderOperation;
import compiler.ir.Ir;

/** What a walk starts from: function names that are reached whatever calls them, and types that exist from the start. */
typedef IrWalkRoots = {
	/** The entry of the build kind, static initializers, `@:keep` / `@:expose` functions, native callbacks and live-host entries. */
	final functions:Array<String>;

	/** Types that exist without any reached function creating them (the types in a root's signature, reflected native types). */
	final types:Array<IrType>;
}

/** The outcome of one walk. The program is never changed. */
typedef IrWalkResult = {
	/** Names of the functions reached. */
	final reached:Map<String, Bool>;

	/** `TypeKey` texts of the types that can exist at run time (the coarse set: see `IrTypeAwareWalk`). */
	final created:Map<String, Bool>;

	/** Names of the classes in `created`. */
	final createdClasses:Map<String, Bool>;

	/** Typed operations the reached code asks for, as `operation\nTypeKey` rows (what a provider table must answer). */
	final demanded:Map<String, Bool>;

	/** Reached typed operations with no provider row, one text each (only when the walk is asked to require providers). */
	final missingProviders:Array<String>;

	/** How many reached functions are provider rows. */
	final providersReached:Int;

	/**
	 * Methods a reached call names on a class whose own implementation nothing reaches (a base class nothing constructs): the class table keeps the
	 * entry the verifier resolves the call against, and the body is not needed. Not in `reached`.
	 */
	final declarationOnly:Map<String, Bool>;

	/** Names of the natives (`IrNative` and `IrCNative`) that reached code calls or takes as a closure. */
	final calledNatives:Map<String, Bool>;
}

/**
 * Functions that code generated after the walk will call for a created class, when one of the natives that is replaced by such code is
 * called: the typed form of a dependency that has no call edge yet (a reflection copy of an observable class).
 */
typedef IrClassDependencies = {
	/** The `IrNative.symbol`s that generated code replaces: when reached code calls one, the generated code's dependencies are reached for every class. */
	final symbols:Array<String>;

	/** The functions the code generated for this class in place of the native with this symbol calls; throws when one that must exist does not. */
	final of:(String, String) -> Array<String>;
}

/**
 * A reachability walk that knows what a class or enum can be created, and follows typed operations to provider rows (ADR 0003 section 13,
 * `docs/design/REACHABILITY_WALK.md`). It is a pure function of a program and its roots: it reads the IR and returns sets, and nothing in the
 * enum code or the passes calls it, so the roots, the created set and the used operations are all explicit.
 *
 * Edges: calls, closures; a method call reaches its implementation in every *created* subclass of the receiver's class (an interface call:
 * in every created implementor); a typed operation (`Intrinsic`) reaches the provider row of its subject; a dynamic site (a call to a native
 * such as `__dynamic_equal`) reaches the provider rows of its operation for every created type.
 *
 * `created` is deliberately coarse and only over-approximates: a type is created when a reached function constructs it (`NewObject`,
 * `MakeEnum`), converts to or from it dynamically (`ToDyn`, `SafeCast`), has it as the type of a value of a value class, passes it across a
 * called native's signature, stores it in a static field the code touches, or holds it in a field of a created class; and when a root
 * names it. A type that is only mentioned by an argument type is not created. Keeping more never miscompiles.
 */
class IrTypeAwareWalk {
	/**
	 * `dynamicSites`: the native a dynamic site calls, to the provider operations it needs of every created type (default `defaultDynamicSites`).
	 * `requireProviders`: report a reached typed operation with no row (the check that holds once the producers have run).
	 * `keepCreatedClassMethods`: every method of a created class is reached, as the plain HashLink prune does today for a mentioned class
	 * (a method can be reached by name through reflection); off, only called methods are.
	 */
	public static function run(program:IrProgram, roots:IrWalkRoots, ?dynamicSites:Map<String, Array<String>>,
			requireProviders = false,
			keepCreatedClassMethods = false, ?classDependencies:IrClassDependencies,
			?lineage:compiler.ir.IrStageMemo.IrLineage):IrWalkResult {
		var walk = new IrTypeAwareWalkState(program, roots, dynamicSites == null ? defaultDynamicSites() : dynamicSites,
			requireProviders,
			keepCreatedClassMethods, classDependencies, lineage);
		return walk.run();
	}

	/** The natives that act as dynamic sites, and the provider operations (without detail) they need of each type. */
	public static function defaultDynamicSites():Map<String, Array<String>> {
		var sites:Map<String, Array<String>> = [];
		var equality:Array<String> = [ProviderOperation.Equals, ProviderOperation.ReflectEquals];
		var reflective:Array<String> = [ProviderOperation.ReflectEquals];
		var test:Array<String> = [ProviderOperation.DynamicTest];
		sites.set("__dynamic_equal", equality);
		sites.set(IrEnumDynamicDispatch.REFLECT, reflective);
		sites.set("__std_is_of_type", test);
		sites.set("__std_is_exact_type", test);
		sites.set(IrExactTypeFacts.TEST, test);
		return sites;
	}

	/** Functions whose name says they are generated (`$...`) but whose kind says nothing: a helper no walk can place without its name. */
	public static function kindlessHelpers(program:IrProgram):Array<String> {
		var names:Array<String> = [];
		for (fn in program.functions)
			if (StringTools.startsWith(fn.name, "$"))
				switch fn.kind {
					case Ordinary:
						names.push(fn.name);
					default:
				}
		return names;
	}

	/**
	 * The side-by-side counts of the diagnostic: everything present, what today's walk (`IrReachability`, the plain HashLink prune) keeps,
	 * and what this walk keeps, as lines of text. Objects count the classes with a reached method.
	 */
	public static function compare(program:IrProgram, roots:IrWalkRoots,
			?dynamicSites:Map<String, Array<String>>):Array<String> {
		var today = IrReachability.withGeneratedRuntimeRoots(program, roots.functions[0], roots.functions.slice(1),
			true);
		var strict = run(program, roots, dynamicSites, false, false);
		var wide = run(program, roots, dynamicSites, false, true);
		var providersAll = 0;
		for (fn in program.functions)
			switch fn.provides {
				case Serves(_, _):
					providersAll++;
				case None:
			}
		var providersToday = 0;
		for (fn in program.functions)
			if (today.exists(fn.name))
				switch fn.provides {
					case Serves(_, _):
						providersToday++;
					case None:
				}
		return [
			'functions: all ${program.functions.length}, today ${count(today)}, type-aware ${count(wide.reached)} (called methods only: ${count(strict.reached)})',
			'objects with a reached method: all ${program.objects.length}, today ${objectsKept(program, today)}, type-aware ${objectsKept(program, wide.reached)} (called methods only: ${objectsKept(program, strict.reached)})',
			'providers: all $providersAll, today $providersToday, type-aware ${wide.providersReached} (called methods only: ${strict.providersReached})',
			'created types: ${count(wide.created)}, created classes: ${count(wide.createdClasses)}',
			'kindless helpers: ${kindlessHelpers(program).length}'
		];
	}

	static function count(set:Map<String, Bool>):Int {
		var total = 0;
		for (_ in set.keys())
			total++;
		return total;
	}

	static function objectsKept(program:IrProgram, reached:Map<String, Bool>):Int {
		var total = 0;
		for (object in program.objects) {
			var any = false;
			for (method in object.methods)
				if (reached.exists(method.functionName.name))
					any = true;
			if (any)
				total++;
		}
		return total;
	}
}

/** One dispatch the walk has met: a method called on a class or interface, re-expanded whenever a class becomes created. */
private typedef DispatchSite = {
	final typeName:String;
	final method:String;
	final isInterface:Bool;
}

private class IrTypeAwareWalkState {
	final program:IrProgram;
	final roots:IrWalkRoots;
	final dynamicSites:Map<String, Array<String>>;
	final requireProviders:Bool;
	final keepCreatedClassMethods:Bool;
	final classDependencies:Null<IrClassDependencies>;
	final lineage:Null<compiler.ir.IrStageMemo.IrLineage>;
	final dependencySymbolsDone:Map<String, Bool> = [];
	final index:IrProgramIndex;
	final byName:Map<String, IrFunction> = [];
	final natives:Map<String, IrNative> = [];
	final cNatives:Map<String, IrCNative> = [];
	final nativeResults:Map<String, String>;
	final staticTypes:Map<String, IrType> = [];

	/** Operation, then `TypeKey` text, to the names of the functions serving it. */
	final providers:Map<String, Map<String, Array<String>>> = [];

	final reached:Map<String, Bool> = [];
	final created:Map<String, Bool> = [];
	final createdClasses:Map<String, Bool> = [];
	final demanded:Map<String, Bool> = [];
	final missing:Array<String> = [];
	final missingSeen:Map<String, Bool> = [];
	final pending:Array<String> = [];
	final sites:Array<DispatchSite> = [];
	/** The methods with a dispatch site, by receiver class and by receiver interface. */
	final classSites:Map<String, Map<String, Bool>> = [];

	final interfaceSites:Map<String, Map<String, Bool>> = [];
	final dynamicOperations:Map<String, Bool> = [];
	final nativesDone:Map<String, Bool> = [];
	var stringUsed:Bool = false;
	var providersReached:Int = 0;
	final declarationOnly:Map<String, Bool> = [];
	final calledNatives:Map<String, Bool> = [];

	/** The summary a walk without a memo reads each function into, one after the other. */
	final scratch = IrWalkSummary.scratch();

	public function new(program:IrProgram, roots:IrWalkRoots, dynamicSites:Map<String, Array<String>>,
			requireProviders:Bool, keepCreatedClassMethods:Bool,
			classDependencies:Null<IrClassDependencies>, lineage:Null<compiler.ir.IrStageMemo.IrLineage>) {
		this.classDependencies = classDependencies;
		this.lineage = lineage;
		this.program = program;
		this.roots = roots;
		this.dynamicSites = dynamicSites;
		this.requireProviders = requireProviders;
		this.keepCreatedClassMethods = keepCreatedClassMethods;
		index = IrProgramIndex.of(program);
		for (fn in program.functions) {
			byName.set(fn.name, fn);
			switch fn.provides {
				case Serves(type, operation):
					// Indexed by the whole operation and by its base: a typed operation names the former (`inline-enum-helper:box`), a dynamic
					// site asks for the latter (every `equals:...` helper of a type).
					addProvider(operation, type.toString(), fn.name);
					if (IrProviders.base(operation) != operation)
						addProvider(IrProviders.base(operation), type.toString(), fn.name);
				case None:
			}
		}
		for (native in program.natives)
			natives.set(native.name, native);
		for (native in program.cNatives)
			cNatives.set(native.name, native);
		nativeResults = IrConstructed.nativeResults(program);
		for (field in program.staticFields)
			staticTypes.set(field.name, field.type);
	}

	function addProvider(operation:String, type:String, name:String):Void {
		var byType = providers.get(operation);
		if (byType == null) {
			byType = [];
			providers.set(operation, byType);
		}
		var names = byType.get(type);
		if (names == null) {
			names = [];
			byType.set(type, names);
		}
		names.push(name);
	}

	function providersOf(operation:String, type:String):Null<Array<String>> {
		var byType = providers.get(operation);
		return byType == null ? null : byType.get(type);
	}

	public function run():IrWalkResult {
		for (type in roots.types)
			create(type);
		for (name in roots.functions)
			reach(name, true);
		while (true) {
			drain();
			expand();
			if (pending.length == 0)
				break;
		}
		return {
			reached: reached,
			created: created,
			createdClasses: createdClasses,
			demanded: demanded,
			missingProviders: missing,
			providersReached: providersReached,
			declarationOnly: declarationOnly,
			calledNatives: calledNatives
		};
	}

	function reach(name:String, root:Bool):Void {
		if (!reached.exists(name) && byName.exists(name)) {
			pending.push(name);
			if (root) {
				var fn = byName.get(name);
				create(fn.result);
				for (argument in fn.arguments)
					create(argument.type);
			}
		}
	}

	function drain():Void {
		while (pending.length > 0) {
			var name = pending.pop();
			if (reached.exists(name))
				continue;
			var fn = byName.get(name);
			if (fn == null)
				continue;
			reached.set(name, true);
			switch fn.provides {
				case Serves(_, _):
					providersReached++;
				case None:
			}
			// Roots' signatures were made created in `reach`; elsewhere a type is created by what the code does with it.
			follow(fn, IrWalkSummary.of(fn, lineage, scratch));
		}
	}

	/** The edges of `fn`, a reached function, from its summary. */
	function follow(fn:IrFunction, summary:IrWalkSummary):Void {
		for (name in summary.outputObjects) {
			var object = index.object(name);
			if (object != null && IrConstructed.withoutConstruction(name, object))
				create(Obj(name));
		}
		for (name in summary.newObjects)
			create(Obj(name));
		for (name in summary.calls) {
			// A native returns an instance of the class its declaration names (`IrConstructed`).
			var made = nativeResults.get(name);
			if (made != null)
				create(Obj(made));
			callTarget(name);
		}
		for (name in summary.staticClosures)
			callTarget(name);
		for (name in summary.instanceClosures)
			reach(name, false);
		for (type in summary.types)
			create(type);
		for (name in summary.globals) {
			var type = staticTypes.get(name);
			if (type != null)
				create(type);
		}
		for (index in 0...summary.siteTypes.length)
			site(summary.siteTypes[index], summary.siteMethods[index], summary.siteInterfaces[index]);
		for (operation in summary.intrinsics) {
			var typed = IrProviders.typedOperation(operation);
			if (typed == null)
				continue;
			var subject = typed.subject.toString(), key = typed.operation + "\n" + subject;
			demanded.set(key, true);
			create(typeOfKey(operation));
			var names = providersOf(typed.operation, subject);
			if (names == null) {
				if (requireProviders && !missingSeen.exists(key)) {
					missingSeen.set(key, true);
					missing.push('${fn.name}: ${typed.operation} of ${typed.subject.toString()} has no provider');
				}
			} else
				for (name in names)
					reach(name, false);
		}
	}

	static function typeOfKey(operation:IrIntrinsic):IrType
		return switch operation {
			case EnumDynamicBox(type), EnumDynamicView(type), EnumTagBox(type), EnumTagUnbox(type), InlineEnumBox(type),
				InlineEnumUnbox(type):
				type;
		};

	function callTarget(target:String):Void {
		if (byName.exists(target))
			reach(target, false);
		else {
			// A call to an optional-field method request names the value method the storage pass will specialize.
			var requested = IrOptionalFieldStorage.requestedMethod(target);
			if (requested != null)
				reach(requested, false);
			// A native constructs exactly the class its declaration returns (`IrConstructed`); an argument was constructed by the caller, which the
			// walk already sees. A C native's call becomes `CNativeCall` only at the end of assembly, so it is a call by name here, like any native.
			if (natives.exists(target) || cNatives.exists(target))
				calledNatives.set(target, true);
			var cNative = cNatives.get(target);
			if (cNative != null && !nativesDone.exists(target)) {
				nativesDone.set(target, true);
				create(cNative.result);
			}
			var native = natives.get(target);
			if (native != null && !nativesDone.exists(target)) {
				nativesDone.set(target, true);
				create(native.result);
				if (native.generatedFunctionDependencies != null)
					for (dependency in native.generatedFunctionDependencies)
						reach(dependency, false);
				if (native.symbol == "__std_string")
					stringUsed = true;
			}
			var operations = dynamicSites.get(target);
			if (operations != null)
				for (operation in operations)
					dynamicOperations.set(operation, true);
		}
	}

	function site(typeName:String, method:String, isInterface:Bool):Void {
		var seen = isInterface ? interfaceSites : classSites, methods = seen.get(typeName);
		if (methods == null) {
			methods = [];
			seen.set(typeName, methods);
		}
		if (!methods.exists(method)) {
			methods.set(method, true);
			sites.push({typeName: typeName, method: method, isInterface: isInterface});
		}
	}

	/** Makes a type created, with the classes it extends and the types its fields hold. */
	function create(type:IrType):Void
		switch type {
			case Obj(name):
				var current:Null<String> = name;
				while (current != null && !createdClasses.exists(current)) {
					createdClasses.set(current, true);
					created.set(TypeKey.of(Obj(current)).toString(), true);
					var object = index.object(current);
					if (object == null)
						break;
					for (field in object.fields)
						create(field.type);
					if (keepCreatedClassMethods)
						for (method in object.methods)
							reach(method.functionName.name, false);
					current = object.base;
				}
			case Enum(name), EnumTag(name):
				var key = TypeKey.of(type).toString();
				if (!created.exists(key)) {
					created.set(key, true);
					// The tag form and the full form of one enum are the same enum to its providers.
					created.set(TypeKey.of(Enum(name)).toString(), true);
					created.set(TypeKey.of(EnumTag(name)).toString(), true);
				}
			case Array(element), Nullable(element), Iterator(element):
				create(element);
			case Function(arguments, result):
				for (argument in arguments)
					create(argument);
				create(result);
			default:
		}

	/** Re-derives the edges that depend on which types are created. */
	function expand():Void {
		for (site in sites) {
			// The verifier resolves a method call against the receiver class's table, so the class keeps the entry even when no instance can
			// exist (a base class nothing constructs); only the declaration is needed, the body is not (see `declarationOnly`).
			if (!site.isInterface) {
				var declared = index.findMethod(site.typeName, site.method);
				if (declared != null && !reached.exists(declared))
					declarationOnly.set(declared, true);
			}
			var candidates = site.isInterface ? index.implementorsOf(site.typeName) : index.subtypesOf(site.typeName);
			for (candidate in candidates)
				if (createdClasses.exists(candidate.name)) {
					var method = index.findMethod(candidate.name, site.method);
					if (method != null)
						reach(method, false);
				}
		}
		for (operation in dynamicOperations.keys()) {
			var byType = providers.get(operation);
			if (byType != null)
				for (type in created.keys()) {
					var names = byType.get(type);
					if (names != null)
						for (name in names)
							reach(name, false);
				}
		}
		// Code is generated in place of a native that reached code calls, for every class; what it calls is reached here, once per symbol.
		if (classDependencies != null)
			for (name in [for (name in calledNatives.keys()) name]) {
				var native = natives.get(name);
				if (native == null || dependencySymbolsDone.exists(native.symbol)
					|| classDependencies.symbols.indexOf(native.symbol) < 0)
					continue;
				dependencySymbolsDone.set(native.symbol, true);
				for (object in program.objects)
					for (dependency in classDependencies.of(object.name, native.symbol))
						reach(dependency, false);
			}
		if (stringUsed)
			for (name in createdClasses.keys()) {
				var method = index.findMethod(name, "__string");
				if (method != null)
					reach(method, false);
			}
	}
}

/**
 * What one function gives the type-aware walk, read once from its instructions: the names and types its edges and creations
 * depend on, each kind in the order the instructions first name it. The walk resolves them against the program (`follow`), so
 * the summary depends on the function alone, and a session keeps it by the function's version (`IrStageMemos.walkSummaries`).
 */
class IrWalkSummary {
	/** The classes an instruction's output has (made created when they need no construction). */
	public final outputObjects:Array<String> = [];

	public final newObjects:Array<String> = [];

	/** The targets of `Call`s. */
	public final calls:Array<String> = [];

	public final staticClosures:Array<String> = [];
	public final instanceClosures:Array<String> = [];

	/** The types made, converted to or from `Dyn`: `MakeEnum`, `ToDyn`, `SafeCast`. */
	public final types:Array<IrType> = [];

	/** The static fields read or written. */
	public final globals:Array<String> = [];

	/** The method calls: receiver class or interface, method, whether the receiver is an interface. */
	public final siteTypes:Array<String> = [];

	public final siteMethods:Array<String> = [];
	public final siteInterfaces:Array<Bool> = [];

	/** The typed operations. */
	public final intrinsics:Array<IrIntrinsic> = [];

	function new() {}

	/** A summary to read functions into one after the other (`of`), for a walk that keeps none. */
	public static function scratch():IrWalkSummary
		return new IrWalkSummary();

	/**
	 * The summary of `fn`: kept by the session for its version with `lineage`; else read now into `scratch`, which the next call
	 * reuses, so a walk without a memo allocates no summary per function.
	 */
	public static function of(fn:IrFunction, lineage:Null<compiler.ir.IrStageMemo.IrLineage>,
			scratch:IrWalkSummary):IrWalkSummary {
		var version = lineage == null ? 0 : lineage.versionOf(fn);
		if (lineage == null || version == 0) {
			scratch.clear();
			scratch.fill(fn);
			return scratch;
		}
		var memo = lineage.memos.walkSummaries, known = memo.get(version);
		if (known == null) {
			known = read(fn);
			memo.keep(version, known);
		} else if (lineage.checks && !same(known, read(fn)))
			throw new compiler.core
				.InternalError('--check-reuse: the walk summary reused for ${fn.name} differs from its instructions');
		return known;
	}

	/** Reads the summary of `fn`. */
	public static function read(fn:IrFunction):IrWalkSummary {
		var summary = new IrWalkSummary();
		summary.fill(fn);
		return summary;
	}

	function clear():Void {
		outputObjects.resize(0);
		newObjects.resize(0);
		calls.resize(0);
		staticClosures.resize(0);
		instanceClosures.resize(0);
		types.resize(0);
		globals.resize(0);
		siteTypes.resize(0);
		siteMethods.resize(0);
		siteInterfaces.resize(0);
		intrinsics.resize(0);
	}

	/** Adds what `fn`'s instructions give the walk. */
	function fill(fn:IrFunction):Void {
		var summary = this;
		for (block in fn.blocks)
			for (located in block.instructions) {
				var instruction = located.value, output = IrOperands.output(instruction);
				if (output != null)
					switch output.type {
						case Obj(name):
							once(summary.outputObjects, name);
						default:
					}
				switch instruction {
					case NewObject(_, typeName):
						once(summary.newObjects, typeName);
					case Call(_, target, _):
						once(summary.calls, target.name);
					case StaticClosure(_, target):
						once(summary.staticClosures, target.name);
					case InstanceClosure(_, target, _):
						once(summary.instanceClosures, target.name);
					case MakeEnum(_, typeName, _, _):
						summary.types.push(Enum(typeName));
					case ToDyn(_, value):
						summary.types.push(value.type);
					case SafeCast(output, _):
						summary.types.push(output.type);
					case GlobalGet(_, name), GlobalSet(name, _):
						once(summary.globals, name);
					case MethodCall(_, object, method, _, _):
						switch object.type {
							case Obj(name):
								summary.site(name, method, false);
							case Virtual(name):
								summary.site(name, method, true);
							default:
						}
					case Intrinsic(_, operation, _):
						if (IrProviders.typedOperation(operation) != null)
							summary.intrinsics.push(operation);
					default:
				}
			}
	}

	/** `name` added to `list` unless a short list has it already: a repeat costs the walk nothing but a no-op. */
	static inline function once(list:Array<String>, name:String):Void
		if (list.length >= 32 || list.indexOf(name) < 0)
			list.push(name);

	function site(typeName:String, method:String, isInterface:Bool):Void {
		var count = siteTypes.length;
		if (count < 32)
			for (index in 0...count)
				if (siteTypes[index] == typeName && siteMethods[index] == method
					&& siteInterfaces[index] == isInterface)
					return;
		siteTypes.push(typeName);
		siteMethods.push(method);
		siteInterfaces.push(isInterface);
	}

	/** Whether two summaries name the same edges, for `--check-reuse`. */
	public static function same(left:IrWalkSummary, right:IrWalkSummary):Bool {
		inline function names(a:Array<String>, b:Array<String>):Bool
			return a.join("\u0001") == b.join("\u0001");
		if (!names(left.outputObjects, right.outputObjects) || !names(left.newObjects, right.newObjects)
			|| !names(left.calls, right.calls) || !names(left.staticClosures, right.staticClosures)
			|| !names(left.instanceClosures, right.instanceClosures) || !names(left.globals, right.globals)
			|| !names(left.siteTypes, right.siteTypes) || !names(left.siteMethods, right.siteMethods)
			|| left.siteInterfaces.length != right.siteInterfaces.length || left.types.length != right.types.length
			|| left.intrinsics.length != right.intrinsics.length)
			return false;
		for (index in 0...left.siteInterfaces.length)
			if (left.siteInterfaces[index] != right.siteInterfaces[index])
				return false;
		for (index in 0...left.types.length)
			if (!IrVerifier.sameType(left.types[index], right.types[index]))
				return false;
		for (index in 0...left.intrinsics.length)
			if (Std.string(left.intrinsics[index]) != Std.string(right.intrinsics[index]))
				return false;
		return true;
	}
}
