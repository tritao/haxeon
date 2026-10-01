import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

/**
 * Pointer results declared with `@span` are read in place as NativeSpans, and functions with counted
 * input arrays take spans through their `_span` companion, so native arrays cross the FFI in both
 * directions without a copy.
 */
class HxiSpanMain {
	static function main():Void {
		var output = Sys.args()[0],
			library = Sys.args()[1],
			compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot(Sys.getCwd() + "/stdlib");
		compiler.addFfiInterface("spans.hxi",
			'interface Spans @target("x86_64-linux-gnu") @library("$library") {\n'
			+ '\textern fn values(which: i32) -> nullable<ptr<const<f64>>> @span("native_fixture_span_values_count") @symbol("native_fixture_span_values");\n'
			+ '\textern fn valuesCount(which: i32) -> c_size @symbol("native_fixture_span_values_count");\n'
			+ '\textern fn ticks() -> ptr<const<i64>> @span("native_fixture_span_ticks_count") @symbol("native_fixture_span_ticks");\n'
			+ '\textern fn ticksCount() -> c_size @symbol("native_fixture_span_ticks_count");\n'
			+ '\textern fn codes() -> ptr<const<u32>> @span("native_fixture_span_codes_count") @symbol("native_fixture_span_codes");\n'
			+ '\textern fn codesCount() -> c_size @symbol("native_fixture_span_codes_count");\n'
			+
			'\textern fn weightedSum(values: ptr<const<f64>> @in_array("count"), weights: ptr<const<f64>> @in_array("count"), count: u32, bias: f64) -> f64 @symbol("native_fixture_span_weighted_sum");\n'
			+ '\textern fn byteSum(bytes: ptr<const<u8>> @in_array("length"), length: u32) -> u32 @symbol("native_fixture_span_byte_sum");\n'
			+ '}');
		compiler.update("Main.hx", MAIN);
		File.saveBytes(output, HlWriter.encode(compiler.compile("Main").module));
	}

	static final MAIN = "import Spans;
import runtime.memory.NativeSpan;

class Owner implements runtime.memory.NativeSpanOwner {
	public var closed = false;
	public function new() {}
	public function isClosed():Bool return closed;
}

function throws(action:() -> Void):Bool {
	try {
		action();
	} catch (_:String) {
		return true;
	}
	return false;
}

function main():Int {
	var values = Spans.values(1);
	if (values.length() != 4 || values.get(0) != 1.5 || values.get(3) != -8.0)
		return 1;
	if (Spans.values(0).length() != 0 || !throws(() -> Spans.values(0).get(0)))
		return 2;
	var ticks = Spans.ticks();
	if (ticks.length() != 2 || haxe.Int64.toStr(ticks.get(0)) != \"5000000000\" || haxe.Int64.toInt(ticks.get(1)) != -7)
		return 3;
	var codes = Spans.codes();
	if (codes.length() != 3 || codes.get(0) != 65535 || codes.get(2) != 300)
		return 4;
	// A slice and the whole span go back to native code without copying.
	var weights = values.slice(1, 3);
	if (Spans.weightedSum_span(values.slice(0, 3), weights, 0.5) != 0.5 + 1.5 * 2.5 + 2.5 * 4.0 + 4.0 * -8.0)
		return 5;
	if (Spans.weightedSum(values.toArray(), [1.0, 1.0, 1.0, 1.0], 0.0) != 0.0)
		return 6;
	if (!throws(() -> Spans.weightedSum_span(values, weights, 0.0)))
		return 7;
	var owner = new Owner(), owned = values.ownedBy(owner);
	if (owned.get(1) != 2.5)
		return 8;
	owner.closed = true;
	if (!throws(() -> owned.get(1)) || !throws(() -> Spans.weightedSum_span(owned, owned, 0.0)))
		return 9;
	var bytes = haxe.io.Bytes.ofString(\"ABC\");
	if (Spans.byteSum(bytes) != 65 + 66 + 67)
		return 10;
	var arena = new runtime.memory.Arena();
	var raw:runtime.memory.RawPtr<UInt8> = arena.alloc(3);
	raw.store(200);
	raw.offset(1).store(50);
	raw.offset(2).store(5);
	if (Spans.byteSum_span(new NativeSpan<UInt8>(raw, 3)) != 255)
		return 11;
	return 42;
}
";
}
