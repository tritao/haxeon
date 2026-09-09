import compiler.Diagnostic.CompileError;
import compiler.Compiler;
import compiler.ffi.HxiModel.HxiDeclaration;
import compiler.ffi.HxiModel.HxiType;
import compiler.ffi.HxiParser;

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
			case Function("nk_open", _, Named("nk_handle"), "nk_open_v1", false, _):
			case _:
				throw "expected symbol-bound function";
		}
		expectError(StringTools.replace(valid, "ptr<nk_context>", "ptr<missing>"), 'Unknown HXI type "missing"');
		expectError(valid + "garbage", "Unexpected token");
		expectError(StringTools.replace(valid, "@offset(8)", "@offset(16)"), "invalid offset");
		expectError(StringTools.replace(valid, "type nk_handle = u32;", "type nk_handle = u32; type nk_handle = u64;"), "Duplicate HXI declaration");
		expectError(StringTools.replace(valid, '@target("x86_64-linux-gnu")', "@target(42)"), "requires a string value");
		expectError(StringTools.replace(valid, "@leaf", "@leaf(1)"), "does not accept values");
		expectError(StringTools.replace(valid, "@leaf", "@unknown"), "Unsupported @unknown metadata");
		var compiler = new Compiler();
		compiler.addFfiInterface("nativekit.hxi", valid);
		expect(compiler.ffiInterfaces().length == 1
			&& compiler.ffiInterfaces()[0].library == "nativekit", "compiler should retain validated FFI models");
		var projection = compiler.modules.get("nativekit");
		expect(projection != null
			&& projection.source.text.indexOf('@:cNative("nativekit", "nk_open_v1", "11>6")') >= 0
			&& projection.source.text.indexOf('extern function nk_version():Int;') >= 0,
			"compiler should expose bridgeable HXI functions through a generated source module");
		compiler.update("Main.hx", "import nativekit; function main():Int return nativekit.nk_version();");
		compiler.analyze("Main");
		expect(compiler.irCNatives().length == 2 && compiler.irCNatives()[1].name == "nativekit.nk_version",
			"compiler should retain executable C descriptors for projected functions");
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
