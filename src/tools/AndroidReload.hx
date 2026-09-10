package tools;

import compiler.Compiler;
import compiler.Compiler.CompileResult;
import compiler.runtime.CompilerIntrinsics;
import compiler.modules.ModulePath;
import compiler.hl.HlWriter;
import haxe.io.Bytes;
import haxe.io.BytesOutput;
import sys.FileSystem;
import sys.io.File;

/** Compiles a structural Android edit into a full HXR domain-reload bundle. */
class AndroidReload {
	public static function main():Void {
		var arguments = Sys.args();
		if (arguments.length != 3)
			throw "Usage: haxe -cp src --run tools.AndroidReload <source.hx> <baseline.hcs> <output.hxr>";

		var sourcePath = FileSystem.fullPath(arguments[0]),
			statePath = arguments[1],
			bundlePath = arguments[2],
			compiler = new Compiler(File.getBytes(statePath), CompilerIntrinsics.configuration());
		compiler.addSourceRoot("stdlib");
		compiler.update(sourcePath, File.getContent(sourcePath));
		var result:CompileResult = compiler.compile(ModulePath.fromFile(sourcePath));
		if (!result.requiresReload)
			throw "Android edit is HLP-compatible; use build-android-patch.sh instead";

		var entry = result.functionIds.get("main");
		if (entry == null)
			throw "Android reload module has no main function";
		var module = HlWriter.encode(result.module),
			bundle = encode(module, result.runtimeIdentity, entry);
		File.saveBytes(bundlePath, bundle);
		compiler.acknowledgePublication(result.revision);
		File.saveBytes(statePath + ".pending", compiler.exportIdentityState());
		Sys.println('compiled Android reload revision ${result.revision} (${bundle.length} bytes) -> $bundlePath (baseline pending device acknowledgement)');
	}

	static function encode(module:Bytes, identity:Bytes, entry:Int):Bytes {
		var output = new BytesOutput();
		output.bigEndian = false;
		output.writeString("HXR");
		output.writeByte(1);
		output.writeInt32(module.length);
		output.writeInt32(identity.length);
		output.writeInt32(entry);
		output.write(module);
		output.write(identity);
		return output.getBytes();
	}
}
