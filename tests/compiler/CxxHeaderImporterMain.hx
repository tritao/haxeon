import compiler.ffi.CxxHeaderImporter;
import compiler.ffi.CxxModel.CxxMethod;
import compiler.ffi.CxxSubsetValidator;
import compiler.ffi.HxiAbi.HxiAbiValue;
import compiler.ffi.HxiAbi.HxiAbi;
import compiler.ffi.HxiModel.HxiDeclaration;
import compiler.ffi.HxiModel.HxiInterface;
import compiler.ffi.HxiParser;
import compiler.ffi.HxiValidator;
import compiler.ffi.HxiWriter;
import compiler.ffi.NativeCallPlan.NativeDispatch;
import haxe.Json;
import sys.FileSystem;
import sys.io.File;

class CxxHeaderImporterMain {
	static function main():Void {
		var imported = CxxHeaderImporter.importHeader("tests/ffi/cxx_import_fixture.hpp", "x86_64-linux-gnu", ["tests/ffi"]),
			model = imported.model;
		expect(model.records.length == 1
			&& model.records[0].qualifiedName == "nkui::DisplayList"
			&& model.records[0].size == 1
			&& model.records[0].align == 1,
			"C++ records should retain qualified source names and Clang layouts");
		expect(model.enums.length == 1
			&& model.enums[0].scoped
			&& model.enums[0].qualifiedName == "nkui::Mode", "enum class semantics should be retained");
		expect(model.aliases.length == 1
			&& model.aliases[0].qualifiedName == "nkui::Count", "C++ aliases should be retained in the semantic model");
		var reset:CxxMethod = null,
			size:CxxMethod = null,
			make:CxxMethod = null;
		for (method in model.records[0].methods)
			switch method.name {
				case "reset":
					reset = method;
				case "size":
					size = method;
				case "make":
					make = method;
				case _:
			}
		expect(reset != null
			&& reset.isNoexcept
			&& !reset.isConst
			&& !reset.isStatic
			&& reset.symbol == "_ZN4nkui11DisplayList5resetEv",
			"non-const C++ methods should retain Clang's exact mangled symbol");
		expect(size != null && size.isNoexcept && size.isConst && size.symbol == "_ZNK4nkui11DisplayList4sizeEv",
			"const C++ methods should retain const semantics and their mangled symbol");
		expect(make != null && make.isStatic, "static C++ methods should not require a synthetic this parameter");
		var generated = HxiWriter.write(imported.hxi, "// test");
		expect(imported.plans.length == 5, "C++ lowering should expose one direct native call plan per imported function or method");
		for (plan in imported.plans)
			switch plan.dispatch {
				case DirectSymbol:
				case _:
					throw "CXX_ABI_V1 calls should use the generic direct-symbol dispatch plan";
			}
		expect(generated.indexOf('extern fn __cxx_nkui__DisplayList__reset(__this: ptr<__cxx_nkui__DisplayList>) -> void @symbol("_ZN4nkui11DisplayList5resetEv")') >= 0,
			"instance methods should lower to HXI functions with an opaque this pointer");
		expect(generated.indexOf('extern fn __cxx_nkui__DisplayList__size(__this: ptr<const<__cxx_nkui__DisplayList>>)') >= 0,
			"const methods should lower this as a const opaque pointer");
		expect(generated.indexOf('extern fn __cxx_nkui__consume(value: ptr<__cxx_nkui__DisplayList>, mode: ptr<const<__cxx_nkui__Mode>>)') >= 0,
			"C++ references should lower to non-null pointer ABI values");
		var parsed:HxiInterface = HxiParser.parse("cxx_import_fixture.hxi", generated),
			functions = HxiAbi.forInterface(parsed).functions(),
			resetAbi:Null<Dynamic> = null;
		HxiValidator.validate(parsed, []);
		for (functionAbi in functions)
			if (functionAbi.name == "__cxx_nkui__DisplayList__reset")
				resetAbi = functionAbi;
		expect(resetAbi != null, "lowered C++ methods should be consumable by the existing HXI ABI classifier");
		if (resetAbi != null)
			switch resetAbi.arguments {
				case [PointerValue(64, false, "__cxx_nkui__DisplayList", null)]:
				case _:
					throw "C++ this pointer did not classify as a 64-bit opaque pointer";
			}
		var compileDatabase = "/tmp/haxeon-cxx-compile-commands.json",
			headerPath = FileSystem.fullPath("tests/ffi/cxx_import_fixture.hpp");
		File.saveContent(compileDatabase, Json.stringify([
			{
				directory: FileSystem.fullPath("."),
				file: headerPath,
				arguments: ["clang++", "-std=c++17", "-D", "CXX_DATABASE_TEST=1", "-c", headerPath]
			}
		]));
		var fromDatabase = CxxHeaderImporter.importHeader(headerPath, "x86_64-linux-gnu", ["tests/ffi"], "clang++", null, null, null, null, "c++20", null,
			compileDatabase);
		expect(fromDatabase.model.functions.length == model.functions.length, "compile_commands.json flags should be accepted by the shared Clang frontend");
		var diagnostics = "";
		try {
			CxxHeaderImporter.importHeader("tests/ffi/cxx_unsupported_fixture.hpp", "x86_64-linux-gnu", ["tests/ffi"]);
		} catch (error:Dynamic)
			diagnostics = Std.string(error);
		expect(diagnostics.indexOf("CXX003") >= 0 && diagnostics.indexOf("CXX004") >= 0 && diagnostics.indexOf("CXX001") >= 0,
			"unsupported C++ constructs should produce first-class diagnostics");
		var trivialDiagnostics = "";
		try {
			CxxHeaderImporter.importHeader("tests/ffi/cxx_trivial_fixture.hpp", "x86_64-linux-gnu", ["tests/ffi"]);
		} catch (error:Dynamic)
			trivialDiagnostics = Std.string(error);
		expect(trivialDiagnostics.indexOf("CXX002") >= 0, "class values should be disabled unless trivial-value lowering is explicitly enabled");
		var trivial = CxxHeaderImporter.importHeader("tests/ffi/cxx_trivial_fixture.hpp", "x86_64-linux-gnu", ["tests/ffi"], "clang++", null, null, null,
			null, "c++20", null, null, true),
			trivialText = HxiWriter.write(trivial.hxi, "// test");
		expect(trivialText.indexOf("struct __cxx_Point @layout(8, 4)") >= 0
			&& trivialText.indexOf("extern fn __cxx_make_point() -> __cxx_Point") >= 0,
			"validated standard-layout records should lower by value only under the explicit trivial-value policy");
	}

	static function expect(value:Bool, message:String):Void {
		if (!value)
			throw message;
	}
}
