package compiler.ir;

import compiler.core.InternalError;
import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;
import compiler.types.typing.EnumRuntimeType;

/**
 * Dispatch Dynamic enum operations by the concrete runtime enum descriptor. Per function (`IrFunctionPass`): a function's summary
 * says which Dynamic enum operations it has (`BOXES`, `CALLS_EQUAL`, `CALLS_REFLECT`, `CLOSES`), and its rewrite reads whether
 * it is reached (`UNREACHED`), whether any enum registers (`REGISTERED`) and whether a helper it calls kept its content name
 * (`RENAMED`), and asks for the unboxes and type tests it calls. The helpers are named by the enum type.
 */
class IrEnumDynamicDispatch implements IrFunctionPass {
	/** Read-only: no type values in a function. */
	@:processWide("a shared empty map, only ever read")
	static final noTypeValues:Map<Int, IrType> = [];

	public static inline final EQUAL = "$enum-dynamic-equal";
	public static inline final REFLECT = "$enum-dynamic-reflect";

	static inline final BOX_PREFIX = "$enum-dynamic-box:";
	static inline final VIEW_PREFIX = "$enum-dynamic-view:";
	static inline final UNBOX_PREFIX = "$enum-dynamic-unbox:";

	// Summary bits.
	static inline final BOXES = 1;
	static inline final CALLS_EQUAL = 2;
	static inline final CALLS_REFLECT = 4;

	/** A closure or a map store, which the escape reach of the reflection decision reads (`IrEnumEscapeReach`). */
	static inline final CLOSES = 8;

	// Facts.
	static inline final UNREACHED = 0;
	static inline final REGISTERED = 1;

	/** Of a helper's content name: 0 while the helper has it, `IrFacts.UNKNOWN` when another function took it. */
	static inline final RENAMED = 2;

	// Helper kinds.
	static inline final UNBOX = 0;
	static inline final TEST_INSTANCE = 1;
	static inline final TEST_EXACT = 2;

	final reflectionProgram:Null<IrProgram>;
	final reflectableObjects:Null<Array<String>>;
	final unreached:Null<Map<String, Bool>>;
	final lineage:Null<compiler.ir.IrStageMemo.IrLineage>;
	final requests:Map<String, IrType> = [];
	final equalities:Map<String, String> = [];
	final reflectiveEqualities:Map<String, String> = [];
	var occupied:Map<String, Bool> = [];
	var names:Array<String> = [];
	final boxNames:Map<String, String> = [];
	final viewNames:Map<String, String> = [];
	final unboxNames:Map<String, String> = [];
	final unboxes:Map<String, IrType> = [];
	final typeTests:Map<String, {type:IrType, exact:Bool}> = [];
	var needsEqual = false;
	var needsReflect = false;

	/** The reflective equality helpers no root reaches, which the stage drops. */
	var dropped:Map<String, Bool> = [];

	/** The box and view helpers, in the order of `names`. */
	final made:Array<IrFunction> = [];

	/** The box helper of `type`: what an `EnumDynamicBox` of it calls, unless a function of the program has the name. */
	public static function boxName(type:IrType):String
		return helperName(BOX_PREFIX, type);

	static function helperName(prefix:String, type:IrType):String
		return prefix + haxe.crypto.Base64.encode(compiler.ir.codec.IrTypeCodec.encode(type));

	static function key(type:IrType):String
		return IrTypeIdentity.text(type);

	/** With `unreached` (the functions a plain build's walk did not reach), only the others register what they need and are rewritten; otherwise every function does. */
	public function new(?reflectionProgram:IrProgram, ?reflectableObjects:Array<String>, ?unreached:Map<String, Bool>,
			?lineage:compiler.ir.IrStageMemo.IrLineage) {
		this.reflectionProgram = reflectionProgram;
		this.reflectableObjects = reflectableObjects;
		this.unreached = unreached;
		this.lineage = lineage;
	}

	public static function rewrite(functions:Array<IrFunction>, ?reflectionProgram:IrProgram,
			?reflectableObjects:Array<String>, ?unreached:Map<String, Bool>):Array<IrFunction>
		return IrFunctionStages.apply("enum-dynamic-dispatch", new IrEnumDynamicDispatch(reflectionProgram,
			reflectableObjects, unreached), functions);

	inline function reached(fn:IrFunction):Bool {
		var skipped = unreached;
		return skipped == null || !skipped.exists(fn.name);
	}

	public function summarize(fn:IrFunction):Int {
		var flags = 0;
		for (block in fn.blocks)
			for (located in block.instructions)
				switch located.value {
					case Intrinsic(_, EnumDynamicBox(_) | EnumDynamicView(_), _):
						flags |= BOXES;
					case Call(_, callTarget, arguments):
						if (callTarget.name == "__dynamic_equal")
							flags |= CALLS_EQUAL;
						else if (callTarget.name == REFLECT)
							flags |= CALLS_REFLECT;
						else if (arguments.length >= 3 && IrEnumEscapeReach.mapSetter(callTarget.name))
							flags |= CLOSES;
					case InstanceClosure(_, _, _):
						flags |= CLOSES;
					default:
				}
		return flags;
	}

	function register(type:IrType):String {
		var id = key(type);
		requests.set(id, type);
		return id;
	}

	public function prepare(functions:Array<IrFunction>, summaries:Array<Int>, index:IrFunctionIndex):Void {
		var boxes:Map<String, Bool> = [], views:Map<String, Bool> = [], closing:Map<String, Bool> = [];
		occupied = [for (fn in functions) fn.name => true];
		for (position in 0...functions.length) {
			var fn = functions[position], flags = summaries[position];
			switch fn.kind {
				case EnumEquality(reflective) if (fn.arguments.length == 2 && isEnum(fn.arguments[0].type)):
					(reflective ? reflectiveEqualities : equalities).set(key(fn.arguments[0].type), fn.name);
				default:
			}
			if (flags & CLOSES != 0)
				closing.set(fn.name, true);
			if (!reached(fn))
				continue;
			if (flags & CALLS_EQUAL != 0)
				needsEqual = true;
			if (flags & CALLS_REFLECT != 0)
				needsReflect = true;
			if (flags & BOXES != 0)
				for (block in fn.blocks)
					for (located in block.instructions)
						switch located.value {
							case Intrinsic(output, EnumDynamicBox(type), arguments):
								if (!isEnum(type) || arguments.length != 1
									|| !IrVerifier.sameType(arguments[0].type, type)
									|| !IrVerifier.sameType(output.type, Dyn))
									throw new InternalError("Invalid enum Dynamic box signature");
								boxes.set(register(type), true);
							case Intrinsic(output, EnumDynamicView(type), arguments):
								if (!isEnum(type) || arguments.length != 1
									|| !IrVerifier.sameType(arguments[0].type, Array(Dyn))
									|| !IrVerifier.sameType(output.type, Array(Dyn)))
									throw new InternalError("Invalid enum Dynamic view signature");
								views.set(register(type), true);
							default:
						}
		}
		// Only observable enum descriptors need reflective dispatch. Preserve the upstream
		// reachability decision while identifying equality helpers by their declared role.
		var program = reflectionProgram;
		if (program != null) {
			var roots:Array<IrType> = [];
			if (ObjectReflection.usesObjectLayouts(program.natives)) {
				var reflectable = reflectableObjects;
				if (reflectable != null) for (name in reflectable) roots.push(Obj(name));
				for (object in program.objects)
					if (compiler.semantic.SemanticSignature.isAnonymousName(object.name)) roots.push(Obj(object.name));
			}
			for (native in program.natives) if (!IrArrayRuntimeNatives.isStorage(native.name)) {
				for (argument in native.arguments) IrEnumEscapeReach.addNativeRoot(roots, argument);
				IrEnumEscapeReach.addNativeRoot(roots, native.result);
			}
			for (native in program.cNatives) {
				for (argument in native.arguments) IrEnumEscapeReach.addNativeRoot(roots, argument);
				IrEnumEscapeReach.addNativeRoot(roots, native.result);
			}
			var observed = new IrEnumEscapeReach(program, fn -> closing.exists(fn.name)).collect(roots, _ -> false);
			for (fn in functions) switch fn.kind {
				case EnumEquality(_) if (fn.arguments.length == 2):
					switch fn.arguments[0].type {
						case Enum(name) if (observed.exists(name)): register(fn.arguments[0].type);
						default:
					}
				default:
			}
		}
		var reflectiveRoots:Array<String> = [];
		if (needsReflect) for (id in requests.keys()) {
			var helper = reflectiveEqualities.get(id);
			if (helper != null) reflectiveRoots.push(helper);
		}
		dropped = droppedReflectiveHelpers(functions, reflectiveRoots, lineage);
		for (fn in functions) if (reached(fn) && !dropped.exists(fn.name)) switch fn.kind {
			case EnumEquality(true) if (fn.arguments.length == 2
				&& isEnum(fn.arguments[0].type)): register(fn.arguments[0].type);
			default:
		}
		names = [for (name in requests.keys()) name];
		names.sort(Reflect.compare);
		// Named by the enum type, not by its place among the requests: an enum that starts or stops being requested renames no
		// other helper, so the callers of the others keep their code.
		for (id in names) {
			var type = requests.get(id);
			boxNames.set(id, symbol(occupied, helperName(BOX_PREFIX, type)));
			viewNames.set(id, symbol(occupied, helperName(VIEW_PREFIX, type)));
			unboxNames.set(id, symbol(occupied, helperName(UNBOX_PREFIX, type)));
		}
		for (id in names) {
			if (boxes.exists(id)) {
				var name = boxNames.get(id), known = remembered(name);
				if (known == null) {
					var builder = new IrBuilder(), value = builder.argument("value", requests.get(id));
					builder.returnValue(builder.toDyn(value));
					known = new IrFunction(name, builder.arguments, Dyn, builder.blocks, GeneratedHelper);
				}
				made.push(known);
			}
			if (views.exists(id)) {
				var name = viewNames.get(id), known = remembered(name);
				if (known == null) {
					var builder = new IrBuilder(), array = builder.argument("array", Array(Dyn));
					builder.returnValue(array);
					known = new IrFunction(name, builder.arguments, Array(Dyn), builder.blocks, GeneratedHelper);
				}
				made.push(known);
			}
		}
	}

	/**
	 * Last build's helper of `name`, when this session has one: a box, view or unbox helper is named by its kind and enum type, which
	 * is all it is made of (`IrStageMemos.helpers`).
	 */
	function remembered(name:String):Null<IrFunction> {
		var session = lineage;
		return session == null ? null : session.memos.helper(name);
	}

	public function fact(kind:Int, key:String):Int
		return switch kind {
			case UNREACHED:
				var skipped = unreached;
				(skipped != null && skipped.exists(key)) || dropped.exists(key) ? 1 : 0;
			case REGISTERED:
				names.length > 0 ? 1 : 0;
			default:
				occupiedBy(key) ? IrFacts.UNKNOWN : 0;
		};

	/** Whether a function of the program, not the helper itself, has the helper's content name `name`. */
	function occupiedBy(name:String):Bool {
		for (names in [boxNames, viewNames, unboxNames])
			for (given in names)
				if (given == name)
					return false;
		return occupied.exists(name);
	}

	/** The unbox helper of `type`: the registered one, else its content name. */
	function unboxNameOf(type:IrType):String {
		var name = unboxNames.get(key(type));
		return name != null ? name : helperName(UNBOX_PREFIX, type);
	}

	public function transform(fn:IrFunction, summary:Int, reader:IrFactReader):IrFunction {
		if (reader.read(UNREACHED, fn.name) == 1)
			return fn;
		var typeValues:Null<Map<Int, IrType>> = null;
		for (block in fn.blocks) for (located in block.instructions) switch located.value {
			case TypeValue(output, type):
				if (typeValues == null) typeValues = [];
				typeValues.set(output.id, type);
			default:
		}
		var types:Map<Int, IrType> = typeValues == null ? noTypeValues : typeValues;
		function named(name:Null<String>):String {
			if (name == null)
				throw new InternalError("An enum Dynamic operation of a reached function has no registered helper");
			reader.read(RENAMED, name);
			return name;
		}
		inline function registered():Bool
			return reader.read(REGISTERED, "") == 1;
		// Only the blocks with an instruction to replace are copied; a function without one comes back as it is.
		return IrFunctionRewrite.instructions(fn, function(located) {
			return switch located.value {
				case Intrinsic(output, EnumDynamicBox(type), arguments):
					[new Located(Call(output, IrSymbol.of(named(boxNames.get(key(type)))), arguments),
						located.provenance)];
				case Intrinsic(output, EnumDynamicView(type), arguments):
					[new Located(Call(output, IrSymbol.of(named(viewNames.get(key(type)))), arguments),
						located.provenance)];
				case Call(output, callTarget, arguments) if (callTarget.name == "__dynamic_equal" && registered()):
					[new Located(Call(output, IrSymbol.of(EQUAL), arguments), located.provenance)];
				case SafeCast(output, input) if (IrVerifier.sameType(input.type, Dyn) && isEnum(output.type)):
					var helper = named(unboxNameOf(output.type));
					reader.request(UNBOX, output.type);
					[new Located(Call(output, IrSymbol.of(helper), [input]), located.provenance)];
				case Call(output, name,
					arguments) if ((name.name == "__std_is_of_type" || name.name == "__std_is_exact_type")
					&& arguments.length == 2 && types.exists(arguments[1].id)
					&& isEnum(types.get(arguments[1].id)) && registered()):
					var type = types.get(arguments[1].id),
						exact = name.name == "__std_is_exact_type";
					reader.request(exact ? TEST_EXACT : TEST_INSTANCE, type);
					[new Located(Call(output, IrSymbol.of(typeTestName(type, exact)), [arguments[0]]),
						located.provenance)];
				default: null;
			};
		});
	}

	public function request(kind:Int, type:IrType):Void {
		if (kind == UNBOX) {
			var id = key(type), helper = unboxNames.get(id);
			if (helper == null) {
				helper = helperName(UNBOX_PREFIX, type);
				if (occupied.exists(helper))
					throw new InternalError('A function of the program has the name of the enum unbox helper "$helper"');
				occupied.set(helper, true);
				unboxNames.set(id, helper);
			}
			unboxes.set(helper, type);
		} else {
			var exact = kind == TEST_EXACT;
			typeTests.set(typeTestName(type, exact), {type: type, exact: exact});
		}
	}

	public function finish(functions:Array<IrFunction>):Array<IrFunction> {
		var rewritten = [for (fn in functions) if (!dropped.exists(fn.name)) fn];
		for (helper in made)
			rewritten.push(helper);
		var usedUnboxNames = [for (name in unboxes.keys()) name];
		usedUnboxNames.sort(Reflect.compare);
		var session = lineage, kept = made.copy();
		for (name in usedUnboxNames) {
			var known = remembered(name);
			if (known == null)
				known = unbox(name, unboxes.get(name));
			rewritten.push(known);
			kept.push(known);
		}
		var testNames = [for (name in typeTests.keys()) name];
		testNames.sort(Reflect.compare);
		for (name in testNames) {
			var test = typeTests.get(name);
			rewritten.push(typeTest(name, test.type, test.exact, names, requests));
		}
		if (needsEqual && names.length > 0) rewritten.push(dispatcher(EQUAL, names, requests, equalities));
		if (needsReflect) rewritten.push(dispatcher(REFLECT, names, requests, reflectiveEqualities));
		if (session != null)
			for (helper in kept)
				session.memos.keepHelper(helper);
		return rewritten;
	}

	/**
	 * The typed reflective equality helpers neither the roots nor a function outside them reaches, which the stage drops; the
	 * calls and closures each function makes are its walk summary (`IrWalkSummary`).
	 */
	static function droppedReflectiveHelpers(functions:Array<IrFunction>, roots:Array<String>,
			lineage:Null<compiler.ir.IrStageMemo.IrLineage>):Map<String, Bool> {
		var helpers:Map<String, IrFunction> = [],
			live:Map<String, Bool> = [],
			pending:Array<String> = [],
			scratch = IrTypeAwareWalk.IrWalkSummary.scratch();
		for (fn in functions) switch fn.kind {
			case EnumEquality(true): helpers.set(fn.name, fn);
			default:
		}
		var dropped:Map<String, Bool> = [];
		if (!helpers.keys().hasNext())
			return dropped;
		function mark(name:String):Void {
			if (helpers.exists(name) && !live.exists(name)) {
				live.set(name, true);
				pending.push(name);
			}
		}
		for (name in roots) mark(name);
		function scan(fn:IrFunction):Void {
			var summary = IrTypeAwareWalk.IrWalkSummary.of(fn, lineage, scratch);
			for (name in summary.calls) mark(name);
			for (name in summary.staticClosures) mark(name);
			for (name in summary.instanceClosures) mark(name);
		}
		for (fn in functions)
			if (!helpers.exists(fn.name)) scan(fn);
		else if (fn.retention != compiler.ir.IrFunction.IrRetention.Reachable) mark(fn.name);
		var index = 0;
		while (index < pending.length) scan(helpers.get(pending[index++]));
		for (name in helpers.keys())
			if (!live.exists(name))
				dropped.set(name, true);
		return dropped;
	}

	static function isEnum(type:IrType):Bool return switch type {
		case Enum(_): true;
		default: false;
	};
	static function symbol(occupied:Map<String, Bool>, base:String):String {
		var name = base, suffix = 0;
		while (occupied.exists(name)) name = base + "_" + suffix++;
		occupied.set(name, true);
		return name;
	}
	static function typeTestName(type:IrType, exact:Bool):String
		return "$enum-dynamic-test:" + (exact ? "exact:" : "instance:")
			+ haxe.crypto.Base64.encode(compiler.ir.codec.IrTypeCodec.encode(type));

	static function unbox(name:String, type:IrType):IrFunction {
		var builder = new IrBuilder(),
			input = builder.argument("value", Dyn),
			absent = builder.createBlock(),
			test = builder.createBlock(),
			matched = builder.createBlock(),
			invalid = builder.createBlock();
		builder.branch(builder.equal(input, builder.constNull(Dyn)), absent, test);
		builder.select(absent);
		builder.returnValue(builder.constNull(type));
		builder.select(test);
		builder.branch(builder.call("__std_is_exact_type", [input, builder.typeValue(type)], Bool), matched, invalid);
		builder.select(matched);
		builder.returnValue(builder.safeCast(input, type));
		builder.select(invalid);
		builder.throwValue(builder.toDyn(builder.constString("Invalid enum cast")));
		return new IrFunction(name, builder.arguments, type, builder.blocks, EnumDynamicUnbox(type));
	}

	static function typeTest(name:String, type:IrType, exact:Bool, names:Array<String>,
			requests:Map<String, IrType>):IrFunction {
		var builder = new IrBuilder(), input = builder.argument("value", Dyn), targetName = switch type {
			case Enum(value): value;
			default: "";
		},
			declaration = EnumRuntimeType.declaration(targetName), family = declaration == targetName;
		for (boxName in names) {
			var candidate = requests.get(boxName), candidateName = switch candidate {
				case Enum(value): value;
				default: "";
			};
			if (!IrVerifier.sameType(candidate, type)
				&& !(family && EnumRuntimeType.declaration(candidateName) == declaration)) continue;
			var matched = builder.createBlock(), next = builder.createBlock();
			builder.branch(builder.call(exact ? "__std_is_exact_type" : "__std_is_of_type", [
				input,
				builder.typeValue(candidate)
			], Bool), matched, next);
			builder.select(matched);
			builder.returnValue(builder.constBool(true));
			builder.select(next);
		}
		builder.returnValue(builder.call(exact ? "__std_is_exact_type" : "__std_is_of_type", [
			input,
			builder.typeValue(type)
		], Bool));
		return new IrFunction(name, builder.arguments, Bool, builder.blocks, GeneratedHelper);
	}

	/** Enums have equality but no declared ordering. Never order their boxed addresses. */
	static function dispatcher(name:String, names:Array<String>, requests:Map<String, IrType>,
			equalities:Map<String, String>):IrFunction {
		var builder = new IrBuilder(), left = builder.argument("left", Dyn), right = builder.argument("right", Dyn);
		for (boxName in names) {
			var type = requests.get(boxName),
				matched = builder.createBlock(),
				next = builder.createBlock(),
				same = builder.createBlock(),
				different = builder.createBlock(),
				equality = equalities.get(boxName);
			builder.branch(builder.call("__std_is_exact_type", [left, builder.typeValue(type)], Bool), matched, next);
			builder.select(matched);
			builder.branch(builder.call("__std_is_exact_type", [right, builder.typeValue(type)], Bool), same,
				different);
			builder.select(different);
			builder.returnValue(builder.constBool(false));
			builder.select(same);
			if (equality != null) builder.returnValue(builder.call(equality, [
				builder.safeCast(left, type),
				builder.safeCast(right, type)
			], Bool));
			else builder.throwValue(builder.toDyn(builder.constString("Enum value does not conform to Equatable")));
			builder.select(next);
		}
		builder.returnValue(builder.call("__dynamic_equal", [left, right], Bool));
		return new IrFunction(name, builder.arguments, Bool, builder.blocks, GeneratedHelper);
	}
}
