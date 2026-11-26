using compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.CompileOptions;
import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

class NullableAbstractWarmMain {
	static final entry =
		'import haxeon.Equality; function main():Int { var a:Null<Wrap>=null, b:Null<Wrap>=null, c:Null<Wrap>=new Wrap(42); return Equality.equals(a,b) && !Equality.equals(a,c) && Equality.equals(c,c) ? 42 : 1; }';
	static final initial = 'abstract Wrap(Int) { public function new(x:Int) this=x; }';
	static final edited =
		'struct Value implements Equatable { public var x:Int; public function new(x:Int) this.x=x; public function equals(other:Value):Bool return x==other.x; } abstract Wrap(Value) { public function new(x:Int) this=new Value(x); }';

	static function make(source:String):Compiler {
		var c = new Compiler();
		c.livePatching = false;
		// Every build checks what it reuses against what a fresh build makes.
		c.options = new CompileOptions({checkReuse: true});
		CompilerIntrinsics.register(c);
		c.addStandardLibrarySourceRoot("stdlib");
		c.update("Main.hx", entry);
		c.update("Wrap.hx", source);
		return c;
	}

	static function main():Void {
		var temp = Sys.getEnv("TMPDIR");
		if (temp == null || temp == "")
			throw "TMPDIR is required";
		var dir = TestHashLink.directory();
		run(temp, dir);
	}

	static function run(temp:String, dir:String):Void {
		var warm = make(initial);
		warm.compile("Main");
		warm.update("Wrap.hx", edited);
		warm.addStandardLibrarySourceRoot("stdlib");
		var a = warm.compile("Main").artifact.hashLink().hashLinkBytes().flatten(),
			b = make(edited).compile("Main").artifact.hashLink().hashLinkBytes().flatten();
		if (a.compare(b) != 0)
			throw "warm/cold differ after changing abstract representation";
		warm.update("Wrap.hx", initial);
		warm.addStandardLibrarySourceRoot("stdlib");
		var c = warm.compile("Main").artifact.hashLink().hashLinkBytes().flatten(),
			d = make(initial).compile("Main").artifact.hashLink().hashLinkBytes().flatten();
		if (c.compare(d) != 0)
			throw "warm/cold differ after restoring abstract representation";
		var path = Path.join([temp, "nullable-abstract-warm-" + Std.random(1000000000) + ".hl"]);
		try {
			File.saveBytes(path, a);
			var status = Sys.command(Path.join([dir, Sys.systemName() == "Windows" ? "hl.exe" : "hl"]), [path]);
			if (status != 42)
				throw 'warm module returned $status';
		} catch (e:Dynamic) {
			if (FileSystem.exists(path))
				FileSystem.deleteFile(path);
			throw e;
		}
		if (FileSystem.exists(path))
			FileSystem.deleteFile(path);
		Sys.println("PASS: nullable abstract representation changes agree in warm and cold builds");
	}
}
