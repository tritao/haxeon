import compiler.ffi.HxiAbi;
import compiler.ffi.HxiAbi.HxiAbiValue;
import compiler.ffi.HxiAbi.HxiIntegerSign;
import compiler.ffi.HxiParser;
import compiler.ffi.HxiProjection;
import compiler.ffi.HxiProjectionProfile;
import compiler.ir.Ir.IrType;

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
				arguments: [PointerValue(64, false, "context", null)],
				result: IntegerValue(32, Signed)
			}:
			case _:
				throw "function ABI did not resolve";
		}
		var opaqueModel = HxiParser.parse("opaque.hxi",
			'interface sample @target("x86_64-linux-gnu") @library("sample") { opaque Context; opaque Window; type ContextAlias = Context; extern fn use_context(value: ptr<ContextAlias>) -> void; extern fn maybe_context(value: nullable<ptr<const<Context>>>) -> void; extern fn use_window(value: ptr<Window>) -> void; extern fn create_context() -> ptr<Context> @borrowed; extern fn maybe_return_context() -> nullable<ptr<Context>> @borrowed; extern fn create_owned_context() -> ptr<Context> @owned("destroy_context"); extern fn maybe_create_owned_context() -> nullable<ptr<Context>> @owned("destroy_context"); extern fn destroy_context(value: ptr<void>) -> void @symbol("destroy_context"); }'),
			opaqueAbi = HxiAbi.forInterface(opaqueModel);
		switch opaqueAbi.functions()[0].arguments[0] {
			case PointerValue(64, false, "Context", null):
			case _:
				throw "opaque pointer ABI should preserve its canonical pointee through aliases";
		}
		switch opaqueAbi.functions()[1].arguments[0] {
			case PointerValue(64, true, "Context", null):
			case _:
				throw "nullable const opaque pointer ABI should preserve its pointee identity";
		}
		switch opaqueAbi.functions()[3].result {
			case PointerValue(64, false, "Context", null):
			case _:
				throw "opaque pointer results should preserve their pointee identity";
		}
		switch opaqueAbi.functions()[4].result {
			case PointerValue(64, true, "Context", null):
			case _:
				throw "nullable opaque pointer results should preserve their pointee identity";
		}
		var opaqueSource = HxiProjection.source(opaqueModel);
		expect(opaqueSource.indexOf('abstract Context(hl.Abstract<"native_pointer">) {') >= 0
			&& opaqueSource.indexOf("extern function use_context(arg0:Context):Void") >= 0
			&& opaqueSource.indexOf("extern function maybe_context(arg0:Null<Context>):Void") >= 0
			&& opaqueSource.indexOf("extern function use_window(arg0:Window):Void") >= 0
			&& opaqueSource.indexOf("extern function create_context():Context") >= 0
			&& opaqueSource.indexOf("extern function maybe_return_context():Null<Context>") >= 0
			&& opaqueSource.indexOf("abstract OwnedContext(hl.Abstract<\"native_pointer\">)") >= 0
			&& opaqueSource.indexOf("function borrow():Context") >= 0
			&& opaqueSource.indexOf("extern function create_owned_context():OwnedContext") >= 0
			&& opaqueSource.indexOf("extern function maybe_create_owned_context():Null<OwnedContext>") >= 0,
			"opaque pointer types should project as distinct nominal Haxe handles");
		var borrowedOpaqueStart = opaqueSource.indexOf('abstract Context(hl.Abstract<"native_pointer">) {'),
			ownedOpaqueStart = opaqueSource.indexOf('abstract OwnedContext(hl.Abstract<"native_pointer">) {');
		expect(borrowedOpaqueStart >= 0
			&& ownedOpaqueStart > borrowedOpaqueStart
			&& opaqueSource.substr(borrowedOpaqueStart, ownedOpaqueStart - borrowedOpaqueStart).indexOf("function close()") < 0
			&& opaqueSource.substr(ownedOpaqueStart).indexOf("function close():Bool") >= 0,
			"only owned opaque results should expose close()");
		var opaqueNative = HxiProjection.cNatives(opaqueModel)[0];
		expect(opaqueNative.signature == "11>0", "opaque handle identity must not change the C pointer ABI signature");
		switch opaqueNative.arguments[0] {
			case Abstract("native_pointer"):
			case _:
				throw "opaque Haxe handles should retain the generic native pointer ABI representation";
		}
		var opaqueResultNative = HxiProjection.cNatives(opaqueModel)[3];
		expect(opaqueResultNative.signature == ">11", "opaque pointer results must keep the generic C pointer ABI signature");
		switch opaqueResultNative.result {
			case Abstract("native_pointer"):
			case _:
				throw "opaque Haxe handle results should retain the generic native pointer ABI representation";
		}
		var ownedOpaqueNative = HxiProjection.cNatives(opaqueModel)[5];
		expect(ownedOpaqueNative.signature == ">11"
			&& ownedOpaqueNative.pointerOwnership == "owned"
			&& ownedOpaqueNative.pointerRelease == "destroy_context",
			"owned opaque results should retain ownership metadata without changing the C pointer ABI");
		var opaqueProfile = HxiProjectionProfile.parse("opaque.hxmap", '{"interface":"sample","typeNames":{"Context":"ContextHandle"}}');
		HxiProjection.validateProfile("opaque.hxmap", opaqueModel, null, null, opaqueProfile);
		var mappedOpaqueSource = HxiProjection.source(opaqueModel, null, null, null, opaqueProfile);
		expect(mappedOpaqueSource.indexOf('abstract ContextHandle(hl.Abstract<"native_pointer">)') >= 0
			&& mappedOpaqueSource.indexOf("abstract OwnedContextHandle(hl.Abstract<\"native_pointer\">)") >= 0
			&& mappedOpaqueSource.indexOf("extern function use_context(arg0:ContextHandle):Void") >= 0
			&& mappedOpaqueSource.indexOf("extern function create_owned_context():OwnedContextHandle") >= 0,
			"opaque handle types should respect Haxe projection naming rules");
		var ownerCollisionModel = HxiParser.parse("owner-collision.hxi",
			'interface owner_collision @target("x86_64-linux-gnu") @library("owner_collision") { opaque Context; opaque OwnedContext; }'),
			ownerCollisionRejected = false;
		try {
			HxiProjection.validateProfile("owner-collision.hxmap", ownerCollisionModel, null, null,
				HxiProjectionProfile.parse("owner-collision.hxmap", '{"interface":"owner_collision"}'));
		} catch (_:Dynamic)
			ownerCollisionRejected = true;
		expect(ownerCollisionRejected, "generated owned opaque type names should participate in Haxe collision checks");
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
