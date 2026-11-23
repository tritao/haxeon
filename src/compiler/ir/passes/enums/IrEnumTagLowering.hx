package compiler.ir.passes.enums;

import compiler.ir.analysis.IrTypeAwareWalk.IrWalkSummary;
import compiler.ir.model.IrBody;
import compiler.ir.model.IrBodyBuilder;
import compiler.ir.model.IrBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrOperands;
import compiler.ir.model.IrProviders;
import compiler.ir.model.IrSymbol;
import compiler.ir.model.IrTypeIds;
import compiler.ir.model.IrValueId;
import compiler.ir.passes.inlining.IrInliner;
import compiler.ir.pipeline.IrFunctionIndex;
import compiler.ir.pipeline.IrFunctionPass;
import compiler.ir.pipeline.IrFunctionStages;
import compiler.ir.reuse.IrFactReader;
import compiler.ir.reuse.IrFacts;
import compiler.ir.verify.IrVerifier;

import compiler.core.InternalError;
import compiler.ir.model.Ir;
import compiler.ir.model.SourceProvenance.Located;
import compiler.ir.passes.enums.IrInlineEnumRequests.IrInlineEnumProviders;

/** Select nominal scalar storage independently of payload-enum escape eligibility. */
@:nullSafety(Strict)
class IrEnumTagLowering {
	/** Lowers the tag-stored enums of `program` (`IrEnumTagLoweringPass`), without a memo. */
	public static function run(program:IrProgram):IrProgram {
		var pass = new IrEnumTagLoweringPass(program, null);
		program.functions = IrFunctionStages.apply("enum-tag-lowering", pass, program.functions);
		return program;
	}

	/** Run again after reflection and other helpers are generated: their escapes need the same checked ABI. */
	public static function escapes(program:IrProgram):Void {
		finishEscapes(program, program.functions);
	}

	/** Resolve only the operations a late producer has just added, without rescanning earlier functions. */
	public static function resolveGenerated(program:IrProgram, generated:Array<IrFunction>):Void {
		for (fn in generated)
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case Intrinsic(_, InlineEnumBox(_) | InlineEnumUnbox(_) | EnumTagBox(_) | EnumTagUnbox(_), _):
							finishEscapes(program, generated);
							return;
						default:
					}
	}

	public static function addAdapters(program:IrProgram, required:Map<String, Bool>, existing:IrFunctionIndex,
			boxNames:Map<String, String>, unboxNames:Map<String, String>):Void {
		var names = [for (name in required.keys()) name];
		names.sort(Reflect.compare);
		if (names.length > 0 && !Lambda.exists(program.natives, native -> native.name == "__std_is_exact_type"))
			program.natives.push({
				name: "__std_is_exact_type",
				library: "haxeon_runtime",
				symbol: "__std_is_exact_type",
				arguments: [Dyn, TypeRef],
				result: Bool
			});
		var declarations = [for (entry in program.enums) entry.name => entry];
		for (name in names) {
			var declaration = declarations.get(name), box = boxNames.get(name), unbox = unboxNames.get(name);
			if (declaration == null || box == null || unbox == null)
				throw new InternalError('Enum tag "$name" needs adapters but has no declaration or adapter names');
			if (!existing.exists(box) || !existing.exists(unbox))
				for (helper in IrEnumTagStorage.adapters(declaration, box, unbox))
					if (!existing.exists(helper.name)) {
						existing.set(helper.name, helper);
						program.functions.push(helper);
					}
		}
	}

	static function finishEscapes(program:IrProgram, changedFunctions:Array<IrFunction>):Void {
		changedFunctions = IrInlineEnumRequests.resolve(program, changedFunctions);
		var required:Map<String, Bool> = [];
		var existing = new IrFunctionIndex("enum-tag-lowering", program.functions),
			adapterEnums:Map<String, String> = [];
		var symbols = IrEnumTagStorage.adapterNames(program);
		var boxNames:Map<String, String> = [],
			unboxNames:Map<String, String> = [];
		for (name => pair in symbols) {
			boxNames.set(name, pair.box);
			unboxNames.set(name, pair.unbox);
		}
		for (fn in program.functions)
			switch fn.kind {
				case EnumTagAdapter(EnumTag(name), _):
					adapterEnums.set(fn.name, name);
				default:
			}
		if (!symbols.keys().hasNext())
			return;
		rewriteEscapes(new IrTagEscapeTables(new IrTagEscapeSignatures(program, existing), adapterEnums, boxNames,
			unboxNames, required), changedFunctions);
		addAdapters(program, required, existing, boxNames, unboxNames);
	}

	/**
	 * Boxes, in `selectedFunctions`, each tag that escapes where a `Dyn` is expected by its adapter, and turns tag boxes, unboxes
	 * and casts into adapter calls, in place: the functions are this lowering's own. What it expects where a value leaves, and the
	 * adapters, are `lookups`'s, which records the adapters it needs.
	 */
	/** The box adapter of the tag-stored enum `name`, which every tag that is boxed has. */
	public static function boxAdapter(reads:IrTagEscapeReads, name:String):String {
		var box = reads.boxName(name);
		if (box == null)
			throw new InternalError('Enum tag "$name" has no box adapter');
		return box;
	}

	/** The unbox adapter of the tag-stored enum `name`. */
	public static function unboxAdapter(reads:IrTagEscapeReads, name:String):String {
		var unbox = reads.unboxName(name);
		if (unbox == null)
			throw new InternalError('Enum tag "$name" has no unbox adapter');
		return unbox;
	}

	public static function rewriteEscapes(lookups:IrTagEscapeReads, selectedFunctions:Array<IrFunction>):Void {
		function isTag(value:IrValue):Bool
			return switch value.type {
				case EnumTag(_):
					true;
				default:
					false;
			};
		function hasTag(arguments:Array<IrValue>):Bool {
			for (argument in arguments)
				if (isTag(argument))
					return true;
			return false;
		}
		function needsArguments(arguments:Array<IrValue>, expected:Null<Array<IrType>>):Bool {
			if (expected == null)
				return false;
			for (index in 0...arguments.length)
				if (index < expected.length && isTag(arguments[index]) && (switch expected[index] {
					case Dyn:
						true;
					default:
						false;
				}))
					return true;
			return false;
		}

		if (selectedFunctions.length == 0)
			return;
		var currentFunction = selectedFunctions[0],
			currentBlock = new IrBlock(-1),
			next = -1,
			position = 0,
			blockChanged = false,
			rewritten:Array<Located<IrInstruction>> = [];
		function markChanged():Void {
			if (!blockChanged) {
				rewritten = currentBlock.instructions.slice(0, position);
				blockChanged = true;
			}
		}
		function adapt(value:IrValue, expected:Null<IrType>):IrValue {
			return switch value.type {
				case EnumTag(name) if ((switch expected {
					case Dyn: true;
					default: false;
				})): markChanged();
				if (next < 0)
					next = currentFunction.nextValueId();
				var boxed = new IrValue(next++, "$enum-tag:implicit-box", Dyn);
				lookups.require(name);
				rewritten.push(new Located(Call(boxed, IrSymbol.of(boxAdapter(lookups, name)), [value]),
					currentBlock.instructions[position].provenance));
				boxed;
				default: value;
			};
		}
		for (fn in selectedFunctions) {
			currentFunction = fn;
			next = -1;
			for (block in fn.blocks) {
				currentBlock = block;
				blockChanged = false;
				for (index in 0...block.instructions.length) {
					position = index;
					var located = block.instructions[index], changed = false;
					var instruction = switch located.value {
						case ToDyn(output, value) if (isTag(value)):
							markChanged();
							changed = true;
							var name = switch value.type {
								case EnumTag(name):
									name;
								default:
									throw new InternalError("Expected tag");
							};
							lookups.require(name);
							Call(output, IrSymbol.of(boxAdapter(lookups, name)), [value]);
						case SafeCast(output, value) if (isTag(output)):
							markChanged();
							changed = true;
							var name = switch output.type {
								case EnumTag(name):
									name;
								default:
									throw new InternalError("Expected tag");
							};
							lookups.require(name);
							Call(output, IrSymbol.of(unboxAdapter(lookups, name)), [value]);
						case Intrinsic(output, EnumTagBox(EnumTag(name)), arguments):
							if (lookups.boxName(name) == null
								|| arguments.length != 1
								|| !IrVerifier.sameType(arguments[0].type, EnumTag(name))
								|| !IrVerifier.sameType(output.type, Dyn))
								throw new InternalError("Invalid enum tag box signature");
							markChanged();
							changed = true;
							lookups.require(name);
							Call(output, IrSymbol.of(boxAdapter(lookups, name)), arguments);
						case Intrinsic(output, EnumTagUnbox(EnumTag(name)), arguments):
							if (lookups.unboxName(name) == null
								|| arguments.length != 1
								|| !IrVerifier.sameType(arguments[0].type, Dyn)
								|| !IrVerifier.sameType(output.type, EnumTag(name)))
								throw new InternalError("Invalid enum tag unbox signature");
							markChanged();
							changed = true;
							lookups.require(name);
							Call(output, IrSymbol.of(unboxAdapter(lookups, name)), arguments);
						case Call(output, name, arguments):
							var tagArgument = hasTag(arguments);
							if (!tagArgument && !isTag(output)) located.value else {
								var adapter = lookups.adapterOf(name.name);
								if (adapter != null) {
									lookups.require(adapter);
									located.value;
								} else if (!tagArgument)
									located.value
										else {
										// Lane primitives consume tags directly in the subsequent array rewrite.
										var lane = arguments.length > 0 && (switch arguments[0].type {
											case Array(EnumTag(_)): IrArrayRuntimeNatives.isStorage(name.name);
											default: false;
										});
										var expected = lane ? null : lookups.signature(name.name);
										if (!needsArguments(arguments, expected))
											located.value
												else {
												changed = true;
												Call(output, name, [
													for (index in 0...arguments.length)
														adapt(arguments[index], expected != null
														&& index < expected.length ? expected[index] : null)
												]);
											}
									}
							}
						case CNativeCall(output, name,
							arguments) if (hasTag(arguments) && needsArguments(arguments, lookups.signature(name))):
							var expected = lookups.signature(name);
							if (expected == null)
								throw new InternalError('Missing tag escape signature "$name"');
							changed = true;
							CNativeCall(output, name, [
								for (index in 0...arguments.length)
									adapt(arguments[index], index < expected.length ? expected[index] : null)
							]);
						case MethodCall(output, owner, method, arguments, terminalReceiver) if (hasTag(arguments)):
							var expected = lookups.methodArguments(owner.type, method);
							if (!needsArguments(arguments, expected)) located.value else {
								changed = true;
								MethodCall(output, owner, method, [
									for (index in 0...arguments.length)
										adapt(arguments[index],
										expected != null && index < expected.length ? expected[index] : null)
								], terminalReceiver);
							}
						case CallClosure(output, closure, arguments) if (hasTag(arguments)):
							var expected = switch closure.type {
								case Function(arguments, _):
									arguments;
								default:
									[];
							};
							if (!needsArguments(arguments, expected)) located.value else {
								changed = true;
								CallClosure(output, closure, [
									for (index in 0...arguments.length)
										adapt(arguments[index], index < expected.length ? expected[index] : null)
								]);
							}
						case FieldSet(object, field, value) if (isTag(value)):
							var expected = lookups.fieldType(object.type, field);
							if ((switch expected {
								case Dyn:
									true;
								default:
									false;
							})) {
								changed = true;
								FieldSet(object, field, adapt(value, expected));
							} else located.value;
						case GlobalSet(name, value) if (isTag(value)):
							var expected = lookups.global(name);
							if ((switch expected {
								case Dyn:
									true;
								default:
									false;
							})) {
								changed = true;
								GlobalSet(name, adapt(value, expected));
							} else located.value;
						case ArraySet(array, index, value) if (isTag(value)):
							var expected = switch array.type {
								case Array(element):
									element;
								default:
									null;
							};
							if ((switch expected {
								case Dyn:
									true;
								default:
									false;
							})) {
								changed = true;
								ArraySet(array, index, adapt(value, expected));
							} else located.value;
						default:
							located.value;
					};
					if (blockChanged)
						rewritten.push(changed ? new Located(instruction, located.provenance) : located);
				}
				if (blockChanged) {
					block.instructions.resize(0);
					for (located in rewritten)
						block.instructions.push(located);
				}
			}
		}
	}
}

/** What the escape rewrite of a function reads (`IrEnumTagLowering.rewriteEscapes`), and the adapters it records as needed. */
interface IrTagEscapeReads {
	/** The argument types of the function or native `name`, or null when there is none. */
	function signature(name:String):Null<Array<IrType>>;

	/** The argument types, receiver left out, of `method` called on a value of `type`, or null. */
	function methodArguments(type:IrType, method:String):Null<Array<IrType>>;

	/** The declared type of `field` on an object of `type`, or null. */
	function fieldType(type:IrType, field:String):Null<IrType>;

	function global(name:String):Null<IrType>;

	/** The enum `name` is a tag adapter of, or null. */
	function adapterOf(name:String):Null<String>;

	function boxName(enumName:String):Null<String>;
	function unboxName(enumName:String):Null<String>;

	/** The adapters of the tag-stored enum `enumName` are needed. */
	function require(enumName:String):Void;
}

/**
 * The inline-enum requests and tag escapes of each function, as the last step of assembly and the pipeline's last check before the
 * inliner (`IrBodyTagEscapes`), per function (`IrFunctionPass`) on bodies: a function that changes becomes its edited body, owned
 * by the next stage. The rewrite reads, through the fact reader, whether the program has tag adapters at all (`TAGS`), the
 * signatures, fields and globals where a tag leaves the function, which callees are tag adapters, the adapters' names and the
 * provider of each inline-enum request; it asks for the adapters it needs, which `finish` adds.
 */
@:nullSafety(Strict)
class IrTagEscapesPass implements IrFunctionPass implements IrTagEscapeReads {
	// Facts.
	static inline final TAGS = 0;
	static inline final SIGNATURE = 1;
	static inline final METHOD = 2;
	static inline final FIELD = 3;
	static inline final GLOBAL = 4;
	static inline final ADAPTER = 5;
	static inline final ADAPTER_NAMES = 6;
	static inline final PROVIDER = 7;

	/** The helper kind of an enum's adapters (`request`). */
	static inline final ADAPTERS = 0;

	final program:IrProgram;
	final types:IrTypeIds;
	final builder:IrBodyBuilder;
	final adapterEnums:Map<String, String> = [];
	final boxNames:Map<String, String> = [];
	final unboxNames:Map<String, String> = [];
	final required:Map<String, Bool> = [];
	final providers:IrInlineEnumProviders;
	var tags = false;
	var existing:Null<IrFunctionIndex> = null;
	var lookups:Null<IrTagEscapeSignatures> = null;

	/** The reader of the function being rewritten when it records, else null. */
	var reader:Null<IrFactReader> = null;

	/** The enums whose adapters the function being rewritten asked for, so it asks once. */
	var asked:Map<String, Bool> = [];

	public function new(program:IrProgram, types:IrTypeIds, builder:IrBodyBuilder) {
		this.program = program;
		this.types = types;
		this.builder = builder;
		providers = new IrInlineEnumProviders(program);
	}

	public function summarize(fn:IrFunction):Int
		return 0;

	public function prepare(functions:Array<IrFunction>, summaries:Array<Int>, names:IrFunctionIndex):Void {
		existing = names;
		for (name => pair in IrEnumTagStorage.adapterNames(program)) {
			boxNames.set(name, pair.box);
			unboxNames.set(name, pair.unbox);
			tags = true;
		}
		for (fn in functions)
			switch fn.kind {
				case EnumTagAdapter(EnumTag(name), _):
					adapterEnums.set(fn.name, name);
				default:
			}
		lookups = new IrTagEscapeSignatures(program, names);
	}

	/** The key of a provider fact: box or unbox, then the type ids of the request's type, argument and output, and its count. */
	function providerKey(box:Bool, type:IrType, count:Int, argument:Null<IrType>, output:IrType):String
		return (box ? "B" : "U") + types.id(type) + ":" + count + ":" + (argument == null ? -1 : types.id(argument))
			+ ":"
			+ types.id(output);

	public function fact(kind:Int, key:String):Int {
		var tables = lookups;
		return switch kind {
			case TAGS: tags ? 1 : 0;
			case SIGNATURE: tables == null ? -1 : IrEnumTagLoweringPass.dynMask(tables.signature(key));
			case METHOD:
				var split = key.indexOf("\u0001");
				tables == null ? -1
					: IrEnumTagLoweringPass.dynMask(tables.methodArguments(IrEnumTagLoweringPass.keyType(key.substr(0,
					split)), key.substr(split + 1)));
			case FIELD:
				var split = key.indexOf("\u0001");
				tables != null
					&& isDyn(tables.fieldType(IrEnumTagLoweringPass.keyType(key.substr(0, split)),
					key.substr(split + 1))) ? 1 : 0;
			case GLOBAL: tables != null && isDyn(tables.global(key)) ? 1 : 0;
			case ADAPTER: adapterEnums.exists(key) ? 1 : 0;
			case ADAPTER_NAMES:
				boxNames.get(key) == "$enum-tag-box:" + key
					&& unboxNames.get(key) == "$enum-tag-unbox:" + key ? 0 : IrFacts.UNKNOWN;
			case PROVIDER: providerFact(key);
			default: IrFacts.UNKNOWN;
		};
	}

	/** The symbol of the provider a request's key names (`providerKey`), or `IrFacts.UNKNOWN` when it has none that fits. */
	function providerFact(key:String):Int {
		var parts = [for (part in key.substr(1).split(":")) Std.parseInt(part) ?? -1], argument = parts[2];
		try {
			return IrSymbol.of(providers.provider(key.charAt(0) == "B", types.type(parts[0]), parts[1],
				argument < 0 ? null : types.type(argument), types.type(parts[3]))).id;
		} catch (error:InternalError) {
			return IrFacts.UNKNOWN;
		}
	}

	static function isDyn(type:Null<IrType>):Bool
		return switch type {
			case Dyn: true;
			default: false;
		};

	/** Whether the program has tag adapters, which a rewrite reads as a fact. */
	public function hasTags():Bool {
		var current = reader;
		if (current != null)
			current.read(TAGS, "");
		return tags;
	}

	/** The provider an inline-enum request resolves to (`IrInlineEnumProviders.provider`). */
	public function provider(box:Bool, type:IrType, count:Int, argument:Null<IrType>, output:IrType):String {
		var current = reader;
		if (current != null)
			current.read(PROVIDER, providerKey(box, type, count, argument, output));
		return providers.provider(box, type, count, argument, output);
	}

	public function signature(name:String):Null<Array<IrType>> {
		var current = reader, tables = lookups;
		if (current != null)
			current.read(SIGNATURE, name);
		return tables == null ? null : tables.signature(name);
	}

	public function methodArguments(type:IrType, method:String):Null<Array<IrType>> {
		var current = reader, tables = lookups, key = IrEnumTagLoweringPass.typeKey(type);
		if (key == null)
			return null;
		if (current != null)
			current.read(METHOD, key + "\u0001" + method);
		return tables == null ? null : tables.methodArguments(type, method);
	}

	public function fieldType(type:IrType, field:String):Null<IrType> {
		var current = reader, tables = lookups, key = switch type {
			case Obj(_): IrEnumTagLoweringPass.typeKey(type);
			default: null;
		};
		if (key == null)
			return null;
		if (current != null)
			current.read(FIELD, key + "\u0001" + field);
		return tables == null ? null : tables.fieldType(type, field);
	}

	public function global(name:String):Null<IrType> {
		var current = reader, tables = lookups;
		if (current != null)
			current.read(GLOBAL, name);
		return tables == null ? null : tables.global(name);
	}

	public function adapterOf(name:String):Null<String> {
		var current = reader;
		if (current != null)
			current.read(ADAPTER, name);
		return adapterEnums.get(name);
	}

	public function boxName(enumName:String):Null<String> {
		var current = reader;
		if (current != null)
			current.read(ADAPTER_NAMES, enumName);
		return boxNames.get(enumName);
	}

	public function unboxName(enumName:String):Null<String> {
		var current = reader;
		if (current != null)
			current.read(ADAPTER_NAMES, enumName);
		return unboxNames.get(enumName);
	}

	public function require(enumName:String):Void {
		var current = reader;
		if (current == null)
			required.set(enumName, true);
		else if (!asked.exists(enumName)) {
			asked.set(enumName, true);
			current.request(ADAPTERS, EnumTag(enumName));
		}
	}

	public function request(kind:Int, type:IrType, name:Null<String>):Void
		switch type {
			case EnumTag(name): required.set(name, true);
			default: throw new InternalError("An enum tag adapter request names no tag");
		}

	public function transform(fn:IrFunction, summary:Int, reader:IrFactReader):IrFunction {
		this.reader = reader.records() ? reader : null;
		if (this.reader != null)
			asked = [];
		var walk = new IrBodyTagEscapes(this), body = fn.bodyIn(types, builder), result = fn;
		if (walk.rewrite(body, false)) {
			var edited = body.forEditing(builder);
			walk.rewrite(edited, true);
			result = IrFunction.ofOwnedBody(edited);
		}
		this.reader = null;
		return result;
	}

	public function finish(functions:Array<IrFunction>):Array<IrFunction> {
		program.functions = functions;
		var names = existing;
		if (tags && names != null)
			IrEnumTagLowering.addAdapters(program, required, names, boxNames, unboxNames);
		return program.functions;
	}
}

/** `IrTagEscapeReads` from the program's tables, as a lowering without a memo reads them. */
@:nullSafety(Strict)
class IrTagEscapeTables implements IrTagEscapeReads {
	final lookups:IrTagEscapeSignatures;
	final adapterEnums:Map<String, String>;
	final boxNames:Map<String, String>;
	final unboxNames:Map<String, String>;
	final required:Map<String, Bool>;

	public function new(lookups:IrTagEscapeSignatures, adapterEnums:Map<String, String>, boxNames:Map<String, String>,
			unboxNames:Map<String, String>, required:Map<String, Bool>) {
		this.lookups = lookups;
		this.adapterEnums = adapterEnums;
		this.boxNames = boxNames;
		this.unboxNames = unboxNames;
		this.required = required;
	}

	public function signature(name:String):Null<Array<IrType>>
		return lookups.signature(name);

	public function methodArguments(type:IrType, method:String):Null<Array<IrType>>
		return lookups.methodArguments(type, method);

	public function fieldType(type:IrType, field:String):Null<IrType>
		return lookups.fieldType(type, field);

	public function global(name:String):Null<IrType>
		return lookups.global(name);

	public function adapterOf(name:String):Null<String>
		return adapterEnums.get(name);

	public function boxName(enumName:String):Null<String>
		return boxNames.get(enumName);

	public function unboxName(enumName:String):Null<String>
		return unboxNames.get(enumName);

	public function require(enumName:String):Void
		required.set(enumName, true);
}

/** The types an escape check expects where a value leaves its function: arguments of calls, fields, globals. Memoized by name. */
@:nullSafety(Strict)
class IrTagEscapeSignatures {
	final functions:IrFunctionIndex;

	/** The argument types of a function by name, when given: in place of the functions' own (`IrEnumTagLoweringPass`). */
	final argumentsOf:Null<String->Null<Array<IrType>>>;

	final signatures:Map<String, Array<IrType>> = [];
	final objects:Map<String, IrObject>;
	final globals:Map<String, IrType>;
	final contracts:Map<String, IrInterface>;
	final fieldTypes:Map<String, Map<String, Null<IrType>>> = [];
	final interfaceMethods:Map<String, Map<String, Null<Array<IrType>>>> = [];
	final objectMethods:Map<String, Map<String, Null<Array<IrType>>>> = [];
	final methodNames:Map<String, Map<String, String>> = [];

	public function new(program:IrProgram, functions:IrFunctionIndex, ?argumentsOf:String->Null<Array<IrType>>) {
		this.functions = functions;
		this.argumentsOf = argumentsOf;
		objects = [for (object in program.objects) object.name => object];
		globals = [for (field in program.staticFields) field.name => field.type];
		contracts = [for (entry in program.interfaces) entry.name => entry];
		for (native in program.natives)
			signatures.set(native.name, native.arguments);
		for (native in program.cNatives)
			signatures.set(native.name, native.arguments);
	}

	/** The argument types of the function or native `name`, or null when there is none. */
	public function signature(name:String):Null<Array<IrType>> {
		if (signatures.exists(name))
			return signatures.get(name);
		var resolve = argumentsOf;
		if (resolve != null) {
			var given = resolve(name);
			if (given != null)
				signatures.set(name, given);
			return given;
		}
		var fn = functions.get(name);
		if (fn == null)
			return null;
		var arguments = [for (argument in fn.arguments) argument.type];
		signatures.set(name, arguments);
		return arguments;
	}

	public function global(name:String):Null<IrType>
		return globals.get(name);

	function fieldIndex(name:String):Null<Map<String, Null<IrType>>> {
		var known = fieldTypes.get(name);
		if (known != null)
			return known;
		var object = objects.get(name);
		if (object == null)
			return null;
		var index:Map<String, Null<IrType>> = [for (field in object.fields) field.name => field.type];
		fieldTypes.set(name, index);
		return index;
	}

	/** The declared type of `field` on an object of `type`, inherited ones included, or null. */
	public function fieldType(type:IrType, field:String):Null<IrType> {
		var name = switch type {
			case Obj(name):
				name;
			default:
				return null;
		}, cache = fieldIndex(name);
		if (cache == null)
			return null;
		if (cache.exists(field))
			return cache.get(field);
		var object = objects.get(name),
			owner = object == null ? null : object.base;
		while (owner != null) {
			var inherited = fieldIndex(owner);
			if (inherited != null && inherited.exists(field)) {
				var type = inherited.get(field);
				cache.set(field, type);
				return type;
			}
			var parent = objects.get(owner);
			owner = parent == null ? null : parent.base;
		}
		cache.set(field, null);
		return null;
	}

	function interfaceArguments(name:String, method:String):Null<Array<IrType>> {
		var declaration = contracts.get(name);
		if (declaration == null)
			return null;
		var cache = interfaceMethods.get(name);
		if (cache == null) {
			cache = [for (entry in declaration.methods) entry.name => entry.arguments];
			interfaceMethods.set(name, cache);
		}
		if (cache.exists(method))
			return cache.get(method);
		for (base in declaration.bases) {
			var inherited = interfaceArguments(base, method);
			if (inherited != null) {
				cache.set(method, inherited);
				return inherited;
			}
		}
		cache.set(method, null);
		return null;
	}

	function methodIndex(name:String):Null<Map<String, String>> {
		var known = methodNames.get(name);
		if (known != null)
			return known;
		var object = objects.get(name);
		if (object == null)
			return null;
		var index = [for (entry in object.methods) entry.name => entry.functionName.name];
		methodNames.set(name, index);
		return index;
	}

	/** The argument types, receiver left out, of `method` called on a value of `type`, or null. */
	public function methodArguments(type:IrType, method:String):Null<Array<IrType>> {
		var name = switch type {
			case Virtual(name):
				return interfaceArguments(name, method);
			case Obj(name):
				name;
			default:
				return null;
		}, cache = objectMethods.get(name);
		if (cache == null) {
			cache = [];
			objectMethods.set(name, cache);
		}
		if (cache.exists(method))
			return cache.get(method);
		var owner:Null<String> = name, result:Null<Array<IrType>> = null;
		while (owner != null) {
			var methods = methodIndex(owner),
				target = methods == null ? null : methods.get(method);
			if (target != null) {
				var arguments = signature(target);
				if (arguments != null)
					result = arguments.slice(1);
				break;
			}
			var object = objects.get(owner);
			owner = object == null ? null : object.base;
		}
		cache.set(method, result);
		return result;
	}
}

/**
 * `IrEnumTagLowering.finishEscapes` on a body: inline-enum requests become calls of their providers, and, when the program has
 * tag adapters, a tag that escapes where a `Dyn` is expected is boxed by its adapter, as the object version does. Everything it
 * reads of the program is read through `reads` (`IrTagEscapesPass`), which records it, and so are the adapters it needs. A walk
 * that does not `edit` only says whether one that does would change the body.
 */
@:nullSafety(Strict)
class IrBodyTagEscapes {
	final reads:IrTagEscapesPass;

	/** Whether the program has tag adapters: -1 until a row with a tag asks, so a body without tags does not read it. */
	var tags = -1;
	/** The body being rewritten (`rewrite`), null before the first. */
	var body:Null<IrBody> = null;
	var edit = false;
	var changed = false;

	public function new(reads:IrTagEscapesPass) {
		this.reads = reads;
	}

	inline function requireBody():IrBody {
		var current = body;
		if (current == null)
			throw new InternalError("Tag escapes were asked about before a body was given");
		return current;
	}

	/** Whether `body` changes; it is changed when `edit` is set. */
	public function rewrite(body:IrBody, edit:Bool):Bool {
		this.body = body;
		this.edit = edit;
		tags = -1;
		changed = false;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var following = body.nextRow(row);
				visit(block, row);
				if (changed && !edit)
					return true;
				row = following;
			}
		}
		return changed;
	}

	static function tagName(type:IrType):Null<String>
		return switch type {
			case EnumTag(name): name;
			default: null;
		};

	static function isDyn(type:Null<IrType>):Bool
		return switch type {
			case Dyn: true;
			default: false;
		};

	inline function isTag(value:IrValueId):Bool
		return tagName(requireBody().valueType(value)) != null;

	function hasTag(row:Int, from:Int):Bool {
		var body = requireBody();
		for (index in from...body.operandCount(row))
			if (isTag(body.operand(row, index)))
				return true;
		return false;
	}

	function needsArguments(row:Int, from:Int, expected:Null<Array<IrType>>):Bool {
		var body = requireBody();
		if (expected == null)
			return false;
		for (index in from...body.operandCount(row))
			if (index - from < expected.length && isTag(body.operand(row, index)) && isDyn(expected[index - from]))
				return true;
		return false;
	}

	/** Makes `row` a call of `name` with its operands and output. */
	function call(row:Int, name:String):Void {
		var body = requireBody();
		changed = true;
		if (edit)
			body.setOperation(row, IrOpcode.Call, IrSymbol.of(name).id);
	}

	/** Boxes each tag operand of `row` from `from` on whose expected type is `Dyn`, in a call before the row. */
	function adapt(block:Int, row:Int, from:Int, expected:Null<Array<IrType>>):Void {
		var body = requireBody();
		changed = true;
		if (!edit || expected == null)
			return;
		for (index in from...body.operandCount(row)) {
			var value = body.operand(row, index), name = tagName(body.valueType(value));
			if (name == null || index - from >= expected.length || !isDyn(expected[index - from]))
				continue;
			adaptOne(block, row, index, value, name);
		}
	}

	function adaptOne(block:Int, row:Int, index:Int, value:IrValueId, name:String):Void {
		var body = requireBody();
		var boxed = body.newValue("$enum-tag:implicit-box", body.typeId(Dyn));
		reads.require(name);
		body.beginRow();
		body.pushOperand(value);
		var made = body.endRow(IrOpcode.Call, boxed, IrSymbol.of(IrEnumTagLowering.boxAdapter(reads, name)).id,
			body.provenance(row));
		body.linkBefore(block, row, made);
		body.setOperand(row, index, boxed);
	}

	function hasTags():Bool {
		if (tags < 0)
			tags = reads.hasTags() ? 1 : 0;
		return tags == 1;
	}

	/** Whether a tag is among `row`'s operands, its output or the type it names: the rows the tag escapes rewrite. */
	function involvesTag(row:Int):Bool {
		var body = requireBody();
		var output = body.output(row);
		if (hasTag(row, 0) || output.exists() && isTag(output))
			return true;
		var opcode = body.opcode(row);
		return (opcode == IrOpcode.EnumTagBox || opcode == IrOpcode.EnumTagUnbox)
			&& tagName(body.typeOperand(row)) != null;
	}

	function visit(block:Int, row:Int):Void {
		var body = requireBody();
		switch body.opcode(row) {
			case IrOpcode.InlineEnumBox, IrOpcode.InlineEnumUnbox:
				var count = body.operandCount(row);
				call(row, reads.provider(body.opcode(row) == IrOpcode.InlineEnumBox, body.typeOperand(row), count,
					count == 1 ? body.valueType(body.operand(row, 0)) : null, body.valueType(body.output(row))));
			case _ if (!involvesTag(row) || !hasTags()):
			case IrOpcode.ToDyn:
				var name = tagName(body.valueType(body.operand(row, 0)));
				if (name != null) {
					reads.require(name);
					call(row, IrEnumTagLowering.boxAdapter(reads, name));
				}
			case IrOpcode.SafeCast:
				var name = tagName(body.valueType(body.output(row)));
				if (name != null) {
					reads.require(name);
					call(row, IrEnumTagLowering.unboxAdapter(reads, name));
				}
			case IrOpcode.EnumTagBox:
				var name = tagName(body.typeOperand(row));
				if (name != null) {
					if (reads.boxName(name) == null
						|| body.operandCount(row) != 1
						|| !IrVerifier.sameType(body.valueType(body.operand(row, 0)), EnumTag(name))
						|| !IrVerifier.sameType(body.valueType(body.output(row)), Dyn))
						throw new InternalError("Invalid enum tag box signature");
					reads.require(name);
					call(row, IrEnumTagLowering.boxAdapter(reads, name));
				}
			case IrOpcode.EnumTagUnbox:
				var name = tagName(body.typeOperand(row));
				if (name != null) {
					if (reads.unboxName(name) == null
						|| body.operandCount(row) != 1
						|| !IrVerifier.sameType(body.valueType(body.operand(row, 0)), Dyn)
						|| !IrVerifier.sameType(body.valueType(body.output(row)), EnumTag(name)))
						throw new InternalError("Invalid enum tag unbox signature");
					reads.require(name);
					call(row, IrEnumTagLowering.unboxAdapter(reads, name));
				}
			case IrOpcode.Call:
				var tagArgument = hasTag(row, 0), output = body.output(row);
				if (!tagArgument && (!output.exists() || !isTag(output)))
					return;
				var name = body.symbol(row).name, adapter = reads.adapterOf(name);
				if (adapter != null) {
					reads.require(adapter);
					return;
				}
				if (!tagArgument)
					return;
				// Lane primitives consume tags directly in the subsequent array rewrite.
				var lane = body.operandCount(row) > 0 && (switch body.valueType(body.operand(row, 0)) {
					case Array(EnumTag(_)): IrArrayRuntimeNatives.isStorage(name);
					default: false;
				});
				var expected = lane ? null : reads.signature(name);
				if (needsArguments(row, 0, expected))
					adapt(block, row, 0, expected);
			case IrOpcode.CNativeCall:
				if (!hasTag(row, 0))
					return;
				var name = body.symbol(row).name, expected = reads.signature(name);
				if (needsArguments(row, 0, expected))
					adapt(block, row, 0, expected);
			case IrOpcode.MethodCall:
				if (!hasTag(row, 1))
					return;
				var expected = reads.methodArguments(body.valueType(body.operand(row, 0)), body.symbol(row).name);
				if (needsArguments(row, 1, expected))
					adapt(block, row, 1, expected);
			case IrOpcode.CallClosure:
				if (!hasTag(row, 1))
					return;
				var expected = switch body.valueType(body.operand(row, 0)) {
					case Function(arguments, _): arguments;
					default: [];
				};
				if (needsArguments(row, 1, expected))
					adapt(block, row, 1, expected);
			case IrOpcode.FieldSet:
				var value = body.operand(row, 1), name = tagName(body.valueType(value));
				if (name != null
					&& isDyn(reads.fieldType(body.valueType(body.operand(row, 0)), body.symbol(row).name)))
					boxOperand(block, row, 1, value, name);
			case IrOpcode.GlobalSet:
				var value = body.operand(row, 0), name = tagName(body.valueType(value));
				if (name != null && isDyn(reads.global(body.symbol(row).name)))
					boxOperand(block, row, 0, value, name);
			case IrOpcode.ArraySet:
				var value = body.operand(row, 2), name = tagName(body.valueType(value));
				if (name != null && isDyn(switch body.valueType(body.operand(row, 0)) {
					case Array(element): element;
					default: null;
				}))
					boxOperand(block, row, 2, value, name);
			default:
		}
	}

	function boxOperand(block:Int, row:Int, index:Int, value:IrValueId, name:String):Void {
		changed = true;
		if (edit)
			adaptOne(block, row, index, value, name);
	}
}

/**
 * Selects nominal scalar storage for the payload-free enums that can have it (`IrEnumTagStorage.eligible`), per function
 * (`IrFunctionPass`). A function whose values, calls or type values involve such an enum is rewritten to carry its tag, and the
 * tags its rewrite lets escape where a `Dyn` is expected are boxed by the enum's adapter (`IrEnumTagLowering.rewriteEscapes`).
 * The rewrite reads, through the fact reader: which enums are eligible (`ELIGIBLE`), which callees are tag equalities, native
 * wrappers or Dynamic unboxes, the signatures, fields and globals where a tag leaves the function, which callees are tag
 * adapters and the adapters' names; it asks for the adapters it needs. The program's tables, the native wrappers, the adapters
 * and the dropping of tag equalities nothing calls are the whole-program steps around it.
 */
@:nullSafety(Strict)
class IrEnumTagLoweringPass implements IrFunctionPass implements IrTagEscapeReads {
	// Facts.
	static inline final ELIGIBLE = 0;
	static inline final TAG_EQUALITY = 1;
	static inline final WRAPPER = 2;
	static inline final UNBOX = 3;
	static inline final SIGNATURE = 4;
	static inline final METHOD = 5;
	static inline final FIELD = 6;
	static inline final GLOBAL = 7;
	static inline final ADAPTER = 8;
	static inline final ADAPTER_NAMES = 9;

	/** Of a function with inline enum requests, which its providers resolve: never stated, so such a function is always redone. */
	static inline final INLINE_REQUESTS = 10;

	/** The summary of a function with inline enum box or unbox requests. */
	static inline final HAS_INLINE_REQUESTS = 1;

	/** The helper kind of an enum's adapters (`request`). */
	static inline final ADAPTERS = 0;

	final program:IrProgram;
	final lineage:Null<compiler.ir.reuse.IrStageMemo.IrLineage>;
	var names:Map<String, Bool> = [];
	final dynamicUnboxes:Map<String, IrType> = [];
	final tagEqualities:Map<String, Bool> = [];
	final nativeWrappers:Map<String, String> = [];
	final generated:Array<IrFunction> = [];
	final adapterEnums:Map<String, String> = [];
	final boxNames:Map<String, String> = [];
	final unboxNames:Map<String, String> = [];
	final required:Map<String, Bool> = [];
	var input:Null<IrFunctionIndex> = null;
	var lookups:Null<IrTagEscapeSignatures> = null;
	var generatedByName:Map<String, IrFunction> = [];

	/** The reader of the function being transformed; null outside a transform, where the program's tables are read directly. */
	var reader:Null<IrFactReader> = null;

	public function new(program:IrProgram, lineage:Null<compiler.ir.reuse.IrStageMemo.IrLineage>) {
		this.program = program;
		this.lineage = lineage;
	}

	function eligible(name:String):Bool {
		var current = reader;
		return current != null ? current.read(ELIGIBLE, name) == 1 : names.exists(name);
	}

	function changes(type:IrType):Bool
		return switch type {
			case Enum(name):
				eligible(name);
			case Array(inner), Iterator(inner), Nullable(inner):
				changes(inner);
			case Function(arguments, result):
				var changed = changes(result);
				for (argument in arguments)
					if (changes(argument)) {
						changed = true;
						break;
					}
				changed;
			default:
				false;
		};

	function mapped(type:IrType):IrType
		return switch type {
			case Enum(name) if (eligible(name)):
				EnumTag(name);
			case Nullable(Enum(name)) if (eligible(name)):
				EnumTag(name);
			case Array(inner) if (changes(inner)):
				Array(mapped(inner));
			case Iterator(inner) if (changes(inner)):
				Iterator(mapped(inner));
			case Nullable(inner) if (changes(inner)):
				Nullable(mapped(inner));
			case Function(arguments, result) if (changes(type)):
				Function([for (argument in arguments) mapped(argument)], mapped(result));
			default:
				type;
		};

	function isTagEquality(name:String):Bool {
		var current = reader;
		return current != null ? current.read(TAG_EQUALITY, name) == 1 : tagEqualities.exists(name);
	}

	function wrapperOf(name:String):Null<String> {
		var current = reader;
		if (current != null)
			current.read(WRAPPER, name);
		return nativeWrappers.get(name);
	}

	function wrapperName(name:String):String {
		var wrapper = wrapperOf(name);
		if (wrapper == null)
			throw new InternalError('Native "$name" has no enum tag wrapper');
		return wrapper;
	}

	function unboxOf(name:String):Null<IrType> {
		var current = reader;
		if (current != null)
			current.read(UNBOX, name);
		return dynamicUnboxes.get(name);
	}

	public function summarize(fn:IrFunction):Int {
		for (block in fn.blocks)
			for (located in block.instructions)
				switch located.value {
					case Intrinsic(_, InlineEnumBox(_) | InlineEnumUnbox(_), _):
						return HAS_INLINE_REQUESTS;
					default:
				}
		return 0;
	}

	public function prepare(functions:Array<IrFunction>, summaries:Array<Int>, index:IrFunctionIndex):Void {
		input = index;
		for (fn in functions)
			switch fn.kind {
				case EnumDynamicUnbox(type):
					dynamicUnboxes.set(fn.name, type);
				default:
			}
		names = [for (entry in program.enums) if (IrEnumTagStorage.eligible(entry)) entry.name => true];
		if (!names.keys().hasNext())
			return;
		// Payload-free enums cannot override equality. Their synthesized calls are
		// scalar comparisons even with source inlining disabled.
		for (fn in functions)
			if ((switch fn.provides {
				case Serves(_,
					operation): (IrProviders.base(operation) == compiler.core.Provides.ProviderOperation.Equals
					|| IrProviders.base(operation) == compiler.core.Provides.ProviderOperation.ReflectEquals);
				case None: false;
			}) && fn.arguments.length == 2)
				switch mapped(fn.arguments[0].type) {
				case EnumTag(name):
					if (IrVerifier.sameType(mapped(fn.arguments[1].type), EnumTag(name)))
						tagEqualities.set(fn.name, true);
				default:
			}
		for (native in program.natives)
			nativeWrapper(native.name, native.arguments, native.result, false);
		for (native in program.cNatives)
			nativeWrapper(native.name, native.arguments, native.result, true);
		generatedByName = [for (fn in generated) fn.name => fn];
		program.objects = [for (object in program.objects)
			{
				name:object.name,
					isValue:object.isValue,
					nativeLayout:object.nativeLayout,
					base:object.base,
					interfaces:object.interfaces,
					methods:object.methods,
					fields:[for (field in object.fields)
					{
						name:field.name,
							type:mapped(field.type),
							nativeLayout:field.nativeLayout,
							scalarStorage:field.scalarStorage,
							nullableScalarStorage:field.nullableScalarStorage
					}]
			}];
		program.staticFields = [for (field in program.staticFields) {
			name:field.name, type:mapped(field.type)
		}];
		program.interfaces = [for (entry in program.interfaces)
			{
				name:entry.name,
					bases:entry.bases,
					methods:[for (method in entry.methods)
					{
						name:method.name,
							arguments:[for (argument in method.arguments) mapped(argument)],
							result:mapped(method.result)
					}]
			}];
		program.enums = [for (entry in program.enums)
			{
				name:entry.name,
					isRecursive:entry.isRecursive,
					inlineStorage:entry.inlineStorage,
					cases:[for (constructor in entry.cases)
					{
						name:constructor.name, params:[for (parameter in constructor.params) mapped(parameter)]
					}]
			}];
		// What the escapes read: the program's tables as lowered, and the functions' signatures as their rewrite makes them.
		for (fn in functions)
			switch fn.kind {
				case EnumTagAdapter(EnumTag(name), _):
					adapterEnums.set(fn.name, name);
				default:
			}
		var view = new IrProgram(program.entryPoint);
		view.enums = program.enums;
		view.functions = functions.concat(generated);
		for (name => pair in IrEnumTagStorage.adapterNames(view)) {
			boxNames.set(name, pair.box);
			unboxNames.set(name, pair.unbox);
		}
		lookups = new IrTagEscapeSignatures(program, index, argumentsOf);
	}

	/** The argument types of `name` as the rewrite makes them: a generated wrapper's own, a function's lowered. */
	function argumentsOf(name:String):Null<Array<IrType>> {
		var made = generatedByName.get(name);
		if (made != null)
			return [for (argument in made.arguments) argument.type];
		var functions = input, fn = functions == null ? null : functions.get(name);
		return fn == null ? null : [for (argument in fn.arguments) mapped(argument.type)];
	}

	function nativeWrapper(name:String, arguments:Array<IrType>, result:IrType, cNative:Bool):Void {
		function directTag(type:IrType):Bool
			return switch mapped(type) {
				case EnumTag(_): true;
				default: false;
			};
		if (!Lambda.exists(arguments, directTag) && !directTag(result))
			return;
		var wrapper = "$enum-tag:native:" + name,
			b = new IrBuilder(),
			converted:Array<IrValue> = [];
		for (index in 0...arguments.length) {
			var logical = arguments[index],
				physical = mapped(logical),
				value = b.argument('argument$index', physical);
			converted.push(switch physical {
				case EnumTag(enumName): b.safeCast(b.intrinsic(EnumTagBox(EnumTag(enumName)), [value], Dyn), logical);
				default: value;
			});
		}
		var called = cNative ? b.cNativeCall(name, converted, result) : b.call(name, converted, result);
		var returned = switch mapped(result) {
			case EnumTag(enumName): b.intrinsic(EnumTagUnbox(EnumTag(enumName)), [b.toDyn(called)], mapped(result));
			default: called;
		};
		b.returnValue(returned);
		generated.push(new IrFunction(wrapper, b.arguments, mapped(result), b.blocks, GeneratedHelper));
		nativeWrappers.set(name, wrapper);
	}

	/** Encodes the positions of `Dyn` in `types` for a fact: -1 for none at all, `IrFacts.UNKNOWN` past 30 arguments. */
	public static function dynMask(types:Null<Array<IrType>>):Int {
		if (types == null)
			return -1;
		var mask = 0;
		for (index in 0...types.length)
			if (isDyn(types[index])) {
				if (index >= 30)
					return IrFacts.UNKNOWN;
				mask |= 1 << index;
			}
		return mask;
	}

	static function isDyn(type:Null<IrType>):Bool
		return switch type {
			case Dyn: true;
			default: false;
		};

	/** The object type of a fact key: `O` for a class, `V` for an interface, then the name. */
	public static function typeKey(type:IrType):Null<String>
		return switch type {
			case Obj(name): "O" + name;
			case Virtual(name): "V" + name;
			default: null;
		};

	public static function keyType(key:String):IrType {
		var name = key.substr(1);
		return key.charAt(0) == "V" ? Virtual(name) : Obj(name);
	}

	public function fact(kind:Int, key:String):Int {
		var tables = lookups;
		return switch kind {
			case ELIGIBLE: names.exists(key) ? 1 : 0;
			case TAG_EQUALITY: tagEqualities.exists(key) ? 1 : 0;
			case WRAPPER: nativeWrappers.exists(key) ? 1 : 0;
			case UNBOX: dynamicUnboxes.exists(key) ? 1 : 0;
			case SIGNATURE: tables == null ? -1 : dynMask(tables.signature(key));
			case METHOD:
				var split = key.indexOf("\u0001");
				tables == null
					? -1 : dynMask(tables.methodArguments(keyType(key.substr(0, split)), key.substr(split + 1)));
			case FIELD:
				var split = key.indexOf("\u0001");
				tables != null && isDyn(tables.fieldType(keyType(key.substr(0, split)), key.substr(split + 1))) ? 1 : 0;
			case GLOBAL: tables != null && isDyn(tables.global(key)) ? 1 : 0;
			case ADAPTER: adapterEnums.exists(key) ? 1 : 0;
			case ADAPTER_NAMES:
				boxNames.get(key) == "$enum-tag-box:" + key
					&& unboxNames.get(key) == "$enum-tag-unbox:" + key ? 0 : IrFacts.UNKNOWN;
			default: IrFacts.UNKNOWN;
		};
	}

	// What the escape rewrite reads (`IrTagEscapeReads`), recorded as facts while a function is transformed.

	public function signature(name:String):Null<Array<IrType>> {
		var current = reader, tables = lookups;
		if (current != null)
			current.read(SIGNATURE, name);
		return tables == null ? null : tables.signature(name);
	}

	public function methodArguments(type:IrType, method:String):Null<Array<IrType>> {
		var current = reader, tables = lookups, key = typeKey(type);
		if (key == null)
			return null;
		if (current != null)
			current.read(METHOD, key + "\u0001" + method);
		return tables == null ? null : tables.methodArguments(type, method);
	}

	public function fieldType(type:IrType, field:String):Null<IrType> {
		var current = reader, tables = lookups, key = switch type {
			case Obj(_): typeKey(type);
			default: null;
		};
		if (key == null)
			return null;
		if (current != null)
			current.read(FIELD, key + "\u0001" + field);
		return tables == null ? null : tables.fieldType(type, field);
	}

	public function global(name:String):Null<IrType> {
		var current = reader, tables = lookups;
		if (current != null)
			current.read(GLOBAL, name);
		return tables == null ? null : tables.global(name);
	}

	public function adapterOf(name:String):Null<String> {
		var current = reader;
		if (current != null)
			current.read(ADAPTER, name);
		return adapterEnums.get(name);
	}

	public function boxName(enumName:String):Null<String> {
		var current = reader;
		if (current != null)
			current.read(ADAPTER_NAMES, enumName);
		return boxNames.get(enumName);
	}

	public function unboxName(enumName:String):Null<String> {
		var current = reader;
		if (current != null)
			current.read(ADAPTER_NAMES, enumName);
		return unboxNames.get(enumName);
	}

	public function require(enumName:String):Void {
		var current = reader;
		if (current != null)
			current.request(ADAPTERS, EnumTag(enumName));
		else
			required.set(enumName, true);
	}

	public function request(kind:Int, type:IrType, name:Null<String>):Void
		switch type {
			case EnumTag(name): required.set(name, true);
			default: throw new InternalError("An enum tag adapter request names no tag");
		}

	public function transform(fn:IrFunction, summary:Int, reader:IrFactReader):IrFunction {
		if (!names.keys().hasNext())
			return fn;
		// A reader that records nothing gains nothing from the reads: the tables are read directly, adapters required at once.
		this.reader = reader.records() ? reader : null;
		var result = lower(fn);
		if (result != fn) {
			if (summary == HAS_INLINE_REQUESTS) {
				reader.read(INLINE_REQUESTS, "");
				result = IrInlineEnumRequests.resolve(program, [result])[0];
			}
			if (boxNames.keys().hasNext())
				IrEnumTagLowering.rewriteEscapes(this, [result]);
		}
		this.reader = null;
		return result;
	}

	public function finish(functions:Array<IrFunction>):Array<IrFunction> {
		if (!names.keys().hasNext())
			return functions;
		// A tag equality nothing calls goes: its callers compare tags. What a function calls is its walk summary (`IrWalkSummary`).
		var kept:Map<String, Bool> = [], scratch = IrWalkSummary.scratch();
		kept.set(program.entryPoint, true);
		for (fn in functions.concat(generated)) {
			if (fn.retention != Reachable)
				kept.set(fn.name, true);
			var summary = IrWalkSummary.of(fn, lineage, scratch);
			for (name in summary.calls)
				kept.set(name, true);
			for (name in summary.staticClosures)
				kept.set(name, true);
			for (name in summary.instanceClosures)
				kept.set(name, true);
		}
		for (object in program.objects)
			for (method in object.methods)
				kept.set(method.functionName.name, true);
		for (native in program.natives)
			if (native.generatedFunctionDependencies != null)
				for (name in native.generatedFunctionDependencies)
					kept.set(name, true);
		var result = [for (fn in functions) if (!tagEqualities.exists(fn.name) || kept.exists(fn.name)) fn];
		// The wrappers are made each build: their escapes are finished here, as a rewritten function's are in its transform.
		var wrappers = IrInlineEnumRequests.resolve(program, generated);
		if (boxNames.keys().hasNext())
			IrEnumTagLowering.rewriteEscapes(this, wrappers);
		program.functions = result.concat(wrappers);
		if (boxNames.keys().hasNext())
			IrEnumTagLowering.addAdapters(program, required,
				new IrFunctionIndex("enum-tag-lowering", program.functions),
				boxNames, unboxNames);
		return program.functions;
	}

	/** `fn` with its eligible enums carried as tags, or `fn` itself when none of its values, calls or type values involves one. */
	function lower(fn:IrFunction):IrFunction {
		function valueChanges(value:IrValue):Bool
			return changes(value.type);
		function nonOutputChanges(instruction:IrInstruction):Bool {
			switch instruction {
				case Call(_, name, _) if (isTagEquality(name.name)):
					return true;
				case Call(_, target, _) if (wrapperOf(target.name) != null):
					return true;
				case CNativeCall(_, name, _) if (wrapperOf(name) != null):
					return true;
				case TypeValue(_, type):
					switch type {
						case Enum(_):
						default:
							if (changes(type)) return true;
					}
				default:
			}
			return false;
		}
		function instructionChanges(instruction:IrInstruction):Bool
			return nonOutputChanges(instruction) || IrOperands.anyValue(instruction, valueChanges);
		function functionChanges(fn:IrFunction):Bool {
			if (changes(fn.result))
				return true;
			for (argument in fn.arguments)
				if (valueChanges(argument))
					return true;
			for (binding in fn.debugBindings)
				if (valueChanges(binding.value))
					return true;
			// Valid SSA uses have the type of their definition. Discover changed carriers once per definition;
			// instruction rewriting below still visits every operand, and the verifier checks every use.
			for (block in fn.blocks)
				for (located in block.instructions) {
					var output = IrOperands.output(located.value);
					if (output != null && valueChanges(output))
						return true;
					if (nonOutputChanges(located.value))
						return true;
				}
			return false;
		}
		if (!functionChanges(fn))
			return fn;

		var values:Map<Int, IrValue> = [];
		function use(value:IrValue):IrValue {
			if (!valueChanges(value))
				return value;
			var known = values.get(value.id);
			if (known == null)
				values.set(value.id, known = new IrValue(value.id, value.name, mapped(value.type)));
			return known;
		}
		var indexTags:Map<Int, IrValue> = [],
			replacedIndices:Map<Int, Bool> = [];
		// The tag an index a guard found among `indexTags` was read from.
		function indexTag(id:Int):IrValue {
			var tag = indexTags.get(id);
			if (tag == null)
				throw new InternalError('Missing enum tag of index $id');
			return tag;
		}
		for (block in fn.blocks)
			for (located in block.instructions)
				switch located.value {
					case EnumIndex(output, input):
						switch use(input).type {
							case EnumTag(_): indexTags.set(output.id, use(input));
							default:
						}
					default:
				}
		var blocks = [for (block in fn.blocks) {
			var result = new IrBlock(block.id);
			for (located in block.instructions) {
				var tagIndexEquality = switch located.value {
					case Equal(_, left, right): indexTags.exists(left.id) && indexTags.exists(right.id);
					default: false;
				};
				if (!tagIndexEquality && !instructionChanges(located.value)) {
					result.instructions.push(located);
					continue;
				}
				var instruction = IrInliner.remap(located.value, use, id -> id);
				switch located.value {
					case Call(output, name, arguments) if (isTagEquality(name.name)):
						instruction = Equal(use(output), use(arguments[0]), use(arguments[1]));
					case Equal(output, left, right)
						if (indexTags.exists(left.id)
						&& indexTags.exists(right.id)
						&& IrVerifier.sameType(indexTag(left.id).type, indexTag(right.id).type)):
						instruction = Equal(use(output), indexTag(left.id), indexTag(right.id));
						replacedIndices.set(left.id, true);
						replacedIndices.set(right.id, true);
					case Call(output, target, arguments) if (wrapperOf(target.name) != null):
						instruction = Call(use(output), IrSymbol.of(wrapperName(target.name)),
							[for (argument in arguments) use(argument)]);
					case CNativeCall(output, name, arguments) if (wrapperOf(name) != null):
						instruction = Call(use(output), IrSymbol.of(wrapperName(name)),
							[for (argument in arguments) use(argument)]);
					case Call(output, name, arguments) if (unboxOf(name.name) != null):
						var unboxed = unboxOf(name.name);
						if (unboxed == null || !IrVerifier.sameType(unboxed, output.type))
							throw new InternalError("Malformed enum unbox signature");
						switch use(output).type {
							case EnumTag(enumName): instruction = Intrinsic(use(output),
								EnumTagUnbox(EnumTag(enumName)),
								[for (argument in arguments) use(argument)]);
							default:
						}
					case TypeValue(output, type):
						// A bare enum descriptor describes its nominal box, not its private scalar carrier.
						instruction = TypeValue(use(output), switch type {
							case Enum(_): type;
							default: mapped(type);
						});
					default:
				}
				result.instructions.push(new Located(instruction, located.provenance));
			}
			var terminator = block.terminator;
			if (terminator != null) result.terminator = new Located(switch terminator.value {
				case Unreachable: Unreachable;
				case Return(value): Return(use(value));
				case Throw(value): Throw(use(value));
				case Rethrow(value): Rethrow(use(value));
				case Jump(id): Jump(id);
				case Branch(condition, yes, no): Branch(use(condition), yes, no);
				case Switch(switchValue, switchTargets, switchOtherwise): Switch(use(switchValue),
					switchTargets.copy(), switchOtherwise);
			}, terminator.provenance);
			result;
		}];
		if (replacedIndices.keys().hasNext()) {
			var used:Map<Int, Bool> = [];
			for (block in blocks) {
				for (located in block.instructions) {
					for (input in IrOperands.inputs(located.value))
						used.set(input.id, true);
					switch located.value {
						case Phi(_, inputs):
							for (input in inputs)
								used.set(input.value.id, true);
						default:
					}
				}
				if (block.terminator != null)
					switch block.terminator.value {
						case Return(value), Throw(value), Rethrow(value), Branch(value, _, _),
							Switch(value, _, _):
							used.set(value.id, true);
						case Jump(_), Unreachable:
					}
			}
			for (binding in fn.debugBindings)
				used.set(binding.value.id, true);
			for (block in blocks) {
				var kept = [for (located in block.instructions)
					if (switch located.value {
						case EnumIndex(output, _): !replacedIndices.exists(output.id) || used.exists(output.id);
						default: true;
					}) located];
				block.instructions.splice(0, block.instructions.length);
				for (located in kept)
					block.instructions.push(located);
			}
		}
		var rewrittenFunction = new IrFunction(fn.name, [for (argument in fn.arguments) use(argument)],
			mapped(fn.result), blocks, fn.kind, [for (binding in fn.debugBindings)
			{
				identity:binding.identity,
					name:binding.name,
					value:use(binding.value),
					path:binding.path,
					scopeStart:binding.scopeStart,
					scopeEnd:binding.scopeEnd
			}], fn.inlineHint, fn.retention);
		return rewrittenFunction;
	}
}
