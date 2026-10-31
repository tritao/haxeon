package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.IrInlineValueLayout.IrInlineValueSlot;

/** Logical optional copies stay explicit until nonescaping value flow has been planned. */
class IrOptionalValueFlow {
	static inline final COPY_PREFIX = "$optional-value:copy:";
	static inline final BOX_PREFIX = "$optional-value:box:";
	static inline final UNBOX_PREFIX = "$optional-value:unbox:";
	public static function copyName(valueName:String):String return COPY_PREFIX + valueName;
	public static function isCopyName(name:String):Bool return StringTools.startsWith(name, COPY_PREFIX);
	public static function boxName(valueName:String):String return BOX_PREFIX + valueName;
	public static function unboxName(valueName:String):String return UNBOX_PREFIX + valueName;
	public static function isBoundaryHelper(name:String):Bool
		return StringTools.startsWith(name, BOX_PREFIX) || StringTools.startsWith(name, UNBOX_PREFIX);
	public static function samePath(left:Array<String>, right:Array<String>):Bool {
		if (left.length != right.length) return false;
		for (index in 0...left.length) if (left[index] != right[index]) return false;
		return true;
	}

	public static function addHelpers(functions:Array<IrFunction>, objects:Array<IrObject>):Array<IrFunction> {
		var declarations:Map<String, IrObject> = [for (object in objects) object.name => object];
		var needed:Map<String, Bool> = [], boxes:Map<String, Bool> = [], unboxes:Map<String, Bool> = [];
		for (fn in functions) for (block in fn.blocks) for (located in block.instructions) switch located.value {
			case Call(_, name, _) if (StringTools.startsWith(name, COPY_PREFIX)): needed.set(name.substr(COPY_PREFIX.length), true);
			case Call(_, name, _) if (StringTools.startsWith(name, BOX_PREFIX)): boxes.set(name.substr(BOX_PREFIX.length), true);
			case Call(_, name, _) if (StringTools.startsWith(name, UNBOX_PREFIX)): unboxes.set(name.substr(UNBOX_PREFIX.length), true);
			default:
		}
		var names = [for (name in needed.keys()) name];
		names.sort(Reflect.compare);
		var result = functions.copy();
		for (name in names) {
			var builder = new IrBuilder(), type:IrType = Nullable(Obj(name)), value = builder.argument("value", type);
			builder.returnValue(copyOptional(builder, value, name, declarations));
			result.push(new IrFunction(copyName(name), builder.arguments, type, builder.blocks));
		}
		var shapes = new IrInlineValueLayout(IrObjectTable.of(declarations));
		var allBoxes = [for (name in boxes.keys()) name]; allBoxes.sort(Reflect.compare);
		for (name in allBoxes) result.push(boxHelper(name, declarations, shapes));
		var allUnboxes = [for (name in unboxes.keys()) name]; allUnboxes.sort(Reflect.compare);
		for (name in allUnboxes) result.push(unboxHelper(name, declarations, shapes));
		return result;
	}

	static function boxHelper(name:String, objects:Map<String, IrObject>, shapes:IrInlineValueLayout):IrFunction {
		var builder = new IrBuilder(), wrapper = builder.argument("components", Obj(IrOptionalScalarFlow.wrapperName(name))),
			type:IrType = Nullable(Obj(name)), present = builder.createBlock(), absent = builder.createBlock(), done = builder.createBlock();
		builder.branch(builder.fieldGet(wrapper, "$slot0", Bool), present, absent);
		builder.select(absent);
		var nil = builder.constNull(type), absentBlock = builder.currentBlock(); builder.jump(done);
		builder.select(present);
		var slots = shapes.slots(type);
		function buildValue(valueName:String, path:Array<String>):IrValue {
			var value = builder.newObject(valueName), object = objects.get(valueName);
			if (object == null) throw 'Unknown optional value "$valueName"';
			for (field in object.fields) {
				var fieldPath = path.concat([field.name]);
				if (isOptionalValue(field.type, objects)) {
					for (index in 1...slots.length) {
						var slot = slots[index];
						if (slot.path.length < fieldPath.length || !samePath(slot.path.slice(0, fieldPath.length), fieldPath)) continue;
						var sub:IrInlineValueSlot = {path: slot.path.slice(fieldPath.length), type: slot.type, isPresence: slot.isPresence, nativeLayout: slot.nativeLayout};
						builder.fieldSet(value, IrInlineValueLayout.slotName(field.name, sub), builder.fieldGet(wrapper, "$slot" + index, slot.type));
					}
				} else switch field.type {
					case Obj(child) if (objects.exists(child) && objects.get(child).isValue):
						builder.fieldSet(value, field.name, buildValue(child, fieldPath));
					default:
						var found = false;
						for (index in 1...slots.length) {
							var slot = slots[index];
							if (!slot.isPresence && samePath(slot.path, fieldPath)) {
								builder.fieldSet(value, field.name, builder.fieldGet(wrapper, "$slot" + index, slot.type)); found = true; break;
							}
						}
						if (!found) throw 'Missing optional value slot ${fieldPath.join(".")}';
				}
			}
			return value;
		}
		var value = buildValue(name, []);
		var boxed = builder.toDyn(value, type), presentBlock = builder.currentBlock(); builder.jump(done);
		builder.select(done);
		builder.returnValue(builder.phi(type, [{block: absentBlock.id, value: nil}, {block: presentBlock.id, value: boxed}]));
		return new IrFunction(boxName(name), builder.arguments, type, builder.blocks);
	}

	static function unboxHelper(name:String, objects:Map<String, IrObject>, shapes:IrInlineValueLayout):IrFunction {
		var builder = new IrBuilder(), type:IrType = Nullable(Obj(name)), input = builder.argument("value", type),
			wrapper = builder.newObject(IrOptionalScalarFlow.wrapperName(name)), present = builder.createBlock(), done = builder.createBlock();
		builder.branch(builder.equal(input, builder.constNull(type)), done, present);
		builder.select(present);
		var source = builder.safeCast(input, Obj(name)), slots = shapes.slots(type);
		builder.fieldSet(wrapper, "$slot0", builder.constBool(true));
		for (index in 1...slots.length) {
			var slot = slots[index], current = source;
			for (partIndex in 0...slot.path.length) {
				var part = slot.path[partIndex], field = findField(objects, current.type, part), last = partIndex == slot.path.length - 1;
				if (isOptionalValue(field.type, objects)) {
					var sub:IrInlineValueSlot = {path: slot.path.slice(partIndex + 1), type: slot.type, isPresence: slot.isPresence, nativeLayout: slot.nativeLayout};
					builder.fieldSet(wrapper, "$slot" + index, builder.fieldGet(current, IrInlineValueLayout.slotName(part, sub), slot.type)); break;
				}
				var value = builder.fieldGet(current, part, field.type);
				if (last) builder.fieldSet(wrapper, "$slot" + index, value); else current = value;
			}
		}
		builder.jump(done); builder.select(done); builder.returnValue(wrapper);
		return new IrFunction(unboxName(name), builder.arguments, Obj(IrOptionalScalarFlow.wrapperName(name)), builder.blocks);
	}

	static function isOptionalValue(type:IrType, objects:Map<String, IrObject>):Bool return switch type {
		case Nullable(Obj(name)): objects.exists(name) && objects.get(name).isValue;
		default: false;
	};
	static function findField(objects:Map<String, IrObject>, type:IrType, field:String):IrObjectField {
		var name = switch type { case Obj(value): value; default: throw "Invalid optional value field"; };
		while (name != null) {
			var object = objects.get(name);
			if (object == null) break;
			for (candidate in object.fields) if (candidate.name == field) return candidate;
			name = object.base;
		}
		throw 'Missing optional value field "$field"';
	}

	static function copyOptional(builder:IrBuilder, value:IrValue, name:String, objects:Map<String, IrObject>):IrValue {
		var type:IrType = Nullable(Obj(name)), absent = builder.createBlock(), present = builder.createBlock(), done = builder.createBlock();
		builder.branch(builder.equal(value, builder.constNull(type)), absent, present);
		builder.select(absent);
		var nil = builder.constNull(type), absentBlock = builder.currentBlock();
		builder.jump(done);
		builder.select(present);
		var original = builder.safeCast(value, Obj(name));
		var clone = copyValue(builder, original, name, objects);
		var boxed = builder.toDyn(clone, type), presentBlock = builder.currentBlock();
		builder.jump(done);
		builder.select(done);
		return builder.phi(type, [{block: absentBlock.id, value: nil}, {block: presentBlock.id, value: boxed}]);
	}

	static function copyValue(builder:IrBuilder, source:IrValue, name:String, objects:Map<String, IrObject>):IrValue {
		var object = objects.get(name);
		if (object == null || !object.isValue) throw 'Unknown optional value "$name"';
		var copy = builder.newObject(name);
		for (field in object.fields) {
			var value = builder.fieldGet(source, field.name, field.type);
			switch field.type {
				case Obj(child) if (objects.exists(child) && objects.get(child).isValue): value = copyValue(builder, value, child, objects);
				case Nullable(Obj(child)) if (objects.exists(child) && objects.get(child).isValue): value = copyOptional(builder, value, child, objects);
				default:
			}
			builder.fieldSet(copy, field.name, value);
		}
		return copy;
	}
}
