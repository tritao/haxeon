import compiler.ffi.CxxHeaderImporter;
import compiler.ffi.CxxModel.CxxMethod;
import compiler.ffi.CxxModel.CxxType;
import compiler.ffi.CxxProjection;
import compiler.ffi.CxxSubsetValidator;
import compiler.ffi.CxxThunkGenerator;
import compiler.ffi.CxxTypeTools;
import compiler.ffi.ClangInvocation;
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
		var selected = CxxHeaderImporter.importHeader("tests/ffi/cxx_import_fixture.hpp", "x86_64-linux-gnu", ["tests/ffi"], "clang++", "cxx_selected", null,
			null, null, "c++20", null, null, false, false, false, false, ["nkui::DisplayList::reset", "nkui::DisplayList::size", "nkui::acquire"]);
		expect(selected.model.records.length == 1
			&& selected.model.records[0].methods.length == 2
			&& Lambda.exists(selected.model.records[0].methods, method -> method.name == "reset")
			&& Lambda.exists(selected.model.records[0].methods, method -> method.name == "size")
			&& selected.model.enums.length == 0
			&& selected.model.aliases.length == 1
			&& selected.model.aliases[0].qualifiedName == "nkui::Count"
			&& selected.model.functions.length == 1
			&& selected.model.functions[0].name == "acquire",
			"C++ declaration selection should retain selected declarations and close named signature dependencies");
		var transitive = CxxHeaderImporter.importHeader("tests/ffi/cxx_selection_fixture.hpp", "x86_64-linux-gnu", ["tests/ffi"], "clang++", "cxx_transitive",
			null, null, null, "c++20", null, null, false, false, false, false, ["cxxselect::read"]);
		expect(transitive.model.records.length == 0
			&& transitive.model.aliases.length == 2
			&& transitive.model.functions.length == 1
			&& transitive.model.functions[0].qualifiedName == "cxxselect::read",
			"selection should retain transitive alias dependencies");
		var missingDependency = "";
		try {
			CxxHeaderImporter.importHeader("tests/ffi/cxx_missing_dependency_fixture.hpp", "x86_64-linux-gnu", ["tests/ffi"], "clang++", "cxx_missing", null,
				null, ["tests/ffi/cxx_missing_dependency_types.hpp"], "c++20", null, null, false, false, false, false, ["cxxmissing::acquire"]);
		} catch (error:Dynamic) {
			missingDependency = Std.string(error);
		}
		expect(missingDependency.indexOf("CXX019") >= 0 && missingDependency.indexOf("cxxmissing::Hidden") >= 0,
			"missing selected C++ type dependencies should have an explicit diagnostic");
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
		var callbackImport = CxxHeaderImporter.importHeader("tests/ffi/cxx_runtime_fixture.hpp", "x86_64-linux-gnu", ["tests/ffi"], "clang++", "cxx_callback");
		var callbackAlias = Lambda.find(callbackImport.model.aliases, alias -> alias.qualifiedName == "nkui::BinaryCallback"),
			applyFunction = Lambda.find(callbackImport.model.functions, functionModel -> functionModel.qualifiedName == "nkui::apply"),
			acquireHandlerFunction = Lambda.find(callbackImport.model.functions, functionModel -> functionModel.qualifiedName == "nkui::acquire_handler"),
			rawApplyFunction = Lambda.find(callbackImport.model.functions, functionModel -> functionModel.qualifiedName == "nkui::apply_raw"),
			setHandlerFunction = Lambda.find(callbackImport.model.functions, functionModel -> functionModel.qualifiedName == "nkui::set_handler"),
			callbackHxi = HxiWriter.write(callbackImport.hxi, "// test");
		var callbackAliasValid = callbackAlias != null && switch callbackAlias.target {
			case CxxType.CxxFunctionPointer([CxxType.CxxPrimitive("c_int"), CxxType.CxxPrimitive("c_int")], CxxType.CxxPrimitive("c_int"), true): true;
			case _: false;
		};
		var callbackParameterValid = applyFunction != null && switch applyFunction.parameters[0].type {
			case CxxType.CxxNamed("nkui::BinaryCallback"): true;
			case _: false;
		};
		var rawCallbackParameterValid = rawApplyFunction != null && switch rawApplyFunction.parameters[0].type {
			case CxxType.CxxFunctionPointer([CxxType.CxxPrimitive("c_int")], CxxType.CxxPrimitive("c_int"), false): true;
			case _: false;
		};
		var acquireHandlerResultValid = acquireHandlerFunction != null && switch acquireHandlerFunction.result {
			case CxxType.CxxNamed("nkui::BinaryCallback"): true;
			case _: false;
		};
		expect(callbackAliasValid
			&& callbackParameterValid
			&& acquireHandlerResultValid
			&& rawCallbackParameterValid
			&& setHandlerFunction != null
			&& setHandlerFunction.parameters.length == 1
			&& setHandlerFunction.parameters[0].retained
			&& callbackHxi.indexOf("callback __cxx_nkui__BinaryCallback = fn(arg0: c_int, arg1: c_int) -> c_int;") >= 0
			&& callbackHxi.indexOf("callback __cxx_callback_") >= 0
			&& callbackHxi.indexOf("extern fn __cxx_nkui__acquire_handler() -> __cxx_nkui__BinaryCallback") >= 0
			&& callbackHxi.indexOf("extern fn __cxx_nkui__apply(callback: __cxx_nkui__BinaryCallback") >= 0
			&& callbackHxi.indexOf("extern fn __cxx_nkui__set_handler(callback: __cxx_nkui__BinaryCallback @retained)") >= 0,
			"C++ function-pointer aliases should lower to typed HXI callbacks without a thunk");
		var callbackPlan = Lambda.find(callbackImport.plans, plan -> plan.name == "__cxx_nkui__apply");
		var callbackArgumentValid = callbackPlan != null && switch callbackPlan.arguments[0] {
			case HxiAbiValue.CallbackValue("__cxx_nkui__BinaryCallback", _, _, false): true;
			case _: false;
		};
		var callbackDispatchValid = callbackPlan != null && switch callbackPlan.dispatch {
			case NativeDispatch.DirectSymbol: true;
			case _: false;
		};
		expect(callbackArgumentValid && callbackDispatchValid, "C++ callback parameters should use the existing direct native call plan");
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
		expect(diagnostics.indexOf("CXX003") >= 0 && diagnostics.indexOf("CXX004") >= 0 && diagnostics.indexOf("CXX001") >= 0
			&& diagnostics.indexOf("CXX022") >= 0,
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
		var hosted = CxxHeaderImporter.importHeader("tests/ffi/cxx_hosted_fixture.hpp", ClangInvocation.hostTarget(), ["tests/ffi"]);
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
			&& lifetimeProjection.indexOf("__CxxNativeMemory_Widget.native_pointer_alloc") >= 0
			&& lifetimeProjection.indexOf("public static function create(value:Int):Widget") >= 0
			&& lifetimeProjection.indexOf("public function close():Void") >= 0
			&& lifetimeProjection.indexOf("C++ object is closed") >= 0
			&& lifetimeProjection.indexOf("public function ~Widget") < 0,
			"C++ lifetime projection should allocate owned objects and hide ABI destructor names");
		var owned = CxxHeaderImporter.importHeader("tests/ffi/cxx_owned_fixture.hpp", "x86_64-linux-gnu", ["tests/ffi"], "clang++", "cxx_owned",
			"CxxOwnedFixture", null, null, "c++20", null, null, false, false, false, true, ["cxxown::Widget::value", "cxxown::acquire"],
			["cxxown::acquire" => "cxxown::release"]),
			ownedText = HxiWriter.write(owned.hxi, "// test"),
			ownedSources = CxxProjection.sources(owned.model, owned.hxi, null, owned.plans),
			ownedFunctions = Lambda.find(ownedSources, source -> source.file == "CxxOwnedFixtureFunctions.hx"),
			ownedWidget = Lambda.find(ownedSources, source -> source.file == "OwnedWidget.hx"),
			ownedAcquire = Lambda.find(owned.model.functions, functionModel -> functionModel.name == "acquire"),
			ownedRelease = Lambda.find(owned.model.functions, functionModel -> functionModel.name == "release");
		expect(ownedAcquire != null
			&& ownedRelease != null
			&& ownedAcquire.thunkSymbol != null
			&& ownedRelease.thunkSymbol != null
			&& ownedText.indexOf('@owned("' + ownedRelease.thunkSymbol + '")') >= 0
			&& ownedFunctions != null
			&& ownedFunctions.source.indexOf("return OwnedWidget.adopt") >= 0
			&& ownedWidget != null
			&& ownedWidget.source.indexOf("public function close():Bool") >= 0,
			"explicit C++ factory ownership should lower through release thunks and closeable object projections");
		var invalidOwnership = "";
		try {
			CxxHeaderImporter.importHeader("tests/ffi/cxx_owned_fixture.hpp", "x86_64-linux-gnu", ["tests/ffi"], "clang++", "cxx_owned_invalid",
				"CxxOwnedFixture", null, null, "c++20", null, null, false, false, false, false, null, ["cxxown::acquire" => "cxxown::released"]);
		} catch (error:Dynamic)
			invalidOwnership = Std.string(error);
		expect(invalidOwnership.indexOf("CXX020") >= 0, "invalid C++ release contracts should produce an explicit ownership diagnostic");
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
		var stringViewDisabled = "";
		try {
			CxxHeaderImporter.importHeader("tests/ffi/cxx_string_view_fixture.hpp", "x86_64-linux-gnu", ["tests/ffi"]);
		} catch (error:Dynamic)
			stringViewDisabled = Std.string(error);
		expect(stringViewDisabled.indexOf("CXX017") >= 0, "std::string_view should require an explicit generated adapter");
		var stringView = CxxHeaderImporter.importHeader("tests/ffi/cxx_string_view_fixture.hpp", "x86_64-linux-gnu", ["tests/ffi"], "clang++", "cxx_view",
			"CxxStringViewFixture", null, null, "c++20", null, null, false, false, false, true),
			stringViewText = HxiWriter.write(stringView.hxi, "// test"),
			stringViewSource = CxxThunkGenerator.source(stringView.model),
			stringViewProjection = Lambda.find(CxxProjection.sources(stringView.model, stringView.hxi, null, stringView.plans),
				source -> source.file == "Text.hx")
				.source,
			stringViewFunctions = Lambda.find(CxxProjection.sources(stringView.model, stringView.hxi, null, stringView.plans),
				source -> source.file == "CxxStringViewFixtureFunctions.hx")
				.source,
			viewMethod = Lambda.find(stringView.model.records[0].methods, method -> method.name == "count"),
			viewFunction = Lambda.find(stringView.model.functions, functionModel -> functionModel.name == "count"),
			viewMethodPlan = viewMethod == null
				|| viewMethod.loweredName == null ? null : Lambda.find(stringView.plans, plan -> plan.name == viewMethod.loweredName),
			viewFunctionPlan = viewFunction == null
				|| viewFunction.loweredName == null ? null : Lambda.find(stringView.plans, plan -> plan.name == viewFunction.loweredName);
		expect(viewMethod != null
			&& viewFunction != null
			&& CxxTypeTools.isStringView(viewMethod.parameters[0].type)
			&& CxxTypeTools.isStringView(viewFunction.parameters[0].type)
			&& viewMethod.thunkSymbol != null
			&& viewFunction.thunkSymbol != null
			&& stringViewText.indexOf("value: utf8, value__length: usize") >= 0
			&& stringViewSource.indexOf("std::string_view(arg0, arg0__length)") >= 0
			&& stringViewProjection.indexOf("public function count(value:String):Int") >= 0
			&& stringViewProjection.indexOf("haxe.Int64.ofInt(__cxx_value_bytes_0.length)") >= 0
			&& stringViewFunctions.indexOf("public static function count(value:String):Int") >= 0,
			"std::string_view should lower to a thunked pointer/length ABI and a String projection");
		if (viewMethodPlan != null)
			switch viewMethodPlan.arguments {
				case [PointerValue(_, _, _, _), Utf8Value(false), IntegerValue(64, Unsigned)]:
				case _:
					throw "std::string_view method should use UTF-8 and target-sized length arguments";
			}
		if (viewFunctionPlan != null)
			switch viewFunctionPlan.arguments {
				case [Utf8Value(false), IntegerValue(64, Unsigned)]:
				case _:
					throw "std::string_view function should use UTF-8 and target-sized length arguments";
			}
		var spanDisabled = "";
		try {
			CxxHeaderImporter.importHeader("tests/ffi/cxx_span_fixture.hpp", "x86_64-linux-gnu", ["tests/ffi"]);
		} catch (error:Dynamic)
			spanDisabled = Std.string(error);
		expect(spanDisabled.indexOf("CXX018") >= 0, "std::span byte adapters should require an explicit generated adapter");
		var span = CxxHeaderImporter.importHeader("tests/ffi/cxx_span_fixture.hpp", "x86_64-linux-gnu", ["tests/ffi"], "clang++", "cxx_span",
			"CxxSpanFixture", null, null, "c++20", null, null, false, false, false, true),
			spanText = HxiWriter.write(span.hxi, "// test"),
			spanSource = CxxThunkGenerator.source(span.model),
			spanSources = CxxProjection.sources(span.model, span.hxi, null, span.plans),
			spanProjection = Lambda.find(spanSources, source -> source.file == "Buffer.hx").source,
			spanFunctions = Lambda.find(spanSources, source -> source.file == "CxxSpanFixtureFunctions.hx").source,
			spanMethod = Lambda.find(span.model.records[0].methods, method -> method.name == "byteCount"),
			spanFunction = Lambda.find(span.model.functions, functionModel -> functionModel.name == "byteCount"),
			spanMethodPlan = spanMethod == null
				|| spanMethod.loweredName == null ? null : Lambda.find(span.plans, plan -> plan.name == spanMethod.loweredName),
			spanFunctionPlan = spanFunction == null
				|| spanFunction.loweredName == null ? null : Lambda.find(span.plans, plan -> plan.name == spanFunction.loweredName);
		expect(spanMethod != null
			&& spanFunction != null
			&& CxxTypeTools.isByteSpan(spanMethod.parameters[0].type)
			&& CxxTypeTools.isByteSpan(spanFunction.parameters[0].type)
			&& spanMethod.thunkSymbol != null
			&& spanFunction.thunkSymbol != null
			&& spanText.indexOf("value: ptr<u8>, value__length: usize") >= 0
			&& spanSource.indexOf("std::span<const std::byte>(arg0, arg0__length)") >= 0
			&& spanSource.indexOf("std::span<const std::uint8_t>(arg0, arg0__length)") >= 0
			&& spanProjection.indexOf("public function byteCount(value:haxe.io.Bytes):Int") >= 0
			&& spanProjection.indexOf("haxe.Int64.ofInt(value.length)") >= 0
			&& spanFunctions.indexOf("public static function byteCount(value:haxe.io.Bytes):Int") >= 0,
			"read-only byte std::span should lower to a thunked pointer/length ABI and a Bytes projection");
		if (spanMethodPlan != null)
			switch spanMethodPlan.arguments {
				case [
					PointerValue(_, _, _, _),
					PointerValue(64, false, null, null),
					IntegerValue(64, Unsigned)
				]:
				case _:
					throw "std::span byte method should use a this pointer and target-sized byte pointer/length arguments";
			}
		if (spanFunctionPlan != null)
			switch spanFunctionPlan.arguments {
				case [PointerValue(64, false, null, null), IntegerValue(64, Unsigned)]:
				case _:
					throw "std::span byte function should use target-sized byte pointer/length arguments";
			}
	}

	static function expect(value:Bool, message:String):Void {
		if (!value)
			throw message;
	}
}
