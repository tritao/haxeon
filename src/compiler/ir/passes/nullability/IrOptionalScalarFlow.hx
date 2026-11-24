package compiler.ir.passes.nullability;

import compiler.ir.model.IrBodyBuilder;
import compiler.ir.model.IrBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.gen.IrGenerator;
import compiler.ir.passes.values.IrInlineValueLayout;
import compiler.ir.passes.inlining.IrInliner;
import compiler.ir.analysis.IrMethodResolution;
import compiler.ir.model.IrObjectTable;
import compiler.ir.model.IrOperands;
import compiler.ir.model.IrProviders;
import compiler.ir.model.IrSymbol;
import compiler.ir.model.SourceProvenance;
import compiler.ir.model.TypeKey;
import compiler.core.InternalError;
import compiler.core.Provides.ProviderOperation;
import compiler.ir.model.Ir;
import compiler.ir.passes.values.IrInlineValueLayout.IrInlineValueSlot;
import compiler.ir.model.SourceProvenance.Located;
import compiler.ir.passes.nullability.IrOptionalValueFlow.IrOptionalHelpers;
import compiler.ir.pipeline.IrFunctionIndex;
import compiler.ir.pipeline.IrFunctionPass;
import compiler.ir.pipeline.IrFunctionStages;
import compiler.ir.reuse.IrFactReader;
import compiler.ir.reuse.IrStageMemo.IrLineage;

private typedef OptionalAlias = {
	final root:Int;
	final path:Array<String>;
	final typeName:String;
}
private typedef OptionalClosure = {
	final name:String;
	final receiver:Null<IrValue>;
}

/**
 * Scalar components for optional values that do not need a boxed representation, per function (`IrFunctionPass`). A function's
 * summary says whether its types name a nullable object at all (`NULLABLE_OBJECTS`) and whether it calls an optional value
 * helper (`CALLS_HELPERS`). Its rewrite reads, for each nullable object its signature and values have, whether the object is a
 * value class (`VALUE`); for a function with an optional value, also which functions it calls are candidates (`CANDIDATE`), what
 * it reads of the classes it touches (`OBJECT`), of the values' slots (`LAYOUT`), of the methods it resolves (`METHOD`,
 * `UNIQUE`) and of the callees it passes a place to (`CALLEE`). It asks for the copy, box and unbox helpers the function it hands
 * on calls, the receiver checks and the component wrappers. `finish` adds the candidates' scalar forms, the receiver checks and
 * the helpers, each derived (`IrFunctionStages.derived`) from what it reads the same way.
 */
@:nullSafety(Strict)
class IrOptionalScalarFlow implements IrFunctionPass {
	public static inline final PREFIX = "$optional-scalar:";
	public static inline final WRAPPER = "$optional-components:";

	static inline final STAGE = "optional-scalar-flow";

	// Facts.

	/** Whether an object, by name, is a value class: 1 or 0. */
	static inline final VALUE = 0;

	/** Whether a function, by name, is a candidate: 1 or 0. */
	static inline final CANDIDATE = 1;

	/** The declaration of a class, by name (`objectText`): its base, whether it is a value and its fields. */
	static inline final OBJECT = 2;

	/** The slots of an optional value, by the value's name. */
	static inline final LAYOUT = 3;

	/** The method a class resolves a name to, by class and method name. */
	static inline final METHOD = 4;

	/** The one implementation every subclass of a class has of a method, by class and method name. */
	static inline final UNIQUE = 5;

	/** What passing a place to a function reads of it (`calleeText`), by its name. */
	static inline final CALLEE = 6;

	// Requests, besides the optional value helpers (`IrOptionalHelpers`).

	/** The component wrapper of a value class. */
	static inline final WRAPPER_REQUEST = 3;

	/** The receiver check of a class. */
	static inline final CHECK = 4;

	// Summaries.
	static inline final NULLABLE_OBJECTS = 1;
	static inline final CALLS_HELPERS = 2;

	final declarations:Array<IrObject>;
	final objects:Map<String, IrObject>;
	final layouts:IrInlineValueLayout;
	final wrappers:Map<String, IrObject> = [];
	var candidates:Map<String, IrFunction> = [];

	/** The stage's input functions by name, made when first looked up. */
	var inputIndex:Null<IrFunctionIndex> = null;

	/** The receiver checks asked for, by name, with the class each checks. */
	final receiverChecks:Map<String, String> = [];
	final resolution:IrMethodResolution;
	final helpers = new IrOptionalHelpers();

	// What the pass reads the functions' bodies with.
	final builder:Null<IrBodyBuilder>;

	/** The functions in program order, for the candidates' scalar forms (`finish`). */
	var originals:Array<IrFunction> = [];

	final lineage:Null<IrLineage>;
	final checks:Bool;

	/** By candidate, the version of the function its scalar form is made from. */
	final versions:Map<String, Int> = [];

	/** What the rewrite or helper being made reads through (`record`); null in the whole-program step. */
	var reading:Null<IrFactReader> = null;

	/** The wrappers and receiver checks the rewrite being made asked for, so each is asked for once. */
	var askedNow:Map<String, Bool> = [];

	/** With `lineage`, the session's memo derives the scalar forms and helpers (`IrFunctionStages.derived`). */
	public function new(declarations:Array<IrObject>, ?builder:IrBodyBuilder, ?lineage:IrLineage, checks = false) {
		this.declarations = declarations;
		this.builder = builder;
		this.lineage = lineage;
		this.checks = checks;
		objects = [for (object in declarations) object.name => object];
		resolution = IrMethodResolution.over(declarations);
		layouts = new IrInlineValueLayout(IrObjectTable.of(objects));
	}

	/**
	 * `originals` with their optional values in scalar slots, followed by the scalar forms, receiver checks and helpers they call,
	 * without a memo; the wrappers join the declarations. Read as their bodies.
	 */
	public function rewrite(originals:Array<IrFunction>):Array<IrFunction> {
		return IrFunctionStages.apply(STAGE, this, originals);
	}

	static function nullableObject(type:IrType):Null<String>
		return switch type {
			case Nullable(Obj(name)): name;
			default: null;
		};

	public function summarize(fn:IrFunction):Int {
		var summary = nullableObject(fn.result) != null ? NULLABLE_OBJECTS : 0;
		for (arg in fn.arguments)
			if (nullableObject(arg.type) != null)
				summary |= NULLABLE_OBJECTS;
		var body = fn.encodedBody(builder);
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var out = body.output(row);
				if (out.exists() && nullableObject(body.valueType(out)) != null)
					summary |= NULLABLE_OBJECTS;
				if (body.opcode(row) == compiler.ir.model.IrOpcode.Call
					&& IrOptionalHelpers.isHelper(body.symbol(row).name))
					summary |= CALLS_HELPERS;
				row = body.nextRow(row);
			}
		}
		return summary;
	}

	public function prepare(functions:Array<IrFunction>, summaries:Array<Int>, names:IrFunctionIndex):Void {
		originals = functions;
		for (index in 0...functions.length) {
			var fn = functions[index];
			if (summaries[index] & NULLABLE_OBJECTS == 0 || StringTools.startsWith(fn.name, PREFIX))
				continue;
			var signature = optional(fn.result) != null;
			for (arg in fn.arguments)
				if (optional(arg.type) != null)
					signature = true;
			if (signature)
				candidates.set(fn.name, fn);
		}
		var changed = true;
		while (changed) {
			changed = false;
			for (fn in functions)
				if (candidates.exists(fn.name) && !eligible(fn)) {
					candidates.remove(fn.name);
					changed = true;
				}
		}
		var known = lineage;
		if (known != null)
			for (name in candidates.keys())
				versions.set(name, known.version(name));
	}

	public function fact(kind:Int, key:String):Int {
		// What the fact is computed from is not what the rewrite being made reads.
		var current = reading;
		reading = null;
		var value = switch kind {
			case VALUE: isValueName(key) ? 1 : 0;
			case CANDIDATE: candidates.exists(key) ? 1 : 0;
			case _:
				var known = lineage;
				known == null ? 0 : known.memos.facts.intern(switch kind {
					case OBJECT: objectText(key);
					case LAYOUT: [for (slot in slots(key)) slotText(slot)].join("\n");
					case METHOD:
						var parts = key.split("\n");
						resolution.find(parts[0], parts[1]) ?? "";
					case UNIQUE:
						var parts = key.split("\n");
						resolution.uniqueImplementation(parts[0], parts[1]) ?? "";
					case _: calleeText(key);
				});
		};
		reading = current;
		return value;
	}

	/** Records the fact of `kind` and `key` for the rewrite or helper being made. */
	inline function record(kind:Int, key:String):Void {
		var current = reading;
		if (current != null)
			current.read(kind, key);
	}

	/** Asks for the helper of `kind` for `name` once for the rewrite or helper being made. */
	function ask(kind:Int, name:String):Void {
		var current = reading;
		if (current != null && !askedNow.exists(kind + ":" + name)) {
			askedNow.set(kind + ":" + name, true);
			current.request(kind, Obj(name));
		}
	}

	/** `make` run with `reader` as what it reads through. */
	function readingWith<T>(reader:IrFactReader, make:() -> T):T {
		reading = reader;
		askedNow = [];
		var made = make();
		reading = null;
		return made;
	}

	public function transform(fn:IrFunction, summary:Int, reader:IrFactReader):IrFunction {
		if (summary == 0)
			return fn;
		return readingWith(reader, () -> {
			var result = fn;
			if (summary & NULLABLE_OBJECTS != 0) {
				var signature = optional(fn.result) != null;
				for (arg in fn.arguments)
					if (optional(arg.type) != null)
						signature = true;
				if (!signature && hasOptional(fn) && eligible(fn))
					result = scalarForm(fn, false);
			}
			// The helpers the function calls: the rewritten one's are read from its body, which the stages after this one read.
			if (result != fn || summary & CALLS_HELPERS != 0)
				helpers.scan(result.encodedBody(builder), reader);
			result;
		});
	}

	public function request(kind:Int, type:IrType, name:Null<String>):Void {
		var value = switch type {
			case Obj(name): name;
			default: throw new InternalError("An optional scalar request names no class");
		};
		switch kind {
			case WRAPPER_REQUEST: declareWrapper(value);
			case CHECK: receiverChecks.set(receiverCheckName(value), value);
			default: helpers.add(kind, value);
		}
	}

	/** A function derived from `input` (`IrFunctionStages.derived`), made by `make` reading through the reader it is given. */
	function derive(name:String, input:Int, make:() -> IrFunction):IrFunction
		return IrFunctionStages.derived(STAGE, name, this, input, lineage, checks, builder,
			reader -> readingWith(reader, () -> {
				var made = make();
				helpers.scan(made.encodedBody(builder), reader);
				made;
			}));

	public function finish(rewritten:Array<IrFunction>):Array<IrFunction> {
		var made:Array<IrFunction> = [];
		for (fn in originals)
			if (candidates.exists(fn.name))
				made.push(derive(PREFIX + fn.name, versions.get(fn.name) ?? 0, () -> scalarForm(fn, true)));
		var checked = [for (name => typeName in receiverChecks) {
			name:name, typeName:typeName
		}];
		checked.sort((a, b) -> Reflect.compare(a.name, b.name));
		for (entry in checked)
			made.push(derive(entry.name, IrFunctionStages.FROM_NAME,
				() -> receiverCheckFunction(entry.name, entry.typeName)));
		var wrapped = [for (name => declared in wrappers) {
			name:name, declared:declared
		}];
		wrapped.sort((a, b) -> Reflect.compare(a.name, b.name));
		for (entry in wrapped)
			declarations.push(entry.declared);
		var shapes = new IrInlineValueLayout(IrObjectTable.of(objects));
		return helpers.append(rewritten.concat(made), declarations,
			(name, value, make) -> derive(name, IrFunctionStages.FROM_NAME, () -> {
				// A helper reads its value's slots and the declarations of the values it holds.
				record(LAYOUT, value);
				for (held in heldValues(value))
					record(OBJECT, held);
				make();
			}));
	}

	/** `name` and the values it holds, by value or as optional values, transitively. */
	function heldValues(name:String):Array<String> {
		var found = [name], index = 0;
		while (index < found.length) {
			var object = objects.get(found[index++]);
			if (object != null)
				for (field in object.fields)
					switch field.type {
						case Obj(held), Nullable(Obj(held)) if (isValueName(held) && found.indexOf(held) < 0):
							found.push(held);
						default:
					}
		}
		return found;
	}

	/** The text of what a rewrite reads of class `name` (`OBJECT`): whether it is a value, its base and its fields. */
	function objectText(name:String):String {
		var object = objects.get(name);
		if (object == null)
			return "";
		var parts = ['${object.isValue} ${object.base}'];
		for (field in object.fields)
			parts.push('${field.name} ${compiler.ir.model.IrTypeIdentity.text(field.type)} ${Std.string(field.nativeLayout)} '
				+ '${Std.string(field.scalarStorage)} ${Std.string(field.nullableScalarStorage)}');
		return parts.join("\n");
	}

	static function slotText(slot:IrInlineValueSlot):String
		return '${slot.path.join(".")} ${compiler.ir.model.IrTypeIdentity.text(slot.type)} ${slot.isPresence} '
			+ '${Std.string(slot.nativeLayout)} ${Std.string(slot.scalarStorage)} ${Std.string(slot.nullableScalarStorage)}';

	/** The text of what passing a place to the function `name` reads of it (`canPassAliases`). */
	function calleeText(name:String):String {
		var called = inputs().get(name);
		if (called == null)
			return "";
		var parts = [
			'${IrProviders.passesAliases(called)} ${snapshotOnlyReceiver(called)} ${snapshotOnlyReceiver(called, true)}'
		];
		for (argument in called.arguments)
			parts.push('${argument.name} ${compiler.ir.model.IrTypeIdentity.text(argument.type)}');
		return parts.join("\n");
	}

	/** The stage's input functions by name. */
	function inputs():IrFunctionIndex {
		var known = inputIndex;
		if (known == null)
			inputIndex = known = new IrFunctionIndex(STAGE, originals);
		return known;
	}

	/** Whether `name` is a candidate, read as a fact. */
	function isCandidate(name:String):Bool {
		record(CANDIDATE, name);
		return candidates.exists(name);
	}

	/** The declaration of class `name`, read as a fact. */
	function declaration(name:String):Null<IrObject> {
		record(OBJECT, name);
		return objects.get(name);
	}

	/** The function `name` a place is passed to, read as a fact. */
	function callee(name:String):Null<IrFunction> {
		record(CALLEE, name);
		return inputs().get(name);
	}

	/** Whether `name` is a value class. */
	function isValueName(name:String):Bool {
		record(VALUE, name);
		var object = objects.get(name);
		return object != null && object.isValue;
	}

	/** Whether `type` is the value class `optionalType` holds when present. */
	function holds(optionalType:IrType, type:IrType):Bool {
		var name = optional(optionalType);
		return name != null && Type.enumEq(type, Obj(name));
	}

	/** Whether a call of the closure `binding` passes a candidate's values or an alias. */
	function closureInvolved(binding:Null<OptionalClosure>, args:Array<IrValue>, alias:Map<Int, OptionalAlias>):Bool
		return binding != null && (isCandidate(binding.name) || hasAlias(args, alias));

	function optional(type:IrType):Null<String>
		return switch type {
			case Nullable(Obj(name)) if (isValueName(name)): name;
			default: null;
		};

	/** Whether `fn` has an optional value. */
	function hasOptional(fn:IrFunction):Bool {
		for (arg in fn.arguments)
			if (optional(arg.type) != null)
				return true;
		var body = fn.encodedBody(builder);
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var out = body.output(row);
				if (out.exists() && optional(body.valueType(out)) != null)
					return true;
				row = body.nextRow(row);
			}
		}
		return optional(fn.result) != null;
	}

	function slots(name:String):Array<IrInlineValueSlot> {
		record(LAYOUT, name);
		return layouts.slots(Nullable(Obj(name)));
	}

	public static function wrapperName(name:String):String
		return WRAPPER + name;

	/** The component wrapper of `name`, asked for so a rewrite reused declares it too. */
	function wrapper(name:String):IrObject {
		ask(WRAPPER_REQUEST, name);
		return declareWrapper(name);
	}

	function declareWrapper(name:String):IrObject {
		var known = wrappers.get(name);
		if (known != null)
			return known;
		var fields:Array<IrObjectField> = [];
		var shape = slots(name);
		for (i in 0...shape.length)
			fields.push({name: "$slot" + i, type: shape[i].type});
		var made:IrObject = {
			name: wrapperName(name),
			isValue: true,
			base: null,
			interfaces: [],
			fields: fields,
			methods: []
		};
		wrappers.set(name, made);
		return made;
	}

	function closureBindings(fn:IrFunction):Map<Int, OptionalClosure> {
		var result:Map<Int, OptionalClosure> = [];
		for (block in fn.blocks)
			for (located in block.instructions)
				switch located.value {
					case StaticClosure(out, name):
						result.set(out.id, {name: name.name, receiver: null});
					case InstanceClosure(out, name, receiver):
						result.set(out.id, {name: name.name, receiver: receiver});
					default:
				}
		return result;
	}

	function exactTypes(fn:IrFunction):Map<Int, String> {
		var result:Map<Int, String> = [], changed = true;
		while (changed) {
			changed = false;
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case NewObject(out, name) if (!result.exists(out.id)):
							result.set(out.id, name);
							changed = true;
						case ValueInit(out) if (!result.exists(out.id)):
							result.set(out.id, compiler.ir.model.IrTypeTools.valueObjectName(out.type));
							changed = true;
						case Upcast(out, value) if (!result.exists(out.id)):
							var name = result.get(value.id);
							if (name != null) {
								result.set(out.id, name);
								changed = true;
							}
						case Phi(out, inputs) if (!result.exists(out.id) && inputs.length > 0):
							var name:Null<String> = null, same = true;
							for (input in inputs) {
								var type = result.get(input.value.id);
								if (type == null || (name != null && name != type))
									same = false;
								else
									name = type;
							}
							if (same && name != null) {
								result.set(out.id, name);
								changed = true;
							}
						default:
					}
		}
		return result;
	}

	function method(typeName:Null<String>, name:String):Null<String> {
		if (typeName == null)
			return null;
		record(METHOD, typeName + "\n" + name);
		return resolution.find(typeName, name);
	}

	/** Resolve class dispatch only when every possible subclass has the same implementation. */
	function resolvedMethod(exact:Map<Int, String>, receiver:IrValue, name:String):Null<String> {
		if (exact.exists(receiver.id))
			return method(exact.get(receiver.id), name);
		var typeName = switch receiver.type {
			case Obj(value): value;
			default: return null;
		};
		var root = declaration(typeName);
		if (root == null || root.isValue)
			return null;
		record(UNIQUE, typeName + "\n" + name);
		return resolution.uniqueImplementation(typeName, name);
	}

	function hasCandidateMethod(exact:Map<Int, String>, receiver:IrValue, name:String):Bool {
		var target = resolvedMethod(exact, receiver, name);
		return target != null && isCandidate(target);
	}

	static function receiverCheckName(typeName:String):String
		return "$optional-scalar:check-receiver:" + typeName;

	/** The receiver check of `typeName`, asked for. */
	function receiverCheck(typeName:String):String {
		ask(CHECK, typeName);
		var name = receiverCheckName(typeName);
		receiverChecks.set(name, typeName);
		return name;
	}

	/** The receiver check `name` of `typeName`: made of its name alone. */
	static function receiverCheckFunction(name:String, typeName:String):IrFunction {
		var b = new IrBuilder(),
			receiver = b.argument("receiver", Obj(typeName));
		var missing = b.createBlock(), present = b.createBlock();
		b.branch(b.equal(receiver, b.constNull(receiver.type)), missing, present);
		b.select(missing);
		b.terminate(Throw(b.toDyn(b.constString("Null access"))));
		b.select(present);
		b.returnValue(b.constVoid());
		return new IrFunction(name, b.arguments, Void, b.blocks,
			Provider(TypeKey.of(Obj(typeName)), ProviderOperation.ReceiverCheck));
	}

	/** Array-backed mutable places retain their identity until the lane-place rewrite. */
	function arrayPlaceValues(fn:IrFunction):Map<Int, Bool> {
		var places:Map<Int, Bool> = [], nulls:Map<Int, Bool> = [];
		for (block in fn.blocks)
			for (located in block.instructions) {
				switch located.value {
					case ConstNull(out):
						nulls.set(out.id, true);
					default:
				}
				switch located.provenance.origin {
					case CompilerGenerated(reason) if (reason == IrGenerator.ArrayValuePlaceReason):
						switch located.value {
							case ArrayGet(out, _, _) if (optional(out.type) != null): places.set(out.id, true);
							case Call(out, callTarget, args) if (callTarget.name == "__array_get_any"
								&& args.length == 2 && switch args[0].type {
									case Array(element): optional(element) != null;
									default: false;
								}): places.set(out.id, true);
							default:
						}
					default:
				}
			}
		var changed = true;
		while (changed) {
			changed = false;
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case SafeCast(out, value) | ToDyn(out,
							value) if (places.exists(value.id) && !places.exists(out.id)):
							switch out.type {
								case Obj(name) if (isValueName(name)):
									places.set(out.id, true);
									changed = true;
								case Nullable(Obj(_)) if (optional(out.type) != null):
									places.set(out.id, true);
									changed = true;
								default:
							}
						case FieldGet(out, owner, _) if (places.exists(owner.id) && !places.exists(out.id)):
							switch out.type {
								case Obj(name) if (isValueName(name)):
									places.set(out.id, true);
									changed = true;
								case Nullable(Obj(_)) if (optional(out.type) != null):
									places.set(out.id, true);
									changed = true;
								default:
							}
						case Equal(_, left, right):
							if (places.exists(left.id) && nulls.exists(right.id) && !places.exists(right.id)) {
								places.set(right.id, true);
								changed = true;
							}
							if (places.exists(right.id) && nulls.exists(left.id) && !places.exists(left.id)) {
								places.set(left.id, true);
								changed = true;
							}
						default:
					}
		}
		return places;
	}

	function aliases(fn:IrFunction, places:Map<Int, Bool>):Map<Int, OptionalAlias> {
		var result:Map<Int, OptionalAlias> = [], changed = true;
		while (changed) {
			changed = false;
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case SafeCast(out, source) if (!places.exists(source.id)):
							var name = optional(source.type);
							if (name != null && Type.enumEq(out.type, Obj(name)) && !result.exists(out.id)) {
								// Haxe's checker types a literal's field by its value's declared type, not by the test above.
								result.set(out.id, {root: source.id, path: [], typeName: (name: String)});
								changed = true;
							}
						case FieldGet(out, owner, field) if (result.exists(owner.id)):
							switch out.type {
								case Obj(name) if (isValueName(name)
									&& !result.exists(out.id)):
									var parent:OptionalAlias = cast result.get(owner.id);
									result.set(out.id, {
										root: parent.root,
										path: parent.path.concat([field]),
										typeName: parent.typeName
									});
									changed = true;
								default:
							}
						default:
					}
		}
		return result;
	}

	function physicalField(type:IrType, physicalName:String):Null<{path:Array<String>, presence:Bool}> {
		var name:Null<String> = switch type {
			case Obj(value): value;
			default: return null;
		};
		while (name != null) {
			var object = declaration(name);
			if (object == null)
				return null;
			for (field in object.fields) {
				var child = optional(field.type);
				if (child != null)
					for (slot in slots(child))
						if (IrInlineValueLayout.slotName(field.name, slot) == physicalName)
							return {path: [field.name].concat(slot.path), presence: slot.isPresence};
			}
			name = object.base;
		}
		return null;
	}

	function declaredField(type:IrType, field:String):Null<IrObjectField> {
		var name:Null<String> = switch type {
			case Obj(value): value;
			default: return null;
		};
		while (name != null) {
			var object = declaration(name);
			if (object == null)
				return null;
			for (entry in object.fields)
				if (entry.name == field)
					return entry;
			name = object.base;
		}
		return null;
	}

	function inlineOptionalField(owner:IrValue, field:String, type:IrType):Bool {
		var declared = declaredField(owner.type, field);
		return declared != null && optional(declared.type) != null && Type.enumEq(declared.type, type);
	}

	function hasAlias(arguments:Array<IrValue>, aliases:Map<Int, OptionalAlias>):Bool {
		for (argument in arguments)
			if (aliases.exists(argument.id))
				return true;
		return false;
	}

	/** A receiver that is only read can be reconstructed from optional components without changing place semantics. */
	function snapshotOnlyReceiver(fn:IrFunction, allowWrites:Bool = false):Bool {
		if (fn.arguments.length == 0 || fn.arguments[0].name != "this")
			return false;
		var roots:Map<Int, Bool> = [fn.arguments[0].id => true], changed = true;
		while (changed) {
			changed = false;
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case FieldGet(out, owner, _) if (roots.exists(owner.id) && !roots.exists(out.id)):
							switch out.type {
								case Obj(name) if (isValueName(name)):
									roots.set(out.id, true);
									changed = true;
								default:
							}
						default:
					}
		}
		for (block in fn.blocks) {
			for (located in block.instructions) {
				switch located.value {
					case Phi(_, incoming):
						for (item in incoming)
							if (roots.exists(item.value.id))
								return false;
					default:
				}
				for (input in IrOperands.inputs(located.value))
					if (roots.exists(input.id))
						switch located.value {
							case FieldGet(_, owner, _) if (roots.exists(owner.id)):
							case FieldSet(owner, _,
								value) if (allowWrites && roots.exists(owner.id) && !roots.exists(value.id)):
							default:
								return false;
						}
			}
			if (block.terminator != null)
				switch block.terminator.value {
					case Return(value), Throw(value), Rethrow(value), Branch(value, _, _),
						Switch(value, _, _) if (roots.exists(value.id)):
						return false;
					default:
				}
		}
		return true;
	}

	function aliasMethod(receiver:IrValue, name:String):Null<String>
		return switch receiver.type {
			case Obj(typeName): method(typeName, name);
			default: null;
		};

	function canPassAliases(name:String, arguments:Array<IrValue>, aliases:Map<Int, OptionalAlias>,
			terminalReceiver:Bool = false):Bool {
		if (!hasAlias(arguments, aliases))
			return true;
		var called = callee(name);
		if (StringTools.startsWith(name, "$") && (called == null || !IrProviders.passesAliases(called)))
			return false;
		if (called == null || called.arguments.length != arguments.length)
			return false;
		for (index in 0...arguments.length)
			if (aliases.exists(arguments[index].id)) {
				var formal = called.arguments[index];
				if ((formal.name == "this" && !snapshotOnlyReceiver(called, terminalReceiver))
					|| !Type.enumEq(formal.type, arguments[index].type))
					return false;
			}
		return true;
	}

	function eligible(fn:IrFunction):Bool {
		var places = arrayPlaceValues(fn),
			nulls:Map<Int, Bool> = [],
			values:Map<Int, Bool> = [],
			alias = aliases(fn, places),
			bindings = closureBindings(fn),
			exact = exactTypes(fn);
		for (arg in fn.arguments)
			if (optional(arg.type) != null)
				values.set(arg.id, true);
		for (block in fn.blocks)
			for (located in block.instructions) {
				var out = IrOperands.output(located.value);
				if (out != null && optional(out.type) != null && !places.exists(out.id))
					values.set(out.id, true);
				switch located.value {
					case ConstNull(out) if (optional(out.type) != null):
						nulls.set(out.id, true);
					default:
				}
			}
		for (block in fn.blocks) {
			for (located in block.instructions) {
				var op = located.value,
					out = IrOperands.output(op),
					involved = out != null && values.exists(out.id);
				for (input in IrOperands.inputs(op))
					if (values.exists(input.id) || alias.exists(input.id))
						involved = true;
				switch op {
					case Phi(_, inputs):
						for (input in inputs)
							if (values.exists(input.value.id) || alias.exists(input.value.id))
								involved = true;
					default:
				}
				if (!involved)
					continue;
				switch op {
					case ConstNull(out) if (values.exists(out.id)):
					case Phi(out, inputs) if (values.exists(out.id)):
						for (input in inputs)
							if (!values.exists(input.value.id) || !Type.enumEq(input.value.type, out.type))
								return false;
					case Phi(_, inputs):
						for (input in inputs)
							if (values.exists(input.value.id) || alias.exists(input.value.id))
								return false;
					case FieldGet(out, owner, _) if (values.exists(out.id) && !alias.exists(owner.id)):
					case FieldGet(_, owner, field) if (alias.exists(owner.id)):
						if (physicalField(owner.type, field) == null && declaredField(owner.type, field) == null)
							return false;
						var declaration = declaredField(owner.type, field);
						if (declaration != null)
							switch declaration.type {
								case Nullable(Obj(_)) if (optional(declaration.type) == null): return false;
								default:
							}
					case FieldSet(owner, field, value) if (alias.exists(owner.id) && !alias.exists(value.id)):
						var physical = physicalField(owner.type, field),
							declared = declaredField(owner.type, field);
						if (physical == null && declared == null)
							return false;
						if (physical == null && declared != null)
							switch declared.type {
								case Obj(name) if (isValueName(name)): return false;
								case Nullable(Obj(_)) if (optional(declared.type) == null): return false;
								default:
							}
					case FieldSet(owner, _, value) if (!alias.exists(owner.id) && values.exists(value.id)):
					case ToDyn(out,
						source) if (values.exists(out.id) && holds(out.type, source.type)):
					case SafeCast(out, source) if (alias.exists(out.id) && values.exists(source.id)):
					case Equal(_, left, right) if ((values.exists(left.id) && nulls.exists(right.id))
						|| (values.exists(right.id) && nulls.exists(left.id))):
					case Call(out, name, args)
						if (IrOptionalValueFlow.isCopyName(name.name)
						&& values.exists(out.id)
						&& args.length == 1
						&& values.exists(args[0].id)):
					case Call(_, name, args) if (isCandidate(name.name) || hasAlias(args, alias)):
						if (!canPassAliases(name.name, args, alias))
							return false;
					case CallClosure(_, closure, args) if (closureInvolved(bindings.get(closure.id), args, alias)):
						var binding = bindings.get(closure.id);
						if (binding != null) {
							var actual = binding.receiver == null ? args : [binding.receiver].concat(args);
							if (!canPassAliases(binding.name, actual, alias))
								return false;
						}
					case MethodCall(_, receiver, name, args, terminalReceiver) if (alias.exists(receiver.id)):
						var target = aliasMethod(receiver, name);
						if (target == null
							|| !canPassAliases(target, [receiver].concat(args), alias, terminalReceiver == true))
							return false;
					case MethodCall(_, receiver, name, args, _)
						if (!alias.exists(receiver.id)
						&& (hasCandidateMethod(exact, receiver, name) || hasAlias(args, alias))):
						var target = resolvedMethod(exact, receiver, name);
						if (target == null || !canPassAliases(target, [receiver].concat(args), alias))
							return false;
					default:
						// Unsupported reference-representation operations remain explicit box/unbox boundaries.
						for (input in IrOperands.inputs(op))
							if (alias.exists(input.id))
								return false;
				}
			}
			if (block.terminator != null)
				switch block.terminator.value {
					case Return(value) if (values.exists(value.id)):
						if (optional(fn.result) == null)
							return false;
					case Throw(value), Rethrow(value) if (values.exists(value.id)):
					case Return(value), Throw(value), Rethrow(value),
						Branch(value, _, _) if (alias.exists(value.id) || values.exists(value.id)):
						return false;
					default:
				}
		}
		return true;
	}

	/** `fn` with its optional values in scalar slots: as the candidate's scalar form when `clone`. */
	function scalarForm(fn:IrFunction, clone:Bool):IrFunction {
		var next = fn.nextValueId();
		var places = arrayPlaceValues(fn),
			types:Map<Int, String> = [],
			components:Map<Int, Array<IrValue>> = [],
			nulls:Map<Int, Bool> = [];
		function component(id:Int):Array<IrValue> {
			var result = components.get(id);
			if (result == null)
				throw new InternalError('Missing optional scalar components for $id');
			return result;
		}
		function typeName(id:Int):String {
			var name = types.get(id);
			if (name == null)
				throw new InternalError('Missing optional scalar type for $id');
			return name;
		}
		function allocate(value:IrValue):Void {
			var name = optional(value.type);
			if (name == null || places.exists(value.id) || components.exists(value.id))
				return;
			types.set(value.id, name);
			components.set(value.id, [for (slot in slots(name)) new IrValue(next++, "$optional-slot", slot.type)]);
		}
		for (arg in fn.arguments)
			allocate(arg);
		for (block in fn.blocks)
			for (located in block.instructions) {
				var out = IrOperands.output(located.value);
				if (out != null)
					allocate(out);
				switch located.value {
					case ConstNull(out) if (optional(out.type) != null):
						nulls.set(out.id, true);
					default:
				}
			}
		var alias = aliases(fn, places),
			bindings = closureBindings(fn),
			exact = exactTypes(fn),
			substitutions:Map<Int, IrValue> = [],
			holders:Map<Int, IrValue> = [];
		// The closure bound to `id`, a value a guard found among the bindings.
		function bindingOf(id:Int):OptionalClosure {
			var binding = bindings.get(id);
			if (binding == null)
				throw new InternalError('Missing optional closure binding for $id');
			return binding;
		}
		for (block in fn.blocks)
			for (located in block.instructions)
				switch located.value {
					case FieldSet(owner, _, _) if (alias.exists(owner.id)):
						var receiver:OptionalAlias = cast alias.get(owner.id),
							root = receiver.root;
						if (!holders.exists(root))
							holders.set(root,
								new IrValue(next++, "$optional-place", Obj(wrapper(typeName(root)).name)));
					default:
				}
		var origin = SourceProvenance.generated("optional-scalar-flow"),
			args:Array<IrValue> = [],
			prefix:Array<Located<IrInstruction>> = [];
		for (arg in fn.arguments) {
			var name = optional(arg.type);
			if (name == null)
				args.push(arg);
			else {
				var aggregate = new IrValue(next++, arg.name, Obj(wrapper(name).name));
				args.push(aggregate);
				var parts = component(arg.id);
				for (i in 0...parts.length)
					prefix.push(new Located(FieldGet(parts[i], aggregate, "$slot" + i), origin));
				var holder = holders.get(arg.id);
				if (holder != null) {
					prefix.push(new Located(ValueInit(holder), origin));
					for (i in 0...parts.length)
						prefix.push(new Located(FieldSet(holder, "$slot" + i, parts[i]), origin));
				}
			}
		}
		function add(block:IrBlock, instruction:IrInstruction, from:Located<IrInstruction>):Void
			block.instructions.push(new Located(instruction, from.provenance));
		function install(block:IrBlock, id:Int, from:Located<IrInstruction>):Void {
			var holder = holders.get(id);
			if (holder == null)
				return;
			var parts = component(id);
			add(block, ValueInit(holder), from);
			for (i in 0...parts.length)
				add(block, FieldSet(holder, "$slot" + i, parts[i]), from);
		}
		function partsAt(block:IrBlock, id:Int, from:Located<IrInstruction>):Array<IrValue> {
			var holder = holders.get(id);
			if (holder == null)
				return component(id);
			var shape = slots(typeName(id)),
				parts:Array<IrValue> = [];
			for (i in 0...shape.length) {
				var value = new IrValue(next++, "$optional-current", shape[i].type);
				add(block, FieldGet(value, holder, "$slot" + i), from);
				parts.push(value);
			}
			return parts;
		}
		function zero(out:IrValue):IrInstruction
			return switch out.type {
				case Bool: ConstBool(out, false);
				case I32, I64: ConstInt(out, 0);
				case F32, F64: ConstFloat(out, 0.0);
				default: ConstNull(out);
			};
		function slotIndex(rootName:String, path:Array<String>, presence:Bool):Int {
			var shape = slots(rootName);
			for (i in 0...shape.length)
				if (shape[i].isPresence == presence && IrOptionalValueFlow.samePath(shape[i].path, path))
					return i;
			throw new InternalError('Missing optional scalar slot ${path.join(".")}');
		}
		function storeSlot(block:IrBlock, holder:IrValue, name:String, index:Int, value:IrValue,
				from:Located<IrInstruction>):Void {
			var slot = slots(name)[index],
				native = slot.scalarStorage,
				bits = switch value.type {
					case I32: 32;
					case I64: 64;
					default: 0;
				};
			if (native != null && bits > 0 && native.size > 0 && native.size * 8 < bits) {
				var shift = new IrValue(next++, "$optional-shift", I32),
					shifted = new IrValue(next++, "$optional-truncate", value.type),
					result = new IrValue(next++, "$optional-extend", value.type);
				add(block, ConstInt(shift, bits - native.size * 8), from);
				add(block, ShiftLeft(shifted, value, shift), from);
				add(block, native.signed ? ShiftRight(result, shifted, shift) : UnsignedShiftRight(result, shifted,
					shift), from);
				value = result;
			} else if ((switch (value.type) {
				case F32: true;
				default: false;
			})) {
				var wide = new IrValue(next++, "$optional-f64", F64),
					rounded = new IrValue(next++, "$optional-f32", F32);
				add(block, FloatToFloat(wide, value), from);
				add(block, FloatToFloat(rounded, wide), from);
				value = rounded;
			}
			add(block, FieldSet(holder, "$slot" + index, value), from);
		}
		function field(type:IrType, name:String):IrObjectField {
			var owner:Null<String> = switch type {
				case Obj(value): value;
				default: throw new InternalError("Invalid value field owner");
			};
			while (owner != null) {
				var object = declaration(owner);
				if (object == null)
					break;
				for (candidate in object.fields)
					if (candidate.name == name)
						return candidate;
				owner = object.base;
			}
			throw new InternalError('Missing value field $name');
		}
		function aliasValue(block:IrBlock, source:IrValue, from:Located<IrInstruction>):IrValue {
			var a:OptionalAlias = cast alias.get(source.id),
				root = partsAt(block, a.root, from);
			function build(name:String, path:Array<String>):IrValue {
				var result = new IrValue(next++, "$optional-alias-copy", Obj(name)),
					object = declaration(name);
				if (object == null)
					throw new InternalError('Missing optional alias value "$name"');
				add(block, ValueInit(result), from);
				for (entry in object.fields) {
					var pathField = path.concat([entry.name]),
						child = optional(entry.type);
					if (child != null) {
						for (slot in slots(child)) {
							var index = slotIndex(a.typeName, pathField.concat(slot.path), slot.isPresence);
							add(block, FieldSet(result, IrInlineValueLayout.slotName(entry.name, slot), root[index]),
								from);
						}
					} else
						switch entry.type {
							case Obj(childName) if (isValueName(childName)):
								add(block, FieldSet(result, entry.name, build(childName, pathField)), from);
							default:
								add(block, FieldSet(result, entry.name, root[slotIndex(a.typeName, pathField, false)]),
									from);
						}
				}
				return result;
			}
			return switch source.type {
				case Obj(name): build(name, a.path);
				default: throw new InternalError("Invalid optional alias value");
			};
		}
		function readValue(block:IrBlock, source:IrValue, name:String, output:Array<IrValue>,
				from:Located<IrInstruction>):Void {
			add(block, ConstBool(output[0], true), from);
			var shape = slots(name);
			for (index in 1...shape.length) {
				var slot = shape[index], current = source;
				for (partIndex in 0...slot.path.length) {
					var part = slot.path[partIndex],
						declaration = field(current.type, part),
						last = partIndex == slot.path.length - 1;
					if (optional(declaration.type) != null) {
						var sub:IrInlineValueSlot = {
							path: slot.path.slice(partIndex + 1),
							type: slot.type,
							isPresence: slot.isPresence,
							nativeLayout: slot.nativeLayout
						};
						add(block, FieldGet(output[index], current, IrInlineValueLayout.slotName(part, sub)), from);
						break;
					}
					if (last)
						add(block, FieldGet(output[index], current, part), from);
					else {
						var child = new IrValue(next++, "$optional-child", declaration.type);
						add(block, FieldGet(child, current, part), from);
						current = child;
					}
				}
			}
		}
		function aggregate(block:IrBlock, name:String, parts:Array<IrValue>, from:Located<IrInstruction>):IrValue {
			var target = new IrValue(next++, "$optional-components", Obj(wrapper(name).name));
			add(block, ValueInit(target), from);
			for (i in 0...parts.length)
				add(block, FieldSet(target, "$slot" + i, parts[i]), from);
			return target;
		}
		function box(block:IrBlock, value:IrValue, from:Located<IrInstruction>):IrValue {
			var name = typeName(value.id),
				packed = aggregate(block, name, partsAt(block, value.id, from), from),
				result = new IrValue(next++, "$optional-boxed", value.type);
			add(block, Call(result, IrSymbol.of(IrOptionalValueFlow.boxName(name)), [packed]), from);
			return result;
		}
		function unbox(block:IrBlock, value:IrValue, output:IrValue, from:Located<IrInstruction>):Void {
			var name = typeName(output.id),
				packed = new IrValue(next++, "$optional-unboxed", Obj(wrapper(name).name));
			add(block, Call(packed, IrSymbol.of(IrOptionalValueFlow.unboxName(name)), [value]), from);
			var parts = component(output.id);
			for (i in 0...parts.length)
				add(block, FieldGet(parts[i], packed, "$slot" + i), from);
		}
		function emitCall(block:IrBlock, out:IrValue, name:String, arguments:Array<IrValue>,
				from:Located<IrInstruction>):Void {
			var expanded:Array<IrValue> = [];
			for (arg in arguments)
				expanded.push(components.exists(arg.id) ? aggregate(block, typeName(arg.id),
					partsAt(block, arg.id, from), from) : arg);
			if (components.exists(out.id)) {
				var valueName = typeName(out.id),
					result = new IrValue(next++, "$optional-result", Obj(wrapper(valueName).name));
				add(block, Call(result, IrSymbol.of(PREFIX + name), expanded), from);
				var parts = component(out.id);
				for (i in 0...parts.length)
					add(block, FieldGet(parts[i], result, "$slot" + i), from);
			} else
				add(block, Call(out, IrSymbol.of(PREFIX + name), expanded), from);
		}
		var blocks:Array<IrBlock> = [],
			pendingReads:Map<Int, Array<Located<IrInstruction>>> = [],
			copies:Map<Int, IrBlock> = [];
		for (block in fn.blocks) {
			var target = new IrBlock(block.id);
			blocks.push(target);
			copies.set(block.id, target);
		}
		for (blockIndex in 0...fn.blocks.length) {
			var block = fn.blocks[blockIndex],
				target:IrBlock = cast copies.get(block.id),
				phiInstall:Array<{id:Int, from:Located<IrInstruction>}> = [],
				installed = false;
			if (blockIndex == 0)
				for (instruction in prefix)
					target.instructions.push(instruction);
			for (located in block.instructions) {
				var op = located.value;
				switch op {
					case Phi(_, _):
					default:
						if (!installed) {
							for (entry in phiInstall)
								install(target, entry.id, entry.from);
							installed = true;
						}
				}
				switch op {
					case ConstNull(out) if (components.exists(out.id)):
						for (part in component(out.id))
							add(target, zero(part), located);
					case Phi(out, incoming) if (components.exists(out.id)):
						var parts = component(out.id);
						var sources:Array<Array<IrValue>> = [];
						for (input in incoming) {
							if (!holders.exists(input.value.id))
								sources.push(component(input.value.id));
							else {
								var pending = new IrBlock(input.block),
									values = partsAt(pending, input.value.id, located),
									list = pendingReads.get(input.block);
								if (list == null) {
									list = [];
									pendingReads.set(input.block, list);
								}
								for (item in pending.instructions)
									list.push(item);
								sources.push(values);
							}
						}
						for (i in 0...parts.length)
							add(target, Phi(parts[i], [for (j in 0...incoming.length) {
								block:incoming[j].block, value:sources[j][i]
							}]), located);
						if (holders.exists(out.id))
							phiInstall.push({id: out.id, from: located});
					case FieldGet(out, owner, name) if (alias.exists(owner.id)):
						var a:OptionalAlias = cast alias.get(owner.id),
							physical = physicalField(owner.type, name),
							path = a.path.concat([name]),
							root = partsAt(target, a.root, located);
						if (physical != null)
							substitutions.set(out.id,
								root[slotIndex(a.typeName, a.path.concat(physical.path), physical.presence)]);
						else if (components.exists(out.id)) {
							var shape = slots(typeName(out.id)),
								parts = component(out.id);
							for (i in 0...parts.length)
								substitutions.set(parts[i].id,
									root[slotIndex(a.typeName, path.concat(shape[i].path), shape[i].isPresence)]);
						} else if (!alias.exists(out.id))
							substitutions.set(out.id, root[slotIndex(a.typeName, path, false)]);
					case FieldGet(out, owner,
						name) if (components.exists(out.id) && inlineOptionalField(owner, name, out.type)):
						var shape = slots(typeName(out.id)),
							parts = component(out.id);
						for (i in 0...parts.length)
							add(target, FieldGet(parts[i], owner, IrInlineValueLayout.slotName(name, shape[i])),
								located);
					case FieldSet(owner, name, value) if (alias.exists(owner.id)):
						var a:OptionalAlias = cast alias.get(owner.id),
							physical = physicalField(owner.type, name),
							path = a.path.concat([name]),
							holder = holders.get(a.root);
						// Every alias that is written to has a holder for its root (made above).
						if (holder == null)
							throw new InternalError('Missing optional place holder for ${a.root}');
						if (components.exists(value.id)) {
							var shape = slots(typeName(value.id)),
								parts = partsAt(target, value.id, located);
							for (i in 0...parts.length)
								storeSlot(target, holder, a.typeName,
									slotIndex(a.typeName, path.concat(shape[i].path), shape[i].isPresence), parts[i],
									located);
						} else if (physical != null)
							storeSlot(target, holder, a.typeName,
								slotIndex(a.typeName, a.path.concat(physical.path), physical.presence), value, located);
						else
							storeSlot(target, holder, a.typeName, slotIndex(a.typeName, path, false), value, located);
					case FieldSet(owner, name,
						value) if (components.exists(value.id) && inlineOptionalField(owner, name, value.type)):
						var shape = slots(typeName(value.id)),
							parts = partsAt(target, value.id, located);
						for (i in 0...parts.length)
							add(target, FieldSet(owner, IrInlineValueLayout.slotName(name, shape[i]), parts[i]),
								located);
					case ToDyn(out, source) if (components.exists(out.id)):
						var parts = component(out.id),
							name = typeName(out.id);
						if (alias.exists(source.id)) {
							add(target, ConstBool(parts[0], true), located);
							var shape = slots(name),
								a:OptionalAlias = cast alias.get(source.id),
								root = partsAt(target, a.root, located);
							for (i in 1...parts.length)
								substitutions.set(parts[i].id,
									root[slotIndex(a.typeName, a.path.concat(shape[i].path), shape[i].isPresence)]);
						} else
							readValue(target, source, name, parts, located);
					case SafeCast(out, _) if (alias.exists(out.id)):
					case Equal(out, left, right)
						if ((components.exists(left.id) || components.exists(right.id))
						&& (nulls.exists(left.id) || nulls.exists(right.id))):
						var value = nulls.exists(left.id) ? right : left,
							no = new IrValue(next++, "$optional-absent", Bool);
						add(target, ConstBool(no, false), located);
						add(target, Equal(out, partsAt(target, value.id, located)[0], no), located);
					case Call(out, name, arguments)
						if (IrOptionalValueFlow.isCopyName(name.name)
						&& components.exists(out.id)
						&& arguments.length == 1
						&& components.exists(arguments[0].id)):
						var from = partsAt(target, arguments[0].id, located),
							to = component(out.id);
						for (i in 0...to.length)
							substitutions.set(to[i].id, from[i]);
					case CallClosure(out, closure, arguments) if (bindings.exists(closure.id)
						&& isCandidate(bindingOf(closure.id).name)):
						var binding = bindingOf(closure.id),
							args = binding.receiver == null ? arguments : [binding.receiver].concat(arguments);
						var actual = [
							for (argument in args)
								alias.exists(argument.id) ? aliasValue(target, argument, located) : argument
						];
						emitCall(target, out, binding.name, actual, located);
					case Call(out, name, arguments) if (isCandidate(name.name)):
						var actual = [
							for (argument in arguments)
								alias.exists(argument.id) ? aliasValue(target, argument, located) : argument
						];
						emitCall(target, out, name.name, actual, located);
					case MethodCall(out, receiver, name, arguments, _) if (!alias.exists(receiver.id)
						&& hasCandidateMethod(exact, receiver, name)):
						var resolved = resolvedMethod(exact, receiver, name);
						if (resolved == null)
							throw new InternalError('The candidate method $name has no implementation');
						// Method arguments have already been evaluated; preserve the null error at the original call.
						if (!exact.exists(receiver.id))
							switch receiver.type {
								case Obj(typeName): add(target,
									Call(new IrValue(next++, "$optional-receiver-check", Void),
									IrSymbol.of(receiverCheck(typeName)),
									[receiver]), located);
								default:
							}
						var actual = [
							for (argument in [receiver].concat(arguments))
								alias.exists(argument.id) ? aliasValue(target, argument, located) : argument
						];
						emitCall(target, out, resolved, actual, located);
					case Call(out, name, arguments) if (hasAlias(arguments, alias)):
						var actual = [
							for (argument in arguments)
								alias.exists(argument.id) ? aliasValue(target, argument,
								located) : components.exists(argument.id) ? box(target, argument, located) : argument
						];
						if (components.exists(out.id)) {
							var output = new IrValue(next++, "$optional-boundary-result", out.type);
							add(target, Call(output, name, actual), located);
							unbox(target, output, out, located);
						} else
							add(target, Call(out, name, actual), located);
					case MethodCall(out, receiver, name, arguments, terminalReceiver) if (alias.exists(receiver.id)):
						var actual = [
							for (argument in arguments)
								alias.exists(argument.id) ? aliasValue(target, argument,
								located) : components.exists(argument.id) ? box(target, argument, located) : argument
						];
						add(target, MethodCall(out, aliasValue(target, receiver, located), name, actual,
							terminalReceiver), located);
					case CallClosure(out, closure, arguments)
						if (bindings.exists(closure.id)
						&& bindingOf(closure.id).receiver == null
						&& callee(bindingOf(closure.id).name) != null
						&& !hasAlias(arguments, alias)):
						var binding = bindingOf(closure.id);
						var boxed = [
							for (argument in arguments)
								components.exists(argument.id) ? box(target, argument, located) : argument
						];
						if (components.exists(out.id)) {
							var output = new IrValue(next++, "$optional-boundary-result", out.type);
							add(target, Call(output, IrSymbol.of(binding.name), boxed), located);
							unbox(target, output, out, located);
						} else
							add(target, Call(out, IrSymbol.of(binding.name), boxed), located);
					case CallClosure(out, closure,
						arguments) if (bindings.exists(closure.id) && hasAlias(arguments, alias)):
						var binding = bindingOf(closure.id),
							args = binding.receiver == null ? arguments : [binding.receiver].concat(arguments);
						var actual = [
							for (argument in args)
								alias.exists(argument.id) ? aliasValue(target, argument,
								located) : components.exists(argument.id) ? box(target, argument, located) : argument
						];
						if (components.exists(out.id)) {
							var output = new IrValue(next++, "$optional-boundary-result", out.type);
							add(target, Call(output, IrSymbol.of(binding.name), actual), located);
							unbox(target, output, out, located);
						} else
							add(target, Call(out, IrSymbol.of(binding.name), actual), located);
					case MethodCall(out, receiver, name, arguments,
						terminalReceiver) if (!alias.exists(receiver.id) && hasAlias(arguments, alias)):
						var actual = [
							for (argument in arguments)
								alias.exists(argument.id) ? aliasValue(target, argument,
								located) : components.exists(argument.id) ? box(target, argument, located) : argument
						];
						if (components.exists(out.id)) {
							var output = new IrValue(next++, "$optional-boundary-result", out.type);
							add(target, MethodCall(output, receiver, name, actual, terminalReceiver), located);
							unbox(target, output, out, located);
						} else
							add(target, MethodCall(out, receiver, name, actual, terminalReceiver), located);
					default:
						var remapped:Map<Int, IrValue> = [],
							out = IrOperands.output(op),
							changed = false;
						for (input in IrOperands.inputs(op))
							if (components.exists(input.id) && !remapped.exists(input.id)) {
								remapped.set(input.id, box(target, input, located));
								changed = true;
							}
						var boxedOutput:Null<IrValue> = null;
						if (out != null && components.exists(out.id)) {
							boxedOutput = new IrValue(next++, "$optional-boundary-result", out.type);
							remapped.set(out.id, boxedOutput);
							changed = true;
						}
						if (!changed)
							target.instructions.push(located);
						else {
							var instruction = IrInliner.remap(op,
								value -> remapped.get(value.id) ?? value, id -> id);
							target.instructions.push(new Located(instruction, located.provenance));
							if (boxedOutput != null && out != null)
								unbox(target, boxedOutput, out, located);
						}
				}
				switch op {
					case Phi(_, _):
					default:
						var out = IrOperands.output(op);
						if (out != null && components.exists(out.id))
							install(target, out.id, located);
				}
			}
			if (!installed)
				for (entry in phiInstall)
					install(target, entry.id, entry.from);
			var terminator = block.terminator;
			target.terminator = terminator;
			if (terminator != null)
				switch terminator.value {
					case Return(value) if (components.exists(value.id)):
						var here:Located<IrInstruction> = new Located(ConstVoid(new IrValue(next++, "$optional-origin",
							Void)), terminator.provenance);
						var result = aggregate(target, typeName(value.id), partsAt(target, value.id, here), here);
						target.terminator = new Located(Return(result), terminator.provenance);
					case Throw(value) if (components.exists(value.id)):
						var here:Located<IrInstruction> = new Located(ConstVoid(new IrValue(next++, "$optional-origin",
							Void)), terminator.provenance);
						target.terminator = new Located(Throw(box(target, value, here)), terminator.provenance);
					case Rethrow(value) if (components.exists(value.id)):
						var here:Located<IrInstruction> = new Located(ConstVoid(new IrValue(next++, "$optional-origin",
							Void)), terminator.provenance);
						target.terminator = new Located(Rethrow(box(target, value, here)), terminator.provenance);
					default:
				}
		}
		for (id => reads in pendingReads) {
			var target:IrBlock = cast copies.get(id);
			for (read in reads)
				target.instructions.push(read);
		}
		var debug = [
			for (binding in fn.debugBindings)
				if (!components.exists(binding.value.id) && !alias.exists(binding.value.id)) binding
		];
		debug = IrInliner.substitute(blocks, substitutions, debug);
		// Remove unobserved static closures after their calls become direct. An
		// optimized-out debug binding does not keep an allocation alive.
		var used:Map<Int, Bool> = [], removed:Map<Int, Bool> = [];
		for (block in blocks) {
			for (located in block.instructions) {
				for (input in IrOperands.inputs(located.value))
					used.set(input.id, true);
				switch located.value {
					case Phi(_, inputs):
						for (input in inputs)
							used.set(input.value.id, true);
					default:
				}
			}
			if (block.terminator != null)
				switch block.terminator.value {
					case Return(v), Throw(v), Rethrow(v), Branch(v, _, _), Switch(v, _, _):
						used.set(v.id, true);
					case Jump(_), Unreachable:
				}
		}
		for (block in blocks) {
			var keep:Array<Located<IrInstruction>> = [];
			for (located in block.instructions)
				switch located.value {
					case StaticClosure(out, _) if (!used.exists(out.id)):
						removed.set(out.id, true);
					default:
						keep.push(located);
				}
			block.instructions.resize(0);
			for (located in keep)
				block.instructions.push(located);
		}
		debug = [for (binding in debug) if (!removed.exists(binding.value.id)) binding];
		var resultName = optional(fn.result), result = resultName == null ? fn.result : Obj(wrapper(resultName).name);
		return new IrFunction(clone ? PREFIX + fn.name : fn.name, args, result, blocks,
			clone ? OptionalScalar(fn.name) : fn.kind, debug, fn.inlineHint,
			clone ? compiler.ir.model.IrFunction.IrRetention.Reachable : fn.retention);
	}
}
