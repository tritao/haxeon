import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

class CxxSpanMain {
	static function main():Void {
		var output = Sys.args()[0],
			hxiPath = Sys.args()[1],
			bufferPath = Sys.args()[2],
			functionsPath = Sys.args()[3],
			compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot(Sys.getCwd() + "/stdlib");
		compiler.addFfiInterface(hxiPath, File.getContent(hxiPath));
		compiler.update("Buffer.hx", File.getContent(bufferPath));
		compiler.update("cxx_spanFunctions.hx", File.getContent(functionsPath));
		compiler.update("Main.hx",
			'import cxx_span; import Buffer; import cxx_spanFunctions; function main():Int { var buffer = Buffer.fromNative(cxx_span.__cxx_cxxspan__acquire()); var values = haxe.io.Bytes.alloc(4); values.set(0, 1); values.set(1, 2); values.set(2, 3); values.set(3, 4); return buffer.byteCount(values) == 4 && buffer.sum(values) == 10 && cxx_spanFunctions.byteCount(values) == 4 && cxx_spanFunctions.sum(values) == 10 ? 42 : 1; }');
		File.saveBytes(output, HlWriter.encode(compiler.compile("Main").module));
	}
}
