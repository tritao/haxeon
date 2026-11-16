using compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.CompileOptions;
import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

class WireFinalWarmMain {
	static final mainSource = 'import haxeon.wire.JsonWire; import haxeon.wire.MessagePack; function main():Int { '
		+ 'var json:WireRecord = JsonWire.decode(JsonWire.encode(new WireRecord())); '
		+ 'var binary:WireRecord = MessagePack.decode(MessagePack.encode(new WireRecord())); '
		+ 'return Std.string(json.value) == "7" && Std.string(binary.value) == "7" ? 42 : 1; }';
	static final initial = '@:wire class WireRecord { @:id(1) public final value:Int = 7; public function new() {} }';
	static final edited =
		'@:wire class WireRecord { @:id(1) public final value:String = "7"; public function new() {} }';

	static function make(record:String):Compiler {
		var compiler = new Compiler();
		compiler.livePatching = false;
		// Every build checks what it reuses against what a fresh build makes.
		compiler.options = new CompileOptions({checkReuse: true});
		CompilerIntrinsics.register(compiler);
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.update("Main.hx", mainSource);
		compiler.update("WireRecord.hx", record);
		return compiler;
	}

	static function main():Void {
		var temp = Sys.getEnv("TMPDIR");
		if (temp == null || temp == "")
			throw "TMPDIR is required";
		var prefix = Path.join([temp, "wire-final-warm-" + Std.random(1000000000)]);
		var warmPath = prefix + ".warm.hl", coldPath = prefix + ".cold.hl";
		try {
			var warm = make(initial);
			warm.compile("Main");
			warm.update("WireRecord.hx", edited);
			warm.addStandardLibrarySourceRoot("stdlib");
			var warmBytes = HlWriter.encode(warm.compile("Main").artifact.hashLink().module).flatten();
			var coldBytes = HlWriter.encode(make(edited).compile("Main").artifact.hashLink().module).flatten();
			if (warmBytes.compare(coldBytes) != 0)
				throw "Warm and cold wire modules differ";
			File.saveBytes(warmPath, warmBytes);
			File.saveBytes(coldPath, coldBytes);
			var dir = Sys.getEnv("HAXEON_HASHLINK_DIR");
			if (dir == null || dir == "")
				throw "HAXEON_HASHLINK_DIR is required";
			var hl = Path.join([dir, Sys.systemName() == "Windows" ? "hl.exe" : "hl"]);
			var warmStatus = Sys.command(hl, [warmPath]),
				coldStatus = Sys.command(hl, [coldPath]);
			if (warmStatus != 42 || coldStatus != 42)
				throw 'Warm returned $warmStatus, cold returned $coldStatus; expected 42';
		} catch (error:Dynamic) {
			cleanup(warmPath, coldPath);
			throw error;
		}
		cleanup(warmPath, coldPath);
		Sys.println("PASS: final wire field type edits agree in warm and cold builds");
	}

	static function cleanup(warmPath:String, coldPath:String):Void {
		if (FileSystem.exists(warmPath))
			FileSystem.deleteFile(warmPath);
		if (FileSystem.exists(coldPath))
			FileSystem.deleteFile(coldPath);
	}
}
