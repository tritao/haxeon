import compiler.ffi.CxxHeaderImporter;
import compiler.ffi.CxxModel.CxxMethod;
import compiler.ffi.CxxProjection;
import compiler.ffi.CxxSubsetValidator;
import compiler.ffi.CxxThunkGenerator;
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
		var imported = CxxHeaderImporter.importHeader("tests/ffi/cxx_import_fixture.hpp", "x86_64-linux-gnu", ["tests/ffi"], "clang++", "cxx_test"),
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
		expect(generated.indexOf('extern fn __cxx_nkui__acquire() -> ptr<__cxx_nkui__DisplayList> @symbol("_ZN4nkui7acquireEv") @borrowed;') >= 0,
			"C++ object pointer results should default to borrowed ownership");
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
		var projections = CxxProjection.sources(model, imported.hxi),
			projection = projections.length == 1 ? projections[0].source : "";
		expect(projections.length == 1
			&& projections[0].file == "DisplayList.hx"
			&& projection.indexOf("class DisplayList") >= 0
			&& projection.indexOf("public function reset():Void") >= 0
			&& projection.indexOf("public function size():haxe.Int64") >= 0
			&& projection.indexOf("public static function make(value:Int):Int") >= 0,
			"C++ records should produce Haxe object wrappers over their lowered HXI methods");
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
		var hosted = CxxHeaderImporter.importHeader("tests/ffi/cxx_hosted_fixture.hpp", "x86_64-linux-gnu", ["tests/ffi"]);
		expect(hosted.model.records.length == 1
			&& hosted.model.records[0].qualifiedName == "nkui::HostedDisplayList"
			&& hosted.model.records[0].size > 0
			&& hosted.model.records[0].align > 0,
			"C++ imports should support hosted standard-library headers without importing their declarations");
		var lifetimeDisabled = "";
		try {
			CxxHeaderImporter.importHeader("tests/ffi/cxx_lifetime_fixture.hpp", "x86_64-linux-gnu", ["tests/ffi"]);
		} catch (error:Dynamic)
			lifetimeDisabled = Std.string(error);
		expect(lifetimeDisabled.indexOf("CXX008") >= 0, "C++ lifetime operations should require explicit opt-in");
		var lifetime = CxxHeaderImporter.importHeader("tests/ffi/cxx_lifetime_fixture.hpp", "x86_64-linux-gnu", ["tests/ffi"], "clang++", "cxx_lifetime",
			null, null, null, "c++20", null, null, false, true),
			lifetimeText = HxiWriter.write(lifetime.hxi, "// test"),
			lifetimeProjection = CxxProjection.sources(lifetime.model, lifetime.hxi, null, lifetime.plans)[0].source,
			hasConstructorDispatch = false,
			hasDestructorDispatch = false;
		for (plan in lifetime.plans)
			switch plan.dispatch {
				case CxxConstructor:
					hasConstructorDispatch = true;
				case CxxDestructor:
					hasDestructorDispatch = true;
				case _:
			}
		expect(hasConstructorDispatch
			&& hasDestructorDispatch
			&& lifetimeText.indexOf("@symbol(\"_ZN7cxxlife6WidgetC1Ei\")") >= 0
			&& lifetimeText.indexOf("@symbol(\"_ZN7cxxlife6WidgetD1Ev\")") >= 0,
			"opted-in C++ lifetimes should lower constructor and destructor symbols into HXI");
		expect(lifetimeProjection.indexOf('@:hlNative("haxeon_runtime")') >= 0
			&& lifetimeProjection.indexOf("__CxxNativeMemory.native_pointer_alloc") >= 0
			&& lifetimeProjection.indexOf("public static function create(value:Int):Widget") >= 0
			&& lifetimeProjection.indexOf("public function close():Void") >= 0
			&& lifetimeProjection.indexOf("C++ object is closed") >= 0
			&& lifetimeProjection.indexOf("public function ~Widget") < 0,
			"C++ lifetime projection should allocate owned objects and hide ABI destructor names");
		var msvc = CxxHeaderImporter.importHeader("tests/ffi/cxx_lifetime_fixture.hpp", "x86_64-pc-windows-msvc", ["tests/ffi"], "clang++",
			"cxx_lifetime_msvc", null, null, null, "c++20", null, null, false, true),
			msvcText = HxiWriter.write(msvc.hxi, "// test"),
			msvcProjection = CxxProjection.sources(msvc.model, msvc.hxi, null, msvc.plans)[0].source,
			hasMsvcConstructor = false,
			hasMsvcDestructor = false;
		for (plan in msvc.plans)
			switch plan.dispatch {
				case CxxConstructor:
					hasMsvcConstructor = plan.symbol == "??0Widget@cxxlife@@QEAA@H@Z";
				case CxxDestructor:
					hasMsvcDestructor = plan.symbol == "??_DWidget@cxxlife@@QEAAXXZ";
				case _:
			}
		expect(msvc.model.target == "x86_64-pc-windows-msvc"
			&& msvc.model.records[0].size == 4
			&& hasMsvcConstructor
			&& hasMsvcDestructor
			&& msvcText.indexOf('@target("x86_64-pc-windows-msvc")') >= 0
			&& msvcProjection.indexOf("public static function create(value:Int):Widget") >= 0,
			"MSVC x64 C++ imports should retain Clang's constructor/destructor symbols and target layout");
		var msvcCxx = CxxHeaderImporter.importHeader("tests/ffi/cxx_import_fixture.hpp", "x86_64-pc-windows-msvc", ["tests/ffi"], "clang++", "cxx_msvc");
		var msvcSizePlan = Lambda.find(msvcCxx.plans, plan -> plan.name == "__cxx_nkui__DisplayList__size");
		expect(msvcSizePlan != null, "MSVC x64 C++ import should retain the const method call plan");
		if (msvcSizePlan != null)
			switch msvcSizePlan.result {
				case IntegerValue(32, Unsigned):
				case _:
					throw "MSVC x64 C++ c_ulong should use the LLP64 32-bit result ABI";
			}
		var virtualDisabled = "";
		try {
			CxxHeaderImporter.importHeader("tests/ffi/cxx_virtual_fixture.hpp", "x86_64-linux-gnu", ["tests/ffi"]);
		} catch (error:Dynamic)
			virtualDisabled = Std.string(error);
		expect(virtualDisabled.indexOf("CXX004") >= 0, "virtual C++ methods should remain opt-in");
		var virtual = CxxHeaderImporter.importHeader("tests/ffi/cxx_virtual_fixture.hpp", "x86_64-linux-gnu", ["tests/ffi"], "clang++", "cxx_virtual", null,
			null, null, "c++20", null, null, false, false, true),
			virtualRenderer = Lambda.find(virtual.model.records, record -> record.qualifiedName == "cxxvirt::Renderer"),
			virtualDraw:CxxMethod = virtualRenderer == null ? null : Lambda.find(virtualRenderer.methods, method -> method.name == "draw"),
			virtualPlan = virtualDraw == null
				|| virtualDraw.loweredName == null ? null : Lambda.find(virtual.plans, plan -> plan.name == virtualDraw.loweredName),
			virtualProjection = virtualRenderer == null ? "" : Lambda.find(CxxProjection.sources(virtual.model, virtual.hxi, null, virtual.plans),
				source -> source.file == "Renderer.hx")
				.source;
		expect(virtualRenderer != null
			&& virtualDraw != null
			&& virtualDraw.virtualAbi != null
			&& virtualDraw.virtualAbi.vtableIndex == 0,
			"Clang Itanium vtable metadata should retain the address-point-relative virtual index");
		if (virtualPlan != null)
			switch virtualPlan.dispatch {
				case CxxVirtual(0, 0):
				case _:
					throw "C++ virtual methods should lower to an indirect vtable call plan";
			}
		expect(virtualProjection.indexOf("native_virtual_invoke_1") >= 0 && virtualProjection.indexOf("vtableIndex:Int") >= 0,
			"C++ virtual projections should call the runtime vtable dispatch primitive");
		var msvcVirtualDiagnostics = "";
		try {
			CxxHeaderImporter.importHeader("tests/ffi/cxx_virtual_fixture.hpp", "x86_64-pc-windows-msvc", ["tests/ffi"], "clang++", null, null, null, null,
				"c++20", null, null, false, false, true);
		} catch (error:Dynamic)
			msvcVirtualDiagnostics = Std.string(error);
		expect(msvcVirtualDiagnostics.indexOf("CXX015") >= 0, "MSVC virtual dispatch should remain rejected until its ABI profile is implemented");
		var thunked = CxxHeaderImporter.importHeader("tests/ffi/cxx_thunk_fixture.hpp", "x86_64-linux-gnu", ["tests/ffi"], "clang++", "cxx_thunk",
			"CxxThunkFixture", null, null, "c++20", null, null, false, false, false, true),
			thunkSource = CxxThunkGenerator.source(thunked.model),
			thunkFunction = Lambda.find(thunked.model.functions, functionModel -> functionModel.name == "add"),
			thunkMethod = Lambda.find(thunked.model.records[0].methods, method -> method.name == "fail"),
			thunkAddPlan = thunkFunction == null
				|| thunkFunction.loweredName == null ? null : Lambda.find(thunked.plans, plan -> plan.name == thunkFunction.loweredName),
			thunkFailPlan = thunkMethod == null
				|| thunkMethod.loweredName == null ? null : Lambda.find(thunked.plans, plan -> plan.name == thunkMethod.loweredName);
		expect(thunkFunction != null
			&& thunkFunction.thunkSymbol != null
			&& thunkMethod != null
			&& thunkMethod.thunkSymbol != null
			&& thunkSource.indexOf("catch (const std::exception &error)") >= 0
			&& thunkSource.indexOf(thunkFunction.thunkSymbol) >= 0
			&& thunkSource.indexOf(thunkMethod.thunkSymbol) >= 0,
			"opted-in C++ thunks should emit stable C-ABI exception boundaries");
		if (thunkAddPlan != null)
			expect(thunkAddPlan.symbol == thunkFunction.thunkSymbol && thunkAddPlan.dispatch == DirectSymbol,
				"throwing free functions should lower to their generated thunk symbol");
		if (thunkFailPlan != null)
			expect(thunkFailPlan.symbol == thunkMethod.thunkSymbol && thunkFailPlan.dispatch == DirectSymbol,
				"throwing methods should use a direct call to their generated thunk");
	}

	static function expect(value:Bool, message:String):Void {
		if (!value)
			throw message;
	}
}
