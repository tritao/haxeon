import compiler.Compiler;
import compiler.hl.HlWriter;
import sys.io.File;

class HxiCallMain {
	static function main():Void {
		var output = Sys.args()[0],
			library = Sys.args()[1],
			compiler = new Compiler();
		compiler.addSourceRoot(Sys.getCwd() + "/stdlib");
		compiler.addFfiInterface("fixture.hxi",
			'interface Fixture @target("x86_64-linux-gnu") @library("$library") {\n'
			+ '\topaque fixture_context;\n'
			+ '\tenum FixtureResult : i32 { TEN = 10; ELEVEN = 11; TWENTY_ONE = 21; }\n'
			+ '\tcallback FixtureBinary = fn(left: i32, right: i32) -> i32;\n'
			+ '\tstruct fixture_options @layout(32, 8) { count: i32 @offset(0); scale: f64 @offset(8); token: i64 @offset(16); delta: i16 @offset(24); }\n'
			+ '\tstruct fixture_point @layout(8, 4) { x: i32 @offset(0); y: i32 @offset(4); }\n'
			+ '\tstruct fixture_box @layout(16, 4) { start: fixture_point @offset(0); end: fixture_point @offset(8); }\n'
			+
			'\tstruct fixture_holder @layout(16, 8) { required: ptr<fixture_context> @offset(0) @borrowed; optional: nullable<ptr<fixture_context>> @offset(8) @borrowed; }\n'
			+
			'\tstruct fixture_arrays @layout(28, 4) { values: array<i16, 3> @offset(0); name: array<u8, 4> @offset(6); points: array<fixture_point, 2> @offset(12); }\n'
			+ '\textern fn checkOptions(options: ptr<const<fixture_options>>) -> i32 @symbol("native_fixture_check_options");\n'
			+ '\textern fn checkBox(box: ptr<const<fixture_box>>) -> i32 @symbol("native_fixture_check_box");\n'
			+ '\textern fn checkHolder(holder: ptr<const<fixture_holder>>) -> i32 @symbol("native_fixture_check_holder");\n'
			+ '\textern fn checkArrays(arrays: ptr<const<fixture_arrays>>) -> i32 @symbol("native_fixture_check_arrays");\n'
			+ '\textern fn add(left: i32, right: i32) -> i32 @symbol("native_fixture_add");\n'
			+ '\textern fn enumAdd(left: FixtureResult, right: FixtureResult) -> FixtureResult @symbol("native_fixture_add");\n'
			+ '\textern fn callCallback(callback: FixtureBinary, left: i32, right: i32) -> i32 @symbol("native_fixture_call_callback");\n'
			+ '\textern fn setCallback(callback: FixtureBinary) -> void @symbol("native_fixture_set_callback");\n'
			+ '\textern fn clearCallback() -> void @symbol("native_fixture_clear_callback");\n'
			+ '\textern fn callRetainedCallback(left: i32, right: i32) -> i32 @symbol("native_fixture_call_retained_callback");\n'
			+ '\textern fn multiply(left: f64, right: f64) -> f64 @symbol("native_fixture_multiply");\n'
			+ '\textern fn isNull(value: nullable<ptr<const<void>>>) -> i32 @symbol("native_fixture_is_null");\n'
			+
			'\textern fn sum16(a0: i32, a1: i32, a2: i32, a3: i32, a4: i32, a5: i32, a6: i32, a7: i32, a8: i32, a9: i32, a10: i32, a11: i32, a12: i32, a13: i32, a14: i32, a15: i32) -> i32 @symbol("native_fixture_sum16");\n'
			+ '\textern fn i64Value() -> i64 @symbol("native_fixture_i64_value");\n'
			+ '\textern fn i64Check(value: i64) -> i32 @symbol("native_fixture_i64_check");\n'
			+ '\textern fn owned(value: i32) -> ptr<fixture_context> @symbol("native_fixture_owned") @owned("native_fixture_release");\n'
			+ '\textern fn borrowed() -> ptr<fixture_context> @symbol("native_fixture_borrowed") @borrowed;\n'
			+ '\textern fn maybeBorrowed(present: i32) -> nullable<ptr<fixture_context>> @symbol("native_fixture_maybe_borrowed") @borrowed;\n'
			+ '\textern fn invalidNonNull() -> ptr<fixture_context> @symbol("native_fixture_invalid_non_null") @borrowed;\n'
			+ '\textern fn pointerValue(value: ptr<const<fixture_context>>) -> i32 @symbol("native_fixture_pointer_value");\n'
			+ '\textern fn nullablePointerValue(value: nullable<ptr<const<fixture_context>>>) -> i32 @symbol("native_fixture_pointer_value");\n'
			+ '\textern fn wasReleased() -> i32 @symbol("native_fixture_was_released");\n'
			+
			'\textern fn ownedData(first: i32) -> ptr<u8> @symbol("native_fixture_owned_data") @owned("native_fixture_data_release") @length("native_fixture_data_length");\n'
			+
			'\textern fn borrowedData(present: i32) -> nullable<ptr<const<u8>>> @symbol("native_fixture_borrowed_data") @borrowed @length("native_fixture_data_length");\n'
			+ '\textern fn dataWasReleased() -> i32 @symbol("native_fixture_data_was_released");\n'
			+ '\textern fn dataCheck(data: ptr<const<u8>>) -> i32 @symbol("native_fixture_data_check");\n'
			+ '\textern fn invalidData() -> ptr<const<u8>> @symbol("native_fixture_invalid_data") @borrowed @length("native_fixture_invalid_data_length");\n'
			+ '}\n');
		compiler.update("Main.hx",
			"import Fixture; import runtime.NativePointer; function main():Int { var options = new fixture_options(); options.set_count(40); options.set_scale(1.5); options.set_token(Fixture.i64Value()); options.set_delta(2); var start = new fixture_point(); start.set_x(10); start.set_y(11); var end = new fixture_point(); end.set_x(20); end.set_y(21); var box = new fixture_box(); box.set_start(start); box.set_end(end); var copied = box.get_start(); var borrowed = Fixture.borrowed(); var holder = new fixture_holder(); holder.set_required(borrowed); holder.set_optional(null); var structure = options.get_count() == 40 && options.get_scale() == 1.5 && options.get_delta() == 2 && Fixture.checkOptions(options) == 42 && copied.get_x() == 10 && copied.get_y() == 11 && Fixture.checkBox(box) == 42 && Fixture.pointerValue(holder.get_required()) == 42 && holder.get_optional() == null && Fixture.checkHolder(holder) == 42; var owned = Fixture.owned(41); var maybe = Fixture.maybeBorrowed(1); var ownedData = Fixture.ownedData(40); var borrowedData = Fixture.borrowedData(1); var buffers = Fixture.dataCheck(ownedData) == 42 && borrowedData != null && Fixture.dataCheck(borrowedData) == 42 && Fixture.borrowedData(0) == null && Fixture.dataWasReleased() == 42; var pointers = !NativePointer.native_pointer_is_closed(owned) && !NativePointer.native_pointer_is_closed(borrowed) && Fixture.maybeBorrowed(0) == null && maybe != null && Fixture.pointerValue(owned) == 41 && Fixture.pointerValue(borrowed) == 42 && Fixture.nullablePointerValue(maybe) == 42 && Fixture.nullablePointerValue(null) == 0 && NativePointer.native_pointer_close(owned) && !NativePointer.native_pointer_close(owned) && !NativePointer.native_pointer_close(borrowed) && Fixture.wasReleased() == 42; return structure && buffers && pointers && Fixture.multiply(6.0, 7.0) == 42.0 && Fixture.isNull(haxe.io.Bytes.alloc(1)) == 0 && Fixture.isNull(null) == 42 && Fixture.sum16(1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 0, 0, 0, 0, 0) == 42 && Fixture.i64Check(Fixture.i64Value()) == 42 ? Fixture.add(Fixture.add(10, 11), 21) : 1; }");
		var mainSource = compiler.modules.get("Main").source.text;
		mainSource = StringTools.replace(mainSource, "var borrowed = Fixture.borrowed();",
			'var arrays = new fixture_arrays(); arrays.set_values(0, 10); arrays.set_values(1, 11); arrays.set_values(2, 12); arrays.set_name_bytes(haxe.io.Bytes.ofString("ABCD")); arrays.set_points(0, start); arrays.set_points(1, end); var arrayFields = arrays.get_values(1) == 11 && arrays.get_name(2) == 67 && arrays.get_points(1).get_x() == 20 && Fixture.checkArrays(arrays) == 42; var borrowed = Fixture.borrowed();');
		mainSource = StringTools.replace(mainSource, "var structure = ", "var structure = arrayFields && ");
		mainSource = StringTools.replace(mainSource, "var options = new fixture_options();",
			"var callback = new FixtureBinaryCallback(function(left:Int, right:Int) return left + right); var callbacks = Fixture.callCallback(callback, 19, 23) == 42; Fixture.setCallback(callback); callbacks = callbacks && Fixture.callRetainedCallback(20, 22) == 42; Fixture.clearCallback(); callbacks = callbacks && callback.close() && !callback.close(); var options = new fixture_options();");
		mainSource = StringTools.replace(mainSource, "return structure && buffers && pointers && ",
			"return structure && buffers && pointers && Fixture.enumAdd(FixtureResult.TEN, FixtureResult.ELEVEN) == FixtureResult.TWENTY_ONE && ");
		mainSource = StringTools.replace(mainSource, "return structure && buffers && pointers && ", "return callbacks && structure && buffers && pointers && ");
		compiler.update("Main.hx", mainSource);
		compiler.compile("Main");
		File.saveBytes(output, HlWriter.encode(compiler.compile("Main").module));
		compiler.update("Main.hx", "import Fixture; function main():Int return Fixture.invalidNonNull() == null ? 1 : 0;");
		File.saveBytes(output + ".invalid-null", HlWriter.encode(compiler.compile("Main").module));
		compiler.update("Main.hx", "import Fixture; function main():Int return Fixture.invalidData() == null ? 1 : 0;");
		File.saveBytes(output + ".invalid-length", HlWriter.encode(compiler.compile("Main").module));
		compiler.update("Main.hx", "import Fixture; function main():Int { var arrays = new fixture_arrays(); return arrays.get_values(3); }");
		File.saveBytes(output + ".invalid-index", HlWriter.encode(compiler.compile("Main").module));
	}
}
