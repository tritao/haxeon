import haxe.Int64;
import compiler.ffi.HxiModel.HxiDeclaration;
import compiler.ffi.HxiParser;
import compiler.ffi.HxiProjection;

class HxiFlagsMain {
	static function main():Void {
		var source = 'interface flag_widths @target("x86_64-linux-gnu") @library("flag_widths") { '
			+ 'flags ByteFlags : u8 { NONE = 0; FIRST = 1; SECOND = 2; BOTH = 3; } '
			+ 'flags ShortFlags : u16 { NONE = 0; FIRST = 1; SECOND = 2; BOTH = 3; } '
			+ 'flags WordFlags : u32 { NONE = 0; FIRST = 1; SECOND = 2; BOTH = 3; HIGH = 0x80000000; } '
			+ 'flags WideFlags : u64 { NONE = 0; FIRST = 1; HIGH = 1 << 63; BOTH = (1 << 63) | 1; } '
			+ 'extern fn check_wide(value: WideFlags) -> WideFlags; }';
		var model = HxiParser.parse("flag-widths.hxi", source),
			projection = HxiProjection.source(model),
			natives = HxiProjection.cNatives(model);
		switch model.declarations[3] {
			case Enumeration("WideFlags", _, true, values, _):
				expect(Int64.compare(values[2].value, Int64.parseString("-9223372036854775808")) == 0,
					"the unsigned 64-bit high bit must preserve its bit pattern");
			case _:
				throw "expected a parsed 64-bit flags declaration";
		}
		expect(projection.indexOf("enum abstract ByteFlags(Int)") >= 0
			&& projection.indexOf("enum abstract WordFlags(Int)") >= 0
			&& projection.indexOf("var High = -2147483648") >= 0
			&& projection.indexOf("abstract WideFlags(haxe.Int64)") >= 0
			&& projection.indexOf("haxe.Int64.make(-2147483648, 0)") >= 0
			&& projection.indexOf("function high():WideFlags") >= 0
			&& projection.indexOf("function contains(flag:WideFlags):Bool return haxe.Int64.compare(haxe.Int64.and(this, flag), flag) == 0") >= 0
			&& natives.length == 1,
			"flags should project to nominal bitwise-friendly types without narrowing the ABI");

		expectError('interface bad @target("x86_64-linux-gnu") { flags value : i32 { A = 1; } }', "unsigned 8/16/32/64-bit integer representation");
		expectError('interface bad @target("x86_64-linux-gnu") { flags value : u8 { A = 256; } }', "outside the representation");
		expectError('interface bad @target("x86_64-linux-gnu") { flags value : u32 { A = 0x100000000; } }', "outside the representation");
		expectError('interface bad @target("x86_64-linux-gnu") { flags value : u32 { FIRST = 1; UNKNOWN = 5; } }', "not declared by a single-bit flag");
		expectError('interface bad @target("x86_64-linux-gnu") { flags value : u32 { FIRST = 1; DUPLICATE = 1; } }', "duplicates");
		expectError('interface bad @target("x86_64-linux-gnu") { flags value : u64 { A = 1 << 64; } }', "between 0 and 63");
		Sys.println("PASS: HXI flags preserve fixed-width masks and reject invalid declarations");
	}

	static function expectError(source:String, message:String):Void {
		var error = "";
		try
			HxiParser.parse("invalid-flags.hxi", source)
		catch (caught:Dynamic)
			error = Std.string(caught);
		if (error.indexOf(message) < 0)
			throw 'Expected HXI flags error containing "$message", got "$error"';
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
