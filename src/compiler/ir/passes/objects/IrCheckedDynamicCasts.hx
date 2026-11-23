package compiler.ir.passes.objects;

import compiler.ir.model.IrBody;
import compiler.ir.model.IrBodyBuilder;
import compiler.ir.model.IrBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrSymbol;
import compiler.ir.model.IrTypeIdentity;
import compiler.ir.model.IrTypeIds;
import compiler.ir.model.TypeKey;
import compiler.ir.passes.IrFunctionRewrite;
import compiler.ir.pipeline.IrFunctionIndex;
import compiler.ir.pipeline.IrFunctionPass;
import compiler.ir.pipeline.IrFunctionStages;
import compiler.ir.reuse.IrFactReader;
import compiler.ir.reuse.IrStageMemo.IrLineage;

import compiler.core.InternalError;
import compiler.core.Provides.ProviderOperation;
import compiler.ir.model.Ir;
import compiler.ir.model.SourceProvenance.Located;

/**
 * Check Dynamic-to-reference casts before target-specific casts, so failure remains catchable. Per function (`IrFunctionPass`):
 * the rewrite reads, for each cast it meets, what the program declares of the object it casts to (`DECLARATION`), and asks
 * for the cast's helper. With a lineage the helpers are derived from that declaration (`IrFunctionStages.derived`).
 */
@:nullSafety(Strict)
class IrCheckedDynamicCasts implements IrFunctionPass {
	public static inline final PREFIX = "$checked-dynamic-cast:";

	/** The fact of an object name: whether it is declared and a value object, with the flags of which casts are checked. */
	static inline final DECLARATION = 0;

	final declarations:Map<String, IrObject>;
	final helpers:Map<String, String> = [];
	final generated:Array<IrFunction> = [];
	final existingFunctions:Null<Array<IrFunction>>;
	var known:Null<IrFunctionIndex> = null;
	final checkObjects:Bool;
	final checkValueObjects:Bool;
	final checkFunctionCasts:Bool;
	final stage:String;
	final lineage:Null<IrLineage>;
	final checks:Bool;
	final types:Null<IrTypeIds>;
	final builder:Null<IrBodyBuilder>;

	public static inline final STAGE = "checked-dynamic-casts";

	/** With `lineage` (and the `types` and `builder` of its bodies), the helpers are derived in the memo of `stage`. */
	public function new(objects:Array<IrObject>, checkObjects:Bool, existingFunctions:Null<Array<IrFunction>>,
			checkValueObjects:Bool, checkFunctionCasts:Bool, stage = STAGE, ?lineage:IrLineage, checks = false,
			?types:IrTypeIds, ?builder:IrBodyBuilder) {
		declarations = [for (object in objects) object.name => object];
		this.existingFunctions = existingFunctions;
		this.checkObjects = checkObjects;
		this.checkValueObjects = checkValueObjects;
		this.checkFunctionCasts = checkFunctionCasts;
		this.stage = stage;
		this.lineage = lineage;
		this.checks = checks;
		this.types = types;
		this.builder = builder;
	}

	public static function rewrite(functions:Array<IrFunction>, objects:Array<IrObject>, checkObjects:Bool,
			?existingFunctions:Array<IrFunction>,
			checkValueObjects:Bool = false, checkFunctionCasts:Bool = false):Array<IrFunction>
		return IrFunctionStages.apply(STAGE, new IrCheckedDynamicCasts(objects, checkObjects,
			existingFunctions, checkValueObjects, checkFunctionCasts), functions);

	/** The functions the helpers must not be made again for: `functions`, after the existing ones. */
	function index(functions:Array<IrFunction>):Void {
		var existing = existingFunctions;
		known = new IrFunctionIndex(stage, existing == null ? functions : existing.concat(functions));
	}

	public function summarize(fn:IrFunction):Int
		return 0;

	public function prepare(functions:Array<IrFunction>, summaries:Array<Int>, names:IrFunctionIndex):Void
		if (existingFunctions == null)
			known = names;
		else
			index(functions);

	public function fact(kind:Int, key:String):Int {
		var declaration = declarations.get(key),
			flags = (checkObjects ? 1 : 0) | (checkValueObjects ? 2 : 0) | (checkFunctionCasts ? 4 : 0);
		return flags * 3 + (declaration == null ? 0 : declaration.isValue ? 2 : 1);
	}

	public function transform(fn:IrFunction, summary:Int, reader:IrFactReader):IrFunction {
		function replacement(located:Located<IrInstruction>):Null<Array<Located<IrInstruction>>>
			return switch located.value {
				case SafeCast(out, input) if (isDyn(input.type)):
					reader.read(DECLARATION, castObject(out.type));
					if (target(out.type) == null) null;
					else {
						reader.request(0, out.type);
						[
							new Located(Call(out, IrSymbol.of(PREFIX + IrTypeIdentity.text(out.type)), [input]),
								located.provenance)
						];
					}
				default: null;
			};
		return IrFunctionRewrite.instructions(fn, replacement);
	}

	public function request(kind:Int, type:IrType, name:Null<String>):Void
		helperFor(type);

	public function finish(functions:Array<IrFunction>):Array<IrFunction>
		return functions.concat(generated);

	/** The object whose declaration decides a cast to `type`; empty for a type that names none. */
	static function castObject(type:IrType):String
		return switch type {
			case Obj(name), Nullable(Obj(name)): name;
			default: "";
		};

	/**
	 * `rewrite` on IR bodies (docs/design/IR_CORE_COLUMNS.md, migration), made with `types`, in the stage `stage`: a checked cast
	 * becomes a call of its helper in place, in the body itself, or a copy when a cache holds it. The helpers are built as
	 * functions and encoded. With `lineage` each function's rewrite is derived from its version and the declarations it read
	 * (`IrFunctionStages.derived`), and so are the helpers.
	 */
	public static function rewriteBodies(stage:String, functions:Array<IrFunction>, objects:Array<IrObject>,
			checkObjects:Bool, existingFunctions:Null<Array<IrFunction>>, checkValueObjects:Bool,
			checkFunctionCasts:Bool,
			types:IrTypeIds, builder:IrBodyBuilder, ?lineage:IrLineage, checks = false):Array<IrFunction> {
		var pass = new IrCheckedDynamicCasts(objects, checkObjects, existingFunctions, checkValueObjects,
			checkFunctionCasts, stage, lineage, checks, types, builder);
		pass.index(functions);
		if (lineage != null)
			lineage.memos.facts.begin();
		var rewritten = [
			for (fn in functions)
				IrFunctionStages.derived(stage, fn.name, pass, lineage == null ? 0 : lineage.versionOf(fn), lineage,
				checks,
				types, builder, reader -> pass.rewriteBody(fn, reader))
		];
		return rewritten.concat(pass.generated);
	}

	/** `fn`'s body with its checked casts calling their helpers, which it asks for; `fn` itself when it has none. */
	function rewriteBody(fn:IrFunction, reader:IrFactReader):IrFunction {
		var body = fn.bodyIn(bodyTypes(), builder), dyn = bodyTypes().id(Dyn), found = false;
		// Whether `row` is a cast from Dyn that is checked, reading what decides it.
		function checked(body:IrBody, row:Int):Bool {
			if (body.opcode(row) != IrOpcode.SafeCast || body.valueTypeId(body.operand(row, 0)) != dyn)
				return false;
			var type = body.valueType(body.output(row));
			reader.read(DECLARATION, castObject(type));
			return target(type) != null;
		}
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (checked(body, row))
					found = true;
				row = body.nextRow(row);
			}
		}
		if (!found)
			return fn;
		var edited = body.forEditing(builder);
		for (block in 0...edited.blockCount()) {
			var row = edited.firstRow(block);
			while (row >= 0) {
				if (checked(edited, row)) {
					var type = edited.valueType(edited.output(row));
					reader.request(0, type);
					edited.setOperation(row, IrOpcode.Call, IrSymbol.of(PREFIX + IrTypeIdentity.text(type)).id);
				}
				row = edited.nextRow(row);
			}
		}
		return IrFunction.ofOwnedBody(edited);
	}

	function bodyTypes():IrTypeIds {
		var known = types;
		if (known == null)
			throw new InternalError("Checked casts on bodies need the program's types");
		return known;
	}

	static function isDyn(type:IrType):Bool
		return switch type {
			case Dyn: true;
			default: false;
		};

	/** What a checked cast from `Dyn` to `type` tests: the type, its name and whether null passes; null when it is not checked. */
	function target(type:IrType):Null<{checked:IrType, name:String, allowNull:Bool}>
		return switch type {
			case Obj(name):
				var declaration = declarations.get(name);
				declaration != null && (checkObjects || (checkValueObjects && declaration.isValue)) ? {
					checked: type,
					name: name,
					allowNull: !declaration.isValue
				} : null;
			case Nullable(Obj(name)):
				var declaration = declarations.get(name);
				checkValueObjects && declaration != null && declaration.isValue ? {
					checked: Obj(name),
					name: name,
					allowNull: true
				} : null;
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
		var name = PREFIX + key;
		helpers.set(key, name);
		var functions = known;
		if (functions == null) throw new InternalError("Checked casts made a helper before indexing the program");
		if (functions.exists(name)) return name;
		var checked = request.checked, label = request.name, allowNull = request.allowNull;
		function make(reader:IrFactReader):IrFunction {
			reader.read(DECLARATION, castObject(type));
			var builder = new IrBuilder(),
				input = builder.argument("value", Dyn),
				check = builder.createBlock(),
				accepted = builder.createBlock(),
				rejected = builder.createBlock();
			if (!allowNull) builder.jump(check);
			else builder.branch(builder.equal(input, builder.constNull(Dyn)), accepted, check);
			builder.select(check);
			var test = switch checked {
				case Function(_, _): "__closure_is_of_type";
				default: "__std_is_of_type";
			};
			builder.branch(builder.call(test, [input, builder.typeValue(checked)], Bool), accepted, rejected);
			builder.select(accepted);
			builder.returnValue(builder.safeCast(input, type));
			builder.select(rejected);
			builder.terminate(Throw(builder.toDyn(builder.constString('Invalid cast to $label'))));
			return new IrFunction(name, builder.arguments, type, builder.blocks,
				Provider(TypeKey.of(type), ProviderOperation.CheckedCast));
		}
		var bodies = types;
		generated.push(lineage == null || bodies == null ? make(new IrFactReader(stage,
			this)) : IrFunctionStages.derived(stage, name, this, IrFunctionStages.FROM_NAME, lineage, checks, bodies,
			builder, make));
		return name;
	}
}
