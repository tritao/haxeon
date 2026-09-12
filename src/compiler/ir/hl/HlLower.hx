package compiler.ir.hl;

import compiler.hl.HlCode;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlFunction;
import compiler.hl.HlFunction.HlInstruction;
import compiler.hl.HlFunction.HlDebugLocation;
import compiler.hl.HlFunction.HlDebugAssignment;
import compiler.hl.HlType;
import compiler.hl.HlWriter;
import compiler.hl.incremental.HlSymbolTable;
import compiler.ir.Ir.IrInstruction;
import compiler.ir.Ir.IrTerminator;
import compiler.ir.Ir.IrBlock;
import compiler.ir.Ir.IrNative;
import compiler.ir.Ir.IrCNative;
import compiler.ir.Ir.IrObject;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrValue;
import compiler.ir.Ir.IrEnum;
import compiler.ir.IrVerifier;
import compiler.ir.SourceProvenance;

/** Lowers verified SSA IR into indexed HashLink types, registers, and opcodes. */
class HlLower {
	final code:HlCode;
	final symbols:HlSymbolTable;
	final functionIndices:Map<String, Int> = [];
	final objectTypeIndices:Map<String, Int> = [];
	final objects:Map<String, IrObject> = [];
	final enumTypeIndices:Map<String, Int> = [];
	final cNatives:Map<String, IrCNative> = [];
	final cDispatchNatives:Array<IrNative> = [];

	public static function lower(program:IrProgram):HlCode {
		IrVerifier.verify(program);
		return new HlLower(new HlSymbolTable(), null).lowerProgram(program);
	}

	public static function lowerStable(program:IrProgram, symbols:HlSymbolTable, indices:Map<String, Int>, ?stableIds:Map<String, Int>):HlCode {
		IrVerifier.verify(program);
		return new HlLower(symbols, indices, stableIds).lowerProgram(program);
	}

	final stableIds:Null<Map<String, Int>>;

	function new(symbols:HlSymbolTable, indices:Null<Map<String, Int>>, ?stableIds:Map<String, Int>) {
		this.symbols = symbols;
		this.stableIds = stableIds;
		code = new HlCode();
		code.ints = symbols.ints;
		code.floats = symbols.floats;
		code.strings = symbols.strings;
		code.types = symbols.types;
		code.globals = symbols.globals;
		if (indices != null)
			for (name => index in indices)
				functionIndices.set(name, index);
	}

	function lowerProgram(program:IrProgram):HlCode {
		var dispatchArities:Map<String, Bool> = [];
		for (native in program.cNatives) {
			cNatives.set(native.name, native);
			var arity = native.arguments.length;
			if (arity > 16)
				throw 'Ordinary C calls support at most 16 arguments, got $arity for "${native.name}"';
			var pointerResult = isNativePointer(native.result),
				bytesResult = isManagedPointerBytes(native),
				aggregateResult = isAggregateResult(native),
				utf8Result = isUtf8Result(native),
				dispatchKey = '$arity:$pointerResult:$bytesResult:$aggregateResult:$utf8Result';
			if ((pointerResult || bytesResult || utf8Result) && native.pointerOwnership == "unspecified")
				throw 'Ordinary C pointer result "${native.name}" requires @borrowed or @owned metadata before execution';
			if (!dispatchArities.exists(dispatchKey)) {
				dispatchArities.set(dispatchKey, true);
				cDispatchNatives.push({
					name: pointerResult ? '__c_native_pointer_invoke_$arity' : bytesResult ? '__c_native_bytes_invoke_$arity' : aggregateResult ? '__c_native_aggregate_invoke_$arity' : utf8Result ? '__c_native_utf8_invoke_$arity' : '__c_native_invoke_$arity',
					library: "haxeon_runtime",
					symbol: pointerResult ? 'native_pointer_invoke_$arity' : bytesResult ? 'native_bytes_invoke_$arity' : aggregateResult ? 'native_aggregate_invoke_$arity' : utf8Result ? 'native_utf8_invoke_$arity' : 'native_invoke_$arity',
					arguments: ((pointerResult || utf8Result) ? [Bytes, Bytes, Bytes, Bytes, Bytes, Bool] : bytesResult ? [Bytes, Bytes, Bytes, Bytes, Bytes, Bytes, Bool] : [Bytes, Bytes, Bytes])
						.concat([for (_ in 0...arity) Dyn]),
					result: pointerResult ? Abstract("native_pointer") : (bytesResult || aggregateResult) ? Abstract("realtime_bytes") : utf8Result ? Bytes : Dyn
				});
			}
		}
		var hasFunctionIndices = false;
		for (_ in functionIndices)
			hasFunctionIndices = true;
		if (!hasFunctionIndices) {
			var nextFunction = 0;
			for (native in program.natives)
				addFunctionName(native.name, nextFunction++);
			for (native in cDispatchNatives)
				addFunctionName(native.name, nextFunction++);
			for (fn in program.functions)
				addFunctionName(fn.name, nextFunction++);
		} else {
			var nextFunction = 0;
			for (index in functionIndices)
				if (index >= nextFunction)
					nextFunction = index + 1;
			for (native in cDispatchNatives)
				if (!functionIndices.exists(native.name))
					addFunctionName(native.name, nextFunction++);
		}
		for (enumDecl in program.enums)
			symbols.reserveEnum(enumDecl.name);
		for (interfaceDecl in program.interfaces)
			symbols.reserveInterface(interfaceDecl.name);
		for (object in program.objects)
			symbols.reserveObject(object.name);
		var valueObjects:Map<String, Bool> = [];
		for (object in program.objects)
			if (object.isValue)
				valueObjects.set(object.name, true);
		for (enumDecl in program.enums)
			enumTypeIndices.set(enumDecl.name, symbols.internEnum(enumDecl));
		var pendingInterfaces = program.interfaces.copy();
		while (pendingInterfaces.length > 0) {
			var progressed = false;
			var remainingInterfaces:Array<compiler.ir.Ir.IrInterface> = [];
			for (interfaceDecl in pendingInterfaces) {
				var ready = true;
				for (base in interfaceDecl.bases)
					if (!symbols.hasInterfaceMethods(base))
						ready = false;
				if (ready) {
					symbols.internInterface(interfaceDecl);
					progressed = true;
				} else
					remainingInterfaces.push(interfaceDecl);
			}
			if (!progressed)
				throw 'Unable to order interface bases';
			pendingInterfaces = remainingInterfaces;
		}
		var pending = program.objects.copy();
		while (pending.length > 0) {
			var progressed = false;
			var remaining:Array<IrObject> = [];
			for (object in pending) {
				var ready = true;
				if (object.base != null) {
					var baseName = Std.string(object.base);
					ready = objectTypeIndices.exists(baseName) || symbols.hasObjectMethods(baseName);
				}
				var fieldsReady = true;
				for (field in object.fields)
					if (!objectTypeReady(field.type))
						fieldsReady = false;
				if (ready && fieldsReady) {
					objects.set(object.name, object);
					objectTypeIndices.set(object.name, symbols.internObject(object, functionIndices, valueObjects));
					progressed = true;
				} else
					remaining.push(object);
			}
			if (!progressed)
				throw 'Unable to order object metadata dependencies';
			pending = remaining;
		}
		for (field in program.staticFields)
			symbols.internGlobal(field.name, field.type);
		for (native in program.natives)
			lowerNative(native);
		for (native in cDispatchNatives)
			lowerNative(native);
		for (fn in program.functions)
			try {
				code.functions.push(lowerFunction(PhiEdges.split(fn)));
			} catch (error:String) {
				throw 'HashLink lowering failed for ${fn.name}: $error';
			}
		var identities = [for (fn in program.functions) functionIdentity(fn)];
		code.debugSections.push({
			kind: HlWriter.FUNCTION_IDENTITIES,
			version: 1,
			flags: 0,
			payload: HlWriter.encodeFunctionIdentities(identities)
		});
		var spans:Array<compiler.hl.HlCode.HlOpcodeSourceSpan> = [];
		for (index in 0...code.functions.length) {
			var identity = identities[index],
				loweredFunction = code.functions[index];
			for (opcode in 0...loweredFunction.debugLocations.length) {
				var location = loweredFunction.debugLocations[opcode];
				spans.push({
					stableId: identity.stableId,
					opcode: opcode,
					sourcePath: location.path,
					start: location.start == null ? -1 : location.start,
					end: location.end == null ? -1 : location.end,
					line: location.line,
					column: location.column,
					endLine: location.endLine,
					endColumn: location.endColumn,
					sourceHash: location.sourceHash,
					flags: location.flags
				});
			}
		}
		code.debugSections.push({
			kind: HlWriter.OPCODE_SOURCE_SPANS,
			version: 2,
			flags: 0,
			payload: HlWriter.encodeOpcodeSourceSpans(spans)
		});

		code.entryPoint = requireFunction(program.entryPoint);
		code.ints = code.ints.copy();
		code.floats = code.floats.copy();
		code.strings = code.strings.copy();
		code.types = code.types.copy();
		code.globals = code.globals.copy();
		return code;
	}

	function functionIdentity(fn:IrFunction):compiler.hl.HlCode.HlFunctionIdentity {
		var functionIndex = requireFunction(fn.name), sourcePath = "", start = -1, end = -1, line = 0;
		for (block in fn.blocks)
			for (instruction in block.instructions) {
				var location = instruction.provenance.location;
				if (location == null)
					continue;
				if (sourcePath == "")
					sourcePath = location.path;
				if (start < 0 || location.start < start)
					start = location.start;
				if (end < location.end)
					end = location.end;
				if (line == 0 || location.line < line)
					line = location.line;
			}
		var parts = fn.name.split(".");
		return {
			stableId: stableIds != null && stableIds.exists(fn.name) ? stableIds.get(fn.name) : functionIndex,
			functionIndex: functionIndex,
			qualifiedName: fn.name,
			displayName: parts[parts.length - 1],
			sourcePath: sourcePath,
			start: start,
			end: end,
			line: line,
			flags: StringTools.startsWith(fn.name, "__") ? 1 : 0
		};
	}

	function objectTypeReady(type:IrType):Bool
		return switch type {
			case Obj(name): objectTypeIndices.exists(name) || symbols.hasType('obj:$name');
			case Function(arguments, result):
				var ready = objectTypeReady(result);
				for (argument in arguments)
					if (!objectTypeReady(argument))
						ready = false;
				ready;
			default: true;
		};

	function lowerNative(native:IrNative):Void {
		code.natives.push({
			library: internString(native.library),
			name: internString(native.symbol),
			type: internFunctionType(native.arguments, native.result),
			functionIndex: requireFunction(native.name),
		});
	}

	function lowerFunction(fn:IrFunction):HlFunction {
		var registers:Map<Int, Int> = [];
		var registerTypes:Array<Int> = [];
		var catchValues:Map<Int, IrValue> = [];
		var nullValues:Map<Int, Bool> = [];
		for (argument in fn.arguments)
			defineRegister(argument, registers, registerTypes);
		for (block in fn.blocks)
			for (instruction in block.instructions) {
				var output = instructionOutput(instruction.value);
				if (output != null)
					defineRegister(output, registers, registerTypes);
				switch instruction.value {
					case ConstNull(value):
						nullValues.set(value.id, true);
					case _:
				}
			}
		var edges:Map<String, Array<{destination:IrValue, source:IrValue}>> = [];
		for (block in fn.blocks)
			for (instruction in block.instructions)
				switch instruction.value {
					case Phi(output, inputs):
						defineRegister(output, registers, registerTypes);
						for (input in inputs) {
							var key = edgeKey(input.block, block.id);
							var moves:Array<{destination:IrValue, source:IrValue}>;
							if (edges.exists(key))
								moves = edges.get(key);
							else {
								moves = [];
								edges.set(key, moves);
							}
							moves.push({destination: output, source: input.value});
						}
					case Catch(output):
						catchValues.set(block.id, output);
						defineRegister(output, registers, registerTypes);
					default:
				}

		var bindingsByValue:Map<Int, Array<compiler.ir.IrFunction.IrDebugBinding>> = [];
		for (binding in fn.debugBindings) {
			var bindings = bindingsByValue.get(binding.value.id);
			if (bindings == null) {
				bindings = [];
				bindingsByValue.set(binding.value.id, bindings);
			}
			bindings.push(binding);
		}
		var debugAssignments:Array<HlDebugAssignment> = [],
			assignmentBindings:Array<compiler.ir.IrFunction.IrDebugBinding> = [],
			seenAssignments:Map<String, Bool> = [];
		for (argument in fn.arguments) {
			var bindings = bindingsByValue.get(argument.id);
			if (bindings != null)
				for (binding in bindings) {
					debugAssignments.push({name: internString(binding.name), position: -1, scopeEnd: -1});
					assignmentBindings.push(binding);
				}
		}
		var instructions:Array<HlInstruction> = [],
			debugLocations:Array<HlDebugLocation> = [];
		for (block in orderedBlocks(fn)) {
			if (block.instructions.length == 0 && block.terminator == null)
				continue;
			instructions.push(HlInstruction.Label('block_${block.id}'));
			debugLocations.push(debugLocation(blockProvenance(block)));
			for (instruction in block.instructions) {
				var instructionStart = instructions.length;
				var output = instructionOutput(instruction.value);
				switch instruction.value {
					case Phi(_, _):
					case ConstVoid(output):
						defineRegister(output, registers, registerTypes);
					case ConstInt(output, value):
						instructions.push(HlInstruction.LoadInt(defineRegister(output, registers, registerTypes), internInt(value)));
					case ConstFloat(output, value):
						instructions.push(HlInstruction.LoadFloat(defineRegister(output, registers, registerTypes), symbols.internFloat(value)));
					case ConstString(output, value):
						instructions.push(HlInstruction.LoadString(defineRegister(output, registers, registerTypes), internString(value)));
					case ConstBool(output, value):
						instructions.push(HlInstruction.LoadBool(defineRegister(output, registers, registerTypes), value));
					case ConstNull(output):
						instructions.push(HlInstruction.LoadNull(defineRegister(output, registers, registerTypes)));
					case TypeValue(output, type):
						instructions.push(HlInstruction.LoadType(defineRegister(output, registers, registerTypes), internType(type)));
					case ToDyn(output, value):
						instructions.push(HlInstruction.ToDyn(defineRegister(output, registers, registerTypes), requireRegister(value, registers)));
					case IntToFloat(output, value):
						instructions.push(HlInstruction.ToSFloat(defineRegister(output, registers, registerTypes), requireRegister(value, registers)));
					case IntToInt64(output, value):
						instructions.push(HlInstruction.ToInt(defineRegister(output, registers, registerTypes), requireRegister(value, registers)));
					case FloatToInt(output, value):
						instructions.push(HlInstruction.ToInt(defineRegister(output, registers, registerTypes), requireRegister(value, registers)));
					case SafeCast(output, value):
						instructions.push(HlInstruction.SafeCast(defineRegister(output, registers, registerTypes), requireRegister(value, registers)));
					case BeginTry(catchBlock, _):
						if (!catchValues.exists(catchBlock))
							throw 'Try block $block.id has no catch value in block $catchBlock';
						var handlerValue = catchValues.get(catchBlock);
						var handlerRegister = requireRegister(handlerValue, registers);
						instructions.push(HlInstruction.Trap(handlerRegister, 'block_$catchBlock'));
					case EndTry(catchBlock):
						if (!catchValues.exists(catchBlock))
							throw 'Try block $block.id ends with unknown handler block $catchBlock';
						instructions.push(HlInstruction.EndTrap(requireRegister(catchValues.get(catchBlock), registers)));
					case Catch(_):
					case GlobalGet(output, name):
						var global = symbols.requireGlobalIndex(name);
						instructions.push(HlInstruction.GlobalGet(defineRegister(output, registers, registerTypes), global));
					case GlobalSet(name, source):
						var global = symbols.requireGlobalIndex(name);
						instructions.push(HlInstruction.GlobalSet(global, requireRegister(source, registers)));
					case Add(output, left, right):
						instructions.push(HlInstruction.Add(defineRegister(output, registers, registerTypes), requireRegister(left, registers),
							requireRegister(right, registers)));
					case Sub(output, left, right):
						instructions.push(HlInstruction.Sub(defineRegister(output, registers, registerTypes), requireRegister(left, registers),
							requireRegister(right, registers)));
					case Mul(output, left, right):
						instructions.push(HlInstruction.Mul(defineRegister(output, registers, registerTypes), requireRegister(left, registers),
							requireRegister(right, registers)));
					case Div(output, left, right):
						instructions.push(HlInstruction.Div(defineRegister(output, registers, registerTypes), requireRegister(left, registers),
							requireRegister(right, registers)));
					case Mod(output, left, right):
						instructions.push(HlInstruction.Mod(defineRegister(output, registers, registerTypes), requireRegister(left, registers),
							requireRegister(right, registers)));
					case BitAnd(output, left, right):
						instructions.push(HlInstruction.BitAnd(defineRegister(output, registers, registerTypes), requireRegister(left, registers),
							requireRegister(right, registers)));
					case BitXor(output, left, right):
						instructions.push(HlInstruction.BitXor(defineRegister(output, registers, registerTypes), requireRegister(left, registers),
							requireRegister(right, registers)));
					case BitOr(output, left, right):
						instructions.push(HlInstruction.BitOr(defineRegister(output, registers, registerTypes), requireRegister(left, registers),
							requireRegister(right, registers)));
					case ShiftLeft(output, left, right):
						instructions.push(HlInstruction.ShiftLeft(defineRegister(output, registers, registerTypes), requireRegister(left, registers),
							requireRegister(right, registers)));
					case ShiftRight(output, left, right):
						instructions.push(HlInstruction.ShiftRight(defineRegister(output, registers, registerTypes), requireRegister(left, registers),
							requireRegister(right, registers)));
					case UnsignedShiftRight(output, left, right):
						instructions.push(HlInstruction.UnsignedShiftRight(defineRegister(output, registers, registerTypes), requireRegister(left, registers),
							requireRegister(right, registers)));
					case Less(output, left, right):
						lowerComparison(output, left, right, 0, registers, registerTypes, instructions);
					case LessEqual(output, left, right):
						lowerComparison(output, left, right, 1, registers, registerTypes, instructions);
					case Equal(output, left, right):
						lowerComparison(output, left, right, 2, registers, registerTypes, instructions);
					case Call(output, functionName, arguments):
						var destination = defineRegister(output, registers, registerTypes);
						var functionIndex = requireFunction(functionName);
						var args = [for (argument in arguments) requireRegister(argument, registers)];
						switch args.length {
							case 0: instructions.push(HlInstruction.Call0(destination, functionIndex));
							case 1: instructions.push(HlInstruction.Call1(destination, functionIndex, args[0]));
							case 2: instructions.push(HlInstruction.Call2(destination, functionIndex, args[0], args[1]));
							default: instructions.push(HlInstruction.CallN(destination, functionIndex, args));
						}
					case CNativeCall(output, functionName, arguments):
						var native = cNatives.get(functionName);
						if (native == null)
							throw 'Unknown ordinary C function "$functionName"';
						for (type in native.arguments)
							if (unsupportedCDispatchArgument(type))
								throw 'Ordinary C function "$functionName" uses an unsupported executable argument type $type';
						if (native.result != Void && unsupportedCDispatchResult(native.result))
							throw 'Ordinary C function "$functionName" uses an unsupported executable result type ${native.result}';
						var callArguments = [
							temporaryRegister(Bytes, registerTypes),
							temporaryRegister(Bytes, registerTypes),
							temporaryRegister(Bytes, registerTypes)
						];
						instructions.push(HlInstruction.LoadString(callArguments[0], internString(native.library)));
						instructions.push(HlInstruction.LoadString(callArguments[1], internString(native.symbol)));
						instructions.push(HlInstruction.LoadString(callArguments[2], internString(native.signature)));
						var pointerResult = isNativePointer(native.result),
							bytesResult = isManagedPointerBytes(native),
							aggregateResult = isAggregateResult(native),
							utf8Result = isUtf8Result(native);
						if (pointerResult || bytesResult || utf8Result) {
							var ownership = temporaryRegister(Bytes, registerTypes),
								release = temporaryRegister(Bytes, registerTypes),
								nullable = temporaryRegister(Bool, registerTypes);
							instructions.push(HlInstruction.LoadString(ownership, internString(native.pointerOwnership)));
							instructions.push(HlInstruction.LoadString(release, internString(native.pointerRelease == null ? "" : native.pointerRelease)));
							instructions.push(HlInstruction.LoadBool(nullable, native.pointerNullable));
							callArguments.push(ownership);
							callArguments.push(release);
							if (bytesResult) {
								var length = temporaryRegister(Bytes, registerTypes);
								instructions.push(HlInstruction.LoadString(length, internString(native.pointerLength)));
								callArguments.push(length);
							}
							callArguments.push(nullable);
						}
						for (argument in arguments) {
							var boxed = temporaryRegister(Dyn, registerTypes);
							if (nullValues.exists(argument.id))
								instructions.push(HlInstruction.LoadNull(boxed));
							else
								instructions.push(HlInstruction.ToDyn(boxed, requireRegister(argument, registers)));
							callArguments.push(boxed);
						}
						var dynamicResult = temporaryRegister(pointerResult ? Abstract("native_pointer") : (bytesResult || aggregateResult) ? Abstract("realtime_bytes") : utf8Result ? Bytes : Dyn,
							registerTypes);
						instructions.push(HlInstruction.CallN(dynamicResult,
							requireFunction(pointerResult ? '__c_native_pointer_invoke_${arguments.length}' : bytesResult ? '__c_native_bytes_invoke_${arguments.length}' : aggregateResult ? '__c_native_aggregate_invoke_${arguments.length}' : utf8Result ? '__c_native_utf8_invoke_${arguments.length}' : '__c_native_invoke_${arguments.length}'),
							callArguments));
						if (native.result == Void)
							defineRegister(output, registers, registerTypes);
						else if (pointerResult || bytesResult || aggregateResult || utf8Result)
							instructions.push(HlInstruction.Move(defineRegister(output, registers, registerTypes), dynamicResult));
						else
							instructions.push(HlInstruction.SafeCast(defineRegister(output, registers, registerTypes), dynamicResult));
					case StaticClosure(output, functionName):
						instructions.push(HlInstruction.StaticClosure(defineRegister(output, registers, registerTypes), requireFunction(functionName)));
					case InstanceClosure(output, functionName, receiver):
						instructions.push(HlInstruction.InstanceClosure(defineRegister(output, registers, registerTypes), requireFunction(functionName),
							requireRegister(receiver, registers)));
					case CallClosure(output, closure, arguments):
						instructions.push(HlInstruction.CallClosure(defineRegister(output, registers, registerTypes), requireRegister(closure, registers),
							[for (argument in arguments) requireRegister(argument, registers)]));
					case ToVirtual(output, value):
						instructions.push(HlInstruction.ToVirtual(defineRegister(output, registers, registerTypes), requireRegister(value, registers)));
					case MethodCall(output, object, methodName, arguments):
						var receiver = requireRegister(object, registers),
							methodArguments = [receiver].concat([for (argument in arguments) requireRegister(argument, registers)]);
						instructions.push(HlInstruction.CallMethod(defineRegister(output, registers, registerTypes), requireObjectMethod(object, methodName),
							methodArguments));
					case NewObject(output, typeName):
						instructions.push(HlInstruction.New(defineRegister(output, registers, registerTypes), requireObjectType(typeName), 0));
					case FieldGet(output, object, fieldName):
						instructions.push(HlInstruction.FieldGet(defineRegister(output, registers, registerTypes), requireRegister(object, registers),
							requireObjectField(object, fieldName)));
					case FieldSet(object, fieldName, value):
						instructions.push(HlInstruction.FieldSet(requireRegister(object, registers), requireObjectField(object, fieldName),
							requireRegister(value, registers)));
					case ArrayGet(output, array, index):
						instructions.push(HlInstruction.ArrayGet(defineRegister(output, registers, registerTypes), requireRegister(array, registers),
							requireRegister(index, registers)));
					case ArraySet(array, index, value):
						instructions.push(HlInstruction.ArraySet(requireRegister(array, registers), requireRegister(index, registers),
							requireRegister(value, registers)));
					case ArraySize(output, array):
						instructions.push(HlInstruction.ArraySize(defineRegister(output, registers, registerTypes), requireRegister(array, registers)));
					case MakeEnum(output, typeName, constructor, arguments):
						var destination = defineRegister(output, registers, registerTypes),
							enumConstructor = requireEnumConstructor(typeName, output.type, constructor),
							args = [for (argument in arguments) requireRegister(argument, registers)];
						instructions.push(HlInstruction.MakeEnum(destination, enumConstructor, args));
					case EnumIndex(output, value):
						instructions.push(HlInstruction.EnumIndex(defineRegister(output, registers, registerTypes), requireRegister(value, registers)));
					case EnumField(output, value, constructor, field):
						instructions.push(HlInstruction.EnumField(defineRegister(output, registers, registerTypes), requireRegister(value, registers),
							constructor, field));
				}
				appendDebugLocations(debugLocations, instructions.length - instructionStart, instruction.provenance);
				if (output != null && instructions.length > instructionStart) {
					var bindings = bindingsByValue.get(output.id);
					if (bindings != null) {
						var position = instructionStart;
						for (binding in bindings) {
							var key = binding.identity + "@" + position;
							if (!seenAssignments.exists(key)) {
								seenAssignments.set(key, true);
								debugAssignments.push({name: internString(binding.name), position: position, scopeEnd: -1});
								assignmentBindings.push(binding);
							}
						}
					}
				}
			}
			var terminator = block.terminator;
			if (terminator == null)
				throw 'Reachable IR block ${block.id} has no terminator';
			var terminatorStart = instructions.length;
			switch terminator.value {
				case Return(value):
					instructions.push(HlInstruction.Return(requireRegister(value, registers)));
				case Throw(value):
					instructions.push(HlInstruction.Throw(requireRegister(value, registers)));
				case Rethrow(value):
					instructions.push(HlInstruction.Rethrow(requireRegister(value, registers)));
				case Jump(target):
					var key = edgeKey(block.id, target);
					if (edges.exists(key))
						for (write in emitPhiMoves(edges.get(key), registers, registerTypes, instructions)) {
							var bindings = bindingsByValue.get(write.value.id);
							if (bindings != null)
								for (binding in bindings) {
									var assignmentKey = binding.identity + "@" + write.position;
									if (!seenAssignments.exists(assignmentKey)) {
										seenAssignments.set(assignmentKey, true);
										debugAssignments.push({name: internString(binding.name), position: write.position, scopeEnd: -1});
										assignmentBindings.push(binding);
									}
								}
						}
					instructions.push(HlInstruction.Jump('block_$target'));
				case Branch(condition, yes, no):
					if (edges.exists(edgeKey(block.id, yes)) || edges.exists(edgeKey(block.id, no)))
						throw "Phi elimination requires split critical edges";
					instructions.push(HlInstruction.JumpTrue(requireRegister(condition, registers), 'block_$yes'));
					instructions.push(HlInstruction.Jump('block_$no'));
			}
			appendDebugLocations(debugLocations, instructions.length - terminatorStart, terminator.provenance);
		}

		var scopedAssignments:Array<HlDebugAssignment> = [];
		for (index in 0...debugAssignments.length) {
			var assignment = debugAssignments[index],
				binding = assignmentBindings[index];
			scopedAssignments.push({
				name: assignment.name,
				position: assignment.position,
				scopeEnd: assignment.position < 0 ? -1 : scopeEndPosition(binding, debugLocations, assignment.position, instructions.length)
			});
		}
		return new HlFunction(internFunctionType([for (argument in fn.arguments) argument.type], fn.result), requireFunction(fn.name), registerTypes,
			instructions, debugLocations, scopedAssignments);
	}

	static function appendDebugLocations(output:Array<HlDebugLocation>, count:Int, provenance:SourceProvenance):Void
		for (_ in 0...count)
			output.push(debugLocation(provenance));

	static function debugLocation(provenance:SourceProvenance):HlDebugLocation {
		var location = provenance.location;
		return location == null ? {
			path: "<generated>",
			line: 1,
			start: -1,
			end: -1,
			column: 1,
			endLine: 1,
			endColumn: 1,
			sourceHash: 0,
			flags: 1
		} : {
			path: location.path,
			line: location.line,
			start: location.start,
			end: location.end,
			column: location.column,
			endLine: location.endLine,
			endColumn: location.endColumn,
			sourceHash: location.sourceHash,
			flags: switch provenance.origin {
				case CompilerGenerated(_): 1;
				case UserSource: 0;
			}
			};
	}

	static function scopeEndPosition(binding:compiler.ir.IrFunction.IrDebugBinding, locations:Array<HlDebugLocation>, position:Int, instructionCount:Int):Int {
		var last = position;
		for (index in position...locations.length) {
			var location = locations[index];
			if (location.path == binding.path
				&& location.start != null
				&& location.start >= binding.scopeStart
				&& location.start < binding.scopeEnd)
				last = index;
		}
		var end = last + 1;
		return end >= instructionCount ? -1 : end;
	}

	static function blockProvenance(block:IrBlock):SourceProvenance {
		if (block.instructions.length > 0)
			return block.instructions[0].provenance;
		if (block.terminator != null)
			return block.terminator.provenance;
		return SourceProvenance.generated("empty-hl-block");
	}

	/**
		HashLink traps are lexical in the bytecode stream. CFG block identifiers are
		allocation details, so lay each protected region out before its handler and
		its continuation regardless of block creation order.
	**/
	static function orderedBlocks(fn:IrFunction):Array<IrBlock> {
		var byId:Map<Int, IrBlock> = [for (block in fn.blocks) block.id => block],
			seen:Map<Int, Bool> = [],
			output:Array<IrBlock> = [];
		appendReversePostorder(byId, seen, output, fn.blocks[0].id);
		for (block in fn.blocks)
			if (!seen.exists(block.id) && (block.instructions.length > 0 || block.terminator != null))
				appendReversePostorder(byId, seen, output, block.id);
		return output;
	}

	static function appendReversePostorder(byId:Map<Int, IrBlock>, seen:Map<Int, Bool>, output:Array<IrBlock>, entry:Int):Void {
		var postorder:Array<IrBlock> = [];
		visitPostorder(byId, seen, postorder, entry);
		var index = postorder.length;
		while (index > 0) {
			index--;
			output.push(postorder[index]);
		}
	}

	static function visitPostorder(byId:Map<Int, IrBlock>, seen:Map<Int, Bool>, output:Array<IrBlock>, id:Int):Void {
		if (seen.exists(id) || !byId.exists(id))
			return;
		var block = byId.get(id);
		seen.set(id, true);
		var region:Null<{catchBlock:Int, afterBlock:Int}> = null;
		for (instruction in block.instructions)
			switch instruction.value {
				case BeginTry(catchBlock, afterBlock):
					region = {catchBlock: catchBlock, afterBlock: afterBlock};
				default:
			}
		var successors:Array<Int> = [];
		var terminator = block.terminator;
		if (terminator != null)
			switch terminator.value {
				case Jump(target):
					successors.push(target);
				case Branch(_, yes, no):
					successors.push(yes);
					successors.push(no);
				case Return(_), Throw(_), Rethrow(_):
			}
		if (region != null) {
			// Visit structural exits first because reversal places the protected
			// body before its handler and the handler before the shared exit.
			visitPostorder(byId, seen, output, region.afterBlock);
			visitPostorder(byId, seen, output, region.catchBlock);
		}
		var successorIndex = successors.length;
		while (successorIndex > 0) {
			successorIndex--;
			visitPostorder(byId, seen, output, successors[successorIndex]);
		}
		output.push(block);
	}

	static function edgeKey(from:Int, to:Int):String
		return '$from:$to';

	function emitPhiMoves(moves:Array<{destination:IrValue, source:IrValue}>, registers:Map<Int, Int>, registerTypes:Array<Int>,
			instructions:Array<HlInstruction>):Array<{value:IrValue, position:Int}> {
		var writes:Array<{value:IrValue, position:Int}> = [];
		if (moves.length == 1) {
			var destination = requireRegister(moves[0].destination, registers),
				source = requireRegister(moves[0].source, registers);
			if (destination != source) {
				writes.push({value: moves[0].destination, position: instructions.length});
				instructions.push(HlInstruction.Move(destination, source));
			}
			return writes;
		}
		var temporaries:Array<Int> = [];
		for (move in moves) {
			var temporary = registerTypes.length;
			registerTypes.push(internType(move.source.type));
			temporaries.push(temporary);
			instructions.push(HlInstruction.Move(temporary, requireRegister(move.source, registers)));
		}
		for (i in 0...moves.length) {
			writes.push({value: moves[i].destination, position: instructions.length});
			instructions.push(HlInstruction.Move(requireRegister(moves[i].destination, registers), temporaries[i]));
		}
		return writes;
	}

	function lowerComparison(output:IrValue, left:IrValue, right:IrValue, operation:Int, registers:Map<Int, Int>, registerTypes:Array<Int>,
			instructions:Array<HlInstruction>):Void {
		var destination = defineRegister(output, registers, registerTypes);
		var leftReg = requireRegister(left, registers),
			rightReg = requireRegister(right, registers);
		var trueLabel = '__cmp_true_${output.id}',
			endLabel = '__cmp_end_${output.id}';
		instructions.push(switch operation {
			case 0: HlInstruction.JumpSignedLess(leftReg, rightReg, trueLabel);
			case 1: HlInstruction.JumpSignedLessOrEqual(leftReg, rightReg, trueLabel);
			default: HlInstruction.JumpEqual(leftReg, rightReg, trueLabel);
		});
		instructions.push(HlInstruction.LoadBool(destination, false));
		instructions.push(HlInstruction.Jump(endLabel));
		instructions.push(HlInstruction.Label(trueLabel));
		instructions.push(HlInstruction.LoadBool(destination, true));
		instructions.push(HlInstruction.Label(endLabel));
	}

	function defineRegister(value:IrValue, registers:Map<Int, Int>, types:Array<Int>):Int {
		if (registers.exists(value.id))
			return registers.get(value.id);
		var index = types.length;
		registers.set(value.id, index);
		types.push(internType(value.type));
		return index;
	}

	function temporaryRegister(type:IrType, types:Array<Int>):Int {
		var index = types.length;
		types.push(internType(type));
		return index;
	}

	static function unsupportedCDispatchArgument(type:IrType):Bool
		return switch type {
			case I32, I64, Bool, F64, Bytes, Abstract("realtime_bytes"), Abstract("native_pointer"), Abstract("native_callback"): false;
			default: true;
		};

	static function unsupportedCDispatchResult(type:IrType):Bool
		return switch type {
			case I32, I64, Bool, F64, Bytes, Abstract("native_pointer"), Abstract("realtime_bytes"): false;
			default: true;
		};

	static function isNativePointer(type:IrType):Bool
		return switch type {
			case Abstract("native_pointer"): true;
			case _: false;
		};

	static function isManagedPointerBytes(native:IrCNative):Bool
		return native.pointerLength != null && switch native.result {
			case Abstract("realtime_bytes"): true;
			case _: false;
		};

	static function instructionOutput(instruction:IrInstruction):Null<IrValue>
		return compiler.ir.IrOperands.output(instruction);

	function requireRegister(value:IrValue, registers:Map<Int, Int>):Int {
		if (!registers.exists(value.id))
			throw 'IR value ${value.id} is used before definition';
		return registers.get(value.id);
	}

	static function isAggregateResult(native:IrCNative):Bool
		return native.pointerLength == null && switch (native.result) {
			case Abstract("realtime_bytes"): true;
			case _: false;
		};

	static function isUtf8Result(native:IrCNative):Bool {
		var separator = native.signature.indexOf(">");
		if (separator < 0)
			return false;
		var result = native.signature.substr(separator + 1);
		return StringTools.startsWith(result, "13") || StringTools.startsWith(result, "14");
	}

	function internInt(value:Int):Int {
		return symbols.internInt(value);
	}

	function internString(value:String):Int {
		return symbols.internString(value);
	}

	function internType(type:IrType):Int {
		return switch type {
			case Function(arguments, result): symbols.internFunction(arguments, result);
			default: symbols.internType(type);
		};
	}

	function internFunctionType(arguments:Array<IrType>, result:IrType):Int {
		return symbols.internFunction(arguments, result);
	}

	function requireObjectType(name:String):Int {
		if (!objectTypeIndices.exists(name))
			throw 'Unknown IR object "$name"';
		return objectTypeIndices.get(name);
	}

	function requireEnumConstructor(typeName:String, type:IrType, constructor:Int):Int {
		var name = switch type {
			case Enum(value): value;
			default: throw 'IR value is not an enum';
		};
		if (name != typeName)
			throw 'IR enum constructor type mismatch';
		if (!enumTypeIndices.exists(name))
			throw 'Unknown IR enum "$name"';
		if (constructor < 0)
			throw 'Invalid IR enum constructor $constructor';
		return constructor;
	}

	function requireObjectField(object:IrValue, name:String):Int {
		var typeName = switch object.type {
			case Obj(value): value;
			default: throw 'IR value ${object.id} is not an object';
		};
		if (!objects.exists(typeName))
			throw 'Unknown IR object "$typeName"';
		var descriptor = objects.get(typeName);
		var baseName = descriptor.base == null ? "" : Std.string(descriptor.base);
		var offset = baseName.length == 0 ? 0 : objectFieldCount(baseName);
		for (index in 0...descriptor.fields.length)
			if (descriptor.fields[index].name == name)
				return offset + index;
		if (baseName.length > 0)
			return requireObjectFieldByType(baseName, name);
		throw 'Unknown IR field "$typeName.$name"';
	}

	function requireObjectFieldByType(typeName:String, name:String):Int {
		if (!objects.exists(typeName))
			throw 'Unknown IR object "$typeName"';
		var descriptor = objects.get(typeName);
		var baseName = descriptor.base == null ? "" : Std.string(descriptor.base);
		var offset = baseName.length == 0 ? 0 : objectFieldCount(baseName);
		for (index in 0...descriptor.fields.length)
			if (descriptor.fields[index].name == name)
				return offset + index;
		if (baseName.length > 0)
			return requireObjectFieldByType(baseName, name);
		throw 'Unknown IR field "$typeName.$name"';
	}

	function requireObjectMethod(value:IrValue, name:String):Int {
		var typeName = switch value.type {
			case Obj(value): value;
			case Virtual(value):
				return symbols.requireInterfaceMethodIndex(value, name);
			default: throw 'IR value ${value.id} is not an object';
		};
		return symbols.requireObjectMethodIndex(typeName, name);
	}

	function objectFieldCount(typeName:String):Int {
		if (!objects.exists(typeName))
			throw 'Unknown IR object "$typeName"';
		var descriptor = objects.get(typeName);
		var baseName = descriptor.base == null ? "" : Std.string(descriptor.base);
		return descriptor.fields.length + (baseName.length == 0 ? 0 : objectFieldCount(baseName));
	}

	function addFunctionName(name:String, index:Int):Void {
		if (functionIndices.exists(name))
			throw 'Duplicate IR function "$name"';
		functionIndices.set(name, index);
	}

	function requireFunction(name:String):Int {
		if (!functionIndices.exists(name))
			throw 'Unknown IR function "$name"';
		return functionIndices.get(name);
	}
}
