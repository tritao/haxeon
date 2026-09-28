package compiler.ir;

import compiler.ir.Ir;

private typedef ReflectedLayout = {final name:String; final fields:Array<IrObjectField>;}

/**
 * Field reflection over compiled object layouts, for runtimes that cannot look up object fields by
 * name (Wasm). Each `__reflect_object_*` native a program declares becomes a generated function
 * that tests the value against every reflectable object type, most derived first, then compares
 * field names. HashLink reflects through its own runtime and never declares these natives.
 */
class ObjectReflection {
	public static function generate(natives:Null<Array<IrNative>>, objects:Null<Array<IrObject>>, reflectable:Null<Array<String>>,
			functions:Array<IrFunction>):Null<Array<IrNative>> {
		if (natives == null)
			return null;
		var remaining:Array<IrNative> = [],
			layouts:Null<Array<ReflectedLayout>> = null;
		for (native in natives) {
			if (!StringTools.startsWith(native.symbol, "__reflect_object_")) {
				remaining.push(native);
				continue;
			}
			if (layouts == null)
				layouts = layoutsOf(objects == null ? [] : objects, reflectable == null ? [] : reflectable);
			functions.push(switch native.symbol {
				case "__reflect_object_field": field(native.name, layouts);
				case "__reflect_object_set_field": setField(native.name, layouts);
				case "__reflect_object_field_count": fieldCount(native.name, layouts);
				case "__reflect_object_field_name": fieldName(native.name, layouts);
				default: throw 'Unknown object reflection native "${native.symbol}"';
			});
		}
		return remaining;
	}

	/** Reflectable layouts with inherited fields first, ordered so subclasses are tested before their bases. */
	static function layoutsOf(objects:Array<IrObject>, reflectable:Array<String>):Array<ReflectedLayout> {
		var byName:Map<String, IrObject> = [for (object in objects) object.name => object],
			result:Array<{layout:ReflectedLayout, depth:Int}> = [];
		for (name in reflectable) {
			var object = byName.get(name);
			if (object == null || object.isValue)
				continue;
			var chain:Array<IrObject> = [object], base = object.base;
			while (base != null) {
				var owner = byName.get(base);
				if (owner == null)
					break;
				chain.unshift(owner);
				base = owner.base;
			}
			var fields:Array<IrObjectField> = [];
			for (owner in chain)
				for (field in owner.fields)
					fields.push(field);
			result.push({layout: {name: name, fields: fields}, depth: chain.length});
		}
		result.sort((left, right) -> right.depth - left.depth);
		return [for (entry in result) entry.layout];
	}

	static function field(name:String, layouts:Array<ReflectedLayout>):IrFunction {
		var builder = new IrBuilder(),
			object = builder.argument("object", Dyn),
			fieldName = builder.argument("field", Bytes);
		forEachLayout(builder, object, layouts, (layout, typed) -> {
			forEachField(builder, fieldName, layout, field -> builder.returnValue(builder.toDyn(builder.fieldGet(typed, field.name, field.type))));
			builder.returnValue(builder.constNull(Dyn));
		});
		builder.returnValue(builder.constNull(Dyn));
		return new IrFunction(name, builder.arguments, Dyn, builder.blocks);
	}

	static function setField(name:String, layouts:Array<ReflectedLayout>):IrFunction {
		var builder = new IrBuilder(),
			object = builder.argument("object", Dyn),
			fieldName = builder.argument("field", Bytes),
			value = builder.argument("value", Dyn);
		forEachLayout(builder, object, layouts, (layout, typed) -> {
			forEachField(builder, fieldName, layout, field -> {
				builder.fieldSet(typed, field.name, field.type == Dyn ? value : builder.safeCast(value, field.type));
				builder.returnValue(builder.constBool(true));
			});
			builder.returnValue(builder.constBool(false));
		});
		builder.returnValue(builder.constBool(false));
		return new IrFunction(name, builder.arguments, Bool, builder.blocks);
	}

	static function fieldCount(name:String, layouts:Array<ReflectedLayout>):IrFunction {
		var builder = new IrBuilder(),
			object = builder.argument("object", Dyn);
		forEachLayout(builder, object, layouts, (layout, _) -> builder.returnValue(builder.constInt(layout.fields.length)));
		builder.returnValue(builder.constInt(0));
		return new IrFunction(name, builder.arguments, I32, builder.blocks);
	}

	static function fieldName(name:String, layouts:Array<ReflectedLayout>):IrFunction {
		var builder = new IrBuilder(),
			object = builder.argument("object", Dyn),
			index = builder.argument("index", I32);
		forEachLayout(builder, object, layouts, (layout, _) -> {
			for (position in 0...layout.fields.length) {
				var matched = builder.createBlock(),
					next = builder.createBlock();
				builder.branch(builder.equal(index, builder.constInt(position)), matched, next);
				builder.select(matched);
				builder.returnValue(builder.constString(layout.fields[position].name));
				builder.select(next);
			}
			builder.returnValue(builder.constNull(Bytes));
		});
		builder.returnValue(builder.constNull(Bytes));
		return new IrFunction(name, builder.arguments, Bytes, builder.blocks);
	}

	/** Runs `body` on the value cast to the first matching layout; `body` must terminate its block. */
	static function forEachLayout(builder:IrBuilder, object:IrValue, layouts:Array<ReflectedLayout>, body:(ReflectedLayout, IrValue) -> Void):Void
		for (layout in layouts) {
			var type:IrType = Obj(layout.name),
				matched = builder.createBlock(),
				next = builder.createBlock();
			builder.branch(builder.call("__std_is_of_type", [object, builder.typeValue(type)], Bool), matched, next);
			builder.select(matched);
			body(layout, builder.safeCast(object, type));
			builder.select(next);
		}

	/** Runs `body` for the field named `fieldName`; `body` must terminate its block. */
	static function forEachField(builder:IrBuilder, fieldName:IrValue, layout:ReflectedLayout, body:IrObjectField->Void):Void
		for (field in layout.fields) {
			var matched = builder.createBlock(), next = builder.createBlock();
			builder.branch(builder.call("__string_equal", [fieldName, builder.constString(field.name)], Bool), matched, next);
			builder.select(matched);
			body(field);
			builder.select(next);
		}
}
