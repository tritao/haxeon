package compiler.ir.passes.enums;

import compiler.core.InternalError;
import compiler.ir.analysis.IrEnumEscapeReach;
import compiler.ir.analysis.IrEnumEscapeReach.IrReachRecord;
import compiler.ir.model.Ir;
import compiler.ir.model.IrBody;
import compiler.ir.model.IrBodyBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrPassScratch;
import compiler.ir.model.IrTypeIds;
import compiler.ir.model.IrValueId;
import compiler.ir.passes.objects.IrObjectReflection;
import compiler.ir.passes.values.IrValueInterfaceBoxes;
import compiler.ir.pipeline.IrFunctionIndex;
import compiler.ir.pipeline.IrFunctionPass;
import compiler.ir.pipeline.IrFunctionStages;
import compiler.ir.reuse.IrFactReader;
import compiler.ir.reuse.IrStageMemo.IrLineage;

/**
 * Project an unobserved nominal tag to its integer ABI, including ordinary integer arrays. On IR bodies
 * (docs/design/IR_CORE_COLUMNS.md, migration), in release builds, per function (`IrFunctionPass`).
 *
 * The whole-program step chooses the closed tags: the payload-free enums no escape reaches (`IrEnumEscapeReach`), from what each
 * function lets escape (`IrTagEscapeRecord`, kept by the function's version in a session). The rewrite of a function reads, for
 * each tag its types name, whether it is closed (`CLOSED`); a function that changes becomes its edited body, owned by the next
 * stage. The program's tables are projected after the functions (`projected`).
 */
@:nullSafety(Strict)
class IrClosedEnumTagAbi implements IrFunctionPass {
	/** What each function lets escape, for the closed enum tag ABI's choice (`IrTagEscapeRecord`). */
	@:processWide("a contribution memo's key, only ever read")
	public static final ESCAPES = new compiler.ir.reuse.IrStageMemo.IrContributionKey<IrTagEscapeRecord>("tag-escapes");

	/** The escape reach of the closed tags' choice, which a session keeps (`IrEnumEscapeReach.collectKept`). */
	@:processWide("a kept reach's key, only ever read")
	public static final REACH = new compiler.ir.reuse.IrStageMemo.IrContributionKey<IrReachRecord>("closed-tag-reach");

	/** The fact of an enum tag: 1 when it is closed. */
	static inline final CLOSED = 0;

	/** Whether any tag is closed (1 or 0), by the empty key: a rewrite that finds none reads only this. */
	static inline final ANY_CLOSED = 1;

	final program:IrProgram;
	final reflectableObjects:Null<Array<String>>;
	final types:IrTypeIds;
	final builder:IrBodyBuilder;
	final lineage:Null<IrLineage>;
	var closed:Map<String, Bool> = [];

	/** By type id: 1 when the type changes, 0 when not, -1 when not yet known. */
	final changing:Array<Int> = [];

	/** By type id: the tags the type names where the projection looks (`changes`), or null when not yet known. */
	final tagNames:Array<Null<Array<String>>> = [];

	/** The reader of the function being rewritten; null in the whole-program step, which reads the tables directly. */
	var reader:Null<IrFactReader> = null;

	/** The program with the closed tags projected, once the run is finished: the program itself when no tag is closed. */
	public var projected(default, null):Null<IrProgram> = null;

	public function new(program:IrProgram, reflectableObjects:Null<Array<String>>, types:IrTypeIds,
			builder:IrBodyBuilder, lineage:Null<IrLineage>) {
		this.program = program;
		this.reflectableObjects = reflectableObjects;
		this.types = types;
		this.builder = builder;
		this.lineage = lineage;
	}

	/**
	 * `program` with the closed tags projected, read from the functions' bodies, made with `types` (those of the program's bodies
	 * when not given), without a memo.
	 */
	public static function run(program:IrProgram, ?reflectableObjects:Array<String>, ?types:IrTypeIds,
			?scratch:IrPassScratch):IrProgram {
		if (types == null)
			types = IrTypeIds.ofFunctions(program.functions);
		var pass = new IrClosedEnumTagAbi(program, reflectableObjects, types,
			scratch == null ? new IrBodyBuilder(types) : scratch.bodyBuilder, null);
		IrFunctionStages.apply("closed-enum-tag-abi", pass, program.functions);
		return pass.result();
	}

	/** The projected program (`projected`) of a finished run. */
	public function result():IrProgram {
		var made = projected;
		if (made == null)
			throw new InternalError("The closed enum tag ABI has not finished");
		return made;
	}

	function changes(type:IrType):Bool
		return switch type {
			case EnumTag(name): closed.exists(name);
			case Array(inner), Iterator(inner), Nullable(inner): changes(inner);
			case Function(args, result): Lambda.exists(args, changes) || changes(result);
			default: false;
		};

	static function addTags(type:IrType, names:Array<String>):Void
		switch type {
			case EnumTag(name):
				if (names.indexOf(name) < 0)
					names.push(name);
			case Array(inner), Iterator(inner), Nullable(inner):
				addTags(inner, names);
			case Function(args, result):
				for (arg in args)
					addTags(arg, names);
				addTags(result, names);
			default:
		}

	/** Whether the type of id `id` changes; while a function is rewritten, the reader reads the facts of the tags it names. */
	function changesId(id:Int):Bool {
		var current = reader;
		if (current != null) {
			var names = id < tagNames.length ? tagNames[id] : null;
			if (names == null) {
				names = [];
				addTags(types.type(id), names);
				while (tagNames.length <= id)
					tagNames.push(null);
				tagNames[id] = names;
			}
			for (name in names)
				current.read(CLOSED, name);
		}
		var known = id < changing.length ? changing[id] : -1;
		if (known < 0) {
			known = changes(types.type(id)) ? 1 : 0;
			while (changing.length <= id)
				changing.push(-1);
			changing[id] = known;
		}
		return known == 1;
	}

	function isClosed(name:String):Bool {
		var current = reader;
		return current != null ? current.read(CLOSED, name) == 1 : closed.exists(name);
	}

	function physical(type:IrType):IrType
		return switch type {
			case EnumTag(name) if (closed.exists(name)): I32;
			case Array(inner) if (changes(inner)): Array(physical(inner));
			case Iterator(inner) if (changes(inner)): Iterator(physical(inner));
			case Nullable(inner) if (changes(inner)): Nullable(physical(inner));
			case Function(args, result) if (changes(type)): Function([for (arg in args) physical(arg)],
				physical(result));
			default: type;
		};

	function functionChanges(body:IrBody):Bool {
		if (changesId(body.result))
			return true;
		for (index in 0...body.argumentCount())
			if (changesId(body.valueTypeId(body.argument(index))))
				return true;
		for (index in 0...body.bindingCount())
			if (changesId(body.valueTypeId(body.bindingValue(index))))
				return true;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var output = body.output(row);
				if (output.exists() && changesId(body.valueTypeId(output)))
					return true;
				if (body.opcode(row) == IrOpcode.TypeValue && changesId(body.aux(row)))
					return true;
				row = body.nextRow(row);
			}
		}
		return false;
	}

	public function summarize(fn:IrFunction):Int
		return 0;

	/** Chooses the closed tags: the payload-free enums that nothing lets escape. */
	public function prepare(functions:Array<IrFunction>, summaries:Array<Int>, names:IrFunctionIndex):Void {
		closed = [for (e in program.enums) if (IrEnumTagStorage.eligible(e)) e.name => true];
		if (!closed.keys().hasNext())
			return;
		var natives = [for (n in program.natives) n.name => n];
		var roots:Array<IrType> = [], rooted:Array<Bool> = [];
		function escape(type:IrType):Void
			roots.push(type);
		// The records' types are named by id, each a root once.
		function escapeId(id:Int):Void {
			while (rooted.length <= id)
				rooted.push(false);
			if (!rooted[id]) {
				rooted[id] = true;
				roots.push(types.type(id));
			}
		}

		for (n in program.cNatives) {
			for (a in n.arguments)
				IrEnumEscapeReach.addNativeRoot(roots, a);
			IrEnumEscapeReach.addNativeRoot(roots, n.result);
		}
		for (n in program.natives)
			if (!IrArrayRuntimeNatives.isStorage(n.name)) {
				for (a in n.arguments)
					IrEnumEscapeReach.addNativeRoot(roots, a);
				IrEnumEscapeReach.addNativeRoot(roots, n.result);
			}
		// The closures and map stores the reach follows are the records', so it reads no function itself.
		var reach = new IrEnumEscapeReach(program, _ -> false);
		for (fn in functions) {
			switch fn.kind {
				case ClosureAdapter(source, target):
					escape(source);
					escape(target);
				case ClosureCast(target), ClosureVarargs(target):
					escape(target);
				case EnumTagAdapter(type, _):
					escape(type);
				default:
			}
			if (fn.retention == Expose || fn.name == program.entryPoint) {
				for (a in fn.arguments)
					escape(a.type);
				escape(fn.result);
			}
			var record = IrTagEscapeRecord.of(fn, types, builder, lineage);
			for (id in record.escaped)
				escapeId(id);
			var callees = record.callees, arguments = record.arguments;
			for (index in 0...callees.length) {
				var name = callees[index], position = arguments[index * 2], type = arguments[index * 2 + 1];
				if (rooted.length > type && rooted[type])
					continue;
				if (natives.exists(name))
					escapeId(type);
				else {
					var target = names.get(name);
					if (target != null && position < target.arguments.length && switch target.arguments[position].type {
						case Dyn: true;
						default: false;
					})
						escapeId(type);
				}
			}
			var closures = record.closures, index = 0;
			while (index < closures.length) {
				reach.closureEnvironment(types.type(closures[index]), types.type(closures[index + 1]));
				index += 2;
			}
			var stores = record.mapStores;
			index = 0;
			while (index < stores.length) {
				reach.mapContent(types.type(stores[index]), types.type(stores[index + 1]),
					types.type(stores[index + 2]));
				index += 3;
			}
		}
		if (IrObjectReflection.usedByProgram(program)) {
			var reflectable = reflectableObjects;
			if (reflectable != null)
				for (name in reflectable)
					escape(Obj(name));
			for (object in program.objects)
				if (object.isValue
					|| compiler.semantic.SemanticSignature.isAnonymousName(object.name)
					|| StringTools.startsWith(object.name, IrValueInterfaceBoxes.BOX_PREFIX))
					escape(Obj(object.name));
		}
		for (name in reach.collectKept(REACH, roots, _ -> false, lineage).keys())
			closed.remove(name);
	}

	public function fact(kind:Int, key:String):Int
		return (kind == ANY_CLOSED ? closed.keys().hasNext() : closed.exists(key)) ? 1 : 0;

	public function transform(fn:IrFunction, summary:Int, reader:IrFactReader):IrFunction {
		if (reader.read(ANY_CLOSED, "") == 0)
			return fn;
		this.reader = reader;
		var result = projectFunction(fn, fn.bodyIn(types, builder));
		this.reader = null;
		return result;
	}

	public function request(kind:Int, type:IrType, name:Null<String>):Void
		throw new InternalError("The closed enum tag ABI asks for no helper");

	public function finish(functions:Array<IrFunction>):Array<IrFunction> {
		if (!closed.keys().hasNext()) {
			projected = program;
			return functions;
		}
		var result = new IrProgram(program.entryPoint);
		result.natives = [for (native in program.natives) projectNative(native)];
		result.cNatives = [for (native in program.cNatives) projectCNative(native)];
		result.functions = functions;
		// Only the selected tag carriers change; native placement and optional payload widths stay intact.
		result.objects = [for (object in program.objects)
			{
				name:object.name,
					isValue:object.isValue,
					nativeLayout:object.nativeLayout,
					base:object.base,
					interfaces:object.interfaces,
					fields:[for (field in object.fields)
					{
						name:field.name,
							type:physical(field.type),
							nativeLayout:field.nativeLayout,
							scalarStorage:field.scalarStorage,
							nullableScalarStorage:field.nullableScalarStorage
					}],
						methods:object.methods
			}];
		result.interfaces = [for (entry in program.interfaces)
			{
				name:entry.name,
					bases:entry.bases,
					methods:[for (method in entry.methods)
					{
						name:method.name,
							arguments:[for (argument in method.arguments) physical(argument)],
							result:physical(method.result)
					}]
			}];
		result.enums = [for (entry in program.enums)
			{
				name:entry.name,
					isRecursive:entry.isRecursive,
					inlineStorage:entry.inlineStorage,
					cases:[for (enumCase in entry.cases)
					{
						name:enumCase.name, params:[for (type in enumCase.params) physical(type)]
					}]
			}];
		result.staticFields = [for (field in program.staticFields)
			{
				name:field.name, type:physical(field.type)
			}];
		result.positionalFingerprints = program.positionalFingerprints;
		result.parameterDefaults = program.parameterDefaults;
		result.positionalPlaces = program.positionalPlaces;
		result.positionalSources = program.positionalSources;
		projected = result;
		return functions;
	}

	function projectFunction(fn:IrFunction, source:IrBody):IrFunction {
		if (!functionChanges(source))
			return fn;
		var body = source.forEditing(builder);
		for (value in 0...body.valueLimit()) {
			var id = IrValueId.of(value), type = body.valueTypeId(id);
			if (type >= 0 && changesId(type))
				body.setValueType(id, body.typeId(physical(body.types.type(type))));
		}
		var i32 = body.typeId(I32);
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				switch body.opcode(row) {
					case IrOpcode.MakeEnum if (body.operandCount(row) == 0 && isClosed(body.symbol(row).name)):
						body.setOperation(row, IrOpcode.ConstInt, body.auxInt(row, 1) + 1);
					case IrOpcode.ConstNull if (body.valueTypeId(body.output(row)) == i32):
						body.setOperation(row, IrOpcode.ConstInt, 0);
					case IrOpcode.TypeValue if (changesId(body.aux(row))):
						body.setAux(row, body.typeId(physical(body.typeOperand(row))));
					default:
				}
				row = body.nextRow(row);
			}
		}
		body.setResult(body.typeId(physical(body.types.type(body.result))));
		return IrFunction.ofOwnedBody(body);
	}

	function projectNative(native:IrNative):IrNative
		return {
			name: native.name,
			library: native.library,
			symbol: native.symbol,
			arguments: [for (argument in native.arguments) physical(argument)],
			result: physical(native.result),
			generatedFunctionDependencies: native.generatedFunctionDependencies
		};

	function projectCNative(native:IrCNative):IrCNative
		return {
			name: native.name,
			library: native.library,
			symbol: native.symbol,
			signature: native.signature,
			pointerOwnership: native.pointerOwnership,
			pointerRelease: native.pointerRelease,
			pointerLength: native.pointerLength,
			pointerNullable: native.pointerNullable,
			pointerSize: native.pointerSize,
			fixedResult: native.fixedResult,
			arguments: [for (argument in native.arguments) physical(argument)],
			argumentModes: native.argumentModes,
			result: physical(native.result)
		};
}

/**
 * What one function lets escape, for the closed tag ABI's choice (`IrClosedEnumTagAbi.prepare`), by type ids of the body's
 * table: the types its instructions hand to `Dyn`, a type value, a throw or a cast; each call's callee with the position and
 * type of each argument (an argument escapes when the callee is a native, or takes `Dyn` there); the closures it makes with
 * their receivers, and the map stores, which the escape reach follows. Only types that can lead to an enum are kept. It depends
 * on the body alone, so a session keeps it by the function's version (`IrStageMemos.tagEscapes`).
 */
@:nullSafety(Strict)
class IrTagEscapeRecord {
	/** The record of a function that lets nothing escape, shared. */
	@:processWide("an empty record, only ever read")
	static final NONE = new IrTagEscapeRecord();

	public final escaped:Array<Int> = [];

	/** One per distinct call argument kept: the callee, with the argument's position and type id at twice its index in `arguments`. */
	public final callees:Array<String> = [];

	public final arguments:Array<Int> = [];

	/** Pairs of a closure's type and its receiver's. */
	public final closures:Array<Int> = [];

	/** Triples of a map's type, the key's and the value's. */
	public final mapStores:Array<Int> = [];

	function new() {}

	public static function of(fn:IrFunction, types:IrTypeIds, builder:IrBodyBuilder,
			lineage:Null<IrLineage>):IrTagEscapeRecord {
		var version = lineage == null ? 0 : lineage.versionOf(fn);
		if (lineage == null || version == 0)
			return read(fn.bodyIn(types, builder));
		var memo = lineage.memos.contribution(IrClosedEnumTagAbi.ESCAPES), known = memo.get(version);
		if (known == null) {
			known = read(fn.bodyIn(types, builder));
			memo.keep(version, known);
		} else if (lineage.checks && !known.same(read(fn.bodyIn(types, builder))))
			throw new InternalError('--check-reuse: the tag escapes reused for ${fn.name} differ from its body');
		return known;
	}

	function same(other:IrTagEscapeRecord):Bool
		return escaped.join(",") == other.escaped.join(",") && callees.join(",") == other.callees.join(",")
			&& arguments.join(",") == other.arguments.join(",") && closures.join(",") == other.closures.join(",")
			&& mapStores.join(",") == other.mapStores.join(",");

	/** Whether the record has the argument at `index`, of type id `type`, of a call of `name`. */
	function hasArgument(name:String, index:Int, type:Int):Bool {
		for (entry in 0...callees.length)
			if (arguments[entry * 2 + 1] == type && arguments[entry * 2] == index && callees[entry] == name)
				return true;
		return false;
	}

	/** Whether a type can lead the escape reach to an enum (`IrEnumEscapeReach.collect`): the others add nothing to it. */
	static function leads(type:IrType):Bool
		return switch type {
			case Enum(_), EnumTag(_), Nullable(_), Array(_), Iterator(_), Function(_, _), Obj(_), Virtual(_),
				Abstract(_):
				true;
			default:
				false;
		};

	function escape(body:IrBody, value:IrValueId):Void
		escapeType(body.types, body.valueTypeId(value));

	function escapeType(types:IrTypeIds, id:Int):Void
		if (leads(types.type(id)) && escaped.indexOf(id) < 0)
			escaped.push(id);

	static function read(body:IrBody):IrTagEscapeRecord {
		var record = new IrTagEscapeRecord(), types = body.types;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				switch body.opcode(row) {
					case IrOpcode.EnumDynamicBox | IrOpcode.EnumDynamicView | IrOpcode.EnumTagBox
						| IrOpcode.EnumTagUnbox
						| IrOpcode.InlineEnumBox | IrOpcode.InlineEnumUnbox | IrOpcode.TypeValue:
						record.escapeType(types, body.aux(row));
					case IrOpcode.ToDyn | IrOpcode.ToVirtual | IrOpcode.EnumIndex | IrOpcode.Throw | IrOpcode.Rethrow:
						record.escape(body, body.operand(row, 0));
					case IrOpcode.SafeCast:
						record.escape(body, body.output(row));
						record.escape(body, body.operand(row, 0));
					case IrOpcode.Call:
						var name = body.symbol(row).name, count = body.operandCount(row);
						for (index in 0...count) {
							var type = body.valueTypeId(body.operand(row, index));
							if (!leads(types.type(type)))
								continue;
							if (!record.hasArgument(name, index, type)) {
								record.callees.push(name);
								record.arguments.push(index);
								record.arguments.push(type);
							}
						}
						if (count >= 3 && IrEnumEscapeReach.mapSetter(name)) {
							record.mapStores.push(body.valueTypeId(body.operand(row, 0)));
							record.mapStores.push(body.valueTypeId(body.operand(row, 1)));
							record.mapStores.push(body.valueTypeId(body.operand(row, count - 1)));
						}
					case IrOpcode.CNativeCall:
						for (index in 0...body.operandCount(row))
							record.escape(body, body.operand(row, index));
					case IrOpcode.CallClosure:
						switch body.valueType(body.operand(row, 0)) {
							case Dyn: for (index in 1...body.operandCount(row))
								record.escape(body, body.operand(row, index));
							default:
						}
					case IrOpcode.InstanceClosure:
						record.closures.push(body.valueTypeId(body.output(row)));
						record.closures.push(body.valueTypeId(body.operand(row, 0)));
					default:
				}
				row = body.nextRow(row);
			}
		}
		return record.escaped.length + record.callees.length + record.closures.length + record.mapStores.length == 0
			? NONE : record;
	}
}
