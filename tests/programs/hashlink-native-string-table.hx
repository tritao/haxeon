import haxe.io.Bytes;
import runtime.hashlink.HlModulePools;
import runtime.hashlink.HlTypeArena;
import runtime.hashlink.HlTypeBuilder;

function main():Int {
	var arena = new HlTypeArena(128, 8),
		builder = new HlTypeBuilder(arena),
		values:Array<String> = [];
	values.push("x".substring(1, 1));
	values.push("std✓");
	values.push("std✓");
	var pools = new HlModulePools(arena, builder, [], [], values, Bytes.alloc(0), [], 0),
		table = pools.stringTable;
	if (table.count != 3
		|| pools.stringCount != 3
		|| table.lengthAt(0) != 0
		|| table.lengthAt(1) != 6
		|| pools.stringLength(2) != 6)
		return 1;
	if (!table.equals(1, "std✓") || table.equals(0, "std✓") || !table.equals(2, "std✓"))
		return 2;
	var pointer = pools.string(1);
	if (pointer.offset(0).load() != 115 || pointer.offset(3).load() != 226 || pointer.offset(6).load() != 0)
		return 3;
	if (!pools.ustrings.offset(2).load().isNull())
		return 4;
	arena.dispose();
	return 42;
}
