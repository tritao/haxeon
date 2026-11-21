package compiler.ir;

import compiler.core.InternalError;
import compiler.core.Provides.ProviderOperation;
import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;

/** Check Dynamic-to-reference casts before target-specific casts, so failure remains catchable. */
class IrCheckedDynamicCasts {
	public static inline final PREFIX = "$checked-dynamic-cast:";

	final declarations:Map<String, IrObject>;
	final helpers:Map<String, String> = [];
	final generated:Array<IrFunction> = [];
	final known:IrFunctionIndex;
	final checkObjects:Bool;
	final checkValueObjects:Bool;
	final checkFunctionCasts:Bool;

	function new(functions:Array<IrFunction>, objects:Array<IrObject>, checkObjects:Bool,
			existingFunctions:Null<Array<IrFunction>>, checkValueObjects:Bool, checkFunctionCasts:Bool) {
		declarations = [for (object in objects) object.name => object];
		known = new IrFunctionIndex("checked-dynamic-casts",
			existingFunctions == null ? functions : existingFunctions.concat(functions));
		this.checkObjects = checkObjects;
		this.checkValueObjects = checkValueObjects;
		this.checkFunctionCasts = checkFunctionCasts;
	}

	public static function rewrite(functions:Array<IrFunction>, objects:Array<IrObject>, checkObjects:Bool,
			?existingFunctions:Array<IrFunction>,
			checkValueObjects:Bool = false, checkFunctionCasts:Bool = false):Array<IrFunction> {
		var pass = new IrCheckedDynamicCasts(functions, objects, checkObjects, existingFunctions, checkValueObjects,
			checkFunctionCasts);
		function replacement(located:Located<IrInstruction>):Null<Array<Located<IrInstruction>>>
			return switch located.value {
				case SafeCast(out, input) if (isDyn(input.type)):
					var helper = pass.helperFor(out.type);
					helper == null ? null : [new Located(Call(out, IrSymbol.of(helper), [input]), located.provenance)];
				default: null;
			};
		var rewritten:Array<IrFunction> = [for (fn in functions) IrFunctionRewrite.instructions(fn, replacement)];
		return rewritten.concat(pass.generated);
	}

	/**
	 * `rewrite` on IR bodies (docs/design/IR_CORE_COLUMNS.md, migration), made with `types`: a checked cast becomes a call of its
	 * helper in place, in the body itself, or a copy when a cache holds it. The helpers are built as functions and encoded.
	 */
	public static function rewriteBodies(functions:Array<IrFunction>, objects:Array<IrObject>, checkObjects:Bool,
			existingFunctions:Null<Array<IrFunction>>, checkValueObjects:Bool, checkFunctionCasts:Bool, types:IrTypeIds,
			builder:IrBodyBuilder):Array<IrFunction> {
		var pass = new IrCheckedDynamicCasts(functions, objects, checkObjects, existingFunctions, checkValueObjects,
			checkFunctionCasts);
		var dyn = types.id(Dyn), rewritten:Array<IrFunction> = [];
		inline function checked(body:IrBody, row:Int):Bool
			return body.opcode(row) == IrOpcode.SafeCast
				&& body.valueTypeId(body.operand(row, 0)) == dyn
				&& pass.target(body.valueType(body.output(row))) != null;
		for (fn in functions) {
			var body = fn.bodyIn(types, builder), found = false;
			for (block in 0...body.blockCount()) {
				var row = body.firstRow(block);
				while (row >= 0 && !found) {
					found = checked(body, row);
					row = body.nextRow(row);
				}
			}
			if (!found) {
				rewritten.push(fn);
				continue;
			}
			var edited = body.forEditing(builder);
			for (block in 0...edited.blockCount()) {
				var row = edited.firstRow(block);
				while (row >= 0) {
					if (checked(edited, row))
						edited.setOperation(row, IrOpcode.Call,
							IrSymbol.of(pass.helperFor(edited.valueType(edited.output(row)))).id);
					row = edited.nextRow(row);
				}
			}
			rewritten.push(IrFunction.ofOwnedBody(edited));
		}
		return rewritten.concat(pass.generated);
	}

	static function isDyn(type:IrType):Bool
		return switch type {
			case Dyn: true;
			default: false;
		};

	/** What a checked cast from `Dyn` to `type` tests: the type, its name and whether null passes; null when it is not checked. */
	function target(type:IrType):Null<{checked:IrType, name:String, allowNull:Bool}>
		return switch type {
			case Obj(name) if (declarations.exists(name)
				&& (checkObjects || (checkValueObjects && declarations.get(name).isValue))):
				var declaration = declarations.get(name);
				if (declaration == null) throw new InternalError('Missing cast target "$name"');
				{
					checked:type, name:name, allowNull:!declaration.isValue
				};
			case Nullable(Obj(name)) if (checkValueObjects && declarations.exists(name)
				&& declarations.get(name).isValue):
				{checked: Obj(name), name: name, allowNull: true};
			case RawPtr:
				{checked: type, name: "hl.Bytes", allowNull: true};
			case Function(_, _) if (checkFunctionCasts):
				{checked: type, name: IrTypeIdentity.text(type), allowNull: false};
			case Nullable(inner = Function(_, _)) if (checkFunctionCasts):
				{checked: inner, name: IrTypeIdentity.text(inner), allowNull: true};
			case Virtual(name):
				{checked: type, name: name, allowNull: true};
			default: null;
		};

	/** The helper that checks a cast from `Dyn` to `type`, made the first time it is asked for; null when the cast is not checked. */
	function helperFor(type:IrType):Null<String> {
		var request = target(type);
		if (request == null)
			return null;
		var key = IrTypeIdentity.text(type), existing = helpers.get(key);
		if (existing != null) return existing;
		var name = PREFIX + key,
			builder = new IrBuilder(),
			input = builder.argument("value", Dyn),
			check = builder.createBlock(),
			accepted = builder.createBlock(),
			rejected = builder.createBlock();
		helpers.set(key, name);
		if (known.exists(name)) return name;
		if (!request.allowNull) builder.jump(check);
		else builder.branch(builder.equal(input, builder.constNull(Dyn)), accepted, check);
		builder.select(check);
		var test = switch request.checked {
			case Function(_, _): "__closure_is_of_type";
			default: "__std_is_of_type";
		};
		builder.branch(builder.call(test, [input, builder.typeValue(request.checked)], Bool), accepted, rejected);
		builder.select(accepted);
		builder.returnValue(builder.safeCast(input, type));
		builder.select(rejected);
		builder.terminate(Throw(builder.toDyn(builder.constString('Invalid cast to ${request.name}'))));
		generated.push(new IrFunction(name, builder.arguments, type, builder.blocks,
			Provider(TypeKey.of(type), ProviderOperation.CheckedCast)));
		return name;
	}
}
