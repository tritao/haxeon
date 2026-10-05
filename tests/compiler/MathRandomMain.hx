import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;
import compiler.Diagnostic.CompileError;

class MathRandomMain {
	static function main():Void {
		var compiler = new Compiler(null, CompilerIntrinsics.configuration());
		compiler.addSourceRoot(Sys.getCwd() + "/stdlib");
		compiler.update("Main.hx",
			'function sample():Float return Math.random(); function main():Int { var first=sample(); if (first<0 || first>=1) return 1; var different=false; for (_ in 0...128) { var value=sample(); if (value<0 || value>=1 || !Math.isFinite(value)) return 2; if (value != first) different=true; } return different ? 42 : 3; }');
		var result = compiler.compile("Main");
		if (GeneratedProgramRunner.exitCode(result) != 42)
			throw "Math.random did not produce changing unit interval values";
		compiler.update("Main.hx", 'function main():Int return Math.random(1);');
		var rejected = false;
		try
			compiler.analyze("Main")
		catch (_:CompileError)
			rejected = true;
		if (!rejected)
			throw "Math.random accepted an argument";
		Sys.println("PASS: Math.random returns changing finite [0,1) values and rejects arguments");
	}
}
