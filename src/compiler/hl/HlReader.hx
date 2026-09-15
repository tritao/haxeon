package compiler.hl;

import haxe.io.Bytes;
import haxe.io.BytesInput;
import compiler.hl.HlCode.HlDebugSection;
import compiler.hl.HlCode.HlFunctionIdentity;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlFunction.HlDebugAssignment;
import compiler.hl.HlFunction.HlDebugLocation;
import compiler.hl.HlFunction.HlInstruction;

private typedef RawInstruction = {
	final opcode:Int;
	final operands:Array<Int>;
}

/** Decodes Haxeon's non-GC HLB module representation without native loader policy. */
class HlReader {
	static inline final MAX_ITEMS = 0x1000000;

	/** Read one complete HLB module and validate all table references. */
	public static function decode(bytes:Bytes):HlCode {
		if (bytes == null)
			throw "HLB data is required";
		var input = new BytesInput(bytes);
		input.bigEndian = false;
		try {
			if (input.readString(3) != "HLB")
				throw "Invalid HL bytecode header";
			var version = input.readByte();
			if (version <= 1 || version > HlCode.VERSION)
				throw 'Unsupported HLB version $version';
			var hasDebug = (readUnsigned(input, "flags") & 1) != 0,
				nints = readCount(input, "integer"),
				nfloats = readCount(input, "float"),
				nstrings = readCount(input, "string"),
				nbytes = version >= 5 ? readCount(input, "byte") : 0,
				ntypes = readCount(input, "type"),
				nglobals = readCount(input, "global"),
				nnatives = readCount(input, "native"),
				nfunctions = readCount(input, "function"),
				nconstants = version >= 4 ? readCount(input, "constant") : 0,
				entryPoint = readUnsigned(input, "entry point");
			var code = new HlCode();
			code.entryPoint = entryPoint;
			code.ints = [for (_ in 0...nints) input.readInt32()];
			code.floats = [for (_ in 0...nfloats) input.readDouble()];
			code.strings = readStrings(input, nstrings);
			code.bytes = version >= 5 ? readBytes(input) : Bytes.alloc(0);
			code.bytePositions = version >= 5 ? [for (_ in 0...nbytes) readUnsigned(input, "byte position")] : [];
			var debugFiles = hasDebug ? readStrings(input, readCount(input, "debug file")) : [];
			code.types = [for (_ in 0...ntypes) readType(input)];
			code.globals = [for (_ in 0...nglobals) readIndex(input)];
			code.natives = [
				for (_ in 0...nnatives)
					{
						library: readIndex(input),
						name: readIndex(input),
						type: readIndex(input),
						functionIndex: readUnsigned(input, "native function index")
					}
			];
			code.functions = [];
			for (_ in 0...nfunctions)
				code.functions.push(readFunction(input, hasDebug, debugFiles, version));
			code.constants = [];
			for (_ in 0...nconstants) {
				var global = readUnsigned(input, "constant global"), fields = [
					for (_ in 0...readCount(input, "constant field"))
						readUnsigned(input, "constant field index")
				];
				code.constants.push({global: global, fields: fields});
			}
			code.debugSections = version >= 7 ? readDebugSections(input) : [];
			for (section in code.debugSections)
				if (section.kind == HlWriter.FUNCTION_IDENTITIES && section.version == 1)
					code.functionIdentities = decodeFunctionIdentities(section.payload);
			if (input.position != bytes.length)
				throw "Trailing HLB data";
			HlValidator.validate(code);
			return code;
		} catch (error:haxe.io.Eof)
			throw "Truncated HLB data";
	}

	static function readStrings(input:BytesInput, count:Int):Array<String> {
		var size = input.readInt32();
		if (size < 0)
			throw "Negative HLB string storage size";
		var data = readBytesOfSize(input, size), result:Array<String> = [], position = 0;
		for (_ in 0...count) {
			var length = readUnsigned(input, "string length");
			if (length > data.length - position - 1 || data.get(position + length) != 0)
				throw "Invalid HLB string table";
			result.push(data.getString(position, length));
			position += length + 1;
		}
		if (position != data.length)
			throw "HLB string storage has trailing data";
		return result;
	}

	static function readBytes(input:BytesInput):Bytes {
		var size = input.readInt32();
		if (size < 0)
			throw "Negative HLB byte storage size";
		return readBytesOfSize(input, size);
	}

	static function readBytesOfSize(input:BytesInput, size:Int):Bytes {
		if (size > MAX_ITEMS * 16)
			throw "HLB byte storage is too large";
		return input.read(size);
	}

	static function readType(input:BytesInput):HlTypeDef {
		var tag = input.readByte();
		return switch tag {
			case HlType.Ref | HlType.Null | HlType.Packed:
				Parameterized(cast tag, readIndex(input));
			case HlType.Abstract:
				Abstract(readIndex(input));
			case HlType.Fun:
				var argumentCount = input.readByte();
				Function([for (_ in 0...argumentCount) readIndex(input)], readIndex(input));
			case HlType.Method:
				var argumentCount = input.readByte();
				Method([for (_ in 0...argumentCount) readIndex(input)], readIndex(input));
			case HlType.Obj:
				readObjectType(input, false);
			case HlType.Struct:
				readObjectType(input, true);
			case HlType.Virtual:
				var fields = [
					for (_ in 0...readCount(input, "virtual field"))
						{name: readIndex(input), type: readIndex(input)}
				];
				Virtual(fields);
			case HlType.Enum:
				var name = readIndex(input),
					global = readUnsigned(input, "enum global"),
					constructors:Array<compiler.hl.HlCode.HlEnumConstructor> = [];
				for (_ in 0...readCount(input, "enum constructor")) {
					var constructorName = readIndex(input), parameters = [
						for (_ in 0...readCount(input, "enum parameter"))
							readIndex(input)
					];
					constructors.push({name: constructorName, params: parameters});
				}
				Enum(name, global, constructors);
			default:
				simpleType(tag);
		}
	}

	static function simpleType(tag:Int):HlTypeDef {
		var lastTag:Int = cast HlType.Guid;
		if (tag < 0 || tag > lastTag)
			throw 'Invalid HLB type tag $tag';
		return Simple(cast tag);
	}

	static function readObjectType(input:BytesInput, structure:Bool):HlTypeDef {
		var name = readIndex(input), base = readIndex(input), global = readUnsigned(input, "object global"), fieldCount = readCount(input, "object field"),
			methodCount = readCount(input, "object method"), bindingCount = readCount(input, "object binding"), fields = [
				for (_ in 0...fieldCount)
					{name: readIndex(input), type: readIndex(input)}
			], methods = [
				for (_ in 0...methodCount)
					{name: readIndex(input), functionIndex: readUnsigned(input, "method function index"), prototype: readIndex(input)}
			];
		if (bindingCount > Std.int(MAX_ITEMS / 2))
			throw "Too many object bindings";
		var bindings = [for (_ in 0...bindingCount * 2) readUnsigned(input, "object binding index")];
		return structure ? Structure(name, global, fields, methods, bindings) : Object(name, base, global, fields, methods, bindings);
	}

	static function readFunction(input:BytesInput, hasDebug:Bool, debugFiles:Array<String>, version:Int):HlFunction {
		var type = readIndex(input),
			functionIndex = readUnsigned(input, "function index"),
			registerCount = readCount(input, "register"),
			opcodeCount = readCount(input, "opcode"),
			registers = [for (_ in 0...registerCount) readIndex(input)];
		var raw = [for (_ in 0...opcodeCount) readRawInstruction(input)];
		var debugLocations:Array<HlDebugLocation> = hasDebug ? readDebugLocations(input, raw.length, debugFiles) : [],
			debugAssignments:Array<HlDebugAssignment> = [];
		if (hasDebug && version >= 3)
			for (_ in 0...readCount(input, "debug assignment"))
				debugAssignments.push({
					name: readUnsigned(input, "debug assignment name"),
					position: readIndex(input) - 1,
					scopeEnd: version >= 6 ? readIndex(input) - 1 : -1
				});
		return new HlFunction(type, functionIndex, registers, decodeInstructions(raw, registers, functionIndex), debugLocations, debugAssignments);
	}

	static function readRawInstruction(input:BytesInput):RawInstruction {
		var opcode = input.readByte();
		return {opcode: opcode, operands: readOperands(input, opcode)};
	}

	static function readOperands(input:BytesInput, opcode:Int):Array<Int> {
		if (opcode == HlOpcode.Switch)
			return readSwitchOperands(input);
		return switch HlOpcodeSchema.arity(opcode) {
			case HlOpcodeSchema.UNSUPPORTED:
				throw 'Unsupported HLB opcode $opcode';
			case HlOpcodeSchema.VARIABLE_ARITY:
				var first = readIndex(input),
					second = readIndex(input),
					count = readCount(input, "variable opcode argument"),
					operands = [first, second, count];
				for (_ in 0...count)
					operands.push(readIndex(input));
				operands;
			case count:
				[for (_ in 0...count) readIndex(input)];
		}
	}

	static function readSwitchOperands(input:BytesInput):Array<Int> {
		var value = readUnsigned(input, "switch value"),
			count = readCount(input, "switch case"),
			offsets = [value, count];
		for (_ in 0...count)
			offsets.push(readUnsigned(input, "switch case offset"));
		offsets.push(readUnsigned(input, "switch default offset"));
		return offsets;
	}

	static function decodeInstructions(raw:Array<RawInstruction>, registers:Array<Int>, functionIndex:Int):Array<HlInstruction> {
		var labels:Map<Int, String> = [];
		for (position in 0...raw.length)
			if (raw[position].opcode == HlOpcode.Label)
				labels.set(position, labelName(position));
		for (position in 0...raw.length)
			for (target in jumpTargets(raw[position])) {
				var absoluteTarget = position + 1 + target;
				if (absoluteTarget < 0 || absoluteTarget >= raw.length)
					throw 'Invalid HLB jump target in function $functionIndex';
				if (!labels.exists(absoluteTarget))
					labels.set(absoluteTarget, labelName(absoluteTarget));
			}
		var result:Array<HlInstruction> = [];
		for (position in 0...raw.length) {
			var instruction = raw[position];
			if (labels.exists(position) && instruction.opcode != HlOpcode.Label)
				result.push(HlInstruction.Label(labels.get(position)));
			if (instruction.opcode == HlOpcode.Label)
				result.push(HlInstruction.Label(labels.get(position)));
			else
				result.push(decodeInstruction(instruction, labels, registers, functionIndex, position));
		}
		return result;
	}

	static function jumpTargets(instruction:RawInstruction):Array<Int> {
		return switch instruction.opcode {
			case HlOpcode.JAlways: [instruction.operands[0]];
			case HlOpcode.JTrue | HlOpcode.JFalse | HlOpcode.JNull | HlOpcode.JNotNull: [instruction.operands[1]];
			case HlOpcode.JSLt | HlOpcode.JSGte | HlOpcode.JSGt | HlOpcode.JSLte | HlOpcode.JULt | HlOpcode.JUGte | HlOpcode.JNotLt | HlOpcode.JNotGte | HlOpcode.JEq | HlOpcode.JNotEq: [instruction.operands[2]];
			case HlOpcode.Trap: [instruction.operands[1]];
			case HlOpcode.Switch:
				var count = instruction.operands[1], result:Array<Int> = [];
				for (index in 0...count)
					if (instruction.operands[index + 2] != 0)
						result.push(instruction.operands[index + 2]);
				if (instruction.operands[count + 2] != 0)
					result.push(instruction.operands[count + 2]);
				result;
			default: [];
		};
	}

	static function decodeInstruction(instruction:RawInstruction, labels:Map<Int, String>, registers:Array<Int>, functionIndex:Int,
			position:Int):HlInstruction {
		var operands = instruction.operands;
		return switch instruction.opcode {
			case HlOpcode.Mov: Move(operands[0], operands[1]);
			case HlOpcode.Int: LoadInt(operands[0], operands[1]);
			case HlOpcode.Float: LoadFloat(operands[0], operands[1]);
			case HlOpcode.Bool: LoadBool(operands[0], operands[1] != 0);
			case HlOpcode.Bytes: LoadBytes(operands[0], operands[1]);
			case HlOpcode.String: LoadString(operands[0], operands[1]);
			case HlOpcode.Null: LoadNull(operands[0]);
			case HlOpcode.NullCheck: NullCheck(operands[0]);
			case HlOpcode.GetType: GetType(operands[0], operands[1]);
			case HlOpcode.GetTID: GetTID(operands[0], operands[1]);
			case HlOpcode.Ref: Ref(operands[0], operands[1]);
			case HlOpcode.Unref: Unref(operands[0], operands[1]);
			case HlOpcode.SetRef: SetRef(operands[0], operands[1]);
			case HlOpcode.RefData: RefData(operands[0], operands[1]);
			case HlOpcode.RefOffset: RefOffset(operands[0], operands[1], operands[2]);
			case HlOpcode.Add: Add(operands[0], operands[1], operands[2]);
			case HlOpcode.Sub: Sub(operands[0], operands[1], operands[2]);
			case HlOpcode.Mul: Mul(operands[0], operands[1], operands[2]);
			case HlOpcode.SDiv: Div(operands[0], operands[1], operands[2]);
			case HlOpcode.UDiv: UnsignedDiv(operands[0], operands[1], operands[2]);
			case HlOpcode.SMod: Mod(operands[0], operands[1], operands[2]);
			case HlOpcode.UMod: UnsignedMod(operands[0], operands[1], operands[2]);
			case HlOpcode.Shl: ShiftLeft(operands[0], operands[1], operands[2]);
			case HlOpcode.SShr: ShiftRight(operands[0], operands[1], operands[2]);
			case HlOpcode.UShr: UnsignedShiftRight(operands[0], operands[1], operands[2]);
			case HlOpcode.And: BitAnd(operands[0], operands[1], operands[2]);
			case HlOpcode.Or: BitOr(operands[0], operands[1], operands[2]);
			case HlOpcode.Xor: BitXor(operands[0], operands[1], operands[2]);
			case HlOpcode.Neg: Negate(operands[0], operands[1]);
			case HlOpcode.Not: BitNot(operands[0], operands[1]);
			case HlOpcode.Incr: Increment(operands[0]);
			case HlOpcode.Decr: Decrement(operands[0]);
			case HlOpcode.Call0: Call0(operands[0], operands[1]);
			case HlOpcode.Call1: Call1(operands[0], operands[1], operands[2]);
			case HlOpcode.Call2: Call2(operands[0], operands[1], operands[2], operands[3]);
			case HlOpcode.Call3: Call3(operands[0], operands[1], operands[2], operands[3], operands[4]);
			case HlOpcode.Call4: Call4(operands[0], operands[1], operands[2], operands[3], operands[4], operands[5]);
			case HlOpcode.CallN: CallN(operands[0], operands[1], operands.slice(3));
			case HlOpcode.StaticClosure: StaticClosure(operands[0], operands[1]);
			case HlOpcode.InstanceClosure: InstanceClosure(operands[0], operands[1], operands[2]);
			case HlOpcode.VirtualClosure: VirtualClosure(operands[0], operands[1], operands[2]);
			case HlOpcode.CallClosure: CallClosure(operands[0], operands[1], operands.slice(3));
			case HlOpcode.ToVirtual: ToVirtual(operands[0], operands[1]);
			case HlOpcode.CallMethod: CallMethod(operands[0], operands[1], operands.slice(3));
			case HlOpcode.CallThis: ThisCall(operands[0], operands[1], operands.slice(3));
			case HlOpcode.GetGlobal: GlobalGet(operands[0], operands[1]);
			case HlOpcode.SetGlobal: GlobalSet(operands[0], operands[1]);
			case HlOpcode.GetThis: ThisGet(operands[0], operands[1]);
			case HlOpcode.SetThis: ThisSet(operands[0], operands[1]);
			case HlOpcode.DynGet: DynamicGet(operands[0], operands[1], operands[2]);
			case HlOpcode.DynSet: DynamicSet(operands[0], operands[1], operands[2]);
			case HlOpcode.Field: FieldGet(operands[0], operands[1], operands[2]);
			case HlOpcode.SetField: FieldSet(operands[0], operands[1], operands[2]);
			case HlOpcode.GetArray: ArrayGet(operands[0], operands[1], operands[2]);
			case HlOpcode.SetArray: ArraySet(operands[0], operands[1], operands[2]);
			case HlOpcode.GetI8: GetI8(operands[0], operands[1], operands[2]);
			case HlOpcode.GetI16: GetI16(operands[0], operands[1], operands[2]);
			case HlOpcode.GetMem: GetMem(operands[0], operands[1], operands[2]);
			case HlOpcode.SetI8: SetI8(operands[0], operands[1], operands[2]);
			case HlOpcode.SetI16: SetI16(operands[0], operands[1], operands[2]);
			case HlOpcode.SetMem: SetMem(operands[0], operands[1], operands[2]);
			case HlOpcode.New:
				if (operands[0] < 0 || operands[0] >= registers.length)
					throw 'Invalid HLB allocation register in function $functionIndex';
				New(operands[0], registers[operands[0]], 0);
			case HlOpcode.ArraySize: ArraySize(operands[0], operands[1]);
			case HlOpcode.Type: LoadType(operands[0], operands[1]);
			case HlOpcode.MakeEnum: MakeEnum(operands[0], operands[1], operands.slice(3));
			case HlOpcode.EnumAlloc: EnumAlloc(operands[0], operands[1]);
			case HlOpcode.EnumIndex: EnumIndex(operands[0], operands[1]);
			case HlOpcode.EnumField: EnumField(operands[0], operands[1], operands[2], operands[3]);
			case HlOpcode.SetEnumField: SetEnumField(operands[0], operands[1], operands[2]);
			case HlOpcode.Assert: Assert;
			case HlOpcode.Nop: Nop;
			case HlOpcode.Prefetch: Prefetch(operands[0], operands[1], operands[2]);
			case HlOpcode.Asm: Asm(operands[0], operands[1], operands[2]);
			case HlOpcode.JTrue: JumpTrue(operands[0], requireLabel(labels, position + 1 + operands[1], functionIndex));
			case HlOpcode.JFalse: JumpFalse(operands[0], requireLabel(labels, position + 1 + operands[1], functionIndex));
			case HlOpcode.JNull: JumpNull(operands[0], requireLabel(labels, position + 1 + operands[1], functionIndex));
			case HlOpcode.JNotNull: JumpNotNull(operands[0], requireLabel(labels, position + 1 + operands[1], functionIndex));
			case HlOpcode.JSLt: JumpSignedLess(operands[0], operands[1], requireLabel(labels, position + 1 + operands[2], functionIndex));
			case HlOpcode.JSGte: JumpSignedGreaterOrEqual(operands[0], operands[1], requireLabel(labels, position + 1 + operands[2], functionIndex));
			case HlOpcode.JSGt: JumpSignedGreater(operands[0], operands[1], requireLabel(labels, position + 1 + operands[2], functionIndex));
			case HlOpcode.JSLte: JumpSignedLessOrEqual(operands[0], operands[1], requireLabel(labels, position + 1 + operands[2], functionIndex));
			case HlOpcode.JULt: JumpUnsignedLess(operands[0], operands[1], requireLabel(labels, position + 1 + operands[2], functionIndex));
			case HlOpcode.JUGte: JumpUnsignedGreaterOrEqual(operands[0], operands[1], requireLabel(labels, position + 1 + operands[2], functionIndex));
			case HlOpcode.JNotLt: JumpNotLess(operands[0], operands[1], requireLabel(labels, position + 1 + operands[2], functionIndex));
			case HlOpcode.JNotGte: JumpNotGreater(operands[0], operands[1], requireLabel(labels, position + 1 + operands[2], functionIndex));
			case HlOpcode.JEq: JumpEqual(operands[0], operands[1], requireLabel(labels, position + 1 + operands[2], functionIndex));
			case HlOpcode.JNotEq: JumpNotEqual(operands[0], operands[1], requireLabel(labels, position + 1 + operands[2], functionIndex));
			case HlOpcode.JAlways: Jump(requireLabel(labels, position + 1 + operands[0], functionIndex));
			case HlOpcode.Switch:
				var count = operands[1],
					targets:Array<String> = [],
					missing:String = cast missingLabel();
				for (index in 0...count) {
					var offset = operands[index + 2];
					targets.push(offset == 0 ? missing : requireLabel(labels, position + 1 + offset, functionIndex));
				}
				var defaultOffset = operands[count + 2];
				Switch(operands[0], cast targets, defaultOffset == 0 ? missing : requireLabel(labels, position + 1 + defaultOffset, functionIndex));
			case HlOpcode.Catch: Catch(operands[0]);
			case HlOpcode.Ret: Return(operands[0]);
			case HlOpcode.ToDyn: ToDyn(operands[0], operands[1]);
			case HlOpcode.ToSFloat: ToSFloat(operands[0], operands[1]);
			case HlOpcode.ToUFloat: ToUFloat(operands[0], operands[1]);
			case HlOpcode.ToInt: ToInt(operands[0], operands[1]);
			case HlOpcode.SafeCast: SafeCast(operands[0], operands[1]);
			case HlOpcode.UnsafeCast: UnsafeCast(operands[0], operands[1]);
			case HlOpcode.Throw: Throw(operands[0]);
			case HlOpcode.Rethrow: Rethrow(operands[0]);
			case HlOpcode.Trap: Trap(operands[0], requireLabel(labels, position + 1 + operands[1], functionIndex));
			case HlOpcode.EndTrap: EndTrap(operands[0]);
			default: throw 'HLB opcode ${instruction.opcode} is not representable in HlInstruction';
		};
	}

	static function requireLabel(labels:Map<Int, String>, position:Int, functionIndex:Int):String {
		var label = labels.get(position);
		if (label == null)
			throw 'Missing HLB jump label in function $functionIndex';
		return label;
	}

	static function labelName(position:Int):String
		return 'L$position';

	static function readDebugLocations(input:BytesInput, count:Int, files:Array<String>):Array<HlDebugLocation> {
		var result:Array<HlDebugLocation> = [],
			currentFile = -1,
			currentLine = 0;
		while (result.length < count) {
			var value = input.readByte();
			if ((value & 1) != 0) {
				currentFile = (value >> 1) << 8 | input.readByte();
				if (currentFile < 0 || currentFile >= files.length)
					throw "Invalid HLB debug file index";
			} else if ((value & 2) != 0) {
				var repeat = (value >> 2) & 15;
				if (repeat == 0)
					throw "Invalid zero-length HLB debug location run";
				currentLine += value >> 6;
				if (result.length + repeat > count)
					throw "HLB debug location run exceeds opcode count";
				for (_ in 0...repeat)
					result.push(debugLocation(files, currentFile, currentLine));
			} else if ((value & 4) != 0) {
				currentLine += value >> 3;
				result.push(debugLocation(files, currentFile, currentLine));
			} else {
				currentLine = (value >> 3) | input.readByte() << 5 | input.readByte() << 13;
				result.push(debugLocation(files, currentFile, currentLine));
			}
		}
		return result;
	}

	static function debugLocation(files:Array<String>, file:Int, line:Int):HlDebugLocation {
		if (file < 0 || file >= files.length || line < 1)
			throw "Invalid HLB debug location";
		return {
			path: files[file],
			line: line,
			column: 1,
			endLine: line,
			endColumn: 1,
			sourceHash: 0,
			start: null,
			end: null,
			flags: 1
		};
	}

	static function readDebugSections(input:BytesInput):Array<HlDebugSection> {
		var result:Array<HlDebugSection> = [];
		for (_ in 0...readCount(input, "debug section")) {
			var kind = readUnsigned(input, "debug section kind"),
				version = readUnsigned(input, "debug section version"),
				flags = readUnsigned(input, "debug section flags"),
				payload = readBytesOfSize(input, readCount(input, "debug section payload"));
			result.push({
				kind: kind,
				version: version,
				flags: flags,
				payload: payload
			});
		}
		return result;
	}

	/** Decode HashLink's canonical function identity debug section. */
	public static function decodeFunctionIdentities(bytes:Bytes):Array<HlFunctionIdentity> {
		if (bytes == null)
			throw "HashLink function identity data is required";
		var input = new BytesInput(bytes);
		input.bigEndian = false;
		var result:Array<HlFunctionIdentity> = [];
		for (_ in 0...readCount(input, "function identity")) {
			var stableId = readUnsigned(input, "stable function identity"),
				functionIndex = readUnsigned(input, "function identity function index"),
				qualifiedName = readSizedString(input, "qualified function identity name"),
				displayName = readSizedString(input, "display function identity name"),
				sourcePath = readSizedString(input, "function identity source path"),
				start = readIndex(input) - 1,
				end = readIndex(input) - 1,
				line = readUnsigned(input, "function identity line"),
				flags = readUnsigned(input, "function identity flags");
			result.push({
				stableId: stableId,
				functionIndex: functionIndex,
				qualifiedName: qualifiedName,
				displayName: displayName,
				sourcePath: sourcePath,
				start: start,
				end: end,
				line: line,
				flags: flags
			});
		}
		if (input.position != bytes.length)
			throw "Trailing function identity data";
		return result;
	}

	static function readSizedString(input:BytesInput, what:String):String {
		return readBytesOfSize(input, readCount(input, what)).toString();
	}

	static function missingLabel():Null<String>
		return null;

	static function readCount(input:BytesInput, what:String):Int {
		var count = readUnsigned(input, what + " count");
		if (count > MAX_ITEMS)
			throw 'Too many HLB $what entries';
		return count;
	}

	static function readUnsigned(input:BytesInput, what:String):Int {
		var value = readIndex(input);
		if (value < 0)
			throw 'Negative HLB $what';
		return value;
	}

	static function readIndex(input:BytesInput):Int {
		var first = input.readByte();
		if ((first & 0x80) == 0)
			return first & 0x7F;
		if ((first & 0x40) == 0) {
			var shortValue = input.readByte() | ((first & 31) << 8);
			return (first & 0x20) == 0 ? shortValue : -shortValue;
		}
		var longValue = ((first & 31) << 24) | (input.readByte() << 16) | (input.readByte() << 8) | input.readByte();
		return (first & 0x20) == 0 ? longValue : -longValue;
	}
}
