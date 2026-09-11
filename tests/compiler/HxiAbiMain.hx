import compiler.ffi.HxiAbi;
import compiler.ffi.HxiAbi.HxiAbiValue;
import compiler.ffi.HxiAbi.HxiIntegerSign;
import compiler.ffi.HxiParser;
import compiler.ffi.HxiProjection;

class HxiAbiMain {
	static function main():Void {
		var linux = parse("x86_64-linux-gnu"),
			windows = parse("x86_64-pc-windows-msvc");
		expectInteger(linux.classify(compiler.ffi.HxiModel.HxiType.Primitive("c_long")), 64, Signed);
		expectInteger(windows.classify(compiler.ffi.HxiModel.HxiType.Primitive("c_long")), 32, Signed);
		expectInteger(linux.classify(compiler.ffi.HxiModel.HxiType.Primitive("c_char")), 8, PlainChar);
		switch linux.classify(compiler.ffi.HxiModel.HxiType.Nullable(compiler.ffi.HxiModel.HxiType.Primitive("utf8"))) {
			case Utf8Value(true):
			case _:
				throw "nullable UTF-8 ABI did not retain its contract";
		}
		expect(HxiProjection.source(linuxModel("x86_64-linux-gnu")).indexOf("haxe.Int64") >= 0, "LP64 c_long should project as haxe.Int64");
		expect(HxiProjection.source(linuxModel("x86_64-pc-windows-msvc")).indexOf("haxe.Int64") < 0, "LLP64 c_long should remain a 32-bit Int");
		var enumModel = HxiParser.parse("enum.hxi",
			'interface sample @target("x86_64-linux-gnu") @library("sample") { enum result : i32 { OK = 0; ERROR = -1; } extern fn check(value: result) -> result; }'),
			enumAbi = HxiAbi.forInterface(enumModel);
		switch enumAbi.functions()[0] {
			case {arguments: [EnumerationValue("result", 32, Signed)], result: EnumerationValue("result", 32, Signed)}:
			case _:
				throw "enum ABI did not retain its nominal type";
		}
		var callbackModel = HxiParser.parse("callback.hxi",
			'interface sample @target("x86_64-linux-gnu") @library("sample") { callback Binary = fn(left: i32, right: i32) -> i32; extern fn apply(callback: Binary) -> i32; }');
		switch HxiAbi.forInterface(callbackModel).functions()[0].arguments[0] {
			case CallbackValue("Binary", [IntegerValue(32, Signed), IntegerValue(32, Signed)], IntegerValue(32, Signed), false):
			case _:
			throw "callback ABI did not retain its typed signature";
		}
		var handleModel = HxiParser.parse("handle.hxi",
			'interface sample @target("x86_64-linux-gnu") @library("sample") { handle resource : u32; extern fn use(value: resource) -> resource; }'),
			handleAbi = HxiAbi.forInterface(handleModel);
		switch handleAbi.functions()[0] {
			case {arguments: [HandleValue("resource")], result: HandleValue("resource")}:
			case _:
				throw "handle ABI did not retain its nominal type";
		}
		var handleSource = HxiProjection.source(handleModel);
		expect(handleSource.indexOf("abstract resource(Int) from Int to Int") >= 0
			&& handleSource.indexOf("function new(value:Int = 0)") >= 0
			&& handleSource.indexOf("function isValid():Bool return this != 0") >= 0
			&& handleSource.indexOf("function rawValue():Int") >= 0
			&& handleSource.indexOf("\tid:") < 0,
			"handles should project as opaque value abstracts");
		switch linux.functions()[0] {
			case {
				name: "open",
				symbol: "open_v1",
				library: "sample",
				arguments: [PointerValue(64, false, true, null)],
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
		return HxiAbi.forInterface(linuxModel(target));
	}

	static function linuxModel(target:String):compiler.ffi.HxiModel.HxiInterface {
		var source = 'interface sample @target("$target") @library("sample") {'
			+ ' opaque context; type result = c_int;'
			+ ' extern fn open(value: ptr<context>) -> result @symbol("open_v1");'
			+ ' extern fn longValue() -> c_long;'
			+ '}';
		return HxiParser.parse("sample.hxi", source);
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
