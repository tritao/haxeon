package compiler.hl;

/**
 * HashLink debugger location corresponding exactly to one encoded opcode, counted from its anchor as an IR location is
 * (`SourceLocation`): the writer finds the file, offsets and lines in the module's sources (`HlCode.sources`), so a lowered
 * function stays valid wherever its declarations moved. Immutable and shared by the opcodes of one source position; a class,
 * because a typedef record costs a virtual object with its own field table, about three times the size, for every one of them.
 * `start` and `end` are -1 when the location has no byte range.
 */
class HlDebugLocation {
	public final anchor:Int;
	public final line:Int;
	public final column:Int;
	public final endLine:Int;
	public final endColumn:Int;
	public final start:Int;
	public final end:Int;
	public final flags:Int;

	/** Whether the location is text the compiler wrote, which no snapshot holds: its source hash is 0. */
	public final generatedText:Bool;

	public function new(anchor:Int, line:Int, column:Int, endLine:Int, endColumn:Int, start:Int, end:Int, flags:Int,
			generatedText:Bool) {
		this.anchor = anchor;
		this.line = line;
		this.column = column;
		this.endLine = endLine;
		this.endColumn = endColumn;
		this.start = start;
		this.end = end;
		this.flags = flags;
		this.generatedText = generatedText;
	}

	/** A location in a file with no declarations, by its lines as they are: what a module made without sources holds. */
	public static function inFile(path:String, line:Int, column:Int, endLine:Int, endColumn:Int, start:Int, end:Int,
			flags:Int):HlDebugLocation
		return new HlDebugLocation(compiler.core.SourceAnchor.file(path), line - 1, column, endLine - 1, endColumn,
			start,
			end, flags, true);
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

	var distinctAnchors:Null<Array<Int>> = null;

	/**
	 * The anchors the debug locations count from, each once, in the order they first appear: what the files a function names
	 * and the places its encoding depends on follow from. Kept with the function, which never changes.
	 */
	public function anchors():Array<Int> {
		var known = distinctAnchors;
		if (known != null)
			return known;
		var result:Array<Int> = [], previous = -1;
		for (location in debugLocations)
			if (location.anchor != previous) {
				previous = location.anchor;
				if (result.indexOf(previous) < 0)
					result.push(previous);
			}
		distinctAnchors = result;
		return result;
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

	/** OGetType: the runtime type of the object or dynamic in `source` (`void` for null). */
	GetType(destination:Int, source:Int);
	ToSFloat(destination:Int, source:Int);
	ToInt(destination:Int, source:Int);
	SafeCast(destination:Int, source:Int);
	UnsafeCast(destination:Int, source:Int);

	/** Address of a register, valid only while its owning frame remains active. */
	Ref(destination:Int, source:Int);

	Unref(destination:Int, reference:Int);
	Setref(reference:Int, source:Int);
	RefOffset(destination:Int, reference:Int, index:Int);
	Trap(destination:Int, target:Int, preserveExceptionStack:Bool);
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
	JumpSignedLessOrEqual(left:Int, right:Int, target:Int);
	JumpSignedLess(left:Int, right:Int, target:Int);

	/** Jumps when `left` is below `right` as unsigned integers, so a negative `left` never jumps: one test for 0 <= left < right. */
	JumpUnsignedLess(left:Int, right:Int, target:Int);

	JumpNull(value:Int, target:Int);
	JumpEqual(left:Int, right:Int, target:Int);
	JumpTrue(condition:Int, target:Int);

	/**
	 * The complements of the jumps above, so a branch whose taken side is written next jumps to the other side. For integers the
	 * complement of `<` is `>=` and of `<=` is `>` (`JumpSignedGreaterOrEqual`, `JumpSignedGreater`). For floats it is "not less"
	 * (`JumpNotLess`) and "not greater or equal" (`JumpNotGreaterOrEqual`), which also jump when either side is NaN; the VM
	 * compares those as floats, never as signed integers.
	 */
	JumpFalse(condition:Int, target:Int);

	JumpSignedGreaterOrEqual(left:Int, right:Int, target:Int);

	/** The complement of `JumpUnsignedLess`: jumps unless `left` is below `right` as unsigned integers. */
	JumpUnsignedGreaterOrEqual(left:Int, right:Int, target:Int);
	JumpSignedGreater(left:Int, right:Int, target:Int);

	JumpNotNull(value:Int, target:Int);
	JumpNotEqual(left:Int, right:Int, target:Int);
	JumpNotLess(left:Int, right:Int, target:Int);
	JumpNotGreaterOrEqual(left:Int, right:Int, target:Int);
	Jump(target:Int);

	/**
	 * A jump table on an Int register: to `targets[value]` when `0 <= value < targets.length`, else to the next instruction. HashLink
	 * takes only forward offsets, so every target comes after the switch.
	 */
	Switch(value:Int, targets:Array<Int>);

	/**
	 * A position jumps, traps and switches name by `id`, unique in its function. Lowering gives block `b` the label `b` and
	 * numbers its other labels after the last block. The writer leaves a label out of the opcodes (`HlWriter.layout`).
	 */
	Label(id:Int);
	Return(register:Int);
	Throw(register:Int);
	Rethrow(register:Int);
}
