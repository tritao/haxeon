import compiler.ffi.HxiAbi;
import compiler.ffi.HxiAbi.HxiAbiValue;
import compiler.ffi.HxiAbi.HxiIntegerSign;
import compiler.ffi.HxiParser;

class HxiAbiMain {
	static function main():Void {
		var linux = parse("x86_64-linux-gnu"),
			windows = parse("x86_64-pc-windows-msvc");
		expectInteger(linux.classify(compiler.ffi.HxiModel.HxiType.Primitive("c_long")), 64, Signed);
		expectInteger(windows.classify(compiler.ffi.HxiModel.HxiType.Primitive("c_long")), 32, Signed);
		expectInteger(linux.classify(compiler.ffi.HxiModel.HxiType.Primitive("c_char")), 8, PlainChar);
		switch linux.functions()[0] {
			case {
				name: "open",
				symbol: "open_v1",
				library: "sample",
				arguments: [PointerValue(64)],
				result: IntegerValue(32, Signed)
			}:
			case _:
				throw "function ABI did not resolve";
		}
		var cycle = 'interface bad @target("x86_64-linux-gnu") { type a = b; type b = a; }';
		var rejected = false;
		try
			HxiParser.parse("cycle.hxi", cycle)
		catch (_:Dynamic)
			rejected = true;
		expect(rejected, "cyclic aliases should be rejected before ABI classification");
		Sys.println("PASS: HXI types classify for target C ABIs");
	}

	static function parse(target:String):HxiAbi {
		var source = 'interface sample @target("$target") @library("sample") {'
			+ ' opaque context; type result = c_int;'
			+ ' extern fn open(value: ptr<context>) -> result @symbol("open_v1");'
			+ '}';
		return HxiAbi.forInterface(HxiParser.parse("sample.hxi", source));
	}

	static function expectInteger(value:HxiAbiValue, bits:Int, sign:HxiIntegerSign):Void
		switch value {
			case IntegerValue(actualBits, actualSign):
				expect(actualBits == bits && actualSign == sign, "integer ABI mismatch");
			case _:
				throw "expected integer ABI";
		}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
