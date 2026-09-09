import compiler.Diagnostic.CompileError;
import compiler.Compiler;
import compiler.ffi.HxiModel.HxiDeclaration;
import compiler.ffi.HxiModel.HxiType;
import compiler.ffi.HxiModel.HxiPointerOwnership;
import compiler.ffi.HxiParser;
import compiler.ffi.HxiProjection;

class HxiParserMain {
	static final valid = '// generated ABI\n'
		+ 'interface nativekit @target("x86_64-linux-gnu") @library("nativekit") {\n'
		+ '\topaque nk_context;\n'
		+ '\ttype nk_handle = u32;\n'
		+ '\ttype native_long = c_long;\n'
		+ '\tconst NK_OK = 0;\n'
		+ '\tstruct nk_options @layout(16, 8) {\n'
		+ '\t\tcontext: ptr<nk_context> @offset(0);\n'
		+ '\t\tflags: u32 @offset(8);\n'
		+ '\t}\n'
		+ '\textern fn nk_open(options: ptr<const<nk_options>>) -> nk_handle @symbol("nk_open_v1");\n'
		+ '\textern fn nk_version() -> u32 @leaf;\n'
		+ '}\n';

	static function main():Void {
		var parsed = HxiParser.parse("nativekit.hxi", valid);
		expect(parsed.name == "nativekit" && parsed.target == "x86_64-linux-gnu" && parsed.library == "nativekit", "interface metadata should parse");
		expect(parsed.declarations.length == 7, "all declarations should parse");
		switch parsed.declarations[4] {
			case Structure("nk_options", 16, 8, fields, _):
				expect(fields.length == 2 && fields[1].offset == 8, "layout and offsets should parse");
			case _:
				throw "expected parsed structure";
		}
		switch parsed.declarations[5] {
			case Function("nk_open", _, Named("nk_handle"), "nk_open_v1", false, "cdecl", _, _):
			case _:
				throw "expected symbol-bound function";
		}
		expectError(StringTools.replace(valid, "ptr<nk_context>", "ptr<missing>"), 'Unknown HXI type "missing"');
		var enumerations = HxiParser.parse("enums.hxi",
			'interface enums @target("x86_64-linux-gnu") @library("enums") { enum Result : i32 { OK = 0; ERROR = -1; } flags Options : u32 { NONE = 0; FIRST = 1; SECOND = 1 << 1; BOTH = 1 | (1 << 1); HIGH = 0x80000000; } extern fn check(value: Result, options: Options) -> Result; }');
		switch enumerations.declarations[1] {
			case Enumeration("Options", _, true, values, _):
				expect(values[3].value == 3 && values[4].value < 0, "flag expressions should evaluate as 32-bit values");
			case _:
				throw "expected parsed flags";
		}
		var enumSource = HxiProjection.source(enumerations);
		expect(enumSource.indexOf("enum abstract Result(Int) from Int to Int") >= 0
			&& enumSource.indexOf("var BOTH = 3") >= 0
			&& enumSource.indexOf("extern function check(arg0:Result, arg1:Options):Result") >= 0,
			"enums should retain nominal types while projecting integer ABI calls");
		var enumCompiler = new Compiler();
		enumCompiler.addFfiInterface("enums.hxi",
			'interface enums @target("x86_64-linux-gnu") @library("enums") { enum Result : i32 { OK = 0; ERROR = -1; } extern fn check(value: Result) -> Result; }');
		enumCompiler.update("EnumMain.hx", "import enums; function main():Result return enums.check(Result.OK);");
		enumCompiler.analyze("EnumMain");
		expectError('interface bad @target("x86_64-linux-gnu") { enum value : i64 { A = 0; } }', "requires an 8/16/32-bit integer representation");
		expectError('interface bad @target("x86_64-linux-gnu") { enum value : u8 { A = 256; } }', "outside the representation");
		expectError('interface bad @target("x86_64-linux-gnu") { enum value : i32 { A = 0; B = 0; } }', "duplicates");
		expectError('interface bad @target("x86_64-linux-gnu") { enum value : i32 { A = 1 << 32; } }', "shift count");
		var callbacks = HxiParser.parse("callbacks.hxi",
			'interface callbacks @target("x86_64-linux-gnu") @library("callbacks") { callback Binary = fn(left: i32, right: i32) -> i32; extern fn apply(callback: Binary, left: i32, right: i32) -> i32; }');
		var callbackSource = HxiProjection.source(callbacks);
		expect(callbackSource.indexOf("typedef Binary = (left:Int, right:Int)->Int") >= 0
			&& callbackSource.indexOf("abstract BinaryCallback") >= 0
			&& callbackSource.indexOf("function takeError():Null<haxe.io.Bytes>") >= 0
			&& callbackSource.indexOf("extern function apply(arg0:BinaryCallback") >= 0,
			"callbacks should project typed functions behind explicitly owned native handles");
		var nullableCallbacks = HxiParser.parse("nullable-callbacks.hxi",
			'interface callbacks @target("x86_64-linux-gnu") @library("callbacks") { callback Binary = fn(value: i32) -> i32; extern fn set(callback: nullable<Binary>) -> void; }');
		expect(HxiProjection.source(nullableCallbacks).indexOf("extern function set(arg0:Null<BinaryCallback>):Void") >= 0,
			"nullable callback parameters should project as nullable managed handles");
		var conventions = HxiParser.parse("conventions.hxi",
			'interface conventions @target("i686-pc-windows-msvc") @library("calls") { callback Hook = fn(value: i32) -> i32 @callconv("stdcall"); extern fn invoke(hook: Hook) -> i32 @callconv("system"); }');
		var conventionSource = HxiProjection.source(conventions);
		expect(conventionSource.indexOf('haxe.io.Bytes.ofString("5>5@stdcall")') >= 0
			&& conventionSource.indexOf('@:cNative("calls", "invoke", "11>5@system")') >= 0,
			"calling conventions should be part of callback and function ABI identity");
		expectError('interface bad @target("x86_64-linux-gnu") { extern fn value() -> i32 @callconv("stdcall"); }', "only available for Windows");
		expectError('interface bad @target("x86_64-linux-gnu") { callback Value = fn() -> i32 @callconv("fastcall"); }', "unsupported calling convention");
		expectError('interface bad @target("x86_64-linux-gnu") { callback Binary = fn(value: i32) -> i32; extern fn get() -> nullable<Binary>; }',
			"cannot return a callback handle yet");
		var callbackCompiler = new Compiler();
		callbackCompiler.addFfiInterface("callbacks.hxi",
			'interface callbacks @target("x86_64-linux-gnu") @library("callbacks") { callback Binary = fn(left: i32, right: i32) -> i32; extern fn apply(callback: Binary) -> i32; }');
		callbackCompiler.update("CallbackMain.hx",
			"import callbacks; function main():Int { var callback = new BinaryCallback(function(left:Int, right:Int) return left + right); return callbacks.apply(callback); }");
		callbackCompiler.analyze("CallbackMain");
		var pointerCallback = HxiParser.parse("pointer-callback.hxi",
			'interface pointers @target("x86_64-linux-gnu") @library("pointers") { opaque Context; callback Visit = fn(context: nullable<ptr<Context>>) -> void; }');
		expect(HxiProjection.source(pointerCallback).indexOf('context:Null<hl.Abstract<"native_pointer">>') >= 0,
			"callback pointer arguments should project as borrowed typed handles");
		expectError('interface bad @target("x86_64-linux-gnu") { callback Invalid = fn() -> ptr<void>; }',
			"Callbacks support scalar, aggregate, and pointer arguments");
		var aggregateCallbacks = HxiParser.parse("aggregate-callbacks.hxi",
			'interface aggregates @target("x86_64-linux-gnu") @library("aggregates") { struct point @layout(8, 4) { x: i32 @offset(0); y: i32 @offset(4); } callback Transform = fn(value: point) -> point; }');
		var aggregateCallbackSource = HxiProjection.source(aggregateCallbacks);
		expect(aggregateCallbackSource.indexOf("typedef Transform = (value:point)->point") >= 0
			&& aggregateCallbackSource.indexOf("{8;4;5,5}>{8;4;5,5}") >= 0,
			"aggregate callbacks should retain their recursive ABI descriptor");
		var strings = HxiParser.parse("strings.hxi",
			'interface strings @target("x86_64-linux-gnu") @library("strings") { callback Filter = fn(value: utf8) -> nullable<utf8>; extern fn check(value: utf8, optional: nullable<utf8>) -> i32; extern fn current() -> utf8 @borrowed; extern fn copy() -> utf8 @owned("release"); }');
		var stringSource = HxiProjection.source(strings),
			stringNatives = HxiProjection.cNatives(strings);
		expect(stringSource.indexOf("typedef Filter = (value:String)->Null<String>") >= 0
			&& stringSource.indexOf('haxe.io.Bytes.ofString("13>14")') >= 0
			&& stringSource.indexOf("extern function check(arg0:String, arg1:Null<String>):Int") >= 0
			&& stringNatives[0].signature == "13,14>5"
			&& stringNatives[1].signature == ">13",
			"UTF-8 strings should project explicit nullability and ABI descriptors");
		expectError(valid + "garbage", "Unexpected token");
		expectError(StringTools.replace(valid, "@offset(8)", "@offset(16)"), "invalid offset");
		expectError('interface bad @target("x86_64-linux-gnu") { struct pair @layout(8, 4) { left: i32 @offset(0); right: i32 @offset(0); } }',
			"overlaps field");
		expectError('interface bad @target("x86_64-linux-gnu") { struct item @layout(16, 8) { value: f64 @offset(4); } }', "invalid offset");
		expectError('interface bad @target("x86_64-linux-gnu") { struct item @layout(12, 4) { value: i64 @offset(8); } }', "invalid offset");
		expectError(StringTools.replace(valid, "type nk_handle = u32;", "type nk_handle = u32; type nk_handle = u64;"), "Duplicate HXI declaration");
		expectError(StringTools.replace(valid, '@target("x86_64-linux-gnu")', "@target(42)"), "requires a string value");
		expectError(StringTools.replace(valid, "@leaf", "@leaf(1)"), "does not accept values");
		expectError(StringTools.replace(valid, "@leaf", "@unknown"), "Unsupported @unknown metadata");
		expectError(StringTools.replace(valid, "ptr<const<nk_options>>", "nullable<i32>"), "nullable<> requires a pointer or callback type");
		var pointerPolicies = HxiParser.parse("pointers.hxi",
			'interface pointers @target("x86_64-linux-gnu") @library("pointers") { opaque context; extern fn create() -> ptr<u8> @owned("context_destroy") @length("context_size"); extern fn current() -> nullable<ptr<context>> @borrowed; }');
		switch pointerPolicies.declarations[1] {
			case Function(_, _, _, _, _, "cdecl", {ownership: Owned("context_destroy"), length: "context_size"}, _):
			case _:
				throw "owned pointer result policy was not retained";
		}
		expectError('interface bad @target("x86_64-linux-gnu") { opaque context; extern fn value() -> ptr<context> @borrowed @owned("free"); }',
			"cannot combine @borrowed and @owned");
		expectError('interface bad @target("x86_64-linux-gnu") { extern fn value() -> i32 @borrowed; }', "requires a pointer return type");
		expectError('interface bad @target("x86_64-linux-gnu") { opaque context; extern fn value() -> ptr<context> @borrowed @length("size"); }',
			"requires a pointer to byte-sized data");
		var compiler = new Compiler();
		compiler.addFfiInterface("nativekit.hxi", valid);
		expect(compiler.ffiInterfaces().length == 1
			&& compiler.ffiInterfaces()[0].library == "nativekit", "compiler should retain validated FFI models");
		var projection = compiler.modules.get("nativekit");
		expect(projection != null
			&& projection.source.text.indexOf("abstract nk_options(haxe.io.Bytes) from haxe.io.Bytes to haxe.io.Bytes") >= 0
			&& projection.source.text.indexOf("function set_flags") >= 0
			&& projection.source.text.indexOf('@:cNative("nativekit", "nk_open_v1", "11>6")') >= 0
			&& projection.source.text.indexOf('extern function nk_version():Int;') >= 0,
			"compiler should expose bridgeable HXI functions through a generated source module");
		var nested = HxiParser.parse("nested.hxi",
			'interface nested @target("x86_64-linux-gnu") @library("nested") { struct point @layout(8, 4) { x: i32 @offset(0); y: i32 @offset(4); } struct box @layout(16, 4) { start: point @offset(0); end: point @offset(8); } }');
		var nestedSource = HxiProjection.source(nested);
		expect(nestedSource.indexOf("function get_start():point") >= 0 && nestedSource.indexOf("__hxi_struct_copy") >= 0,
			"nested fixed-layout structs should project typed copy accessors");
		var pointerFields = HxiParser.parse("pointer-fields.hxi",
			'interface fields @target("x86_64-linux-gnu") @library("fields") { opaque context; struct holder @layout(8, 8) { context: nullable<ptr<context>> @offset(0) @borrowed; } }');
		switch pointerFields.declarations[1] {
			case Structure(_, _, _, [{ownership: Borrowed}], _):
			case _:
				throw "borrowed pointer field policy was not retained";
		}
		expect(HxiProjection.source(pointerFields).indexOf("function set_context") >= 0, "borrowed opaque pointer fields should project typed accessors");
		var arrays = HxiParser.parse("arrays.hxi",
			'interface arrays @target("x86_64-linux-gnu") @library("arrays") { struct point @layout(8, 4) { x: i32 @offset(0); y: i32 @offset(4); } struct values @layout(24, 4) { bytes: array<u8, 4> @offset(0); numbers: array<i32, 3> @offset(4); points: array<point, 1> @offset(16); } }');
		var arraySource = HxiProjection.source(arrays);
		expect(arraySource.indexOf("function get_numbers(index:Int):Int") >= 0
			&& arraySource.indexOf("function set_bytes_bytes") >= 0
			&& arraySource.indexOf("function get_points(index:Int):point") >= 0,
			"fixed scalar, byte, and nested structure arrays should project typed accessors");
		var unnatural = HxiParser.parse("unnatural.hxi",
			'interface bad @target("x86_64-linux-gnu") @library("bad") { struct values @layout(12, 4) { byte: u8 @offset(0); number: i32 @offset(8); } extern fn consume(value: values) -> void; }');
		var unnaturalRejected = false;
		try
			HxiProjection.cNatives(unnatural)
		catch (error:Dynamic)
			unnaturalRejected = Std.string(error).indexOf("natural C struct") >= 0;
		expect(unnaturalRejected, "non-natural layouts should be rejected when passed by value");
		expectError('interface bad @target("x86_64-linux-gnu") { struct values @layout(12, 4) { numbers: array<i32, 2> @offset(2); } }', "invalid offset");
		expectError('interface bad @target("x86_64-linux-gnu") { opaque context; struct holder @layout(8, 8) { context: ptr<context> @offset(0) @owned("destroy"); } }',
			"Owned pointer field");
		expectError('interface bad @target("x86_64-linux-gnu") { struct holder @layout(16, 8) { data: ptr<u8> @offset(0) @length_field("size"); size: usize @offset(8); } }',
			"reserved until structures can retain input buffers");
		compiler.update("Main.hx", "import nativekit; function main():Int return nativekit.nk_version();");
		compiler.analyze("Main");
		expect(compiler.irCNatives().length == 2 && compiler.irCNatives()[1].name == "nativekit.nk_version",
			"compiler should retain executable C descriptors for projected functions");
		var pointerDescriptors = HxiProjection.cNatives(pointerPolicies);
		expect(!pointerDescriptors[0].pointerNullable
			&& pointerDescriptors[1].pointerNullable, "pointer result nullability should survive IR projection");
		var duplicateRejected = false;
		try
			compiler.addFfiInterface("duplicate.hxi", valid)
		catch (_:Dynamic)
			duplicateRejected = true;
		expect(duplicateRejected, "compiler should reject duplicate FFI interface names");
		Sys.println("PASS: raw HXI parses into a validated ABI model");
	}

	static function expectError(text:String, message:String):Void {
		try {
			HxiParser.parse("invalid.hxi", text);
			throw 'expected "$message"';
		} catch (error:CompileError) {
			expect(error.diagnostic.code == "E3001"
				&& error.diagnostic.message.indexOf(message) >= 0, 'expected HXI diagnostic "$message"');
		}
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
