import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

/**
	Several outputs in one call: queried typed arrays and buffers (with and
	without @initial_capacity), fixed-capacity arrays and ordinary output
	slots, mixed freely. The program returns 42, or the number of the first
	failed check.
**/
class HxiOutputsMain {
	static function main():Void {
		var output = Sys.args()[0],
			library = Sys.args()[1],
			compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot(Sys.getCwd() + "/stdlib");
		compiler.addFfiInterface("outputs.hxi",
			'interface Outputs @target("x86_64-linux-gnu") @library("$library") {\n'
			+ '\tstruct fixture_point @layout(8, 4) { x: i32 @offset(0); y: i32 @offset(4); }\n'
			+ '\textern fn calls() -> u32 @symbol("native_fixture_output_calls_take");\n'
			+ '\textern fn squares(n: i32, values: nullable<ptr<i32>> @out_array("count"), count: ptr<u32> @inout) -> i32 @symbol("native_fixture_squares");\n'
			+
			'\textern fn squaresHinted(n: i32, values: nullable<ptr<i32>> @out_array("count") @initial_capacity(4), count: ptr<u32> @inout) -> i32 @symbol("native_fixture_squares");\n'
			+
			'\textern fn squaresOnly(n: i32, values: nullable<ptr<i32>> @out_array("count"), count: ptr<u32> @inout) -> void @symbol("native_fixture_squares");\n'
			+
			'\textern fn mixed(n: i32, points: nullable<ptr<fixture_point>> @out_array("pointCount"), pointCount: ptr<u32> @inout, bytes: nullable<ptr<u8>> @out_buffer("byteCount"), byteCount: ptr<u32> @inout, total: ptr<i32> @out, last: ptr<fixture_point> @out) -> i32 @symbol("native_fixture_mixed");\n'
			+
			'\textern fn mixedPartlyHinted(n: i32, points: nullable<ptr<fixture_point>> @out_array("pointCount") @initial_capacity(8), pointCount: ptr<u32> @inout, bytes: nullable<ptr<u8>> @out_buffer("byteCount"), byteCount: ptr<u32> @inout, total: ptr<i32> @out, last: ptr<fixture_point> @out) -> i32 @symbol("native_fixture_mixed");\n'
			+
			'\textern fn mixedHinted(n: i32, points: nullable<ptr<fixture_point>> @out_array("pointCount") @initial_capacity(8), pointCount: ptr<u32> @inout, bytes: nullable<ptr<u8>> @out_buffer("byteCount") @initial_capacity(16), byteCount: ptr<u32> @inout, total: ptr<i32> @out, last: ptr<fixture_point> @out) -> i32 @symbol("native_fixture_mixed");\n'
			+ '\textern fn greedy(values: nullable<ptr<i32>> @out_array("count"), count: ptr<u32> @inout) -> i32 @symbol("native_fixture_greedy");\n'
			+
			'\textern fn greedyHinted(values: nullable<ptr<i32>> @out_array("count") @initial_capacity(2), count: ptr<u32> @inout) -> i32 @symbol("native_fixture_greedy");\n'
			+ '\textern fn fillSum(count: u64, results: ptr<u32> @out_array("count"), sum: ptr<u64> @out) -> i32 @symbol("native_fixture_fill_sum");\n'
			+
			'\textern fn splitPoints(values: ptr<const<fixture_point>> @in_array("count"), count: u64, xs: ptr<i32> @out_array("count"), ys: ptr<i32> @out_array("count")) -> i32 @symbol("native_fixture_split_points");\n'
			+ '}');
		compiler.update("Main.hx", 'import Outputs;
function point(x:Int, y:Int):fixture_point {
	var result = new fixture_point();
	result.set_x(x);
	result.set_y(y);
	return result;
}
function main():Int {
	// A queried typed array: a size query, then a fill.
	var squares = Outputs.squares(5);
	if (squares.status != 42 || squares.values.length != 5 || squares.values[4] != 16 || Outputs.calls() != 2) return 1;
	var none = Outputs.squares(0);
	if (none.status != 42 || none.values.length != 0 || Outputs.calls() != 2) return 2;
	// With an initial capacity, one call when it fits and a second only when it does not.
	var fits = Outputs.squaresHinted(4);
	if (fits.status != 42 || fits.values.length != 4 || fits.values[3] != 9 || Outputs.calls() != 1) return 3;
	var grows = Outputs.squaresHinted(7);
	if (grows.status != 42 || grows.values.length != 7 || grows.values[6] != 36 || Outputs.calls() != 2) return 4;
	// A void function with one output returns it directly.
	var only:Array<Int> = Outputs.squaresOnly(3);
	if (only.length != 3 || only[2] != 4) return 5;
	Outputs.calls();
	// A queried array, a queried buffer and two ordinary outputs together.
	var mixed = Outputs.mixed(3);
	if (mixed.status != 42 || mixed.points.length != 3 || mixed.points[2].get_x() != 2 || mixed.points[2].get_y() != 4) return 6;
	if (mixed.bytes.length != 6 || mixed.bytes.get(5) != 105 || mixed.total != 9 || mixed.last.get_y() != 4 || Outputs.calls() != 2) return 7;
	var partly = Outputs.mixedPartlyHinted(0);
	if (partly.status != 42 || partly.points.length != 0 || partly.bytes.length != 0 || partly.total != 0 || Outputs.calls() != 1) return 8;
	var partlyMore = Outputs.mixedPartlyHinted(2);
	if (partlyMore.status != 42 || partlyMore.points.length != 2 || partlyMore.bytes.length != 4 || Outputs.calls() != 2) return 9;
	var hinted = Outputs.mixedHinted(3);
	if (hinted.status != 42 || hinted.points.length != 3 || hinted.bytes.length != 6 || hinted.total != 9 || Outputs.calls() != 1) return 10;
	var hintedMore = Outputs.mixedHinted(9);
	if (hintedMore.status != 42 || hintedMore.points.length != 9 || hintedMore.bytes.length != 18 || hintedMore.last.get_x() != 8
		|| Outputs.calls() != 2)
		return 11;
	// Fixed-capacity arrays beside an ordinary output, and two arrays sharing an input count.
	var filled = Outputs.fillSum(haxe.Int64.ofInt(4));
	if (filled.status != 42 || filled.results.length != 4 || filled.results[3] != 13 || haxe.Int64.toInt(filled.sum) != 46) return 12;
	var split = Outputs.splitPoints([point(1, 2), point(3, 4)]);
	if (split.status != 42 || split.xs.length != 2 || split.xs[1] != 3 || split.ys[0] != 2 || split.ys[1] != 4) return 13;
	// A function that keeps reporting more than it was given is refused, not truncated.
	var refused = 0;
	try Outputs.greedy() catch (error:Dynamic) refused++;
	try Outputs.greedyHinted() catch (error:Dynamic) refused++;
	if (refused != 2 || Outputs.calls() != 4) return 14;
	return 42;
}
');
		File.saveBytes(output, HlWriter.encode(compiler.compile("Main").module));
	}
}
