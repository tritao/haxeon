package compiler.ir;

import compiler.Provides.ProviderOperation;
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
}

/**
 * A reachability walk that knows what a class or enum can be created, and follows typed operations to provider rows (ADR 0003 section 13,
 * `docs/REACHABILITY_WALK.md`). It is a pure function of a program and its roots: it reads the IR and returns sets, and nothing in the
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
	public static function run(program:IrProgram, roots:IrWalkRoots, ?dynamicSites:Map<String, Array<String>>, requireProviders = false,
			keepCreatedClassMethods = false):IrWalkResult {
		var walk = new IrTypeAwareWalkState(program, roots, dynamicSites == null ? defaultDynamicSites() : dynamicSites, requireProviders,
			keepCreatedClassMethods);
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
	public static function compare(program:IrProgram, roots:IrWalkRoots, ?dynamicSites:Map<String, Array<String>>):Array<String> {
		var today = IrReachability.withGeneratedRuntimeRoots(program, roots.functions[0], roots.functions.slice(1), true);
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
				if (reached.exists(method.functionName))
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
	final index:IrProgramIndex;
	final byName:Map<String, IrFunction> = [];
	final natives:Map<String, IrNative> = [];
	final staticTypes:Map<String, IrType> = [];
	/** `operation\nTypeKey` (operation without detail) to the names of the functions serving it. */
	final providers:Map<String, Array<String>> = [];
	final reached:Map<String, Bool> = [];
	final created:Map<String, Bool> = [];
	final createdClasses:Map<String, Bool> = [];
	final demanded:Map<String, Bool> = [];
	final missing:Array<String> = [];
	final missingSeen:Map<String, Bool> = [];
	final pending:Array<String> = [];
	final sites:Array<DispatchSite> = [];
	final siteSeen:Map<String, Bool> = [];
	final dynamicOperations:Map<String, Bool> = [];
	final nativesDone:Map<String, Bool> = [];
	var stringUsed:Bool = false;
	var providersReached:Int = 0;

	public function new(program:IrProgram, roots:IrWalkRoots, dynamicSites:Map<String, Array<String>>, requireProviders:Bool,
			keepCreatedClassMethods:Bool) {
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
					var key = IrProviders.base(operation) + "\n" + type.toString();
					var names = providers.get(key);
					if (names == null) {
						names = [];
						providers.set(key, names);
					}
					names.push(fn.name);
				case None:
			}
		}
		for (native in program.natives)
			natives.set(native.name, native);
		for (field in program.staticFields)
			staticTypes.set(field.name, field.type);
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
			providersReached: providersReached
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
			for (block in fn.blocks)
				for (located in block.instructions) {
					var output = IrOperands.output(located.value);
					if (output != null)
						switch output.type {
							case Obj(objectName):
								var object = index.object(objectName);
								if (object != null && object.isValue)
									create(output.type);
							default:
						}
					visit(fn, located.value);
				}
		}
	}

	function visit(fn:IrFunction, instruction:IrInstruction):Void
		switch instruction {
			case Call(_, target, _):
				callTarget(target);
			case StaticClosure(_, target):
				callTarget(target);
			case InstanceClosure(_, target, _):
				reach(target, false);
			case NewObject(_, typeName):
				create(Obj(typeName));
			case MakeEnum(_, typeName, _, _):
				create(Enum(typeName));
			case ToDyn(_, value):
				create(value.type);
			case SafeCast(output, _):
				create(output.type);
			case GlobalGet(_, name), GlobalSet(name, _):
				var type = staticTypes.get(name);
				if (type != null)
					create(type);
			case MethodCall(_, object, method, _, _):
				switch object.type {
					case Obj(name):
						site(name, method, false);
					case Virtual(name):
						site(name, method, true);
					default:
				}
			case Intrinsic(_, operation, _):
				var typed = IrProviders.typedOperation(operation);
				if (typed != null) {
					var key = IrProviders.base(typed.operation) + "\n" + typed.subject.toString();
					demanded.set(key, true);
					create(typeOfKey(operation));
					var names = providers.get(key);
					if (names == null) {
						if (requireProviders && !missingSeen.exists(key)) {
							missingSeen.set(key, true);
							missing.push('${fn.name}: ${typed.operation} of ${typed.subject.toString()} has no provider');
						}
					} else
						for (name in names)
							reach(name, false);
				}
			default:
		}

	static function typeOfKey(operation:IrIntrinsic):IrType
		return switch operation {
			case EnumDynamicBox(type), EnumDynamicView(type), EnumTagBox(type), EnumTagUnbox(type):
				type;
		};

	function callTarget(target:String):Void {
		if (byName.exists(target))
			reach(target, false);
		else {
			var native = natives.get(target);
			if (native != null && !nativesDone.exists(target)) {
				nativesDone.set(target, true);
				for (argument in native.arguments)
					create(argument);
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
		var key = typeName + (isInterface ? "\u0002" : "\u0001") + method;
		if (!siteSeen.exists(key)) {
			siteSeen.set(key, true);
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
							reach(method.functionName, false);
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
			var candidates = site.isInterface ? index.implementorsOf(site.typeName) : index.subtypesOf(site.typeName);
			for (candidate in candidates)
				if (createdClasses.exists(candidate.name)) {
					var method = index.findMethod(candidate.name, site.method);
					if (method != null)
						reach(method, false);
				}
		}
		for (operation in dynamicOperations.keys())
			for (type in created.keys()) {
				var names = providers.get(operation + "\n" + type);
				if (names != null)
					for (name in names)
						reach(name, false);
			}
		if (stringUsed)
			for (name in createdClasses.keys()) {
				var method = index.findMethod(name, "__string");
				if (method != null)
					reach(method, false);
			}
	}
}
