package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.Ir.IrInterface;
import compiler.ir.Ir.IrEnum;
import compiler.ir.Ir.IrCNativeArgumentMode;
import compiler.ir.IrFunction.IrFunctionKind;

/** Rejects malformed or ill-typed SSA programs before backend lowering. */
class IrVerifier {
	/** After value-array lowering, ordinary array instructions must never address lane storage. */
	public static function verifyValueArraysLowered(program:IrProgram):Void {
		var valueObjects:Map<String, Bool> = [for (object in program.objects) if (object.isValue) object.name => true],
			valueEnums:Map<String, Bool> = [
				for (declaration in program.enums)
					if (declaration.inlineStorage != null) declaration.name => true
			],
			ordinaryRefNatives:Map<String, Bool> = [];
		function ordinaryRef(name:String):Bool
			return StringTools.startsWith(name, "__array_") && StringTools.endsWith(name, "_ref");
		for (native in program.natives)
			if (ordinaryRef(native.symbol))
				ordinaryRefNatives.set(native.name, true);
		function laneArray(type:IrType):Bool
			return switch type {
				case Array(Obj(name)) | Array(Nullable(Obj(name))): valueObjects.exists(name);
				case Array(Enum(name)) | Array(Nullable(Enum(name))): valueEnums.exists(name);
				case Array(EnumTag(_)): true;
				default: false;
			};
		for (fn in program.functions)
			for (block in fn.blocks)
				for (located in block.instructions) {
					var invalid = switch located.value {
						case ArrayGet(_, array, _) | ArraySet(array, _, _) | IteratorNew(_, array): laneArray(array.type);
						case Call(_, name, arguments) if (ordinaryRef(name) || ordinaryRefNatives.exists(name)):
							var found = false;
							for (argument in arguments)
								if (laneArray(argument.type))
									found = true;
							found;
						default: false;
					};
					if (invalid)
						throw 'IR verification failed for ${fn.name}: ordinary array operation on inline value lanes';
				}
	}

	/** A producer boundary must not pass typed enum conversions to a backend without resolution. */
	public static function verifyResolvedEnumOperations(functions:Array<IrFunction>):Void {
		for (fn in functions)
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case Intrinsic(_, InlineEnumBox(_) | InlineEnumUnbox(_) | EnumTagBox(_) | EnumTagUnbox(_), _):
							throw 'IR verification failed for ${fn.name}: unresolved typed enum conversion';
						default:
					}
	}

	/** Physical values must not retain an inline enum's nominal boxed carrier. */
	public static function verifyInlineEnumsLowered(program:IrProgram, ?memo:IrVerifyMemo):Void {
		var selected:Map<String, IrEnum> = [
			for (declaration in program.enums)
				if (declaration.inlineStorage != null) declaration.name => declaration
		];
		if (!selected.keys().hasNext())
			return;
		function forbidden(type:IrType):Null<String>
			return switch type {
				case Enum(name): selected.exists(name) ? name : null;
				case Array(element), Iterator(element): switch element {
						// Containers retain their logical element descriptor; their values are lane handles.
						case Enum(_), Nullable(Enum(_)): null;
						default: forbidden(element);
					};
				case Nullable(element): forbidden(element);
				case Function(arguments, result):
					var found = forbidden(result);
					for (argument in arguments)
						if (found == null)
							found = forbidden(argument);
					found;
				default: null;
			};
		function check(type:IrType, where:String):Void {
			var name = forbidden(type);
			if (name != null)
				throw 'IR inline enum "$name" retains nominal value storage in $where';
		}
		// The hot checks build their message only when they fail: `check(type, 'operand ${fn.name}')` concatenated a string for every
		// operand of every instruction, passing or not.
		function fails(type:IrType):Bool
			return forbidden(type) != null;
		var escapes:Map<String, Bool> = [],
			functions = [for (fn in program.functions) fn.name => fn],
			nativeSymbols = [for (native in program.natives) native.name => native.symbol];
		var selectedTypes = [
			for (name => declaration in selected)
				TypeKey.of(Enum(name)).toString() => declaration
		];
		for (fn in program.functions)
			switch fn.kind {
				case Provider(subject, operation):
					var declaration = selectedTypes.get(subject.toString());
					if (declaration != null) {
						var box = operation == compiler.Provides.ProviderOperations.detailed(compiler.Provides.ProviderOperation.InlineEnumHelper, "box"),
							unbox = operation == compiler.Provides.ProviderOperations.detailed(compiler.Provides.ProviderOperation.InlineEnumHelper, "unbox"),
							storage:IrType = Obj(declaration.inlineStorage);
						if ((box || unbox)
							&& fn.arguments.length == 1
							&& sameType(fn.arguments[0].type, box ? storage : Dyn)
							&& sameType(fn.result, box ? Dyn : storage))
							escapes.set(fn.name, true);
					}
				default:
			}

		for (object in program.objects)
			for (field in object.fields)
				check(field.type, 'field ${object.name}.${field.name}');
		for (field in program.staticFields)
			check(field.type, 'static field ${field.name}');
		for (contract in program.interfaces)
			for (method in contract.methods) {
				for (argument in method.arguments)
					check(argument, 'interface ${contract.name}.${method.name}');
				check(method.result, 'interface result ${contract.name}.${method.name}');
			}
		for (native in program.natives) {
			for (argument in native.arguments)
				check(argument, 'native ${native.name}');
			check(native.result, 'native result ${native.name}');
		}
		for (native in program.cNatives) {
			for (argument in native.arguments)
				check(argument, 'C native ${native.name}');
			check(native.result, 'C native result ${native.name}');
		}
		// A function's check reads the selected enums, the escape helpers and the native symbols besides the function itself.
		if (memo != null) {
			var selectedNames = [for (name in selected.keys()) name],
				escapeNames = [for (name in escapes.keys()) name];
			selectedNames.sort(Reflect.compare);
			escapeNames.sort(Reflect.compare);
			var context = selectedNames.join(",")
				+ "|"
				+ escapeNames.join(",")
				+ "|"
				+ [for (native in program.natives) native.name + "=" + native.symbol].join(",");
			if (context != memo.enumContext) {
				for (name in [for (name in memo.enumChecked.keys()) name])
					memo.enumChecked.remove(name);
				memo.enumContext = context;
			}
		}
		for (fn in program.functions) {
			if (memo != null && memo.enumChecked.get(fn.name) == fn)
				continue;
			var original = IrTypedInterfaceDispatch.originalEntryName(fn.name);
			if (escapes.exists(original))
				continue;
			for (argument in fn.arguments)
				if (fails(argument.type))
					check(argument.type, 'argument ${fn.name}');
			if (fails(fn.result))
				check(fn.result, 'result ${fn.name}');
			var descriptors:Null<Map<Int, IrType>> = null;
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case TypeValue(out, type) if (forbidden(type) != null):
							if (descriptors == null)
								descriptors = [];
							descriptors.set(out.id, type);
						default:
					}
			var anyDescriptors = descriptors != null;
			function descriptorUse(value:IrValue, instruction:Null<IrInstruction>):Void {
				var type = descriptors.get(value.id);
				if (type == null)
					return;
				var valid = false;
				if (instruction != null)
					switch instruction {
						case Call(out, callee, arguments):
							var symbol = nativeSymbols.get(callee);
							if (symbol == null)
								symbol = callee;
							if (arguments.length > 1 && arguments[1].id == value.id) {
								if (symbol == "__value_array_alloc" || symbol == "__value_array_retype" || symbol == "__array_alloc_typed_ref")
									valid = switch out.type {
										case Array(element): sameType(element, type);
										default: false;
									};
								else if (symbol == "__std_is_exact_type" && StringTools.startsWith(original, "$value-array:bridge:")) {
									var bridge = "$value-array:bridge:" + haxe.crypto.Base64.encode(compiler.ir.codec.IrTypeCodec.encode(type)) + ":accepts";
									valid = original == bridge && fn.arguments.length == 1 && sameType(fn.arguments[0].type, Dyn) && sameType(fn.result, Bool);
								} else if ((symbol == "__std_is_exact_type" || symbol == "__std_is_of_type")
									&& logicalEnumDescriptorFunction(original))
									valid = switch type {
										case Enum(name): var expected = original == IrEnumDynamicDispatch.EQUAL
												|| original == IrEnumDynamicDispatch.REFLECT ? 2 : 1,
												allDynamic = fn.arguments.length == expected; for (argument in fn.arguments) if (!sameType(argument.type,
												Dyn)) allDynamic = false; selected.exists(name) && allDynamic && sameType(fn.result, Bool);
										default: false;
									};
							}
						default:
					}
				if (!valid)
					check(type, 'non-array descriptor use ${fn.name}');
			}
			for (binding in fn.debugBindings) {
				if (fails(binding.value.type))
					check(binding.value.type, 'debug binding ${fn.name}');
				if (anyDescriptors)
					descriptorUse(binding.value, null);
			}
			for (block in fn.blocks) {
				for (located in block.instructions) {
					var instruction = located.value,
						out = IrOperands.output(instruction);
					if (out != null && fails(out.type))
						check(out.type, 'instruction output ${fn.name}');
					for (inputIndex in 0...IrOperands.count(instruction)) {
						var input = IrOperands.at(instruction, inputIndex);
						if (fails(input.type))
							check(input.type, 'instruction operand ${fn.name}');
						if (anyDescriptors)
							descriptorUse(input, instruction);
					}
					switch instruction {
						case Phi(_, inputs):
							for (input in inputs) {
								if (fails(input.value.type))
									check(input.value.type, 'phi input ${fn.name}');
								if (anyDescriptors)
									descriptorUse(input.value, null);
							}
						case MakeEnum(_, name, _, _) if (selected.exists(name)):
							check(Enum(name), 'boxed constructor ${fn.name}');
						default:
					}
				}
				if (block.terminator != null)
					switch block.terminator.value {
						case Return(value), Throw(value), Rethrow(value), Branch(value, _, _):
							if (fails(value.type))
								check(value.type, 'terminator ${fn.name}');
							if (anyDescriptors)
								descriptorUse(value, null);
						default:
					}
			}
			if (memo != null)
				memo.enumChecked.set(fn.name, fn);
		}
	}

	static function logicalEnumDescriptorFunction(name:String):Bool
		return name == IrEnumDynamicDispatch.EQUAL
			|| name == IrEnumDynamicDispatch.REFLECT
			|| StringTools.startsWith(name, "$enum-dynamic-test:");

	public static function verify(program:IrProgram):Void {
		verifySelected(program, null, null);
	}

	/**
	 * `verify`, skipping the functions the last verification accepted whose IR and whose reads of the rest of the program are unchanged
	 * (see `IrVerifyMemo`). The program-level checks still run in full.
	 */
	public static function verifyReusing(program:IrProgram, memo:IrVerifyMemo):Void {
		verifySelected(program, null, memo);
	}

	/** Verify shared program metadata and only the named function bodies. */
	public static function verifyFunctions(program:IrProgram, names:Map<String, Bool>):Void {
		verifySelected(program, names, null);
	}

	static function verifySelected(program:IrProgram, selected:Null<Map<String, Bool>>, memo:Null<IrVerifyMemo>):Void {
		var signatures:Map<String, {arguments:Array<IrType>, result:IrType, kind:IrFunctionKind}> = [];
		var closureCasts:Map<String, String> = [];
		for (fn in program.functions)
			switch fn.kind {
				case ClosureCast(target):
					var key = Std.string(target);
					if (closureCasts.exists(key))
						throw 'Duplicate closure cast for $key';
					closureCasts.set(key, fn.name);
				default:
			}
		var scalarFunctions = [
			for (fn in program.functions)
				if (StringTools.startsWith(fn.name, IrScalarArguments.PREFIX)) fn.name => true
		];
		for (native in program.natives)
			addSignature(signatures, native.name, native.arguments, native.result);
		for (native in program.cNatives)
			verifyCNative(native);
		for (native in program.cNatives)
			addSignature(signatures, native.name, native.arguments, native.result);
		for (fn in program.functions)
			addSignature(signatures, fn.name, [for (a in fn.arguments) a.type], fn.result, fn.kind);
		var objects:Map<String, IrObject> = [];
		var physicalValues:Map<String, Bool> = [];
		var interfaces:Map<String, IrInterface> = [];
		var enums:Map<String, IrEnum> = [];
		for (object in program.objects) {
			if (objects.exists(object.name))
				throw 'Duplicate IR object "${object.name}"';
			for (field in object.fields)
				if (field.scalarStorage != null && !validScalarStorage(field.type, field.scalarStorage))
					throw 'Invalid scalar storage for "${object.name}.${field.name}"';
				else if (field.nullableScalarStorage != null && !validNullableScalarStorage(field.type, field.nullableScalarStorage))
					throw 'Invalid nullable scalar storage for "${object.name}.${field.name}"';
			objects.set(object.name, object);
		}
		// Private enum records and values containing opaque references need logical escape adapters.
		for (object in program.objects)
			if (object.isValue && StringTools.startsWith(object.name, IrInlineEnumLayout.VALUE_PREFIX))
				physicalValues.set(object.name, true);
		var physicalTable = new IrVerifyTable<Bool>("physicalValues", (key:String) -> physicalValues.get(key), (key:String) -> physicalValues.exists(key));
		var changed = true;
		while (changed) {
			changed = false;
			for (object in program.objects)
				if (object.isValue && !physicalValues.exists(object.name))
					for (field in object.fields)
						if (requiresLogicalValueAdapter(field.type, physicalTable)) {
							physicalValues.set(object.name, true);
							changed = true;
							break;
						}
		}
		for (interfaceDecl in program.interfaces) {
			if (interfaces.exists(interfaceDecl.name))
				throw 'Duplicate IR interface "${interfaceDecl.name}"';
			interfaces.set(interfaceDecl.name, interfaceDecl);
		}
		var objectTable = IrObjectTable.of(objects);
		for (enumDecl in program.enums) {
			if (enums.exists(enumDecl.name))
				throw 'Duplicate IR enum "${enumDecl.name}"';
			IrInlineEnumStorage.validate(enumDecl, objectTable);
			enums.set(enumDecl.name, enumDecl);
		}
		verifyInlineEnumsLowered(program, memo);
		IrEnumTagStorage.verify(program);
		var globals:Map<String, IrType> = [];
		for (field in program.staticFields) {
			if (globals.exists(field.name))
				throw 'Duplicate IR static field "${field.name}"';
			globals.set(field.name, field.type);
		}
		// Carrier results are permitted only for an actual reference leaf in a lane array.
		var carrierSlots:Map<String, Bool> = [];
		var laneValues = new IrInlineValueLayout(objectTable);
		for (fn in program.functions) {
			switch fn.kind {
				case EnumTagAdapter(type, box):
					switch type {
						case EnumTag(_):
						default: throw "Enum tag adapter requires a tag type";
					}
					if (fn.arguments.length != 1
						|| !sameType(fn.arguments[0].type, box ? type : Dyn)
						|| !sameType(fn.result, box ? Dyn : type))
						throw "Invalid enum tag adapter signature";
				case ValueArraySlot(namespace, _, operation):
					if (namespace < 0)
						throw "Invalid value-array slot namespace";
					switch operation {
						case Read(slot, _, _), Write(slot, _, _):
							if (slot < 0) throw "Invalid value-array slot";
						default:
					}
				default:
			}
			var access = switch fn.kind {
				case ValueArraySlot(_, element, Read(_, path, true)): {element: element, path: path, write: false};
				case ValueArraySlot(_, element, Write(_, path, true)): {element: element, path: path, write: true};
				default: null;
			};
			if (access == null)
				continue;
			var fieldFound = false;
			var stored = switch access.element {
				case Enum(name), Nullable(Enum(name)):
					var resolved = IrInlineEnumStorage.resolve(program.enums, objectTable, name);
					if (resolved == null)
						throw "Lane carrier accessor requires inline enum storage";
					resolved;
				default: access.element;
			};
			for (slot in laneValues.slots(stored))
				if (!slot.isPresence && IrValueLaneReference.isCarrier(slot.type) && sameCarrierPath(slot.path, access.path))
					fieldFound = true;
			if (!fieldFound
				|| fn.arguments.length != (access.write ? 3 : 2)
				|| !sameType(fn.arguments[0].type, Array(access.element))
				|| !sameType(fn.arguments[1].type, I32)
				|| (access.write ? !IrValueLaneReference.isCarrier(fn.arguments[2].type)
					|| !sameType(fn.result, Void) : !IrValueLaneReference.isCarrier(fn.result)))
				throw "Invalid lane carrier accessor signature";
			carrierSlots.set(fn.name, access.write);
		}
		if (!signatures.exists(program.entryPoint))
			throw 'Unknown IR entry point "${program.entryPoint}"';
		if (memo != null) {
			memo.attach([
				"signatures" => k -> signatures.get(k),
				"objects" => k -> objects.get(k),
				"interfaces" => k -> interfaces.get(k),
				"enums" => k -> enums.get(k),
				"globals" => k -> globals.get(k),
				"scalarFunctions" => k -> scalarFunctions.get(k),
				"carrierSlots" => k -> carrierSlots.get(k),
				"physicalValues" => k -> physicalValues.get(k),
				"closureCasts" => k -> closureCasts.get(k)
			]);
			memo.forget([for (fn in program.functions) fn.name => true]);
		}
		var tables = {
			closureCasts: new IrVerifyTable<String>("closureCasts", (key:String) -> closureCasts.get(key), (key:String) -> closureCasts.exists(key), memo),
			signatures: new IrVerifyTable<{
				arguments:Array<IrType>,
				result:IrType,
				kind:IrFunctionKind
			}>("signatures", (key:String) -> signatures.get(key), (key:String) -> signatures.exists(key), memo),
			objects: new IrVerifyTable<IrObject>("objects", (key:String) -> objects.get(key), (key:String) -> objects.exists(key), memo),
			interfaces: new IrVerifyTable<IrInterface>("interfaces", (key:String) -> interfaces.get(key), (key:String) -> interfaces.exists(key), memo),
			enums: new IrVerifyTable<IrEnum>("enums", (key:String) -> enums.get(key), (key:String) -> enums.exists(key), memo),
			globals: new IrVerifyTable<IrType>("globals", (key:String) -> globals.get(key), (key:String) -> globals.exists(key), memo),
			scalarFunctions: new IrVerifyTable<Bool>("scalarFunctions", (key:String) -> scalarFunctions.get(key), (key:String) -> scalarFunctions.exists(key),
				memo),
			carrierSlots: new IrVerifyTable<Bool>("carrierSlots", (key:String) -> carrierSlots.get(key), (key:String) -> carrierSlots.exists(key), memo),
			physicalValues: new IrVerifyTable<Bool>("physicalValues", (key:String) -> physicalValues.get(key), (key:String) -> physicalValues.exists(key), memo)
		};
		for (fn in program.functions)
			if (selected == null || selected.exists(fn.name)) {
				if (memo != null && memo.holds(fn))
					continue;
				try {
					if (memo != null)
						memo.begin();
					verifyFunction(fn, tables.signatures, tables.objects, tables.interfaces, tables.enums, tables.globals, tables.scalarFunctions,
						tables.carrierSlots, tables.physicalValues, tables.closureCasts);
					if (memo != null)
						memo.accept(fn);
				} catch (error:String) {
					if (memo != null)
						memo.abandon();
					throw 'IR verification failed for ${fn.name}: $error';
				}
			}
	}

	static function validScalarStorage(type:IrType, storage:IrScalarStorage):Bool {
		var size = storage.size;
		return switch type {
			case I32: size == 1 || size == 2 || size == 4;
			case EnumTag(_): size == 4;
			case I64: size == 1 || size == 2 || size == 4 || size == 8;
			case F32: size == 4;
			case F64: size == 8;
			case Bool: size == 1;
			case RawPtr: size == 4 || size == 8;
			default: false;
		};
	}

	static function validNullableScalarStorage(type:IrType, storage:IrScalarStorage):Bool
		return switch type {
			case Nullable(I32): storage.size == 1 || storage.size == 2;
			case Nullable(I64): storage.size == 1 || storage.size == 2 || storage.size == 4;
			default: false;
		};

	static function verifyCNative(native:IrCNative):Void {
		if (native.argumentModes == null || native.argumentModes.length != native.arguments.length)
			throw 'C native "${native.name}" has mismatched argument ABI metadata';
		if (native.pointerSize != null && native.pointerSize != 4 && native.pointerSize != 8)
			throw 'C native "${native.name}" has invalid pointer-size metadata';
		if (native.fixedResult != null && ((switch (native.result) {
			case ManagedBytes: false;
			default: true;
		}) || !validAggregateLayout(native.fixedResult.size, native.fixedResult.alignment)))
			throw 'C native "${native.name}" has invalid fixed aggregate result metadata';
		for (index in 0...native.argumentModes.length)
			switch native.argumentModes[index] {
				case BytesInput(lengthArgument):
					if ((switch (native.arguments[index]) {
						case ManagedBytes: false;
						default: true;
					})
						|| lengthArgument < 0
						|| lengthArgument >= native.arguments.length
						|| !validByteInputCount(native.arguments[lengthArgument]))
						throw 'C native "${native.name}" has invalid byte-buffer argument metadata';
				case BytesInputOutput(lengthArgument):
					if ((switch (native.arguments[index]) {
						case ManagedBytes: false;
						default: true;
					})
						|| lengthArgument < 0
						|| lengthArgument >= native.arguments.length
						|| !validByteInputCount(native.arguments[lengthArgument]))
						throw 'C native "${native.name}" has invalid mutable byte-buffer argument metadata';
				case BytesOutput(sizeArgument):
					if ((switch (native.arguments[index]) {
						case ManagedBytes: false;
						default: true;
					})
						|| sizeArgument < 0
						|| sizeArgument >= native.arguments.length
						|| (switch (native.arguments[sizeArgument]) {
							case ManagedBytes: false;
							default: true;
						}))
						throw 'C native "${native.name}" has invalid output-buffer argument metadata';
				case BytesSize:
					if ((switch (native.arguments[index]) {
						case ManagedBytes: false;
						default: true;
					}))
						throw 'C native "${native.name}" has invalid output-buffer size metadata';
				case FixedInput(size, alignment, _) | FixedValue(size, alignment, _) | FixedOutput(size, alignment, _) | FixedInputOutput(size, alignment, _):
					if ((switch (native.arguments[index]) {
						case ManagedBytes: false;
						default: true;
					}) || !validAggregateLayout(size, alignment))
						throw 'C native "${native.name}" has invalid fixed output layout metadata';
				case Value | Output | InputOutput:
			}
	}

	/** Counted byte inputs use the integer width declared by the native ABI. */
	public static function validByteInputCount(type:IrType):Bool
		return (switch (type) {
			case I32: true;
			default: false;
		}) || (switch (type) {
			case I64: true;
			default: false;
		});

	static function validAggregateLayout(size:Int, alignment:Int):Bool
		return size > 0 && size <= 0x10000000 && alignment > 0 && alignment <= 0x10000 && (alignment & (alignment - 1)) == 0;

	static function verifyFunction(fn:IrFunction, signatures:IrVerifyTable<{arguments:Array<IrType>, result:IrType, kind:IrFunctionKind}>,
			objects:IrVerifyTable<IrObject>, interfaces:IrVerifyTable<IrInterface>, enums:IrVerifyTable<IrEnum>, globals:IrVerifyTable<IrType>,
			scalarFunctions:IrVerifyTable<Bool>, carrierSlots:IrVerifyTable<Bool>, physicalValues:IrVerifyTable<Bool>,
			closureCasts:IrVerifyTable<String>):Void {
		if (IrHlScalarRef.element(fn.result) != null)
			throw "A scalar stack reference cannot be returned";
		if (IrValueLaneReference.isCarrier(fn.result) && !(carrierSlots.exists(fn.name) && carrierSlots.get(fn.name) == false))
			throw "A value lane reference cannot be returned";
		for (arg in fn.arguments)
			if (IrHlScalarRef.element(arg.type) != null && !StringTools.startsWith(fn.name, IrScalarArguments.PREFIX))
				throw "A scalar stack reference cannot cross an ordinary function boundary";
			else if (IrValueLaneReference.isCarrier(arg.type)
				&& !StringTools.startsWith(fn.name, IrScalarArguments.PREFIX)
				&& !(carrierSlots.exists(fn.name) && carrierSlots.get(fn.name) == true))
				throw "A value lane reference cannot cross an ordinary function boundary";
		var graph = new IrGraph(fn), values = scratchValues;
		values.reset();
		// Lane and scalar stack references are rare. A function whose arguments and outputs have none of those types has no operand of
		// those types either (an operand has the type of its definition, checked below), so the operand scans for them are skipped.
		var lanes = false, scalarRefs = false;
		for (argument in fn.arguments) {
			lanes = lanes || IrValueLaneReference.isCarrier(argument.type);
			scalarRefs = scalarRefs || IrHlScalarRef.element(argument.type) != null;
		}
		for (block in fn.blocks)
			for (located in block.instructions) {
				var produced = IrOperands.output(located.value);
				if (produced != null) {
					lanes = lanes || IrValueLaneReference.isCarrier(produced.type);
					scalarRefs = scalarRefs || IrHlScalarRef.element(produced.type) != null;
				}
			}
		for (argument in fn.arguments)
			values.define(argument, fn.blocks[0].id, -1);
		for (id in graph.order) {
			var block = graph.block(id), ordinary = false;
			for (position in 0...block.instructions.length) {
				var instruction = block.instructions[position].value;
				verifyScalarReferenceUse(instruction, scalarFunctions, carrierSlots, physicalValues, fn, signatures, closureCasts, lanes, scalarRefs);
				switch instruction {
					case Phi(_, _):
						if (ordinary)
							throw "IR phis must precede ordinary instructions";
					case BeginTry(_, _, _):
						ordinary = true;
						if (position != block.instructions.length - 1)
							throw "IR trap entry must end its block";
					default:
						ordinary = true;
				}
				var output = IrOperands.output(instruction);
				if (output != null)
					values.define(output, id, position);
			}
		}
		for (id in graph.order) {
			var block = graph.block(id);
			for (position in 0...block.instructions.length) {
				var instruction = block.instructions[position].value;
				for (valueIndex in 0...IrOperands.count(instruction)) {
					var value = IrOperands.at(instruction, valueIndex);
					verifyUse(value, id, position, values, graph);
				}
				switch instruction {
					case Phi(out, inputs):
						var expected = graph.predecessors.get(id);
						if (expected == null || inputs.length != expected.length)
							throw 'Phi ${out.id} does not cover every predecessor';
						for (position in 0...inputs.length) {
							var input = inputs[position], repeated = false;
							for (earlier in 0...position)
								if (inputs[earlier].block == input.block)
									repeated = true;
							if (expected.indexOf(input.block) < 0 || repeated)
								throw 'Invalid phi predecessor ${input.block}';
							verifyUse(input.value, input.block, graph.block(input.block).instructions.length, values, graph);
							if (!sameType(input.value.type, out.type))
								throw 'Wrong phi input type for ${out.id}';
						}
					default:
				}
				verifyInstruction(instruction, values, signatures, objects, interfaces, enums, globals);
			}
			var terminator = block.terminator;
			if (terminator == null)
				throw 'Reachable IR block $id has no terminator';
			switch terminator.value {
				case Unreachable:
					// No value and no successor: nothing to check beyond the block ending here.
				case Return(value):
					verifyUse(value, id, block.instructions.length, values, graph);
					if (!sameType(value.type, fn.result))
						throw 'Wrong return type in ${fn.name}';
				case Throw(value), Rethrow(value):
					verifyUse(value, id, block.instructions.length, values, graph);
					if ((switch (value.type) {
						case Dyn: false;
						default: true;
					}))
						throw "IR throw value is not Dyn";
				case Branch(condition, _, _):
					verifyUse(condition, id, block.instructions.length, values, graph);
					if ((switch (condition.type) {
						case Bool: false;
						default: true;
					}))
						throw "IR branch condition is not Bool";
				case Jump(_):
			}
		}
	}

	static function sameCarrierPath(left:Array<String>, right:Array<String>):Bool {
		if (left.length != right.length)
			return false;
		for (index in 0...left.length)
			if (left[index] != right[index])
				return false;
		return true;
	}

	static function requiresLogicalValueAdapter(type:IrType, values:IrVerifyTable<Bool>):Bool
		return switch type {
			case Obj(name): values.exists(name);
			case Nullable(element), Array(element), Iterator(element): requiresLogicalValueAdapter(element, values);
			case Function(arguments, result):
				var found = requiresLogicalValueAdapter(result, values);
				for (argument in arguments)
					if (requiresLogicalValueAdapter(argument, values))
						found = true;
				found;
			default: IrValueLaneReference.isCarrier(type);
		};

	/** A generated adapter may cast its erased receiver only at its declared semantic signature. */
	static function isGeneratedClosureAdapterCast(fn:IrFunction, output:IrValue, input:IrValue,
			signatures:IrVerifyTable<{arguments:Array<IrType>, result:IrType, kind:IrFunctionKind}>, closureCasts:IrVerifyTable<String>):Bool {
		var source:IrType, target:IrType;
		switch fn.kind {
			case ClosureAdapter(s, t):
				source = s;
				target = t;
			default:
				return false;
		}
		if (!sameType(input.type, Dyn)
			|| fn.arguments.length == 0
			|| !sameType(fn.arguments[0].type, Dyn)
			|| !sameType(output.type, source))
			return false;
		var actualTarget:IrType = Function([for (index in 1...fn.arguments.length) fn.arguments[index].type], fn.result);
		if (!sameType(target, actualTarget))
			return false;
		var castName = closureCasts.get(Std.string(source));
		if (castName == null)
			return false;
		var castSignature = signatures.get(castName);
		if (castSignature == null
			|| castSignature.arguments.length != 1
			|| !sameType(castSignature.arguments[0], Dyn)
			|| !sameType(castSignature.result, Dyn))
			return false;
		for (block in fn.blocks)
			for (located in block.instructions)
				switch located.value {
					case CallClosure(_, closure, _) if (closure.id == output.id):
						return true;
					default:
				}
		return false;
	}

	static function isGeneratedClosureAdapterValue(fn:IrFunction, value:IrValue,
			signatures:IrVerifyTable<{arguments:Array<IrType>, result:IrType, kind:IrFunctionKind}>):Bool {
		var target:IrType;
		switch fn.kind {
			case ClosureCast(t):
				target = t;
			default:
				return false;
		}
		if (fn.arguments.length != 1
			|| !sameType(fn.arguments[0].type, Dyn)
			|| !sameType(fn.result, Dyn)
			|| !sameType(target, value.type))
			return false;
		var targetArguments = switch target {
			case Function(arguments, _): arguments;
			default: return false;
		}, targetResult = switch target {
			case Function(_, result): result;
			default: return false;
		};
		for (block in fn.blocks)
			for (located in block.instructions)
				switch located.value {
					case InstanceClosure(output, name, receiver) if (output.id == value.id && receiver.id == fn.arguments[0].id):
						var adapter = signatures.get(name);
						if (adapter == null
							|| adapter.arguments.length != targetArguments.length + 1
							|| !sameType(adapter.arguments[0], Dyn)
							|| !sameType(adapter.result, targetResult))
							continue;
						var validKind = switch adapter.kind {
							case ClosureAdapter(_, t), ClosureVarargs(t): sameType(t, target);
							default: false;
						};
						if (!validKind)
							continue;
						var matches = true;
						for (index in 0...targetArguments.length)
							if (!sameType(adapter.arguments[index + 1], targetArguments[index]))
								matches = false;
						if (matches)
							return true;
					default:
				}
		return false;
	}

	static function verifyScalarReferenceUse(instruction:IrInstruction, scalarFunctions:IrVerifyTable<Bool>, carrierSlots:IrVerifyTable<Bool>,
			physicalValues:IrVerifyTable<Bool>, fn:IrFunction, signatures:IrVerifyTable<{
			arguments:Array<IrType>,
			result:IrType,
			kind:IrFunctionKind
		}>, closureCasts:IrVerifyTable<String>, lanes:Bool, scalarRefs:Bool):Void {
		switch instruction {
			case ToDyn(output, value)
				if (sameType(output.type, Dyn)
					&& !IrValueLaneReference.isCarrier(value.type)
					&& requiresLogicalValueAdapter(value.type, physicalValues)
					&& !isGeneratedClosureAdapterValue(fn, value, signatures)):
				throw "Inline value storage requires a logical Dynamic adapter";
			case SafeCast(output, value)
				if (sameType(output.type, Dyn)
					&& !IrValueLaneReference.isCarrier(value.type)
					&& requiresLogicalValueAdapter(value.type, physicalValues)
					|| sameType(value.type, Dyn)
					&& !IrValueLaneReference.isCarrier(output.type)
					&& requiresLogicalValueAdapter(output.type, physicalValues)
					&& !isGeneratedClosureAdapterCast(fn, output, value, signatures, closureCasts)):
				throw "Inline value storage requires a logical cast adapter";
			default:
		}

		switch instruction {
			case StaticClosure(output, name), InstanceClosure(output, name, _)
				if (IrScalarArguments.isPrivateClosureType(output.type) && !scalarFunctions.exists(name)):
				throw "A scalar closure must target a verified scalar function";
			case ToDyn(_, value) if (IrScalarArguments.isPrivateClosureType(value.type)):
				throw "A scalar closure cannot cross a Dynamic boundary without an adapter";
			case SafeCast(output, value) if (IrScalarArguments.isPrivateClosureType(output.type)
				|| IrScalarArguments.isPrivateClosureType(value.type)):
				throw "A scalar closure cannot cross a cast boundary without an adapter";
			default:
		}
		var output = IrOperands.output(instruction);
		if (output != null && IrValueLaneReference.isCarrier(output.type))
			switch instruction {
				case Call(_, name, _) if (name == IrValueLaneReference.PACK || name == IrValueLaneReference.READ):
				case ConstNull(_), FieldGet(_, _, _), Phi(_, _):
				case Call(_, name, _) if (name == IrHlScalarRef.LOAD || carrierSlots.exists(name) && carrierSlots.get(name) == false):
				default:
					throw "Only a value lane operation can create a lane reference";
			}
		if (lanes)
			for (inputIndex in 0...IrOperands.count(instruction)) {
				var input = IrOperands.at(instruction, inputIndex);
				if (IrValueLaneReference.isCarrier(input.type))
					switch instruction {
						case FieldSet(_, _, value) if (value.id == input.id):
						case Phi(_, _):
						case Call(_, name, _) if (scalarFunctions.exists(name) || carrierSlots.exists(name) && carrierSlots.get(name) == true):
						case Call(_, name, args)
							if ((name == IrHlScalarRef.STORE && args.length == 2 && args[1].id == input.id)
								|| (name == IrHlScalarRef.ADDRESS && args.length == 1 && args[0].id == input.id)):
						case CallClosure(_, closure, args)
							if (IrScalarArguments.isPrivateClosureType(closure.type) && scalarClosureArgument(closure.type, args, input)):
						case Call(_, name, args) if (name == IrValueLaneReference.UNPACK && args.length == 1 && args[0].id == input.id):
						case Call(_, name, args) if (name == IrValueLaneReference.WRITE && args.length == 4 && args[3].id == input.id):
						default:
							throw "A value lane reference cannot escape its operation";
					}
			}
		if (output != null && IrHlScalarRef.element(output.type) != null)
			switch instruction {
				case Call(_, name, _) if (name == IrHlScalarRef.ADDRESS):
				default:
					throw "Only a scalar address operation can create a stack reference";
			}
		if (scalarRefs)
			for (inputIndex in 0...IrOperands.count(instruction)) {
				var input = IrOperands.at(instruction, inputIndex);
				if (IrHlScalarRef.element(input.type) != null)
					switch instruction {
						case Call(_, name, args) if ((name == IrHlScalarRef.LOAD || name == IrHlScalarRef.STORE)
							&& args.length > 0
							&& args[0].id == input.id):
						case Call(_, name, _) if (scalarFunctions.exists(name)):
						case CallClosure(_, closure, args) if (scalarClosureArgument(closure.type, args, input)):
						default:
							throw "A scalar stack reference cannot escape its call";
					}
			}
		switch instruction {
			case Phi(_, inputs):
				for (input in inputs)
					if (IrHlScalarRef.element(input.value.type) != null)
						throw "A scalar stack reference cannot be merged";
			default:
		}
		}

	static function scalarClosureArgument(type:IrType, arguments:Array<IrValue>, input:IrValue):Bool
		return switch type {
			case Function(expected, _):
				var found = false;
				for (index in 0...arguments.length)
					if (arguments[index].id == input.id && index < expected.length && sameType(expected[index], input.type))
						found = true;
				found;
			default: false;
		};

	static function verifyUse(value:IrValue, block:Int, position:Int, values:IrVerifyValues, graph:IrGraph):Void {
		require(values, value);
		if (!values.exists(value.id))
			throw 'Unknown IR definition ${value.id}';
		var definitionBlock = values.blockOf(value.id),
			definitionPosition = values.positionOf(value.id);
		if (definitionBlock == block ? definitionPosition >= position : !graph.dominates(definitionBlock, block))
			throw 'IR value ${value.id} does not dominate its use in block $block';
	}

	static function verifyInstruction(instruction:IrInstruction, values:IrVerifyValues, signatures, objects:IrVerifyTable<IrObject>,
			interfaces:IrVerifyTable<IrInterface>, enums:IrVerifyTable<IrEnum>, globals:IrVerifyTable<IrType>):Void
		switch instruction {
			case Phi(_, _):
			case ConstVoid(out):
				expect(out, Void);
			case ConstInt(out, _):
				switch out.type {
					case I32, I64:
					default: throw 'IR integer constant ${out.id} must produce I32 or I64';
				}
			case ConstFloat(out, _):
				if ((switch (out.type) {
					case F64: false;
					default: true;
				}) && (switch (out.type) {
					case F32: false;
					default: true;
				}))
					throw 'IR float constant ${out.id} must produce F32 or F64';
			case ConstString(out, _):
				expect(out, Bytes);
			case StaticDataAddress(out, bytes):
				expect(out, I32);
				if (bytes.length == 0 || (bytes.length & 3) != 0)
					throw "IR static data must contain complete 32-bit words";
				for (byte in bytes)
					if (byte < 0 || byte > 255)
						throw "IR static data contains a value outside the byte range";
			case PointerOffset(out, pointer, byteOffset):
				require(values, pointer);
				require(values, byteOffset);
				expect(pointer, RawPtr);
				expect(byteOffset, I32);
				expect(out, RawPtr);
			case MemoryLoad(out, pointer, size, _):
				require(values, pointer);
				expect(pointer, RawPtr);
				if (size != 1 && size != 2 && size != 4 && size != 8)
					throw 'Unsupported IR memory load size $size';
			case MemoryStore(pointer, value, size):
				require(values, pointer);
				require(values, value);
				expect(pointer, RawPtr);
				if (size != 1 && size != 2 && size != 4 && size != 8)
					throw 'Unsupported IR memory store size $size';
			case ConstBool(out, _):
				expect(out, Bool);
			case ConstNull(out):
				switch out.type {
					case Obj(name) if (StringTools.startsWith(name, IrInlineEnumLayout.VALUE_PREFIX)):
						var declaration = enums.get(name.substr(IrInlineEnumLayout.VALUE_PREFIX.length));
						if (declaration != null && declaration.inlineStorage == name) throw "IR inline enum null must use a tag-zero packet";
					default:
				}
				if (!isReference(out.type) && !(switch out.type {
					case EnumTag(_): true;
					default: false;
				}))
					throw 'IR null constant must produce a reference value';
			case TypeValue(out, _):
				expect(out, TypeRef);
			case ToDyn(out, value):
				require(values, value);
				// Boxing a primitive may keep it on record as a nullable of its own type.
				if ((switch (out.type) {
					case Dyn: false;
					default: true;
				}) && !(nullableOf(out.type) != null && sameType(nullableOf(out.type), value.type)))
					throw 'IR dynamic conversion must produce Dyn or the nullable of its input';
			case IntToFloat(out, value):
				require(values, value);
				if ((switch (value.type) {
					case I32: false;
					default: true;
				}) || (switch (out.type) {
					case F64: false;
					default: true;
				}))
					throw "IR Int-to-Float conversion requires I32 input and F64 output";
			case IntToInt64(out, value):
				require(values, value);
				if ((switch (value.type) {
					case I32: false;
					default: true;
				}) || (switch (out.type) {
					case I64: false;
					default: true;
				}))
					throw "IR Int-to-Int64 conversion requires I32 input and I64 output";
			case FloatToInt(out, value):
				require(values, value);
				if ((switch (value.type) {
					case F64: false;
					default: true;
				}) || (switch (out.type) {
					case I32: false;
					default: true;
				}))
					throw "IR Float-to-Int conversion requires F64 input and I32 output";
			case FloatToFloat(out, value):
				require(values, value);
				if (!(((switch (value.type) {
					case F64: true;
					default: false;
				}) && (switch (out.type) {
					case F32: true;
					default: false;
				})) || ((switch (value.type) {
					case F32: true;
					default: false;
				}) && (switch (out.type) {
					case F64: true;
					default: false;
				}))))
					throw "IR Float-to-Float conversion requires F64/F32 or F32/F64 types";
			case SafeCast(out, value):
				require(values, value);
				if (!IrTypeTools.isDynamic(value.type))
					throw 'IR safe cast source must be Dyn or a nullable primitive';
			case BeginTry(catchBlock, afterBlock, _):
			case EndTry(_, _):
			case Catch(out):
				if ((switch (out.type) {
					case Dyn: false;
					default: true;
				}))
					throw 'IR catch value must be Dyn';
			case GlobalGet(out, name):
				if (!globals.exists(name))
					throw 'Unknown IR static field "$name"';
				var type = globals.get(name);
				if (!sameType(out.type, type))
					throw 'Mismatched IR static field "$name" (declared=${Std.string(type)}, actual=${Std.string(out.type)})';
			case GlobalSet(name, value):
				if (!globals.exists(name))
					throw 'Unknown IR static field "$name"';
				var type = globals.get(name);
				if (!sameType(value.type, type))
					throw 'Mismatched IR static field "$name" (declared=${Std.string(type)}, actual=${Std.string(value.type)})';
				require(values, value);
			case Add(out, a, b), Sub(out, a, b), Mul(out, a, b), Div(out, a, b):
				if (!sameType(out.type, a.type)
					|| !sameType(a.type, b.type)
					|| (!sameType(a.type, I32) && !sameType(a.type, I64) && !sameType(a.type, F32) && !sameType(a.type, F64)))
					throw "IR arithmetic requires matching numeric values";
				require(values, a);
				require(values, b);
			case Mod(out, a, b):
				if (!sameType(out.type, a.type) || !sameType(a.type, b.type) || ((switch (a.type) {
					case I32: false;
					default: true;
				}) && (switch (a.type) {
					case I64: false;
					default: true;
				})))
					throw "IR modulo requires matching integer values";
				require(values, a);
				require(values, b);
			case BitAnd(out, a, b), BitXor(out, a, b), BitOr(out, a, b):
				if (!sameType(out.type, a.type) || !sameType(a.type, b.type) || ((switch (a.type) {
					case I32: false;
					default: true;
				}) && (switch (a.type) {
					case I64: false;
					default: true;
				})))
					throw "IR bitwise operation requires matching integer values";
				require(values, a);
				require(values, b);
			case ShiftLeft(out, a, b), ShiftRight(out, a, b), UnsignedShiftRight(out, a, b):
				if (!sameType(out.type, a.type) || ((switch (a.type) {
					case I32: false;
					default: true;
				}) && (switch (a.type) {
					case I64: false;
					default: true;
				})) || (switch (b.type) {
					case I32: false;
					default: true;
				}))
					throw "IR shift requires an Int or Int64 value and an Int count";
				require(values, a);
				require(values, b);
			case Less(out, a, b), LessEqual(out, a, b):
				expect(out, Bool);
				if (!sameType(a.type, b.type) || ((switch (a.type) {
					case I32: false;
					default: true;
				}) && (switch (a.type) {
					case I64: false;
					default: true;
				}) && (switch (a.type) {
					case F32: false;
					default: true;
				}) && (switch (a.type) {
					case F64: false;
					default: true;
				})))
					throw 'IR ordered comparison requires matching numeric values';
				require(values, a);
				require(values, b);
			case Equal(out, a, b):
				expect(out, Bool);
				require(values, a);
				require(values, b);
				if (!sameType(a.type, b.type)
					|| (!sameType(a.type, I32) && !sameType(a.type, I64) && !sameType(a.type, F32) && !sameType(a.type, F64) && !sameType(a.type, Bool)
						&& !isReference(a.type) && !(switch a.type {
							case EnumTag(_): true;
							default: false;
						})))
					throw 'IR equality requires matching primitive or reference values';
			case Intrinsic(out, operation, args):
				if (args.length != 1)
					throw "IR enum Dynamic intrinsic requires one argument";
				require(values, args[0]);
				switch operation {
					case EnumDynamicBox(type):
						switch type {
							case Enum(_):
							default: throw "IR enum Dynamic box requires an enum type";
						}
						if (!sameType(args[0].type, type) || !sameType(out.type, Dyn)) throw "Invalid IR enum Dynamic box signature";
					case EnumDynamicView(type):
						switch type {
							case Enum(_):
							default: throw "IR enum Dynamic view requires an enum type";
						}
						if (!sameType(args[0].type, Array(Dyn)) || !sameType(out.type, Array(Dyn))) throw "Invalid IR enum Dynamic view signature";
					case EnumTagBox(type):
						switch type {
							case EnumTag(_):
							default: throw "IR enum tag box requires a tag type";
						}
						if (!sameType(args[0].type, type) || !sameType(out.type, Dyn)) throw "Invalid IR enum tag box signature";
					case EnumTagUnbox(type):
						switch type {
							case EnumTag(_):
							default: throw "IR enum tag unbox requires a tag type";
						}
						if (!sameType(args[0].type, Dyn) || !sameType(out.type, type)) throw "Invalid IR enum tag unbox signature";
					case InlineEnumBox(type):
						var storage = inlineEnumStorage(type, enums);
						if (!sameType(args[0].type, storage) || !sameType(out.type, Dyn)) throw "Invalid IR inline enum box signature";
					case InlineEnumUnbox(type):
						var storage = inlineEnumStorage(type, enums);
						if (!sameType(args[0].type, Dyn) || !sameType(out.type, storage)) throw "Invalid IR inline enum unbox signature";
				}
			case Call(out, name, args), CNativeCall(out, name, args):
				if (name == IrArrayFactory.NAME) {
					switch instruction {
						case CNativeCall(_, _, _): throw "Array factory is not a C native";
						default:
					}
					if (args.length != 1 || !sameType(args[0].type, I32) || !(switch out.type {
						case Array(_): true;
						default: false;
					}))
						throw "Invalid typed array factory signature";
					require(values, args[0]);
					return;
				}
				if (IrScalarWordBits.matches(name)) {
					switch instruction {
						case CNativeCall(_, _, _): throw "Scalar word transport is not a C native";
						default:
					}
					if (args.length != 1 || !IrScalarWordBits.valid(name, args[0].type, out.type))
						throw "Invalid scalar word transport signature";
					require(values, args[0]);
					return;
				}
				if (name == IrValueLaneReference.PACK || name == IrValueLaneReference.UNPACK) {
					switch instruction {
						case CNativeCall(_, _, _): throw "A lane reference cast is not a C native";
						default:
					}
					if (args.length != 1)
						throw 'Wrong lane reference cast arity';
					require(values, args[0]);
					if (name == IrValueLaneReference.PACK ? !IrValueLaneReference.isCarrier(out.type)
						|| !IrValueLaneReference.canCarry(args[0].type) : !IrValueLaneReference.isCarrier(args[0].type)
						|| !IrValueLaneReference.canCarry(out.type))
						throw 'Invalid lane reference cast';
					return;
				}
				if (name == IrReferenceIdentity.NAME) {
					switch instruction {
						case CNativeCall(_, _, _): throw "Reference identity is not a C native";
						default:
					}
					if (args.length != 2 || (switch out.type {
						case Bool: false;
						default: true;
					}))
						throw "Invalid reference identity signature";
					for (arg in args) {
						require(values, arg);
						var valid = switch arg.type {
							case Obj(name): var object = objects.get(name); object != null && !object.isValue;
							// Managed references retain identity at erased boundaries; the operation never creates a box.
							case Bytes, ManagedBytes, Virtual(_), Dyn, Array(_), Iterator(_): true;
							case Nullable(inner): isIdentityReference(inner, objects);
							default: false;
						};
						if (!valid)
							throw 'Reference identity requires class or interface references, got ${Std.string(arg.type)}';
					}
					return;
				}
				if (name == IrReceiverCheck.NAME) {
					switch instruction {
						case CNativeCall(_, _, _): throw "A receiver check is not a C native";
						default:
					}
					if (args.length != 1 || (switch (out.type) {
						case Void: false;
						default: true;
					}) || (!isReference(args[0].type) && !(switch args[0].type {
						case EnumTag(_): true;
						default: false;
					})))
						throw "Invalid receiver check";
					require(values, args[0]);
					return;
				}
				if (name == IrHlScalarRef.ADDRESS || name == IrHlScalarRef.LOAD || name == IrHlScalarRef.STORE) {
					switch instruction {
						case CNativeCall(_, _, _): throw "A scalar reference intrinsic is not a C native";
						default:
					}
					var expected = name == IrHlScalarRef.STORE ? 2 : 1;
					if (args.length != expected)
						throw 'Wrong scalar reference intrinsic arity for $name';
					for (arg in args)
						require(values, arg);
					var element = IrHlScalarRef.element(name == IrHlScalarRef.ADDRESS ? out.type : args[0].type);
					if (element == null
						|| (switch (element) {
							case Void: true;
							default: false;
						})
						|| IrHlScalarRef.element(element) != null
						|| !sameType(name == IrHlScalarRef.ADDRESS ? args[0].type : name == IrHlScalarRef.LOAD ? out.type : args[1].type, element)
						|| (name == IrHlScalarRef.STORE && (switch (out.type) {
							case Void: false;
							default: true;
						})))
						throw 'Invalid scalar reference intrinsic type for $name';
					return;
				}
				var signature = signatures.get(name);
				if (signature == null)
					throw 'Unknown IR call "$name"';
				if (args.length != signature.arguments.length)
					throw 'Wrong IR argument count for "$name"';
				for (i in 0...args.length) {
					require(values, args[i]);
					if (!compatible(args[i].type, signature.arguments[i], objects, interfaces))
						throw 'Wrong IR argument type for "$name" at argument $i: got ${args[i].type}, expected ${signature.arguments[i]}';
				}
				if (!sameType(out.type, signature.result) && !trustedNativeResult(name, out.type, signature.result))
					throw 'Wrong IR result type for "$name"';
			case StaticClosure(out, name):
				var signature = signatures.get(name);
				if (signature == null)
					throw 'Unknown IR closure target "$name"';
				if (!sameType(out.type, Function(signature.arguments, signature.result)))
					throw 'Wrong IR closure type for "$name"';
			case InstanceClosure(out, name, receiver):
				var signature = signatures.get(name);
				if (signature == null)
					throw 'Unknown or receiver-less IR closure target "$name"';
				if (signature.arguments.length == 0)
					throw 'Unknown or receiver-less IR closure target "$name"';
				require(values, receiver);
				if (!compatible(receiver.type, signature.arguments[0], objects, interfaces))
					throw 'Wrong IR instance closure receiver type';
				var closureType:IrType = Function(signature.arguments.slice(1), signature.result);
				if (!sameType(out.type, closureType))
					throw 'Wrong IR instance closure type for "$name"';
			case CallClosure(out, closure, args) if (sameType(closure.type, Dyn)):
				// A call through a Dynamic value: the arguments and the result are Dynamic too.
				require(values, closure);
				for (argument in args) {
					require(values, argument);
					if (!IrTypeTools.compatible(Dyn, argument.type))
						throw 'IR dynamic closure call argument must be Dynamic';
				}
				if (!sameType(out.type, Dyn))
					throw 'IR dynamic closure call must produce a Dynamic value';
			case CallClosure(out, closure, args):
				require(values, closure);
				var functionType = switch closure.type {
					case Function(arguments, result): {arguments: arguments, result: result};
					default: throw 'IR closure value ${closure.id} is not callable';
				};
				if (args.length != functionType.arguments.length)
					throw 'Wrong IR closure argument count';
				for (i in 0...args.length) {
					require(values, args[i]);
					if (!sameType(args[i].type, functionType.arguments[i]))
						throw 'Wrong IR closure argument type';
				}
				if (!sameType(out.type, functionType.result))
					throw 'Wrong IR closure result type';
			case Upcast(out, value):
				require(values, value);
				switch out.type {
					case Obj(_) if (compatible(value.type, out.type, objects, interfaces) && !sameType(value.type, out.type)):
					default: throw 'IR upcast from ${value.type} to ${out.type} is not to a base class';
				}
			case ClassId(out, value):
				require(values, value);
				if (!sameType(out.type, I32))
					throw 'IR class id must be an I32, not ${out.type}';
				switch value.type {
					case Obj(_), Virtual(_):
					default: throw 'IR class id of ${value.type} is not of an object or an interface value';
				}
			case ToVirtual(out, value):
				require(values, value);
				switch out.type {
					case Virtual(_):
					default: throw 'IR virtual conversion must produce a virtual value';
				}
			case MethodCall(out, object, methodName, args, _):
				var signature = methodSignature(object.type, methodName, signatures, objects, interfaces);
				if (signature == null || signature.arguments.length != args.length + 1)
					throw 'Unknown or mismatched IR method "$methodName"';
				if (!compatible(object.type, signature.arguments[0], objects, interfaces))
					throw 'Wrong IR method receiver type for "$methodName": got ${object.type}, expected ${signature.arguments[0]}';
				for (i in 0...args.length) {
					require(values, args[i]);
					if (!compatible(args[i].type, signature.arguments[i + 1], objects, interfaces))
						throw 'Wrong IR method argument type for "$methodName" at argument ${i + 1}: got ${args[i].type}, expected ${signature.arguments[i + 1]}';
				}
				if (!sameType(out.type, signature.result))
					throw 'Wrong IR method result type for "$methodName": got ${out.type}, expected ${signature.result}';
			case NewObject(out, typeName):
				if (!objects.exists(typeName) || !isObjectType(out.type, typeName))
					throw 'Unknown or mismatched IR object "$typeName"';
			case FieldGet(out, object, fieldName):
				if (fieldName == compiler.backend.wasm.WasmFlattenValueFields.CHECK_FIELD) {
					requireObject(object, values, objects);
					expect(out, I32);
				} else {
					var objectType = requireObject(object, values, objects),
						field = findField(objectType, fieldName, objects);
					if (field == null || !sameType(out.type, field.type))
						throw 'Unknown or mismatched IR field "${objectType.name}.$fieldName": output=${out.type}, declared=${field == null ? "missing" : Std.string(field.type)}';
				}
			case FieldSet(object, fieldName, value):
				var objectType = requireObject(object, values, objects),
					field = findField(objectType, fieldName, objects);
				if (field == null)
					throw 'Unknown IR field "${objectType.name}.$fieldName"';
				if (!sameType(field.type, value.type))
					throw 'Mismatched IR field "${objectType.name}.$fieldName": got ${value.type}, expected ${field.type}';
				require(values, value);
			case ArrayGet(out, array, index):
				require(values, array);
				require(values, index);
				expect(index, I32);
				switch array.type {
					case Array(element):
						if (!sameType(out.type, element)) throw 'IR array read has the wrong element type';
					default: throw 'IR array read requires an Array value';
				}
			case ArraySet(array, index, value):
				require(values, array);
				require(values, index);
				require(values, value);
				expect(index, I32);
				switch array.type {
					case Array(element):
						if (!sameType(value.type, element)) throw 'IR array write has the wrong element type';
					default: throw 'IR array write requires an Array value';
				}
			case ArraySize(out, array):
				require(values, array);
				switch array.type {
					case Array(_):
					default: throw 'IR array size requires an Array value';
				}
				expect(out, I32);
			case IteratorNew(out, array):
				require(values, array);
				switch array.type {
					case Array(element): expect(out, Iterator(element));
					default: throw 'IR iterator creation requires an Array value';
				}
			case IteratorHasNext(out, iterator):
				require(values, iterator);
				switch iterator.type {
					case Iterator(_):
					default: throw 'IR hasNext requires an Iterator value';
				}
				expect(out, Bool);
			case IteratorNext(out, iterator):
				require(values, iterator);
				switch iterator.type {
					case Iterator(element): expect(out, element);
					default: throw 'IR next requires an Iterator value';
				}
				if ((switch (out.type) {
					case Void: true;
					default: false;
				}))
					throw 'IR iterator next cannot produce Void';
			case MakeEnum(out, typeName, constructor, arguments):
				if (!isEnumType(out.type, typeName, enums))
					throw 'Unknown or mismatched IR enum "$typeName"';
				var enumDecl = enums.get(typeName);
				if (enumDecl == null)
					throw 'Invalid IR enum constructor "$typeName"';
				if (constructor < 0 || constructor >= enumDecl.cases.length)
					throw 'Invalid IR enum constructor "$typeName"';
				var constructorDecl = enumDecl.cases[constructor];
				if (constructorDecl.params.length != arguments.length)
					throw 'Invalid IR enum constructor "$typeName"';
				for (i in 0...arguments.length) {
					require(values, arguments[i]);
					if (!sameType(arguments[i].type, constructorDecl.params[i]))
						throw 'Wrong IR enum payload type for "$typeName"';
				}
			case EnumIndex(out, value):
				expect(out, I32);
				require(values, value);
				switch value.type {
					case Enum(_), EnumTag(_):
					default: throw 'IR enum index requires an enum value';
				}
			case EnumField(out, value, constructor, field):
				require(values, value);
				var typeName = switch value.type {
					case Enum(name): name;
					default: throw 'IR enum field requires an enum value';
				};
				var enumDecl = enums.get(typeName);
				if (enumDecl == null)
					throw 'Invalid IR enum field constructor';
				if (constructor < 0 || constructor >= enumDecl.cases.length)
					throw 'Invalid IR enum field constructor';
				var constructorDecl = enumDecl.cases[constructor];
				if (field < 0 || field >= constructorDecl.params.length || !sameType(out.type, constructorDecl.params[field]))
					throw 'Invalid IR enum field';
		}

	static function requireObject(value:IrValue, values:IrVerifyValues, objects:IrVerifyTable<IrObject>):IrObject {
		require(values, value);
		return switch value.type {
			case Obj(name):
				var object = objects.get(name);
				if (object == null)
					throw 'Unknown IR object "$name"';
				object;
			default: throw 'IR value ${value.id} is not an object';
		};
	}

	static function isObjectType(type:IrType, name:String):Bool
		return switch type {
			case Obj(value): value == name;
			default: false;
		};

	static function inlineEnumStorage(type:IrType, enums:IrVerifyTable<IrEnum>):IrType {
		var name = switch type {
			case Enum(name): name;
			default: throw "IR inline enum intrinsic requires a nominal enum type";
		};
		var declaration = enums.get(name);
		if (declaration == null || declaration.inlineStorage == null)
			throw "IR inline enum intrinsic requires declared inline storage";
		return Obj(declaration.inlineStorage);
	}

	static function isEnumType(type:IrType, name:String, enums:IrVerifyTable<IrEnum>):Bool
		return switch type {
			case Enum(value): value == name && enums.exists(name);
			case EnumTag(value): value == name && enums.exists(name);
			default: false;
		};

	static function findField(object:IrObject, name:String, objects:IrVerifyTable<IrObject>):Null<IrObjectField> {
		for (field in object.fields)
			if (field.name == name)
				return field;
		var baseName = object.base;
		if (baseName != null && objects.exists(baseName)) {
			var base = objects.get(baseName);
			if (base != null)
				return findField(base, name, objects);
		}
		return null;
	}

	static function findMethodFunction(object:IrObject, name:String, objects:IrVerifyTable<IrObject>):Null<String> {
		for (method in object.methods)
			if (method.name == name)
				return method.functionName;
		var baseName = object.base;
		if (baseName == null || !objects.exists(baseName))
			return null;
		var base = objects.get(baseName);
		return base == null ? null : findMethodFunction(base, name, objects);
	}

	static function methodSignature(type:IrType, name:String, signatures, objects:IrVerifyTable<IrObject>,
			interfaces:IrVerifyTable<IrInterface>):Null<{arguments:Array<IrType>, result:IrType, kind:IrFunctionKind}> {
		return switch type {
			case Obj(_):
				var object = requireObjectType(type, objects),
					functionName = findMethodFunction(object, name, objects);
				if (functionName == null || !signatures.exists(functionName)) null; else signatures.get(functionName);
			case Virtual(interfaceName):
				var interfaceDecl = interfaces.get(interfaceName);
				if (interfaceDecl == null) null; else {
					var method = findInterfaceMethod(interfaceDecl, name, interfaces);
					if (method == null)
						null;
					else {
						var arguments:Array<IrType> = [Virtual(interfaceName)];
						arguments = arguments.concat(method.arguments);
						{arguments: arguments, result: method.result, kind: Ordinary};
					}
				}
			default: null;
		};
	}

	static function findInterfaceMethod(interfaceDecl:IrInterface, name:String, interfaces:IrVerifyTable<IrInterface>):Null<IrInterfaceMethod> {
		for (method in interfaceDecl.methods)
			if (method.name == name)
				return method;
		for (base in interfaceDecl.bases) {
			var baseDecl = interfaces.get(base);
			if (baseDecl != null) {
				var found = findInterfaceMethod(baseDecl, name, interfaces);
				if (found != null)
					return found;
			}
		}
		return null;
	}

	static function requireObjectType(type:IrType, objects:IrVerifyTable<IrObject>):IrObject {
		return switch type {
			case Obj(name):
				var object = objects.get(name);
				if (object == null)
					throw 'Unknown IR object "$name"';
				object;
			default: throw "IR method receiver is not an object";
		};
	}

	static function addSignature(map:Map<String, {arguments:Array<IrType>, result:IrType, kind:IrFunctionKind}>, name:String, arguments:Array<IrType>,
			result:IrType, kind:IrFunctionKind = Ordinary):Void {
		if (map.exists(name))
			throw 'Duplicate IR function "$name"';
		map.set(name, {arguments: arguments, result: result, kind: kind});
	}

	/** The one table of value types and definition sites, cleared and reused by every function (`IrVerifyValues`). */
	static final scratchValues = new IrVerifyValues();

	static function require(values:IrVerifyValues, value:IrValue):Void {
		if (!values.exists(value.id))
			throw 'IR value ${value.id} is used before definition';
		if (!sameType(values.get(value.id), value.type))
			throw 'IR value ${value.id} disagrees with its definition type';
	}

	static function expect(value:IrValue, type:IrType):Void {
		if (!sameType(value.type, type))
			throw 'IR value ${value.id} has the wrong type';
	}

	public static function sameType(left:IrType, right:IrType):Bool
		return switch left {
			case Obj(a): switch right {
					case Obj(b): a == b;
					default: false;
				};
			case Enum(a): switch right {
					case Enum(b): a == b;
					default: false;
				};
			case EnumTag(a): switch right {
					case EnumTag(b): a == b;
					default: false;
				};
			case Abstract(a): switch right {
					case Abstract(b): a == b;
					default: false;
				};
			case Virtual(a): switch right {
					case Virtual(b): a == b;
					default: false;
				};
			case Nullable(a): switch right {
					case Nullable(b): sameType(a, b);
					default: false;
				};
			case Array(a): switch right {
					case Array(b): sameType(a, b);
					default: false;
				};
			case Iterator(a): switch right {
					case Iterator(b): sameType(a, b);
					default: false;
				};
			case Function(aArgs, aResult): switch right {
					case Function(bArgs, bResult):
						if (aArgs.length != bArgs.length) false; else {
							var equal = sameType(aResult, bResult);
							for (i in 0...aArgs.length)
								if (!sameType(aArgs[i], bArgs[i]))
									equal = false;
							equal;
						}
					default: false;
				};
			default: Type.enumEq(left, right);
		};

	static function isReference(type:IrType):Bool
		return switch type {
			case Bytes, RawPtr, ManagedBytes, Dyn, Nullable(_), Obj(_), Enum(_), Abstract(_), Virtual(_), Array(_), Iterator(_), Function(_, _): true;
			default: false;
		};

	static function isIdentityReference(type:IrType, objects:IrVerifyTable<IrObject>):Bool
		return switch type {
			case Obj(name): var object = objects.get(name); object != null && !object.isValue;
			case Bytes, ManagedBytes, Virtual(_), Dyn, Array(_), Iterator(_): true;
			case Nullable(inner): isIdentityReference(inner, objects);
			default: false;
		};

	static function nullableOf(type:IrType):Null<IrType>
		return IrTypeTools.nullableElement(type);

	static function abiCompatible(actual:IrType, expected:IrType):Bool
		return switch expected {
			case Array(Dyn): switch actual {
					case Array(element): isReference(element) || (switch element {
							case EnumTag(_): true;
							default: false;
						});
					default: false;
				};
			case Dyn: isReference(actual);
			default: false;
		};

	static function trustedNativeResult(name:String, actual:IrType, expected:IrType):Bool
		return (StringTools.startsWith(name, "__array_")
			&& StringTools.endsWith(name, "_ref")
			|| StringTools.startsWith(name, "__map_")
			&& name.indexOf("_ref_values") >= 0)
			&& abiCompatible(actual, expected);

	public static function compatibleType(actual:IrType, expected:IrType, objects:Map<String, IrObject>, interfaces:Map<String, IrInterface>):Bool
		return compatible(actual, expected, new IrVerifyTable<IrObject>("objects", (key:String) -> objects.get(key), (key:String) -> objects.exists(key)),
			new IrVerifyTable<IrInterface>("interfaces", (key:String) -> interfaces.get(key), (key:String) -> interfaces.exists(key)));

	static function compatible(actual:IrType, expected:IrType, objects:IrVerifyTable<IrObject>, interfaces:IrVerifyTable<IrInterface>):Bool {
		if (sameType(actual, expected))
			return true;
		if (abiCompatible(actual, expected))
			return true;
		return switch actual {
			case Obj(actualName): switch expected {
					case Obj(_):
						var object = objects.get(actualName);
						if (object == null) false; else {
							var base = object.base;
							base != null && compatible(Obj(base), expected, objects, interfaces)
							;
						}
					case Dyn: true;
					default: false;
				};
			case Virtual(actualName): switch expected {
					case Virtual(expectedName): interfaceExtends(actualName, expectedName, interfaces);
					case Dyn: true;
					default: false;
				};
			case Array(actualElement): switch expected {
					case Array(expectedElement): (switch (expectedElement) {
							case Dyn: true;
							default: false;
						}) ? isReference(actualElement) : sameType(actualElement, expectedElement);
					case Dyn: true;
					default: false;
				};
			case Bytes, RawPtr, Function(_, _), Nullable(_): switch expected {
					case Dyn: true;
					default: false;
				};
			default: false;
		};
	}

	static function interfaceExtends(actual:String, expected:String, interfaces:IrVerifyTable<IrInterface>):Bool {
		if (actual == expected)
			return true;
		var declaration = interfaces.get(actual);
		if (declaration == null)
			return false;
		for (base in declaration.bases)
			if (interfaceExtends(base, expected, interfaces))
				return true;
		return false;
	}
}

/**
 * The type and definition site (block id and position) of each value of one function, by value id, in arrays that every function
 * reuses: a verification allocates no table and no record per value. `reset` clears only the ids the last function defined.
 */
class IrVerifyValues {
	var types:Array<Null<IrType>> = [];
	var blocks:Array<Int> = [];
	var positions:Array<Int> = [];
	var defined:Array<Int> = [];
	var count = 0;

	public function new() {}

	public function reset():Void {
		for (index in 0...count)
			types[defined[index]] = null;
		count = 0;
	}

	public inline function exists(id:Int):Bool
		return id >= 0 && id < types.length && types[id] != null;

	public inline function get(id:Int):IrType
		return types[id];

	public inline function blockOf(id:Int):Int
		return blocks[id];

	public inline function positionOf(id:Int):Int
		return positions[id];

	public function define(value:IrValue, block:Int, position:Int):Void {
		var id = value.id;
		if (id < 0)
			throw 'Invalid IR value id $id';
		if (exists(id))
			throw 'Duplicate IR value $id';
		while (types.length <= id) {
			types.push(null);
			blocks.push(0);
			positions.push(0);
		}
		types[id] = value.type;
		blocks[id] = block;
		positions[id] = position;
		if (count == defined.length)
			defined.push(id);
		else
			defined[count] = id;
		count++;
	}
}
