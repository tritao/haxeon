package compiler.ir;

import compiler.ir.Ir;

private typedef ReflectedLayout = {final name:String; final fields:Array<IrObjectField>;}

/**
 * Field reflection over compiled object layouts, for runtimes that cannot look up object fields by
 * name (Wasm). Each `__reflect_object_*` native a program declares becomes a generated function
 * that tests the value against every reflectable object type, most derived first, and calls that
 * layout's generated function to compare field names. HashLink reflects through its own runtime and never declares these natives.
 */
class ObjectReflection {
	/**
	 * With `tableDispatch`, only the per-layout functions are generated and each native stays declared, listing them as
	 * the functions its backend implementation calls: the backend finds a value's layout from the type id in its header
	 * (linear Wasm), which costs the same however many layouts the program has.
	 */
	public static function generate(natives:Null<Array<IrNative>>, objects:Null<Array<IrObject>>, reflectable:Null<Array<String>>,
			functions:Array<IrFunction>, tableDispatch:Bool = false):Null<Array<IrNative>> {
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
			// Copying allocates a value of the matching layout, so it keeps the per-layout dispatcher instead of joining the table.
			if (tableDispatch && native.symbol != "__reflect_object_copy") {
				remaining.push({
					name: native.name,
					library: native.library,
					symbol: native.symbol,
					arguments: native.arguments,
					result: native.result,
					generatedFunctionDependencies: tableLayoutFunctions(native, layouts, functions)
				});
				continue;
			}
			functions.push(switch native.symbol {
				case "__reflect_object_copy": copy(native.name, layouts, functions);
				case "__reflect_object_field": field(native.name, layouts, functions);
				case "__reflect_object_set_field": setField(native.name, layouts, functions);
				case "__reflect_object_field_count": fieldCount(native.name, layouts);
				case "__reflect_object_field_name": fieldName(native.name, layouts, functions);
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

	static function copy(name:String, layouts:Array<ReflectedLayout>, functions:Array<IrFunction>):IrFunction
		return perLayout(name, layouts, functions, Dyn, [], (builder, layout, typed, _) -> {
			var result = builder.newObject(layout.name);
			for (field in layout.fields)
				builder.fieldSet(result, field.name, builder.fieldGet(typed, field.name, field.type));
			builder.returnValue(builder.toDyn(result));
		}, builder -> builder.constNull(Dyn));

	static function field(name:String, layouts:Array<ReflectedLayout>, functions:Array<IrFunction>):IrFunction
		return perLayout(name, layouts, functions, Dyn, [{name: "field", type: Bytes}], fieldBody, builder -> builder.constNull(Dyn));

	static function fieldBody(builder:IrBuilder, layout:ReflectedLayout, typed:IrValue, arguments:Array<IrValue>):Void {
		forEachField(builder, arguments[0], layout, field -> builder.returnValue(builder.toDyn(builder.fieldGet(typed, field.name, field.type))));
		builder.returnValue(builder.constNull(Dyn));
	}

	static function setField(name:String, layouts:Array<ReflectedLayout>, functions:Array<IrFunction>):IrFunction
		return perLayout(name, layouts, functions, Bool, [{name: "field", type: Bytes}, {name: "value", type: Dyn}], setFieldBody,
			builder -> builder.constBool(false));

	static function setFieldBody(builder:IrBuilder, layout:ReflectedLayout, typed:IrValue, arguments:Array<IrValue>):Void {
		var value = arguments[1];
		forEachField(builder, arguments[0], layout, field -> {
			builder.fieldSet(typed, field.name, field.type == Dyn ? value : builder.safeCast(value, field.type));
			builder.returnValue(builder.constBool(true));
		});
		builder.returnValue(builder.constBool(false));
	}

	static function fieldCount(name:String, layouts:Array<ReflectedLayout>):IrFunction {
		var builder = new IrBuilder(),
			object = builder.argument("object", Dyn);
		forEachLayout(builder, object, layouts, (layout, _) -> builder.returnValue(builder.constInt(layout.fields.length)));
		builder.returnValue(builder.constInt(0));
		return new IrFunction(name, builder.arguments, I32, builder.blocks);
	}

	static function fieldName(name:String, layouts:Array<ReflectedLayout>, functions:Array<IrFunction>):IrFunction
		return perLayout(name, layouts, functions, Bytes, [{name: "index", type: I32}], fieldNameBody, builder -> builder.constNull(Bytes));

	static function fieldNameBody(builder:IrBuilder, layout:ReflectedLayout, _:IrValue, arguments:Array<IrValue>):Void {
		for (position in 0...layout.fields.length) {
			var matched = builder.createBlock(), next = builder.createBlock();
			builder.branch(builder.equal(arguments[0], builder.constInt(position)), matched, next);
			builder.select(matched);
			builder.returnValue(builder.constString(layout.fields[position].name));
			builder.select(next);
		}
		builder.returnValue(builder.constNull(Bytes));
	}

	/** One function per layout for a native the backend dispatches itself; returns their names, in layout order. */
	static function tableLayoutFunctions(native:IrNative, layouts:Array<ReflectedLayout>, functions:Array<IrFunction>):Array<String> {
		var result:IrType, parameters:Array<{name:String, type:IrType}>, body:(IrBuilder, ReflectedLayout, IrValue, Array<IrValue>) -> Void;
		switch native.symbol {
			case "__reflect_object_field":
				result = Dyn;
				parameters = [{name: "field", type: Bytes}];
				body = fieldBody;
			case "__reflect_object_set_field":
				result = Bool;
				parameters = [{name: "field", type: Bytes}, {name: "value", type: Dyn}];
				body = setFieldBody;
			case "__reflect_object_field_count":
				result = I32;
				parameters = [];
				body = (builder, layout, _, _) -> builder.returnValue(builder.constInt(layout.fields.length));
			case "__reflect_object_field_name":
				result = Bytes;
				parameters = [{name: "index", type: I32}];
				body = fieldNameBody;
			default:
				throw 'Unknown object reflection native "${native.symbol}"';
		}
		return [
			for (layout in layouts)
				layoutFunction('${native.name}.${layout.name}', layout, functions, result, parameters, body, true)
		];
	}

	/**
	 * With `dynamicReceiver` the function takes the object as Dynamic and casts it itself, so every layout's function has one
	 * signature and a backend can call any of them through a single function type.
	 */
	static function layoutFunction(layoutName:String, layout:ReflectedLayout, functions:Array<IrFunction>, result:IrType,
			parameters:Array<{name:String, type:IrType}>, body:(IrBuilder, ReflectedLayout, IrValue, Array<IrValue>) -> Void,
			dynamicReceiver:Bool = false):String {
		var layoutBuilder = new IrBuilder(),
			dynamicObject = layoutBuilder.argument("object", dynamicReceiver ? Dyn : Obj(layout.name)),
			layoutObject = dynamicReceiver ? layoutBuilder.safeCast(dynamicObject, Obj(layout.name)) : dynamicObject;
		body(layoutBuilder, layout, layoutObject, [
			for (parameter in parameters)
				layoutBuilder.argument(parameter.name, parameter.type)
		]);
		functions.push(new IrFunction(layoutName, layoutBuilder.arguments, result, layoutBuilder.blocks));
		return layoutName;
	}

	/**
	 * A native that dispatches on the value's layout to one generated function per layout, which `body` fills
	 * with the typed object and the remaining arguments. Each function's size and locals then grow with one
	 * layout's fields rather than every reflectable field in the program.
	 */
	static function perLayout(name:String, layouts:Array<ReflectedLayout>, functions:Array<IrFunction>, result:IrType,
			parameters:Array<{name:String, type:IrType}>, body:(IrBuilder, ReflectedLayout, IrValue, Array<IrValue>) -> Void,
			fallback:IrBuilder->IrValue):IrFunction {
		var builder = new IrBuilder(),
			object = builder.argument("object", Dyn),
			arguments = [for (parameter in parameters) builder.argument(parameter.name, parameter.type)];
		forEachLayout(builder, object, layouts, (layout, typed) -> {
			var layoutName = layoutFunction('$name.${layout.name}', layout, functions, result, parameters, body);
			builder.returnValue(builder.call(layoutName, [typed].concat(arguments), result));
		});
		builder.returnValue(fallback(builder));
		return new IrFunction(name, builder.arguments, result, builder.blocks);
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
