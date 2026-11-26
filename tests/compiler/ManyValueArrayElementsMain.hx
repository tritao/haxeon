using compiler.compilation.BackendArtifact.BackendArtifacts;

import compiler.CompileOptions;
import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;

/**
 * A session build of a program whose arrays hold more value element types than a query database holds kinds: the stages run once
 * per element type (`IrValueArrayProgramRewrite`), each a part of one stage's kind, so the count of element types a program uses
 * has no limit. Built cold, then warm after an edit of one element's array, which must give the bytes of a fresh build.
 */
class ManyValueArrayElementsMain {
	static inline final ELEMENTS = 300;

	static function source(edited:Int):String {
		var buffer = new StringBuf();
		buffer.add("class Main { static function main():Int { var sum = 0; ");
		for (index in 0...ELEMENTS)
			buffer.add('sum += f$index(); ');
		buffer.add("return sum; } ");
		for (index in 0...ELEMENTS)
			buffer.add('static function f$index():Int { var items = [new S$index(${index == edited ? 7 : index})]; return items[0].a; } ');
		buffer.add("}\n");
		for (index in 0...ELEMENTS)
			buffer.add('struct S$index { public var a:Int; public function new(a:Int) this.a = a; }\n');
		return buffer.toString();
	}

	static function main():Void {
		var compiler = newCompiler(source(-1), true);
		compiler.compile("Main");
		compiler.update("Main.hx", source(3));
		var warm = compiler.compile("Main"), fresh = newCompiler(source(3), false).compile("Main");
		var warmBytes = warm.artifact.hashLink().hashLinkBytes().flatten(),
			freshBytes = fresh.artifact.hashLink().hashLinkBytes().flatten();
		if (warmBytes.compare(freshBytes) != 0)
			throw 'the warm module differs from a fresh one (${warmBytes.length} and ${freshBytes.length} bytes)';
		Sys.println('PASS: a session build with $ELEMENTS value array element types builds warm as a fresh one');
	}

	static function newCompiler(main:String, check:Bool):Compiler {
		var compiler = new Compiler(null, CompilerIntrinsics.configuration());
		compiler.livePatching = false;
		compiler.options = new CompileOptions({checkReuse: check});
		compiler.addSourceRoot("stdlib");
		compiler.update("Main.hx", main);
		return compiler;
	}
}
