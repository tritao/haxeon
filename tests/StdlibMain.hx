import compiler.runtime.CompilerIntrinsics;
import compiler.hl.HlWriter;
import compiler.Compiler;
import compiler.Diagnostic.CompileError;
import sys.io.File;

/** Compiles a program against the selectively vendored Haxe standard library. */
class StdlibMain {
	static function main():Void {
		var output = Sys.args()[0];
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot("stdlib");
		compiler.update("Main.hx",
			"import Date; import Math; import Reflect; import haxe.io.Bytes; import haxe.io.BytesInput; import haxe.io.BytesOutput; import sys.FileSystem; import sys.io.File; " +
			"import haxe.ds.ArraySort; import haxe.ds.Option; import haxe.ds.Either; function compare(left:Int, right:Int):Int return left - right; function optionValue():Option<Int> return Some(20); function eitherValue():Either<Int,String> return Left(22); function readOption(value:Option<Int>):Int return switch value { case Some(number): number; case None: 0; }; function readEither(value:Either<Int,String>):Int return switch value { case Left(number): number; case Right(_): 0; }; function stdlibWorks():Bool { var buffer = new StringBuf(); buffer.add(\"A\"); buffer.add(1); buffer.addChar(66); buffer.addSub(\"cdef\", 1); buffer.addSub(\"XYZ\", 1, 1); var random = Std.random(10); var cwd = Sys.getCwd(); var environment = Sys.getEnv(\"PATH\"); return buffer.length == 7 && buffer.toString() == \"A1BdefY\" && StringTools.contains(\"abc\", \"b\") && StringTools.startsWith(\"abc\", \"ab\") && StringTools.endsWith(\"abc\", \"bc\") && StringTools.replace(\"a-b-a\", \"a\", \"x\") == \"x-b-x\" && StringTools.ltrim(\"  x\") == \"x\" && StringTools.rtrim(\"x \\t\") == \"x\" && StringTools.rtrim(\" \\n\") == \"\" && StringTools.trim(\" x \") == \"x\" && StringTools.lpad(\"x\", \"0\", 3) == \"00x\" && StringTools.lpad(\"x\", \"ab\", 4) == \"ababx\" && StringTools.lpad(\"abc\", \"0\", 2) == \"abc\" && StringTools.lpad(\"x\", \"\", 3) == \"x\" && StringTools.rpad(\"x\", \"0\", 3) == \"x00\" && StringTools.rpad(\"x\", \"ab\", 4) == \"xabab\" && StringTools.rpad(\"abc\", \"0\", 2) == \"abc\" && StringTools.rpad(\"x\", \"\", 3) == \"x\" && StringTools.hex(0) == \"0\" && StringTools.hex(42) == \"2A\" && StringTools.hex(42, 4) == \"002A\" && StringTools.hex(-1) == \"FFFFFFFF\" && StringTools.isSpace(\" x\", 0) && !StringTools.isSpace(\"\", 0) && !StringTools.isSpace(\"x\", -1) && !StringTools.isSpace(\"x\", 1) && Std.parseInt(\"42\") == 42 && Std.parseInt(\"-7\") == -7 && Std.parseInt(\"0x2A\") == 42 && Std.parseInt(\"12tail\") == 12 && Std.parseInt(\"bad\") == 0 && Std.parseFloat(\"3.5\") == 3.5 && Std.parseFloat(\"-2.25\") == -2.25 && Std.int(3.9) == 3 && Std.int(-3.9) == -3 && Std.int(7) == 7 && Std.string(42) == \"42\" && Std.random(0) == 0 && Std.random(1) == 0 && random >= 0 && random < 10 && cwd.length > 0 && Sys.time() >= 0.0 && Sys.cpuTime() >= 0.0 && Sys.threadCpuTime() >= 0.0 && Sys.processMemory() >= 0.0 && Sys.fullPath(\".\").length > 0 && Sys.executablePath().length > 0 && (environment == null || environment.length >= 0) && Sys.exists(cwd) && Sys.isDir(cwd) && Sys.readDir(cwd).length >= 0 && Sys.getPid() > 0 && Sys.args().length >= 0; } function main():Int { var values = [30, 10, 20, 20]; ArraySort.sort(values, compare); return stdlibWorks() ? values[0] + values[1] + values[2] - values[3] + readOption(optionValue()) + readEither(eitherValue()) - 20 : 0; }");
		if (compiler.modules.exists("StringBuf") || compiler.modules.exists("haxe.ds.ArraySort"))
			throw "stdlib modules were loaded eagerly";
		var result = compiler.compile("Main");
		var sourceOwnedNatives = [
			"Std.parseInt",
			"Std.parseFloat",
			"Std.random",
			"Std.string",
			"Sys.time",
			"Sys.cpuTime",
			"Sys.threadCpuTime",
			"Sys.processMemory",
			"Sys.getCwd",
			"Sys.fullPath",
			"Sys.executablePath",
			"Sys.getEnv",
			"Sys.setCwd",
			"Sys.putEnv",
			"Sys.exists",
			"Sys.isDir",
			"Sys.createDir",
			"Sys.removeDir",
			"Sys.delete",
			"Sys.rename",
			"Sys.readDir",
			"Sys.command",
			"Sys.sleep",
			"Sys.getPid",
			"Sys.getChar",
			"Sys.args",
			"Sys.println",
			"sys.io.File.getContent",
			"sys.io.File.getBytes",
			"sys.io.File.saveContent",
			"sys.io.File.saveBytes",
			"sys.FileSystem.exists",
			"sys.FileSystem.isDirectory",
			"sys.FileSystem.fullPath",
			"sys.FileSystem.absolutePath",
			"sys.FileSystem.readDirectory",
			"sys.FileSystem.createDirectory",
			"sys.FileSystem.deleteFile",
			"sys.FileSystem.deleteDirectory",
			"sys.FileSystem.rename",
			"Math.isNaN",
			"Reflect.compare",
			"haxe.io.Bytes.alloc",
			"haxe.io.Bytes.ofString",
			"haxe.io.BytesInput.new",
			"haxe.io.BytesOutput.new",
			"Date.now",
			"__date_get_time"
		];
		for (native in compiler.nativeConfiguration())
			if (sourceOwnedNatives.indexOf(native.name) >= 0)
				throw 'source-owned native "${native.name}" remained in the host registry';
		for (native in compiler.nativeConfiguration())
			if (native.name != "trace" && !StringTools.startsWith(native.name, "__"))
				throw 'ordinary API native "${native.name}" remained in the compiler intrinsic registry';
		for (module in [
			"Std",
			"StringBuf",
			"StringTools",
			"Sys",
			"Date",
			"Math",
			"Reflect",
			"haxe.io.Bytes",
			"haxe.io.BytesInput",
			"haxe.io.BytesOutput",
			"sys.FileSystem",
			"sys.io.File",
			"haxe.ds.ArraySort",
			"haxe.ds.Option",
			"haxe.ds.Either"
		])
			if (!compiler.modules.exists(module))
				throw 'stdlib module "$module" was not discovered';
		if (compiler.compile("Main").retyped.length != 0)
			throw "unchanged stdlib modules were not cached";
		var stringToolsSymbols:Map<String, Bool> = [
			"__string_starts_with" => true,
			"__string_ends_with" => true,
			"__string_replace" => true,
			"__string_ltrim" => true,
			"__string_trim" => true,
			"__string_is_space" => true
		];
		var stdSymbols:Map<String, Bool> = [
			"__std_parse_int" => true,
			"__std_parse_float" => true,
			"__std_random" => true,
			"__std_string" => true
		];
		var sysSymbols:Map<String, Bool> = [
			"sys_time" => true,
			"sys_cpu_time" => true,
			"sys_thread_cpu_time" => true,
			"sys_process_memory" => true,
			"__sys_get_cwd" => true,
			"__sys_full_path" => true,
			"__sys_exe_path" => true,
			"__sys_get_env" => true,
			"__sys_exists" => true,
			"__sys_is_dir" => true,
			"__sys_read_dir" => true,
			"sys_getpid" => true,
			"__sys_args" => true,
			"__sys_set_cwd" => true,
			"__sys_put_env" => true,
			"__sys_create_dir" => true,
			"__sys_remove_dir" => true,
			"__sys_delete" => true,
			"__sys_rename" => true,
			"__sys_command" => true,
			"sys_sleep" => true,
			"sys_get_char" => true,
			"__sys_print" => true
		];
		var fileSymbols:Map<String, Bool> = [
			"__file_get_content" => true,
			"__file_get_bytes" => true,
			"__file_save_content" => true,
			"__file_save_bytes" => true
		];
		var fileSystemSymbols:Map<String, Bool> = [
			"__sys_exists" => true,
			"__sys_is_dir" => true,
			"__sys_full_path" => true,
			"__sys_read_dir" => true,
			"__sys_create_dir" => true,
			"__sys_delete" => true,
			"__sys_remove_dir" => true,
			"__sys_rename" => true
		];
		var dateSymbols:Map<String, Bool> = ["__date_now" => true, "__date_get_time" => true];
		var coreSymbols:Map<String, Bool> = ["__math_is_nan" => true, "__reflect_compare" => true];
		var bytesSymbols:Map<String, Bool> = ["__bytes_alloc" => true, "__bytes_of_string" => true];
		var streamSymbols:Map<String, Bool> = [
			"__bytes_input_new" => true,
			"__bytes_input_read_byte" => true,
			"__bytes_input_read_i32" => true,
			"__bytes_input_read_f64" => true,
			"__bytes_input_read_string" => true,
			"__bytes_input_read" => true,
			"__bytes_output_new" => true,
			"__bytes_output_write_byte" => true,
			"__bytes_output_write_i32" => true,
			"__bytes_output_write_f64" => true,
			"__bytes_output_write_string" => true,
			"__bytes_output_write" => true,
			"__bytes_output_get_bytes" => true
		];
		for (native in result.module.natives) {
			var symbol = result.module.strings[native.name];
			stringToolsSymbols.remove(symbol);
			stdSymbols.remove(symbol);
			sysSymbols.remove(symbol);
			fileSymbols.remove(symbol);
			fileSystemSymbols.remove(symbol);
			dateSymbols.remove(symbol);
			coreSymbols.remove(symbol);
			bytesSymbols.remove(symbol);
			streamSymbols.remove(symbol);
		}
		for (symbol in stringToolsSymbols.keys())
			throw 'StringTools source binding "$symbol" was not emitted';
		for (symbol in stdSymbols.keys())
			throw 'Std source binding "$symbol" was not emitted';
		for (symbol in sysSymbols.keys())
			throw 'Sys source binding "$symbol" was not emitted';
		for (symbol in fileSymbols.keys())
			throw 'sys.io.File source binding "$symbol" was not emitted';
		for (symbol in fileSystemSymbols.keys())
			throw 'sys.FileSystem source binding "$symbol" was not emitted';
		for (symbol in dateSymbols.keys())
			throw 'Date source binding "$symbol" was not emitted';
		for (symbol in coreSymbols.keys())
			throw 'core source binding "$symbol" was not emitted';
		for (symbol in bytesSymbols.keys())
			throw 'haxe.io.Bytes source binding "$symbol" was not emitted';
		for (symbol in streamSymbols.keys())
			throw 'byte stream source binding "$symbol" was not emitted';
		File.saveBytes(output, HlWriter.encode(result.module));

		var invalid = new Compiler();
		CompilerIntrinsics.register(invalid);
		invalid.addSourceRoot("stdlib");
		invalid.update("Main.hx", 'import haxe.ds.Option; function main():Int { var value:Option<Int> = Some("bad"); return 0; }');
		try {
			invalid.compile("Main");
			throw "generic enum accepted an invalid payload";
		} catch (_:CompileError) {}

		var missing = new Compiler();
		CompilerIntrinsics.register(missing);
		missing.addSourceRoot("stdlib");
		missing.update("Main.hx", "import haxe.ds.Missing; function main():Int return 0;");
		try {
			missing.compile("Main");
			throw "missing stdlib import compiled";
		} catch (error:CompileError) {
			if (error.diagnostic.code != "E2001")
				throw error;
		}
	}
}
