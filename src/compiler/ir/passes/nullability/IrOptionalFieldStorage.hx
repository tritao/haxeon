package compiler.ir.passes.nullability;

import compiler.ir.model.IrBody;
import compiler.ir.model.IrBodyBuilder;
import compiler.ir.model.IrBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrObjectTable;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrOperands;
import compiler.ir.model.IrSymbol;
import compiler.ir.model.IrTypeIds;
import compiler.ir.model.IrValueId;
import compiler.ir.model.TypeKey;
import compiler.ir.passes.inlining.IrInliner;
import compiler.ir.passes.values.IrInlineValueLayout;
import compiler.ir.pipeline.IrFunctionIndex;

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
 */
@:nullSafety(Strict)
class IrOptionalFieldStorage {
	final objects:Map<String, IrObject>;
	final layouts:IrInlineValueLayout;

	/** The plans by owner, then field: a lookup builds no key string. `key` is only for names and for the order plans are emitted in. */
	final plans:Map<String, Map<String, OptionalFieldPlan>> = [];

	var planCount = 0;

	public function new(declarations:Array<IrObject>) {
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
	}

	function planFor(owner:String, field:String):Null<OptionalFieldPlan> {
		var fields = plans.get(owner);
		return fields == null ? null : fields.get(field);
	}

	public function hasFields():Bool
		return planCount > 0;

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
	 * Replace logical reads and writes, including generated reflection operations, with field-specific accessors. On IR bodies
	 * (docs/design/IR_CORE_COLUMNS.md, migration), made with `types` (those of the functions' bodies when not given): a function
	 * that changes becomes its edited body, owned by the next stage. The accessors and the value methods specialized to a field path (still cloned from their decoding) are built as
	 * functions and encoded.
	 */
	public function rewrite(functions:Array<IrFunction>, ?types:IrTypeIds, ?builder:IrBodyBuilder):Array<IrFunction> {
		if (types == null)
			types = IrTypeIds.ofFunctions(functions);
		var all = functions.copy();
		var ordered = [for (fields in plans)
			for (plan in fields)
			{
				name:key(plan.owner, plan.field), plan:plan
			}];
		ordered.sort((a, b) -> Reflect.compare(a.name, b.name));
		for (entry in ordered) {
			var plan = entry.plan;
			all.push(accessor(plan, false));
			all.push(accessor(plan, true));
			var element = switch plan.type {
				case Nullable(Obj(value)): value;
				default: throw new InternalError("Invalid optional field plan");
			};
			var rootReader = new IrBuilder(),
				rootOwner = rootReader.argument("owner", Obj(plan.owner));
			rootReader.returnValue(readValue(rootReader, plan, rootOwner, Obj(element), []));
			all.push(new IrFunction(placeGetterName(plan.owner, plan.field, []), rootReader.arguments, Obj(element),
				rootReader.blocks,
				Provider(TypeKey.of(Obj(plan.owner)),
				ProviderOperations.detailed(ProviderOperation.OptionalFieldHelper,
				placeGetterName(plan.owner, plan.field, [])))));
			appendPlaceSetters(all, plan, Obj(element), []);
		}
		var originals = new IrFunctionIndex("optional-field-storage", functions),
			generated:Map<String, Bool> = [];
		var index = 0;
		while (index < all.length) {
			var body = all[index++].bodyIn(types, builder);
			for (block in 0...body.blockCount()) {
				var row = body.firstRow(block);
				while (row >= 0) {
					if (body.opcode(row) == IrOpcode.Call) {
						var name = body.symbol(row).name, request = methodRequest(name);
						if (request != null && !generated.exists(name)) {
							generated.set(name, true);
							var original = originals.get(request.method);
							if (original == null)
								throw new InternalError('Missing value method "${request.method}" for optional field');
							all.push(specializeMethod(name, request, original));
						}
					}
					row = body.nextRow(row);
				}
			}
		}
		return [for (fn in all) {
			var body = fn.bodyIn(types, builder);
			if (needsRewrite(body)) {
				var edited = body.forEditing(builder);
				rewriteBody(edited);
				IrFunction.ofOwnedBody(edited);
			} else fn;
		}];
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

	function appendPlaceSetters(functions:Array<IrFunction>, plan:OptionalFieldPlan, type:IrType,
			path:Array<String>):Void {
		switch type {
			case Nullable(Obj(name)) if (isValue(name)):
				appendPlaceSetters(functions, plan, Obj(name), path);
			case Obj(name) if (isValue(name)):
				var object = objects.get(name);
				if (object == null)
					throw new InternalError('Missing value object "$name"');
				for (field in object.fields) {
					var childPath = path.concat([field.name]);
					if (isComposite(field.type)) {
						var reader = new IrBuilder(),
							source = reader.argument("owner", Obj(plan.owner));
						reader.returnValue(readValue(reader, plan, source, field.type, childPath));
						functions.push(new IrFunction(placeGetterName(plan.owner, plan.field, childPath),
							reader.arguments, field.type, reader.blocks,
							Provider(TypeKey.of(Obj(plan.owner)),
							ProviderOperations.detailed(ProviderOperation.OptionalFieldHelper,
							placeGetterName(plan.owner, plan.field, childPath)))));
						switch field.type {
							case Nullable(Obj(child)) if (isValue(child)):
								var unwrapped = new IrBuilder(),
									sourceOwner = unwrapped.argument("owner", Obj(plan.owner));
								unwrapped.returnValue(readValue(unwrapped, plan, sourceOwner, Obj(child), childPath));
								functions.push(new IrFunction(placeUnwrappedGetterName(plan.owner, plan.field,
									childPath), unwrapped.arguments, Obj(child),
									unwrapped.blocks,
									Provider(TypeKey.of(Obj(plan.owner)),
									ProviderOperations.detailed(ProviderOperation.OptionalFieldHelper,
									placeUnwrappedGetterName(plan.owner, plan.field, childPath)))));
							default:
						}
						var builder = new IrBuilder(),
							owner = builder.argument("owner", Obj(plan.owner)),
							value = builder.argument("value", field.type);
						writeValue(builder, plan, owner, field.type, childPath, value);
						builder.returnValue(builder.constVoid());
						functions.push(new IrFunction(placeSetterName(plan.owner, plan.field, childPath),
							builder.arguments, Void, builder.blocks,
							Provider(TypeKey.of(Obj(plan.owner)),
							ProviderOperations.detailed(ProviderOperation.OptionalFieldHelper,
							placeSetterName(plan.owner, plan.field, childPath)))));
					}
					appendPlaceSetters(functions, plan, field.type, childPath);
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

	function needsRewrite(body:IrBody):Bool {
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				switch body.opcode(row) {
					case IrOpcode.Call if (StringTools.startsWith(body.symbol(row).name, COPY_PREFIX)):
						return true;
					case IrOpcode.FieldGet, IrOpcode.FieldSet:
						if (find(body.valueType(body.operand(row, 0)), body.symbol(row).name) != null)
							return true;
					default:
				}
				row = body.nextRow(row);
			}
		}
		return false;
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
