package compiler.hl;

/** Structural comparison of two lowered functions: type, slot, registers, opcodes, debug locations and assignments. */
class HlFunctionEquality {
	/** Null when the functions are the same; otherwise the first difference. */
	public static function difference(a:HlFunction, b:HlFunction):Null<String> {
		if (a.type != b.type)
			return 'type ${a.type} and ${b.type}';
		if (a.functionIndex != b.functionIndex)
			return 'slot ${a.functionIndex} and ${b.functionIndex}';
		if (a.registers.length != b.registers.length)
			return 'register counts ${a.registers.length} and ${b.registers.length}';
		for (index in 0...a.registers.length)
			if (a.registers[index] != b.registers[index])
				return 'register $index is type ${a.registers[index]} and ${b.registers[index]}';
		// Jump targets and labels are strings; lowering again numbers its generated ones from a counter of its own, so two functions
		// are the same when their labels correspond one to one.
		var forward:Map<String, String> = [],
			backward:Map<String, String> = [];
		if (a.opcodes.length != b.opcodes.length)
			return 'opcode counts ${a.opcodes.length} and ${b.opcodes.length}';
		for (index in 0...a.opcodes.length)
			if (!same(a.opcodes[index], b.opcodes[index], forward, backward))
				return 'opcode $index is ${a.opcodes[index]} and ${b.opcodes[index]}';
		if (a.debugLocations.length != b.debugLocations.length)
			return 'debug location counts ${a.debugLocations.length} and ${b.debugLocations.length}';
		for (index in 0...a.debugLocations.length) {
			var x = a.debugLocations[index], y = b.debugLocations[index];
			if (x != y
				&& (x.path != y.path || x.line != y.line || x.column != y.column || x.endLine != y.endLine || x.endColumn != y.endColumn
					|| x.sourceHash != y.sourceHash || x.start != y.start || x.end != y.end || x.flags != y.flags))
				return 'debug location $index differs';
		}
		if (a.debugAssignments.length != b.debugAssignments.length)
			return 'debug assignment counts ${a.debugAssignments.length} and ${b.debugAssignments.length}';
		for (index in 0...a.debugAssignments.length) {
			var x = a.debugAssignments[index], y = b.debugAssignments[index];
			if (x.name != y.name || x.position != y.position || x.scopeEnd != y.scopeEnd)
				return 'debug assignment $index differs';
		}
		return null;
	}

	/** Equal constructor and equal parameters, arrays and nested enums compared by value (`Type.enumEq` compares arrays by reference on HashLink). */
	static function same(a:Dynamic, b:Dynamic, forward:Map<String, String>, backward:Map<String, String>):Bool {
		if (Std.isOfType(a, String) && Std.isOfType(b, String)) {
			var x:String = a, y:String = b, mapped = forward.get(x), origin = backward.get(y);
			if (mapped == null && origin == null) {
				forward.set(x, y);
				backward.set(y, x);
				return true;
			}
			return mapped == y && origin == x;
		}
		if (a == b)
			return true;
		if (Std.isOfType(a, Array) && Std.isOfType(b, Array)) {
			var x:Array<Dynamic> = a, y:Array<Dynamic> = b;
			if (x.length != y.length)
				return false;
			for (index in 0...x.length)
				if (!same(x[index], y[index], forward, backward))
					return false;
			return true;
		}
		var enumA = Type.getEnum(a), enumB = Type.getEnum(b);
		if (enumA == null || enumA != enumB || Type.enumIndex(a) != Type.enumIndex(b))
			return false;
		return same(Type.enumParameters(a), Type.enumParameters(b), forward, backward);
	}
}
