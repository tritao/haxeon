package compiler.ir.passes.nullability;

import compiler.ir.model.IrBody;
import compiler.ir.model.IrBodyBuilder;
import compiler.ir.model.IrBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.passes.values.IrInlineValueLayout;
import compiler.ir.model.IrObjectTable;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrTypeIds;
import compiler.ir.model.TypeKey;
import compiler.core.InternalError;
import compiler.core.Provides.ProviderOperation;
import compiler.ir.model.Ir;
import compiler.ir.passes.values.IrInlineValueLayout.IrInlineValueSlot;

/** Logical optional copies stay explicit until nonescaping value flow has been planned. */
@:nullSafety(Strict)
class IrOptionalValueFlow {
	static inline final COPY_PREFIX = "$optional-value:copy:";
	static inline final BOX_PREFIX = "$optional-value:box:";
	static inline final UNBOX_PREFIX = "$optional-value:unbox:";

	public static function copyName(valueName:String):String
		return COPY_PREFIX + valueName;

	public static function isCopyName(name:String):Bool
		return StringTools.startsWith(name, COPY_PREFIX);

	public static function boxName(valueName:String):String
		return BOX_PREFIX + valueName;

	public static function unboxName(valueName:String):String
		return UNBOX_PREFIX + valueName;

	public static function isBoundaryHelper(name:String):Bool
		return StringTools.startsWith(name, BOX_PREFIX) || StringTools.startsWith(name, UNBOX_PREFIX);

	public static function samePath(left:Array<String>, right:Array<String>):Bool {
		if (left.length != right.length)
			return false;
		for (index in 0...left.length)
			if (left[index] != right[index])
				return false;
		return true;
	}

	/**
	 * `functions` followed by the copy, box and unbox helpers their calls name, built as functions. The calls are read from the
	 * functions' bodies made with `types` (those of the functions' bodies when not given), encoding a function that has none.
	 */
	public static function addHelpers(functions:Array<IrFunction>, objects:Array<IrObject>, ?types:IrTypeIds,
			?builder:IrBodyBuilder):Array<IrFunction> {
		if (types == null)
			types = IrTypeIds.ofFunctions(functions);
		var helpers = new IrOptionalHelpers();
		for (fn in functions)
			helpers.scan(fn.bodyIn(types, builder), null);
		return helpers.append(functions, objects);
	}

	/** The kind of the optional value helper `name` (`IrOptionalHelpers`), or -1 when it is not one. */
	public static function helperKind(name:String):Int
		return StringTools.startsWith(name, COPY_PREFIX) ? IrOptionalHelpers.COPY : StringTools.startsWith(name,
			BOX_PREFIX) ? IrOptionalHelpers.BOX : StringTools.startsWith(name, UNBOX_PREFIX)
			? IrOptionalHelpers.UNBOX : -1;

	/** The value class an optional value helper of kind `kind` named `name` is for. */
	public static function helperValue(kind:Int, name:String):String
		return name.substr((kind == IrOptionalHelpers.COPY ? COPY_PREFIX : kind == IrOptionalHelpers.BOX
			? BOX_PREFIX : UNBOX_PREFIX)
			.length);

	/** `functions` followed by the helpers of `needed`, `boxes` and `unboxes` (value class names), in name order of each. */
	public static function appendHelpers(functions:Array<IrFunction>, objects:Array<IrObject>, needed:Map<String, Bool>,
			boxes:Map<String, Bool>, unboxes:Map<String, Bool>):Array<IrFunction> {
		var declarations:Map<String, IrObject> = [for (object in objects) object.name => object];
		var names = [for (name in needed.keys()) name];
		names.sort(Reflect.compare);
		var result = functions.copy();
		for (name in names) {
			var builder = new IrBuilder(),
				type:IrType = Nullable(Obj(name)),
				value = builder.argument("value", type);
			builder.returnValue(copyOptional(builder, value, name, declarations));
			result.push(new IrFunction(copyName(name), builder.arguments, type, builder.blocks,
				Provider(TypeKey.of(Obj(name)), ProviderOperation.OptionalCopy)));
		}
		var shapes = new IrInlineValueLayout(IrObjectTable.of(declarations));
		var allBoxes = [for (name in boxes.keys()) name];
		allBoxes.sort(Reflect.compare);
		for (name in allBoxes)
			result.push(boxHelper(name, declarations, shapes));
		var allUnboxes = [for (name in unboxes.keys()) name];
		allUnboxes.sort(Reflect.compare);
		for (name in allUnboxes)
			result.push(unboxHelper(name, declarations, shapes));
		return result;
	}

	static function boxHelper(name:String, objects:Map<String, IrObject>, shapes:IrInlineValueLayout):IrFunction {
		var builder = new IrBuilder(),
			wrapper = builder.argument("components", Obj(IrOptionalScalarFlow.wrapperName(name))),
			type:IrType = Nullable(Obj(name)),
			present = builder.createBlock(),
			absent = builder.createBlock(),
			done = builder.createBlock();
		builder.branch(builder.fieldGet(wrapper, "$slot0", Bool), present, absent);
		builder.select(absent);
		var nil = builder.constNull(type),
			absentBlock = builder.currentBlock();
		builder.jump(done);
		builder.select(present);
		var slots = shapes.slots(type);
		function buildValue(valueName:String, path:Array<String>):IrValue {
			var value = builder.valueInit(valueName),
				object = objects.get(valueName);
			if (object == null)
				throw new InternalError('Unknown optional value "$valueName"');
			for (field in object.fields) {
				var fieldPath = path.concat([field.name]);
				if (isOptionalValue(field.type, objects)) {
					for (index in 1...slots.length) {
						var slot = slots[index];
						if (slot.path.length < fieldPath.length
							|| !samePath(slot.path.slice(0, fieldPath.length), fieldPath))
							continue;
						var sub:IrInlineValueSlot = {
							path: slot.path.slice(fieldPath.length),
							type: slot.type,
							isPresence: slot.isPresence,
							nativeLayout: slot.nativeLayout
						};
						builder.fieldSet(value, IrInlineValueLayout.slotName(field.name, sub),
							builder.fieldGet(wrapper, "$slot" + index, slot.type));
					}
				} else
					switch field.type {
						case Obj(child) if (isValueIn(child, objects)):
							builder.fieldSet(value, field.name, buildValue(child, fieldPath));
						default:
							var found = false;
							for (index in 1...slots.length) {
								var slot = slots[index];
								if (!slot.isPresence && samePath(slot.path, fieldPath)) {
									builder.fieldSet(value, field.name,
										builder.fieldGet(wrapper, "$slot" + index, slot.type));
									found = true;
									break;
								}
							}
							if (!found)
								throw new InternalError('Missing optional value slot ${fieldPath.join(".")}');
					}
			}
			return value;
		}
		var value = buildValue(name, []);
		var boxed = builder.toDyn(value, type),
			presentBlock = builder.currentBlock();
		builder.jump(done);
		builder.select(done);
		builder.returnValue(builder.phi(type, [
			{block: absentBlock.id, value: nil},
			{block: presentBlock.id, value: boxed}
		]));
		return new IrFunction(boxName(name), builder.arguments, type, builder.blocks,
			Provider(TypeKey.of(Obj(name)), ProviderOperation.OptionalBox));
	}

	static function unboxHelper(name:String, objects:Map<String, IrObject>, shapes:IrInlineValueLayout):IrFunction {
		var builder = new IrBuilder(),
			type:IrType = Nullable(Obj(name)),
			input = builder.argument("value", type),
			wrapper = builder.valueInit(IrOptionalScalarFlow.wrapperName(name)),
			present = builder.createBlock(),
			done = builder.createBlock();
		builder.branch(builder.equal(input, builder.constNull(type)), done, present);
		builder.select(present);
		var source = builder.safeCast(input, Obj(name)),
			slots = shapes.slots(type);
		builder.fieldSet(wrapper, "$slot0", builder.constBool(true));
		for (index in 1...slots.length) {
			var slot = slots[index], current = source;
			for (partIndex in 0...slot.path.length) {
				var part = slot.path[partIndex],
					field = findField(objects, current.type, part),
					last = partIndex == slot.path.length - 1;
				if (isOptionalValue(field.type, objects)) {
					var sub:IrInlineValueSlot = {
						path: slot.path.slice(partIndex + 1),
						type: slot.type,
						isPresence: slot.isPresence,
						nativeLayout: slot.nativeLayout
					};
					builder.fieldSet(wrapper, "$slot" + index,
						builder.fieldGet(current, IrInlineValueLayout.slotName(part, sub), slot.type));
					break;
				}
				var value = builder.fieldGet(current, part, field.type);
				if (last)
					builder.fieldSet(wrapper, "$slot" + index, value);
				else
					current = value;
			}
		}
		builder.jump(done);
		builder.select(done);
		builder.returnValue(wrapper);
		return new IrFunction(unboxName(name), builder.arguments, Obj(IrOptionalScalarFlow.wrapperName(name)),
			builder.blocks,
			Provider(TypeKey.of(Obj(name)), ProviderOperation.OptionalUnbox));
	}

	/** Whether `name` is a value class of `objects`. */
	static function isValueIn(name:String, objects:Map<String, IrObject>):Bool {
		var object = objects.get(name);
		return object != null && object.isValue;
	}

	static function isOptionalValue(type:IrType, objects:Map<String, IrObject>):Bool
		return switch type {
			case Nullable(Obj(name)):
				var object = objects.get(name);
				object != null && object.isValue;
			default: false;
		};

	static function findField(objects:Map<String, IrObject>, type:IrType, field:String):IrObjectField {
		var name:Null<String> = switch type {
			case Obj(value): value;
			default: throw new InternalError("Invalid optional value field");
		};
		while (name != null) {
			var object = objects.get(name);
			if (object == null)
				break;
			for (candidate in object.fields)
				if (candidate.name == field)
					return candidate;
			name = object.base;
		}
		throw new InternalError('Missing optional value field "$field"');
	}

	static function copyOptional(builder:IrBuilder, value:IrValue, name:String, objects:Map<String, IrObject>):IrValue {
		var type:IrType = Nullable(Obj(name)),
			absent = builder.createBlock(),
			present = builder.createBlock(),
			done = builder.createBlock();
		builder.branch(builder.equal(value, builder.constNull(type)), absent, present);
		builder.select(absent);
		var nil = builder.constNull(type),
			absentBlock = builder.currentBlock();
		builder.jump(done);
		builder.select(present);
		var original = builder.safeCast(value, Obj(name));
		var clone = copyValue(builder, original, name, objects);
		var boxed = builder.toDyn(clone, type),
			presentBlock = builder.currentBlock();
		builder.jump(done);
		builder.select(done);
		return builder.phi(type, [{block: absentBlock.id, value: nil}, {block: presentBlock.id, value: boxed}]);
	}

	static function copyValue(builder:IrBuilder, source:IrValue, name:String, objects:Map<String, IrObject>):IrValue {
		var object = objects.get(name);
		if (object == null || !object.isValue)
			throw new InternalError('Unknown optional value "$name"');
		var copy = builder.valueInit(name);
		for (field in object.fields) {
			var value = builder.fieldGet(source, field.name, field.type);
			switch field.type {
				case Obj(child) if (isValueIn(child, objects)):
					value = copyValue(builder, value, child, objects);
				case Nullable(Obj(child)) if (isValueIn(child, objects)):
					value = copyOptional(builder, value, child, objects);
				default:
			}
			builder.fieldSet(copy, field.name, value);
		}
		return copy;
	}
}

/** The optional value helpers a pass found called (`IrOptionalValueFlow.appendHelpers`), by kind and value class. */
@:nullSafety(Strict)
class IrOptionalHelpers {
	public static inline final COPY = 0;
	public static inline final BOX = 1;
	public static inline final UNBOX = 2;

	final copies:Map<String, Bool> = [];
	final boxes:Map<String, Bool> = [];
	final unboxes:Map<String, Bool> = [];

	public function new() {}

	public static function isHelper(name:String):Bool
		return IrOptionalValueFlow.helperKind(name) >= 0;

	/** The helper of `kind` for the value class `name` is called. */
	public function add(kind:Int, name:String):Void (kind == COPY ? copies : kind == BOX ? boxes : unboxes).set(name,
		true);

	/**
	 * The helpers `body` calls: asked for through `reader` when given (`IrFactReader.request`, which comes back to the pass that
	 * adds them), else added.
	 */
	public function scan(body:IrBody, reader:Null<compiler.ir.reuse.IrFactReader>):Void {
		var asked:Map<String, Bool> = [];
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (body.opcode(row) == IrOpcode.Call) {
					var name = body.symbol(row).name, kind = IrOptionalValueFlow.helperKind(name);
					if (kind >= 0) {
						var value = IrOptionalValueFlow.helperValue(kind, name);
						if (reader == null)
							add(kind, value);
						else if (!asked.exists(name)) {
							asked.set(name, true);
							reader.request(kind, Obj(value));
						}
					}
				}
				row = body.nextRow(row);
			}
		}
	}

	/** `functions` followed by the helpers found. */
	public function append(functions:Array<IrFunction>, objects:Array<IrObject>):Array<IrFunction>
		return IrOptionalValueFlow.appendHelpers(functions, objects, copies, boxes, unboxes);
}
