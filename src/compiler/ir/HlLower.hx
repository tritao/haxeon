package compiler.ir;

import compiler.hl.HlCode;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlFunction;
import compiler.hl.HlFunction.HlInstruction;
import compiler.hl.HlType;
import compiler.hl.HlSymbolTable;
import compiler.ir.Ir.IrInstruction;
import compiler.ir.Ir.IrNative;
import compiler.ir.Ir.IrObject;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrValue;

class HlLower {
	final code:HlCode;
	final symbols:HlSymbolTable;
	final functionIndices:Map<String, Int> = [];
	final objectTypeIndices:Map<String, Int> = [];
	final objects:Map<String, IrObject> = [];

	public static function lower(program:IrProgram):HlCode {
		IrVerifier.verify(program);
		return new HlLower(new HlSymbolTable(), null).lowerProgram(program);
	}

	public static function lowerStable(program:IrProgram, symbols:HlSymbolTable, indices:Map<String, Int>):HlCode {
		IrVerifier.verify(program);
		return new HlLower(symbols, indices).lowerProgram(program);
	}

	function new(symbols:HlSymbolTable, indices:Null<Map<String, Int>>) {
		this.symbols = symbols;
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
		var pending = program.objects.copy();
		while (pending.length > 0) {
			var progressed = false;
			for (object in pending.copy()) {
				if (object.base != null && !objectTypeIndices.exists(object.base) && symbols.typeIndex('obj:${object.base}') == null)
					continue;
				objects.set(object.name, object);
				objectTypeIndices.set(object.name, symbols.internObject(object));
				pending.remove(object);
				progressed = true;
			}
			if (!progressed)
				throw 'Unable to order object bases';
		}
		if (functionIndices.keys().hasNext() == false) {
			var nextFunction = 0;
			for (native in program.natives)
				addFunctionName(native.name, nextFunction++);
			for (fn in program.functions)
				addFunctionName(fn.name, nextFunction++);
		}

		for (native in program.natives)
			lowerNative(native);
		for (fn in program.functions)
			code.functions.push(lowerFunction(fn));

		code.entryPoint = requireFunction(program.entryPoint);
		code.ints = code.ints.copy();
		code.floats = code.floats.copy();
		code.strings = code.strings.copy();
		code.types = code.types.copy();
		code.globals = code.globals.copy();
		return code;
	}

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
		for (argument in fn.arguments)
			defineRegister(argument, registers, registerTypes);

		var edges:Map<String, Array<{destination:IrValue, source:IrValue}>> = [];
		for (block in fn.blocks)
			for (instruction in block.instructions)
				switch instruction {
					case Phi(output, inputs):
						defineRegister(output, registers, registerTypes);
						for (input in inputs) {
							var key = edgeKey(input.block, block.id),
								moves = edges.get(key);
							if (moves == null) {
								moves = [];
								edges.set(key, moves);
							}
							moves.push({destination: output, source: input.value});
						}
					default:
				}

		var instructions:Array<HlInstruction> = [];
		for (block in fn.blocks) {
			if (block.instructions.length == 0 && block.terminator == null)
				continue;
			instructions.push(HlInstruction.Label('block_${block.id}'));
			for (instruction in block.instructions) {
				switch instruction {
					case Phi(_, _):
					case ConstVoid(output):
						defineRegister(output, registers, registerTypes);
					case ConstInt(output, value):
						instructions.push(HlInstruction.LoadInt(defineRegister(output, registers, registerTypes), internInt(value)));
					case ConstFloat(output, value):
						instructions.push(HlInstruction.LoadFloat(defineRegister(output, registers, registerTypes), symbols.internFloat(value)));
					case ConstString(output, value):
						instructions.push(HlInstruction.LoadString(defineRegister(output, registers, registerTypes), internString(value)));
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
							default: throw 'HL lowering supports at most two call arguments, got ${args.length}';
						}
					case StaticClosure(output, functionName):
						instructions.push(HlInstruction.StaticClosure(defineRegister(output, registers, registerTypes), requireFunction(functionName)));
					case InstanceClosure(output, functionName, receiver):
						instructions.push(HlInstruction.InstanceClosure(defineRegister(output, registers, registerTypes), requireFunction(functionName),
							requireRegister(receiver, registers)));
					case CallClosure(output, closure, arguments):
						instructions.push(HlInstruction.CallClosure(defineRegister(output, registers, registerTypes), requireRegister(closure, registers),
							[for (argument in arguments) requireRegister(argument, registers)]));
					case NewObject(output, typeName):
						instructions.push(HlInstruction.New(defineRegister(output, registers, registerTypes), requireObjectType(typeName), 0));
					case FieldGet(output, object, fieldName):
						instructions.push(HlInstruction.FieldGet(defineRegister(output, registers, registerTypes), requireRegister(object, registers),
							requireObjectField(object, fieldName)));
					case FieldSet(object, fieldName, value):
						instructions.push(HlInstruction.FieldSet(requireRegister(object, registers), requireObjectField(object, fieldName),
							requireRegister(value, registers)));
				}
			}
			if (block.terminator == null)
				throw 'Reachable IR block ${block.id} has no terminator';
			switch block.terminator {
				case Return(value):
					instructions.push(HlInstruction.Return(requireRegister(value, registers)));
				case Jump(target):
					emitPhiMoves(edges.get(edgeKey(block.id, target)), registers, registerTypes, instructions);
					instructions.push(HlInstruction.Jump('block_$target'));
				case Branch(condition, yes, no):
					if (edges.exists(edgeKey(block.id, yes)) || edges.exists(edgeKey(block.id, no)))
						throw "Phi elimination requires split critical edges";
					instructions.push(HlInstruction.JumpTrue(requireRegister(condition, registers), 'block_$yes'));
					instructions.push(HlInstruction.Jump('block_$no'));
			}
		}

		return new HlFunction(internFunctionType([for (argument in fn.arguments) argument.type], fn.result), requireFunction(fn.name), registerTypes,
			instructions);
	}

	static function edgeKey(from:Int, to:Int):String
		return '$from:$to';

	function emitPhiMoves(moves:Null<Array<{destination:IrValue, source:IrValue}>>, registers:Map<Int, Int>, registerTypes:Array<Int>,
			instructions:Array<HlInstruction>):Void {
		if (moves == null)
			return;
		if (moves.length == 1) {
			var destination = requireRegister(moves[0].destination, registers),
				source = requireRegister(moves[0].source, registers);
			if (destination != source)
				instructions.push(HlInstruction.Move(destination, source));
			return;
		}
		var temporaries = [];
		for (move in moves) {
			var temporary = registerTypes.length;
			registerTypes.push(internType(move.source.type));
			temporaries.push(temporary);
			instructions.push(HlInstruction.Move(temporary, requireRegister(move.source, registers)));
		}
		for (i in 0...moves.length)
			instructions.push(HlInstruction.Move(requireRegister(moves[i].destination, registers), temporaries[i]));
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
			throw 'IR value ${value.id} is defined more than once';
		var index = types.length;
		registers.set(value.id, index);
		types.push(internType(value.type));
		return index;
	}

	function requireRegister(value:IrValue, registers:Map<Int, Int>):Int {
		var index = registers.get(value.id);
		if (index == null)
			throw 'IR value ${value.id} is used before definition';
		return index;
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
		var index = objectTypeIndices.get(name);
		if (index == null)
			throw 'Unknown IR object "$name"';
		return index;
	}

	function requireObjectField(object:IrValue, name:String):Int {
		var typeName = switch object.type {
			case Obj(value): value;
			default: throw 'IR value ${object.id} is not an object';
		};
		var descriptor = objects.get(typeName);
		if (descriptor == null)
			throw 'Unknown IR object "$typeName"';
		var offset = descriptor.base == null ? 0 : objectFieldCount(descriptor.base);
		for (index in 0...descriptor.fields.length)
			if (descriptor.fields[index].name == name)
				return offset + index;
		if (descriptor.base != null)
			return requireObjectFieldByType(descriptor.base, name);
		throw 'Unknown IR field "$typeName.$name"';
	}

	function requireObjectFieldByType(typeName:String, name:String):Int {
		var descriptor = objects.get(typeName);
		if (descriptor == null)
			throw 'Unknown IR object "$typeName"';
		var offset = descriptor.base == null ? 0 : objectFieldCount(descriptor.base);
		for (index in 0...descriptor.fields.length)
			if (descriptor.fields[index].name == name)
				return offset + index;
		if (descriptor.base != null)
			return requireObjectFieldByType(descriptor.base, name);
		throw 'Unknown IR field "$typeName.$name"';
	}

	function objectFieldCount(typeName:String):Int {
		var descriptor = objects.get(typeName);
		if (descriptor == null)
			throw 'Unknown IR object "$typeName"';
		return descriptor.fields.length + (descriptor.base == null ? 0 : objectFieldCount(descriptor.base));
	}

	function addFunctionName(name:String, index:Int):Void {
		if (functionIndices.exists(name))
			throw 'Duplicate IR function "$name"';
		functionIndices.set(name, index);
	}

	function requireFunction(name:String):Int {
		var index = functionIndices.get(name);
		if (index == null)
			throw 'Unknown IR function "$name"';
		return index;
	}
}
