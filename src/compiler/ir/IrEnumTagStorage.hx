package compiler.ir;

import compiler.ir.Ir;

/** Nominal I32 storage is available only when the entire enum has no payload. */
@:access(compiler.ir.IrBuilder)
class IrEnumTagStorage {
	public static function eligible(declaration:IrEnum):Bool {
		for (constructor in declaration.cases)
			if (constructor.params.length != 0)
				return false;
		return true;
	}

	/** Assign opaque linkage while preserving adapters declared before new enum specializations appeared. */
	public static function adapterNames(program:IrProgram):Map<String, {box:String, unbox:String}> {
		var names = [for (entry in program.enums) if (eligible(entry)) entry.name];
		names.sort(Reflect.compare);
		var occupied:Map<String, Bool> = [], boxes:Map<String, String> = [], unboxes:Map<String, String> = [];
		for (fn in program.functions) {
			occupied.set(fn.name, true);
			switch fn.kind {
				case EnumTagAdapter(EnumTag(type), true): boxes.set(type, fn.name);
				case EnumTagAdapter(EnumTag(type), false): unboxes.set(type, fn.name);
				default:
			}
		}
		var nextBox = 0, nextUnbox = 0, result:Map<String, {box:String, unbox:String}> = [];
		for (name in names) {
			var box = boxes.get(name), unbox = unboxes.get(name);
			if (box == null) {
				do box = "$haxeon_enum_tag_box_" + nextBox++ while (occupied.exists(box));
				occupied.set(box, true);
			}
			if (unbox == null) {
				do unbox = "$haxeon_enum_tag_unbox_" + nextUnbox++ while (occupied.exists(unbox));
				occupied.set(unbox, true);
			}
			result.set(name, {box: box, unbox: unbox});
		}
		return result;
	}

	/** Request the checked boundary when a later helper introduces a tag escape. */
	public static function request(program:IrProgram, name:String):{box:String, unbox:String} {
		var symbols = adapterNames(program).get(name);
		if (symbols == null) throw 'Unknown enum tag adapter type "$name"';
		var box = symbols.box, unbox = symbols.unbox;
		var foundBox = false, foundUnbox = false;
		for (fn in program.functions) switch fn.kind {
			case EnumTagAdapter(EnumTag(actual), true) if (actual == name): box = fn.name; foundBox = true;
			case EnumTagAdapter(EnumTag(actual), false) if (actual == name): unbox = fn.name; foundUnbox = true;
			default:
		}
		if (!foundBox || !foundUnbox) {
			var declaration = Lambda.find(program.enums, entry -> entry.name == name);
			for (fn in adapters(declaration, box, unbox)) switch fn.kind {
				case EnumTagAdapter(_, true) if (!foundBox): program.functions.push(fn);
				case EnumTagAdapter(_, false) if (!foundUnbox): program.functions.push(fn);
				default:
			}
		}
		if (!Lambda.exists(program.natives, native -> native.name == "__std_is_exact_type"))
			program.natives.push({name: "__std_is_exact_type", library: "haxeon_runtime", symbol: "__std_is_exact_type", arguments: [Dyn, TypeRef], result: Bool});
		return {box: box, unbox: unbox};
	}

	/** Only these adapters materialize the nominal boxed carrier at an escape. */
	public static function adapters(declaration:IrEnum, boxName:String, unboxName:String):Array<IrFunction> {
		if (!eligible(declaration))
			throw 'Cannot tag-store enum "${declaration.name}" with payloads';
		var name = declaration.name,
			storage:IrType = EnumTag(name),
			box = new IrBuilder(),
			value = box.argument("value", storage),
			tag = box.call(IrScalarWordBits.PACK, [value], I32),
			absent = box.createBlock(),
			present = box.createBlock();
		box.branch(box.equal(tag, box.constInt(0)), absent, present);
		box.select(absent);
		box.returnValue(box.constNull(Dyn));
		box.select(present);
		for (index in 0...declaration.cases.length) {
			var matched = box.createBlock(), next = box.createBlock();
			box.branch(box.equal(tag, box.constInt(index + 1)), matched, next);
			box.select(matched);
			var boxed = box.temporary(Enum(name));
			box.emit(MakeEnum(boxed, name, index, []));
			box.returnValue(box.toDyn(boxed));
			box.select(next);
		}
		box.throwValue(box.toDyn(box.constString("Invalid enum tag")));
		var unbox = new IrBuilder(),
			input = unbox.argument("value", Dyn),
			nil = unbox.createBlock(),
			populated = unbox.createBlock();
		unbox.branch(unbox.equal(input, unbox.constNull(Dyn)), nil, populated);
		unbox.select(nil);
		unbox.returnValue(unbox.constNull(storage));
		unbox.select(populated);
		var accepted = unbox.createBlock(), rejected = unbox.createBlock();
		unbox.branch(unbox.call("__std_is_exact_type", [input, unbox.typeValue(Enum(name))], Bool), accepted, rejected);
		unbox.select(rejected);
		unbox.throwValue(unbox.toDyn(unbox.constString('Invalid cast to $name')));
		unbox.select(accepted);
		var checked = unbox.safeCast(input, Enum(name)),
			index = unbox.temporary(I32);
		unbox.emit(EnumIndex(index, checked));
		unbox.returnValue(unbox.call(IrScalarWordBits.UNPACK, [unbox.add(index, unbox.constInt(1))], storage));
		return [
			new IrFunction(boxName, box.arguments, Dyn, box.blocks, EnumTagAdapter(storage, true)),
			new IrFunction(unboxName, unbox.arguments, storage, unbox.blocks, EnumTagAdapter(storage, false))
		];
	}

	/** A physical tag must never reach a backend's primitive Dynamic conversion. */
	public static function verify(program:IrProgram):Void {
		var tags = [for (entry in program.enums) if (eligible(entry)) entry.name => true];
		function check(type:IrType):Void {
			switch type {
				case EnumTag(name):
					if (!tags.exists(name))
						throw 'IR tag storage requires a payload-free enum "$name"';
				case Nullable(EnumTag(_)):
					throw "IR enum tag nullability must use tag zero";
				case Array(inner), Iterator(inner), Nullable(inner):
					check(inner);
				case Function(arguments, result):
					for (argument in arguments)
						check(argument);
					check(result);
				default:
			}
		}
		for (object in program.objects)
			for (field in object.fields)
				check(field.type);
		for (field in program.staticFields)
			check(field.type);
		for (entry in program.enums)
			for (constructor in entry.cases)
				for (parameter in constructor.params)
					check(parameter);
		for (entry in program.interfaces)
			for (method in entry.methods) {
				for (argument in method.arguments)
					check(argument);
				check(method.result);
			}
		for (native in program.natives) {
			for (argument in native.arguments)
				check(argument);
			check(native.result);
		}
		for (native in program.cNatives) {
			for (argument in native.arguments)
				check(argument);
			check(native.result);
		}
		function checkValue(value:IrValue):Bool {
			check(value.type);
			return false;
		}
		for (fn in program.functions) {
			for (argument in fn.arguments)
				check(argument.type);
			check(fn.result);
			for (block in fn.blocks) {
				for (located in block.instructions) {
					IrOperands.anyValue(located.value, checkValue);
					switch located.value {
						case TypeValue(_, type):
							check(type);
						case ToDyn(_, value):
							switch value.type {
								case EnumTag(_): throw "IR enum tag Dynamic escape requires a box adapter";
								default:
							};
						case SafeCast(output, _):
							switch output.type {
								case EnumTag(_): throw "IR enum tag Dynamic cast requires an unbox adapter";
								default:
							};
						default:
					}
				}
			}
		}
	}
}
