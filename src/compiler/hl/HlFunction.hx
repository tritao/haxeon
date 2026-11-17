package compiler.hl;

/**
 * HashLink debugger location corresponding exactly to one encoded opcode. Immutable and shared by the opcodes of one source position;
 * a class, because a typedef record costs a virtual object with its own field table, about three times the size, for every one of them.
 * `start` and `end` are -1 when the location has no byte range.
 */
class HlDebugLocation {
	public final path:String;
	public final line:Int;
	public final column:Int;
	public final endLine:Int;
	public final endColumn:Int;
	public final sourceHash:Int;
	public final start:Int;
	public final end:Int;
	public final flags:Int;

	public function new(path:String, line:Int, column:Int, endLine:Int, endColumn:Int, sourceHash:Int, start:Int,
			end:Int, flags:Int) {
		this.path = path;
		this.line = line;
		this.column = column;
		this.endLine = endLine;
		this.endColumn = endColumn;
		this.sourceHash = sourceHash;
		this.start = start;
		this.end = end;
		this.flags = flags;
	}
}

/** HashLink debugger binding at an encoded opcode, or -1 for an argument. */
typedef HlDebugAssignment = {
	final name:Int;
	final position:Int;
	final scopeEnd:Int;
}

/** HashLink bytecode function after register allocation and symbol resolution. */
class HlFunction {
	public final type:Int;
	public final functionIndex:Int;
	public final registers:Array<Int>;
	public final opcodes:Array<HlInstruction>;
	public final debugLocations:Array<HlDebugLocation>;
	public final debugAssignments:Array<HlDebugAssignment>;

	public function new(type:Int, functionIndex:Int, registers:Array<Int>, opcodes:Array<HlInstruction>,
			?debugLocations:Array<HlDebugLocation>,
			?debugAssignments:Array<HlDebugAssignment>) {
		this.type = type;
		this.functionIndex = functionIndex;
		this.registers = registers;
		this.opcodes = opcodes;
		this.debugLocations = debugLocations == null ? [] : debugLocations;
		this.debugAssignments = debugAssignments == null ? [] : debugAssignments;
	}
}

/** Symbolic HashLink instruction used before labels become relative offsets. */
enum HlInstruction {
	Move(destination:Int, source:Int);
	LoadInt(destination:Int, constant:Int);
	LoadFloat(destination:Int, constant:Int);
	LoadString(destination:Int, constant:Int);
	LoadBool(destination:Int, value:Bool);
	LoadNull(destination:Int);
	LoadType(destination:Int, type:Int);
	ToDyn(destination:Int, source:Int);
	ToSFloat(destination:Int, source:Int);
	ToInt(destination:Int, source:Int);
	SafeCast(destination:Int, source:Int);
	UnsafeCast(destination:Int, source:Int);

	/** Address of a register, valid only while its owning frame remains active. */
	Ref(destination:Int, source:Int);

	Unref(destination:Int, reference:Int);
	Setref(reference:Int, source:Int);
	RefOffset(destination:Int, reference:Int, index:Int);
	Trap(destination:Int, target:String, preserveExceptionStack:Bool);
	EndTrap(destination:Int, preserveExceptionStack:Bool);
	GlobalGet(destination:Int, global:Int);
	GlobalSet(global:Int, source:Int);
	Add(destination:Int, left:Int, right:Int);
	Sub(destination:Int, left:Int, right:Int);
	Mul(destination:Int, left:Int, right:Int);
	Div(destination:Int, left:Int, right:Int);
	Mod(destination:Int, left:Int, right:Int);
	BitAnd(destination:Int, left:Int, right:Int);
	BitXor(destination:Int, left:Int, right:Int);
	BitOr(destination:Int, left:Int, right:Int);
	ShiftLeft(destination:Int, left:Int, right:Int);
	ShiftRight(destination:Int, left:Int, right:Int);
	UnsignedShiftRight(destination:Int, left:Int, right:Int);
	Call0(destination:Int, functionIndex:Int);
	Call1(destination:Int, functionIndex:Int, argument:Int);
	Call2(destination:Int, functionIndex:Int, argument1:Int, argument2:Int);
	CallN(destination:Int, functionIndex:Int, arguments:Array<Int>);
	StaticClosure(destination:Int, functionIndex:Int);
	InstanceClosure(destination:Int, functionIndex:Int, receiver:Int);
	CallClosure(destination:Int, closure:Int, arguments:Array<Int>);
	NullCheck(register:Int);
	ToVirtual(destination:Int, source:Int);
	CallMethod(destination:Int, method:Int, arguments:Array<Int>);
	New(destination:Int, type:Int, extra:Int);
	FieldGet(destination:Int, object:Int, field:Int);
	FieldSet(object:Int, field:Int, source:Int);
	ArrayGet(destination:Int, array:Int, index:Int);
	ArraySet(array:Int, index:Int, source:Int);
	GetI8(destination:Int, pointer:Int, offset:Int);
	GetI16(destination:Int, pointer:Int, offset:Int);
	GetMem(destination:Int, pointer:Int, offset:Int);
	SetI8(pointer:Int, offset:Int, source:Int);
	SetI16(pointer:Int, offset:Int, source:Int);
	SetMem(pointer:Int, offset:Int, source:Int);
	ArraySize(destination:Int, array:Int);

	/** The address of an array's first element, for raw GetMem/SetMem access once its index is known to be in range. */
	RefData(destination:Int, array:Int);

	MakeEnum(destination:Int, constructor:Int, arguments:Array<Int>);
	EnumIndex(destination:Int, value:Int);
	EnumField(destination:Int, value:Int, constructor:Int, field:Int);
	JumpSignedLessOrEqual(left:Int, right:Int, target:String);
	JumpSignedLess(left:Int, right:Int, target:String);

	/** Jumps when `left` is below `right` as unsigned integers, so a negative `left` never jumps: one test for 0 <= left < right. */
	JumpUnsignedLess(left:Int, right:Int, target:String);

	JumpNull(value:Int, target:String);
	JumpEqual(left:Int, right:Int, target:String);
	JumpTrue(condition:Int, target:String);

	/**
	 * The complements of the jumps above, so a branch whose taken side is written next jumps to the other side. For integers the
	 * complement of `<` is `>=` and of `<=` is `>` (`JumpSignedGreaterOrEqual`, `JumpSignedGreater`). For floats it is "not less"
	 * (`JumpNotLess`) and "not greater or equal" (`JumpNotGreaterOrEqual`), which also jump when either side is NaN; the VM
	 * compares those as floats, never as signed integers.
	 */
	JumpFalse(condition:Int, target:String);

	JumpSignedGreaterOrEqual(left:Int, right:Int, target:String);

	/** The complement of `JumpUnsignedLess`: jumps unless `left` is below `right` as unsigned integers. */
	JumpUnsignedGreaterOrEqual(left:Int, right:Int, target:String);
	JumpSignedGreater(left:Int, right:Int, target:String);

	JumpNotNull(value:Int, target:String);
	JumpNotEqual(left:Int, right:Int, target:String);
	JumpNotLess(left:Int, right:Int, target:String);
	JumpNotGreaterOrEqual(left:Int, right:Int, target:String);
	Jump(target:String);

	/**
	 * A jump table on an Int register: to `targets[value]` when `0 <= value < targets.length`, else to the next instruction. HashLink
	 * takes only forward offsets, so every target comes after the switch.
	 */
	Switch(value:Int, targets:Array<String>);

	Label(name:String);
	Return(register:Int);
	Throw(register:Int);
	Rethrow(register:Int);
}
