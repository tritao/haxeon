import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

class HxiValueHandleMain {
	static function main():Void {
		var output = Sys.args()[0],
			library = Sys.args()[1],
			compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot(Sys.getCwd() + "/stdlib");
		compiler.addFfiInterface("value-handles.hxi",
			'interface ValueHandles @target("x86_64-linux-gnu") @library("$library") {\n'
			+ '\thandle value_handle : u32 @destroy("native_fixture_value_handle_destroy");\n'
			+ '\textern fn createOwned() -> value_handle @owned @symbol("native_fixture_value_handle_create");\n'
			+ '\textern fn createOut(handle: ptr<value_handle> @out @owned) -> void @symbol("native_fixture_value_handle_create_out");\n'
			+ '\textern fn borrowed() -> value_handle @symbol("native_fixture_value_handle_borrowed");\n'
			+ '\textern fn releaseCount() -> u32 @symbol("native_fixture_value_handle_release_count");\n'
			+ '\textern fn destroy(handle: value_handle) -> void @symbol("native_fixture_value_handle_destroy");\n'
			+ '}');
		compiler.update("Main.hx",
			'import ValueHandles; function main():Int { var first = ValueHandles.createOwned(); var borrowed:value_handle = ValueHandles.borrowed(); if (borrowed.rawValue() != first.rawValue() || first.isClosed()) return 1; if (!first.close() || first.close() || !first.isClosed() || ValueHandles.releaseCount() != 1) return 2; var second = ValueHandles.createOut(); if (second.rawValue() != 2 || !second.close() || ValueHandles.releaseCount() != 2) return 3; return 42; }');
		compiler.compile("Main");
		File.saveBytes(output, HlWriter.encode(compiler.compile("Main").module));
	}
}
