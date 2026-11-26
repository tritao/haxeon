package compiler.ir.passes.nullability;

import compiler.ir.model.IrBody;
import compiler.ir.model.IrBodyBuilder;
import compiler.ir.model.IrBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrObjectTable;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrOperands;
import compiler.ir.model.IrSymbol;
import compiler.ir.model.IrTypeIdentity;
import compiler.ir.model.IrValueId;
import compiler.ir.model.TypeKey;
import compiler.ir.passes.inlining.IrInliner;
import compiler.ir.passes.values.IrInlineValueLayout;
import compiler.ir.pipeline.IrFunctionIndex;
import compiler.ir.pipeline.IrFunctionPass;
import compiler.ir.pipeline.IrFunctionStages;
import compiler.ir.reuse.IrFactReader;
import compiler.ir.reuse.IrStageMemos;

import compiler.core.InternalError;
import compiler.core.Provides.ProviderOperation;
import compiler.core.Provides.ProviderOperations;
import compiler.ir.model.Ir;
import compiler.ir.model.SourceProvenance.Located;
import compiler.ir.passes.values.IrInlineValueLayout.IrInlineValueSlot;

private typedef OptionalFieldPlan = {
	final owner:String;
	final field:String;
	final type:IrType;
	final slots:Array<IrInlineValueSlot>;
}

private typedef OptionalMethodRequest = {
	final owner:String;
	final field:String;
	final method:String;
	final path:Array<String>;
}

/**
 * Plans inline optional fields and builds their storage accessors. Logical value copies are made only at the accessor
 * boundary; the holder itself contains a flag and recursively flattened payload slots, including managed references.
 *
 * Per function (`IrFunctionPass`): a rewrite reads, for each class whose fields it reads or writes, the plans along its bases
 * (`RECEIVER`), and asks for the value methods its calls specialize to a field path (`METHOD`). The accessors are derived from
 * their plan (`PLAN`), the specialized methods from the value method they clone and the value declarations (`DECLARATIONS`), so a
 * session reuses them too (`IrFunctionStages.derived`).
 */
@:nullSafety(Strict)
class IrOptionalFieldStorage extends IrFunctionPass {
	public static inline final STAGE = "optional-field-storage";

	// Facts.

	/** The plans along a class and its bases, by the class's name. */
	static inline final RECEIVER = 0;

	/** What a plan's accessors are made of (`planText`), by the plan's key. */
	static inline final PLAN = 1;

	/** The plans and the value objects' declarations, methods included: what a specialized method reads. */
	static inline final DECLARATIONS = 2;

	/** The kind of a request for a value method specialized to a field path, by its name. */
	static inline final METHOD = 0;

	// Summaries.
	static inline final ACCESSES = 1;

	final declarations:Array<IrObject>;
	final objects:Map<String, IrObject>;
	final layouts:IrInlineValueLayout;
	final stageMemos:Null<IrStageMemos>;
	var builder:Null<IrBodyBuilder>;

	/** The functions the stage is given, in program order: the value methods are specialized from them. */
	var originals:Array<IrFunction> = [];

	var originalIndex:Null<IrFunctionIndex> = null;

	/** The specialized methods asked for, in the order they were first asked for. */
	final methods:Array<String> = [];

	final asked:Map<String, Bool> = [];

	/** The plans by owner, then field: a lookup builds no key string. `key` is only for names and for the order plans are emitted in. */
	final plans:Map<String, Map<String, OptionalFieldPlan>> = [];

	var planCount = 0;

	/** The plans by `key`. */
	final byKey:Map<String, OptionalFieldPlan> = [];

	/** With `stageMemos`, the session's memo derives the helpers, and `builder` reads the bodies. */
	public function new(declarations:Array<IrObject>, ?stageMemos:IrStageMemos, ?builder:IrBodyBuilder) {
		this.declarations = declarations;
		this.stageMemos = stageMemos;
		this.builder = builder;
		objects = [for (object in declarations) object.name => object];
		layouts = new IrInlineValueLayout(IrObjectTable.of(objects));
		for (object in declarations)
			for (field in object.fields)
				switch field.type {
					case Nullable(Obj(name)) if (isValue(name)):
						addPlan({
							owner: object.name,
							field: field.name,
							type: field.type,
							slots: layouts.slots(field.type)
						});
					default:
				}
	}

	function addPlan(plan:OptionalFieldPlan):Void {
		var fields = plans.get(plan.owner);
		if (fields == null) {
			fields = [];
			plans.set(plan.owner, fields);
		}
		if (!fields.exists(plan.field))
			planCount++;
		fields.set(plan.field, plan);
		byKey.set(key(plan.owner, plan.field), plan);
	}

	function planFor(owner:String, field:String):Null<OptionalFieldPlan> {
		var fields = plans.get(owner);
		return fields == null ? null : fields.get(field);
	}

	public function hasFields():Bool
		return planCount > 0;

	/** Whether `declarations` have an optional value field to plan: a field of a nullable value object. */
	public static function hasPlans(declarations:Array<IrObject>):Bool {
		var values:Map<String, Bool> = [for (object in declarations) if (object.isValue) object.name => true];
		for (object in declarations)
			for (field in object.fields)
				switch field.type {
					case Nullable(Obj(name)) if (values.exists(name)):
						return true;
					default:
				}
		return false;
	}

	/** The physical field declarations; field order remains deterministic. */
	public function physicalObjects(declarations:Array<IrObject>):Array<IrObject> {
		return [for (object in declarations) {
			var fields:Array<IrObjectField> = [];
			for (field in object.fields) {
				var plan = planFor(object.name, field.name);
				if (plan == null)
					fields.push(field);
				else
					for (slot in plan.slots)
						fields.push({
							name: IrInlineValueLayout.slotName(field.name, slot),
							type: slot.type,
							nativeLayout: null,
							scalarStorage: slot.scalarStorage,
							nullableScalarStorage: slot.nullableScalarStorage
						});
			}
			{
				name:object.name,
					isValue:object.isValue,
					nativeLayout:object.nativeLayout,
					base:object.base,
					interfaces:object.interfaces,
					fields:fields,
					methods:object.methods
			};
		}];
	}

	/**
	 * Replace logical reads and writes, including generated reflection operations, with field-specific accessors, without a memo.
	 * On IR bodies (docs/design/IR_CORE_COLUMNS.md, migration):
	 * a function that changes becomes its edited body, owned by the next stage. The accessors and the value methods specialized
	 * to a field path are built as functions and encoded.
	 */
	public function rewrite(functions:Array<IrFunction>, ?builder:IrBodyBuilder):Array<IrFunction> {
		this.builder = builder;
		return IrFunctionStages.apply(STAGE, this, functions);
	}

	override public function summarize(fn:IrFunction):Int {
		var body = fn.encodedBody(builder);
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				switch body.opcode(row) {
					case IrOpcode.FieldGet, IrOpcode.FieldSet:
						return ACCESSES;
					case IrOpcode.Call:
						var name = body.symbol(row).name;
						if (StringTools.startsWith(name, COPY_PREFIX) || StringTools.startsWith(name, METHOD_PREFIX))
							return ACCESSES;
					default:
				}
				row = body.nextRow(row);
			}
		}
		return 0;
	}

	override public function prepare(functions:Array<IrFunction>, summaries:Array<Int>, names:IrFunctionIndex):Void
		originals = functions;

	override public function fact(kind:Int, key:String):Int {
		var known = stageMemos;
		if (known == null)
			return 0;
		return known.stageFacts.intern(switch kind {
			case RECEIVER: receiverText(key);
			case PLAN:
				var plan = byKey.get(key);
				plan == null ? "" : planText(plan);
			case _: declarationsText();
		});
	}

	override public function transform(fn:IrFunction, summary:Int, reader:IrFactReader):IrFunction
		return summary == 0 ? fn : rewritten(fn, reader);

	override public function request(kind:Int, type:IrType, name:Null<String>):Void
		if (name != null && !asked.exists(name)) {
			asked.set(name, true);
			methods.push(name);
		}

	/**
	 * The rewritten functions, then for each plan in key order its accessors and place getters and setters, then the value methods
	 * specialized to a field path, in the order they were asked for.
	 */
	override public function finish(functions:Array<IrFunction>):Array<IrFunction> {
		var all = functions.copy();
		var ordered = [for (fields in plans)
			for (plan in fields)
			{
				name: key(plan.owner, plan.field), plan: plan
			}];
		ordered.sort((a, b) -> Reflect.compare(a.name, b.name));
		for (entry in ordered) {
			var plan = entry.plan, planKey = entry.name;
			// A helper of `plan` named `name`, which `make` builds, rewritten as the program's functions are.
			function helper(name:String, make:() -> IrFunction):Void
				all.push(IrFunctionStages.derived(STAGE, name, this, IrFunctionStages.FROM_NAME, stageMemos, builder,
					reader -> {
						reader.read(PLAN, planKey);
						rewritten(make(), reader);
					}));
			helper(accessorName(plan, false), () -> accessor(plan, false));
			helper(accessorName(plan, true), () -> accessor(plan, true));
			var element = switch plan.type {
				case Nullable(Obj(value)): value;
				default: throw new InternalError("Invalid optional field plan");
			};
			var rootName = placeGetterName(plan.owner, plan.field, []);
			helper(rootName, () -> {
				var rootReader = new IrBuilder(),
					rootOwner = rootReader.argument("owner", Obj(plan.owner));
				rootReader.returnValue(readValue(rootReader, plan, rootOwner, Obj(element), []));
				new IrFunction(rootName, rootReader.arguments, Obj(element), rootReader.blocks,
					Provider(TypeKey.of(Obj(plan.owner)),
					ProviderOperations.detailed(ProviderOperation.OptionalFieldHelper, rootName)));
			});
			appendPlaceSetters(helper, plan, Obj(element), []);
		}
		var index = 0;
		while (index < methods.length) {
			var name = methods[index++], request = methodRequest(name);
			if (request == null)
				continue;
			var original = inputIndex().get(request.method);
			if (original == null)
				throw new InternalError('Missing value method "${request.method}" for optional field');
			var known = stageMemos, input = known == null ? 0 : original.version, method:IrFunction = original;
			all.push(IrFunctionStages.derived(STAGE, name, this, input, stageMemos, builder,
				reader -> {
					reader.read(DECLARATIONS, "");
					rewritten(specializeMethod(name, request, method), reader);
				}));
		}
		return all;
	}

	/** The functions the stage was given, by name: a value method is specialized from its form before this stage. */
	function inputIndex():IrFunctionIndex {
		var known = originalIndex;
		if (known == null)
			originalIndex = known = new IrFunctionIndex(STAGE, originals);
		return known;
	}

	/**
	 * `fn` with its reads and writes of planned fields and its optional field copies replaced by accessor calls, reading the plans of
	 * the classes it accesses through `reader` and asking for the specialized methods it calls; `fn` itself when it has none.
	 */
	function rewritten(fn:IrFunction, reader:IrFactReader):IrFunction {
		var body = fn.encodedBody(builder), changes = false, specialized:Null<Map<String, Bool>> = null;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				switch body.opcode(row) {
					case IrOpcode.Call:
						var name = body.symbol(row).name;
						if (StringTools.startsWith(name, COPY_PREFIX)) {
							var fields:Array<String> = haxe.Json.parse(name.substr(COPY_PREFIX.length));
							if (fields.length == 4) {
								reader.read(RECEIVER, fields[0]);
								reader.read(RECEIVER, fields[2]);
							}
							changes = true;
						} else if (StringTools.startsWith(name, METHOD_PREFIX)) {
							var known = specialized;
							if (known == null)
								specialized = known = [];
							if (!known.exists(name)) {
								known.set(name, true);
								reader.request(METHOD, Void, name);
							}
						}
					case IrOpcode.FieldGet, IrOpcode.FieldSet:
						switch body.valueType(body.operand(row, 0)) {
							case Obj(owner):
								reader.read(RECEIVER, owner);
								if (find(Obj(owner), body.symbol(row).name) != null)
									changes = true;
							default:
						}
					default:
				}
				row = body.nextRow(row);
			}
		}
		if (!changes)
			return fn;
		var edited = body.forEditing(builder);
		rewriteBody(edited);
		return IrFunction.ofOwnedBody(edited);
	}

	/** The text of the plans along `name` and its bases: what `find` reads of a class. */
	function receiverText(name:String):String {
		var parts:Array<String> = [], current:Null<String> = name;
		while (current != null) {
			var fields = plans.get(current);
			if (fields != null) {
				var names = [for (field in fields.keys()) field];
				names.sort(Reflect.compare);
				for (field in names) {
					var plan = fields.get(field);
					if (plan != null)
						parts.push(planText(plan));
				}
			}
			var object = objects.get(current);
			current = object == null ? null : object.base;
			if (current != null)
				parts.push('base $current');
		}
		return parts.join("\n");
	}

	/** The text of what `plan`'s accessors are made of: its slots and the declarations of the values it holds. */
	function planText(plan:OptionalFieldPlan):String {
		var parts = ['plan ${plan.owner} ${plan.field} ${IrTypeIdentity.text(plan.type)}'];
		for (slot in plan.slots)
			parts.push('slot ${slot.path.join(".")} ${IrTypeIdentity.text(slot.type)} ${slot.isPresence} '
				+ '${Std.string(slot.nativeLayout)} ${Std.string(slot.scalarStorage)} ${Std.string(slot.nullableScalarStorage)}');
		var seen:Map<String, Bool> = [];
		function values(type:IrType):Void
			switch type {
				case Obj(name), Nullable(Obj(name)) if (isValue(name) && !seen.exists(name)):
					seen.set(name, true);
					var object = objects.get(name);
					if (object != null)
						for (field in object.fields) {
							parts.push('value $name ${field.name} ${IrTypeIdentity.text(field.type)}');
							values(field.type);
						}
				default:
			}
		values(plan.type);
		return parts.join("\n");
	}

	/** The text of every plan and of the value objects' declarations, their methods included. */
	function declarationsText():String {
		var parts = [IrInlineValueLayout.valueDeclarations(declarations)];
		for (object in declarations)
			if (object.isValue)
				for (method in object.methods)
					parts.push('method ${object.name} ${method.name} ${method.functionName.name}');
		var keys = [for (fields in plans) for (plan in fields) plan];
		keys.sort((a, b) -> Reflect.compare(key(a.owner, a.field), key(b.owner, b.field)));
		for (plan in keys)
			parts.push(planText(plan));
		return parts.join("\n");
	}

	/** Clone a value method with its receiver represented by an owner and field path. */
	function specializeMethod(name:String, request:OptionalMethodRequest, fn:IrFunction):IrFunction {
		var plan = planFor(request.owner, request.field);
		if (plan == null || fn.arguments.length == 0)
			throw new InternalError('Invalid optional method specialization "$name"');
		var receiver = fn.arguments[0],
			next = fn.nextValueId(),
			owner = new IrValue(next++, "$optional-owner", Obj(request.owner)),
			aliases:Map<Int, Array<String>> = [receiver.id => request.path];
		// The path of a value a guard found among the aliases.
		function aliasPath(id:Int):Array<String> {
			var path = aliases.get(id);
			if (path == null)
				throw new InternalError('Missing optional field place alias $id');
			return path;
		}
		// A receiver projection remains a place across SSA blocks. A cast only unwraps a nullable projection; the original
		// null check remains in the cloned body.
		var changed = true;
		while (changed) {
			changed = false;
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case FieldGet(out, object,
							field) if (aliases.exists(object.id) && isComposite(out.type) && !aliases.exists(out.id)):
							aliases.set(out.id, aliasPath(object.id).concat([field]));
							changed = true;
						case SafeCast(out,
							value) if (aliases.exists(value.id) && isComposite(out.type) && !aliases.exists(out.id)):
							aliases.set(out.id, aliasPath(value.id));
							changed = true;
						default:
					}
		}
		var blocks:Array<IrBlock> = [];
		for (blockIndex in 0...fn.blocks.length) {
			var block = fn.blocks[blockIndex], target = new IrBlock(block.id);
			if (blockIndex == 0)
				target.instructions
					.push(new Located(Call(receiver, IrSymbol.of(getterFor(plan, request.path, receiver.type)),
					[owner]),
					compiler.ir.model.SourceProvenance.generated("optional-method-receiver")));
			for (located in block.instructions) {
				var instruction = located.value, handled = false;
				switch instruction {
					case FieldGet(out, object, field) if (aliases.exists(object.id)):
						var nested = nestedPhysicalField(object.type, field),
							path = aliasPath(object.id).concat(nested == null ? [field] : nested.path);
						instruction = nested == null
							&& isComposite(out.type) ? Call(out, IrSymbol.of(getterFor(plan, path, out.type)),
							[owner]) : FieldGet(out, owner, physical(plan, path, nested != null && nested.presence));
						handled = true;
					case FieldSet(object, field, value) if (aliases.exists(object.id)):
						var nested = nestedPhysicalField(object.type, field),
							path = aliasPath(object.id).concat(nested == null ? [field] : nested.path),
							actual = materializeAlias(value, aliases, plan, owner, target, located, next);
						next = actual.next;
						if (nested == null && isComposite(value.type)) {
							var unused = new IrValue(next++, "$optional-place-write", Void);
							instruction = Call(unused, IrSymbol.of(placeSetterName(plan.owner, plan.field, path)), [
								owner,
								actual.value
							]);
						} else
							instruction = FieldSet(owner, physical(plan, path, nested != null && nested.presence),
								actual.value);
						handled = true;
					case MethodCall(out, object, method, arguments, _) if (aliases.exists(object.id)):
						var resolved = methodName(object.type, method),
							args:Array<IrValue> = [owner];
						for (argument in arguments) {
							var actual = materializeAlias(argument, aliases, plan, owner, target, located, next);
							next = actual.next;
							args.push(actual.value);
						}
						instruction = Call(out,
							IrSymbol.of(placeMethodName(plan.owner, plan.field, aliasPath(object.id), resolved)),
							args);
						handled = true;
					case Call(out, called, arguments)
						if (compiler.semantic.GeneratedNames.isSpecialization(called.name) && arguments.length > 0
						&& aliases.exists(arguments[0].id)):
						var args:Array<IrValue> = [owner];
						for (argument in arguments.slice(1)) {
							var actual = materializeAlias(argument, aliases, plan, owner, target, located, next);
							next = actual.next;
							args.push(actual.value);
						}
						instruction = Call(out,
							IrSymbol.of(placeMethodName(plan.owner, plan.field, aliasPath(arguments[0].id),
							called.name)), args);
						handled = true;
					default:
				}
				if (!handled) {
					var substitutions:Map<Int, IrValue> = [];
					for (input in IrOperands.inputs(instruction))
						if (aliases.exists(input.id) && !substitutions.exists(input.id)) {
							var actual = materializeAlias(input, aliases, plan, owner, target, located, next);
							next = actual.next;
							substitutions.set(input.id, actual.value);
						}
					if (substitutions.keys().hasNext())
						instruction = IrInliner.remap(instruction,
							value -> substitutions.get(value.id) ?? value, id -> id);
				}
				target.instructions.push(new Located(instruction, located.provenance));
			}
			var terminator = block.terminator;
			if (terminator != null) {
				var terminalValue = switch terminator.value {
					case Return(value), Throw(value), Rethrow(value), Branch(value, _, _), Switch(value, _, _): value;
					default: null;
				};
				if (terminalValue != null && aliases.exists(terminalValue.id)) {
					var anchor = new Located(ConstVoid(new IrValue(-1, "", Void)), terminator.provenance),
						actual = materializeAlias(terminalValue, aliases, plan, owner, target, anchor, next);
					next = actual.next;
					var mapped = switch terminator.value {
						case Return(_): Return(actual.value);
						case Throw(_): Throw(actual.value);
						case Rethrow(_): Rethrow(actual.value);
						case Branch(_, yes, no): Branch(actual.value, yes, no);
						case Switch(switchValue, switchTargets, switchOtherwise): Switch(actual.value,
							switchTargets.copy(), switchOtherwise);
						default: terminator.value;
					};
					terminator = new Located(mapped, terminator.provenance);
				}
			}
			target.terminator = terminator;
			blocks.push(target);
		}
		return new IrFunction(name, [owner].concat(fn.arguments.slice(1)), fn.result, blocks,
			Provider(TypeKey.of(owner.type), ProviderOperations.detailed(ProviderOperation.OptionalFieldHelper, name)),
			[], fn.inlineHint);
	}

	function materializeAlias(value:IrValue, aliases:Map<Int, Array<String>>, plan:OptionalFieldPlan, owner:IrValue,
			target:IrBlock,
			located:Located<IrInstruction>, next:Int):{
				value:IrValue,
				next:Int
			} {
		var path = aliases.get(value.id);
		if (path == null)
			return {value: value, next: next};
		var result = new IrValue(next++, "$optional-place-value", value.type);
		target.instructions.push(new Located(Call(result, IrSymbol.of(getterFor(plan, path, value.type)), [owner]),
			located.provenance));
		return {value: result, next: next};
	}

	function getterFor(plan:OptionalFieldPlan, path:Array<String>, requested:IrType):String {
		if (path.length == 0)
			return placeGetterName(plan.owner, plan.field, path);
		var declared = pathType(plan, path);
		return switch [declared, requested] {
			case [Nullable(Obj(name)), Obj(other)] if (name == other): placeUnwrappedGetterName(plan.owner, plan.field,
				path);
			default: placeGetterName(plan.owner, plan.field, path);
		};
	}

	function pathType(plan:OptionalFieldPlan, path:Array<String>):IrType {
		var type = plan.type;
		for (part in path) {
			var name = switch type {
				case Obj(value), Nullable(Obj(value)): value;
				default: throw new InternalError('Invalid optional field path at "$part"');
			};
			var object = objects.get(name), found:Null<IrType> = null;
			if (object == null)
				throw new InternalError('Missing optional field path object "$name"');
			for (field in object.fields)
				if (field.name == part)
					found = field.type;
			if (found == null)
				throw new InternalError('Missing optional field path "$name.$part"');
			type = found;
		}
		return type;
	}

	function methodName(type:IrType, method:String):String {
		var name:Null<String> = switch type {
			case Obj(value): value;
			default: throw new InternalError('Invalid value method receiver');
		};
		while (name != null) {
			var object = objects.get(name);
			if (object == null)
				break;
			for (entry in object.methods)
				if (entry.name == method)
					return entry.functionName.name;
			name = object.base;
		}
		throw new InternalError('Unknown value method "$method"');
	}

	/** Translate an already-lowered nested optional slot through a specialized receiver. */
	function nestedPhysicalField(type:IrType, physicalName:String):Null<{path:Array<String>, presence:Bool}> {
		var name = switch type {
			case Obj(value): value;
			default: return null;
		}, object = objects.get(name);
		if (object == null)
			return null;
		for (field in object.fields) {
			var plan = planFor(name, field.name);
			if (plan != null)
				for (slot in plan.slots)
					if (IrInlineValueLayout.slotName(field.name, slot) == physicalName)
						return {path: [field.name].concat(slot.path), presence: slot.isPresence};
		}
		return null;
	}

	/** The place getters and setters of `plan` below `path`, each made through `helper` by its name. */
	function appendPlaceSetters(helper:(String, () -> IrFunction) -> Void, plan:OptionalFieldPlan, type:IrType,
			path:Array<String>):Void {
		switch type {
			case Nullable(Obj(name)) if (isValue(name)):
				appendPlaceSetters(helper, plan, Obj(name), path);
			case Obj(name) if (isValue(name)):
				var object = objects.get(name);
				if (object == null)
					throw new InternalError('Missing value object "$name"');
				for (field in object.fields) {
					var childPath = path.concat([field.name]);
					if (isComposite(field.type)) {
						var getter = placeGetterName(plan.owner, plan.field, childPath);
						helper(getter, () -> {
							var reader = new IrBuilder(),
								source = reader.argument("owner", Obj(plan.owner));
							reader.returnValue(readValue(reader, plan, source, field.type, childPath));
							new IrFunction(getter, reader.arguments, field.type, reader.blocks,
								Provider(TypeKey.of(Obj(plan.owner)),
								ProviderOperations.detailed(ProviderOperation.OptionalFieldHelper, getter)));
						});
						switch field.type {
							case Nullable(Obj(child)) if (isValue(child)):
								var unwrappedGetter = placeUnwrappedGetterName(plan.owner, plan.field, childPath);
								helper(unwrappedGetter, () -> {
									var unwrapped = new IrBuilder(),
										sourceOwner = unwrapped.argument("owner", Obj(plan.owner));
									unwrapped.returnValue(readValue(unwrapped, plan, sourceOwner, Obj(child),
										childPath));
									new IrFunction(unwrappedGetter, unwrapped.arguments, Obj(child), unwrapped.blocks,
										Provider(TypeKey.of(Obj(plan.owner)),
										ProviderOperations.detailed(ProviderOperation.OptionalFieldHelper,
										unwrappedGetter)));
								});
							default:
						}
						var setter = placeSetterName(plan.owner, plan.field, childPath);
						helper(setter, () -> {
							var builder = new IrBuilder(),
								owner = builder.argument("owner", Obj(plan.owner)),
								value = builder.argument("value", field.type);
							writeValue(builder, plan, owner, field.type, childPath, value);
							builder.returnValue(builder.constVoid());
							new IrFunction(setter, builder.arguments, Void, builder.blocks,
								Provider(TypeKey.of(Obj(plan.owner)),
								ProviderOperations.detailed(ProviderOperation.OptionalFieldHelper, setter)));
						});
					}
					appendPlaceSetters(helper, plan, field.type, childPath);
				}
			default:
		}
	}

	function isComposite(type:IrType):Bool
		return switch type {
			case Obj(name), Nullable(Obj(name)): isValue(name);
			default: false;
		};

	/** Rewrites `body` in place. */
	function rewriteBody(body:IrBody):Void {
		// A new value of `type` that `operation` makes from `input`, linked before `row`.
		function linkUnary(block:Int, row:Int, operation:IrOpcode, label:String, type:IrType, input:IrValueId,
				aux:Int):IrValueId {
			var made = body.newValue(label, body.typeId(type));
			body.beginRow();
			body.pushOperand(input);
			body.linkBefore(block, row, body.endRow(operation, made, aux, body.provenance(row)));
			return made;
		}
		// `row` replaced by a call of `name` with `operands` and the output `output`.
		function replaceByCall(block:Int, row:Int, output:IrValueId, name:String, operands:Array<IrValueId>):Void {
			body.beginRow();
			for (operand in operands)
				body.pushOperand(operand);
			body.linkBefore(block, row, body.endRow(IrOpcode.Call, output, IrSymbol.of(name).id, body.provenance(row)));
			body.removeRow(block, row);
		}
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var following = body.nextRow(row);
				switch body.opcode(row) {
					case IrOpcode.Call if (StringTools.startsWith(body.symbol(row).name, COPY_PREFIX)):
						var name = body.symbol(row).name, out = body.output(row);
						var fields:Array<String> = haxe.Json.parse(name.substr(COPY_PREFIX.length));
						if (fields.length != 4 || body.operandCount(row) != 2 || (switch body.valueType(out) {
							case Void: false;
							default: true;
						}))
							throw new InternalError('Invalid optional field copy "$name"');
						var target = planFor(fields[0], fields[1]),
							source = planFor(fields[2], fields[3]);
						if (target == null || source == null)
							throw new InternalError('Incompatible optional field copy "$name"');
						if (!Type.enumEq(target.type, source.type)
							|| target.slots.length != source.slots.length)
							throw new InternalError('Incompatible optional field copy "$name"');
						var destination = body.operand(row, 0),
							origin = body.operand(row, 1),
							where = body.provenance(row);
						if (!Type.enumEq(body.valueType(destination), Obj(target.owner)))
							destination = linkUnary(block, row, IrOpcode.Upcast, "$optional-copy-target",
								Obj(target.owner),
								destination, 0);
						if (!Type.enumEq(body.valueType(origin), Obj(source.owner)))
							origin = linkUnary(block, row, IrOpcode.Upcast, "$optional-copy-source", Obj(source.owner),
								origin, 0);
						var snapshot:Array<IrValueId> = [];
						for (slot in source.slots)
							snapshot.push(linkUnary(block, row, IrOpcode.FieldGet, "$optional-copy-slot", slot.type,
								origin,
								IrSymbol.of(IrInlineValueLayout.slotName(source.field, slot)).id));
						for (index in 0...target.slots.length) {
							body.beginRow();
							body.pushOperand(destination);
							body.pushOperand(snapshot[index]);
							body.linkBefore(block, row, body.endRow(IrOpcode.FieldSet, IrValueId.of(-1),
								IrSymbol.of(IrInlineValueLayout.slotName(target.field, target.slots[index])).id,
								where));
						}
						body.beginRow();
						body.linkBefore(block, row, body.endRow(IrOpcode.ConstVoid, out, 0, where));
						body.removeRow(block, row);
					case IrOpcode.FieldGet:
						var object = body.operand(row, 0), plan = find(body.valueType(object), body.symbol(row).name);
						if (plan != null) {
							var receiver = object;
							if (!Type.enumEq(body.valueType(object), Obj(plan.owner)))
								receiver = linkUnary(block, row, IrOpcode.Upcast, "$optional-field-base",
									Obj(plan.owner),
									object, 0);
							replaceByCall(block, row, body.output(row), accessorName(plan, false), [receiver]);
						}
					case IrOpcode.FieldSet:
						var object = body.operand(row, 0), plan = find(body.valueType(object), body.symbol(row).name);
						if (plan != null) {
							var receiver = object, value = body.operand(row, 1);
							if (!Type.enumEq(body.valueType(object), Obj(plan.owner)))
								receiver = linkUnary(block, row, IrOpcode.Upcast, "$optional-field-base",
									Obj(plan.owner),
									object, 0);
							var unused = body.newValue("$optional-field-write", body.typeId(Void));
							replaceByCall(block, row, unused, accessorName(plan, true), [receiver, value]);
						}
					default:
				}
				row = following;
			}
		}
	}

	function accessor(plan:OptionalFieldPlan, write:Bool):IrFunction {
		var builder = new IrBuilder(),
			owner = builder.argument("owner", Obj(plan.owner));
		if (write) {
			var value = builder.argument("value", plan.type);
			writeValue(builder, plan, owner, plan.type, [], value);
			builder.returnValue(builder.constVoid());
		} else
			builder.returnValue(readValue(builder, plan, owner, plan.type, []));
		return new IrFunction(accessorName(plan, write), builder.arguments, write ? Void : plan.type, builder.blocks,
			Provider(TypeKey.of(Obj(plan.owner)),
			ProviderOperations.detailed(ProviderOperation.OptionalFieldHelper, accessorName(plan, write))));
	}

	function readValue(builder:IrBuilder, plan:OptionalFieldPlan, owner:IrValue, type:IrType,
			path:Array<String>):IrValue {
		return switch type {
			case Nullable(Obj(name)) if (isValue(name)):
				var present = builder.fieldGet(owner, physical(plan, path, true), Bool),
					yes = builder.createBlock(),
					no = builder.createBlock(),
					done = builder.createBlock();
				builder.branch(present, yes, no);
				builder.select(no);
				var absentValue = builder.constNull(type),
					absentBlock = builder.currentBlock();
				builder.jump(done);
				builder.select(yes);
				var value = readValue(builder, plan, owner, Obj(name), path),
					wrapped = builder.toDyn(value, type),
					presentBlock = builder.currentBlock();
				builder.jump(done);
				builder.select(done);
				builder.phi(type, [
					{block: absentBlock.id, value: absentValue},
					{block: presentBlock.id, value: wrapped}
				]);
			case Obj(name) if (isValue(name)):
				var value = builder.valueInit(name),
					object = objects.get(name);
				if (object == null)
					throw new InternalError('Missing value object "$name"');
				for (field in object.fields)
					builder.fieldSet(value, field.name,
						readValue(builder, plan, owner, field.type, path.concat([field.name])));
				value;
			default:
				builder.fieldGet(owner, physical(plan, path, false), type);
		};
	}

	function writeValue(builder:IrBuilder, plan:OptionalFieldPlan, owner:IrValue, type:IrType, path:Array<String>,
			value:IrValue):Void {
		switch type {
			case Nullable(Obj(name)) if (isValue(name)):
				var missing = builder.createBlock(),
					present = builder.createBlock(),
					done = builder.createBlock();
				builder.branch(builder.equal(value, builder.constNull(type)), missing, present);
				builder.select(missing);
				zeroSlots(builder, plan, owner, path);
				builder.jump(done);
				builder.select(present);
				builder.fieldSet(owner, physical(plan, path, true), builder.constBool(true));
				writeValue(builder, plan, owner, Obj(name), path, builder.safeCast(value, Obj(name)));
				builder.jump(done);
				builder.select(done);
			case Obj(name) if (isValue(name)):
				var object = objects.get(name);
				if (object == null)
					throw new InternalError('Missing value object "$name"');
				for (field in object.fields)
					writeValue(builder, plan, owner, field.type, path.concat([field.name]),
						builder.fieldGet(value, field.name, field.type));
			default:
				builder.fieldSet(owner, physical(plan, path, false), value);
		}
	}

	function zeroSlots(builder:IrBuilder, plan:OptionalFieldPlan, owner:IrValue, prefix:Array<String>):Void {
		for (slot in plan.slots) {
			if (prefix.length > slot.path.length)
				continue;
			var within = true;
			for (index in 0...prefix.length)
				if (slot.path[index] != prefix[index])
					within = false;
			if (within)
				builder.fieldSet(owner, IrInlineValueLayout.slotName(plan.field, slot), zero(builder, slot.type));
		}
	}

	static function zero(builder:IrBuilder, type:IrType):IrValue
		return switch type {
			case Bool: builder.constBool(false);
			case I32, I64: builder.constInt(0, type);
			case F32, F64: builder.constFloat(0, type);
			default: builder.constNull(type);
		};

	function find(type:IrType, field:String):Null<OptionalFieldPlan> {
		var name:Null<String> = switch type {
			case Obj(value): value;
			default: return null;
		};
		while (name != null) {
			var plan = planFor(name, field);
			if (plan != null)
				return plan;
			var object = objects.get(name);
			name = object == null ? null : object.base;
		}
		return null;
	}

	function isValue(name:String):Bool {
		var object = objects.get(name);
		return object != null && object.isValue;
	}

	static function key(owner:String, field:String):String
		return owner.length + ":" + owner + ":" + field;

	static inline final COPY_PREFIX = "$optional-field:copy:";

	public static function isCopyName(name:String):Bool
		return StringTools.startsWith(name, COPY_PREFIX);

	public static function copyName(targetOwner:String, targetField:String, sourceOwner:String,
			sourceField:String):String
		return COPY_PREFIX + haxe.Json.stringify([targetOwner, targetField, sourceOwner, sourceField]);

	public static function placeSetterName(owner:String, field:String, path:Array<String>):String {
		var name = "$optional-field:place-set:" + key(owner, field);
		for (part in path)
			name += ":" + part.length + ":" + part;
		return name;
	}

	public static function placeGetterName(owner:String, field:String, path:Array<String>):String {
		var name = "$optional-field:place-get:" + key(owner, field);
		for (part in path)
			name += ":" + part.length + ":" + part;
		return name;
	}

	public static function placeUnwrappedGetterName(owner:String, field:String, path:Array<String>):String
		return placeGetterName(owner, field, path) + ":unwrapped";

	static inline final METHOD_PREFIX = "$optional-field:method:";

	public static function placeMethodName(owner:String, field:String, path:Array<String>, method:String):String
		return METHOD_PREFIX + haxe.Json.stringify([owner, field, method].concat(path));

	/** The value method a call to `name` asks this pass to specialize, or null when `name` is no such request: the typed demand a reachability walk reads. */
	public static function requestedMethod(name:String):Null<String> {
		var request = methodRequest(name);
		return request == null ? null : request.method;
	}

	static function methodRequest(name:String):Null<OptionalMethodRequest> {
		if (!StringTools.startsWith(name, METHOD_PREFIX))
			return null;
		var components:Array<String> = cast haxe.Json.parse(name.substr(METHOD_PREFIX.length));
		if (components.length < 3)
			throw new InternalError('Invalid optional method specialization "$name"');
		return {
			owner: components[0],
			field: components[1],
			method: components[2],
			path: components.slice(3)
		};
	}

	static function accessorName(plan:OptionalFieldPlan, write:Bool):String
		return "$optional-field:" + (write ? "set:" : "get:") + key(plan.owner, plan.field);

	static function physical(plan:OptionalFieldPlan, path:Array<String>, presence:Bool):String
		return IrInlineValueLayout.slotName(plan.field, {
			path: path,
			type: presence ? Bool : Void,
			isPresence: presence,
			nativeLayout: null
		});
}
