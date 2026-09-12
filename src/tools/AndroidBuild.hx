package tools;

import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.ir.Ir.IrType;
import compiler.modules.ModulePath;
import compiler.runtime.CompilerIntrinsics;
import compiler.tools.CompilerDriver;
import compiler.tools.SourceManifestLoader;
import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/** Builds an Android HLB asset and its persistent hot-reload sidecars. */
class AndroidBuild {
	public static function main():Void {
		var arguments = Sys.args();
		if (arguments.length == 2)
			buildSingle(arguments[0], arguments[1]);
		else if (arguments.length == 3 && arguments[0] == "--project")
			buildProject(arguments[1], arguments[2]);
		else
			throw "Usage: tools.AndroidBuild <source.hx> <output.hl> | --project <haxeon.json> <output.hl>";
	}

	static function buildSingle(sourcePath:String, outputPath:String):Void {
		var source = FileSystem.fullPath(sourcePath);
		build([source], [], ModulePath.fromFile(source), [], outputPath);
	}

	static function buildProject(projectPath:String, outputPath:String):Void {
		var absoluteProjectPath = FileSystem.fullPath(projectPath), projectDirectory = Path.directory(absoluteProjectPath), raw:Dynamic;
		try {
			raw = Json.parse(File.getContent(absoluteProjectPath));
		} catch (error:Dynamic) {
			throw 'Could not parse $absoluteProjectPath: ${Std.string(error)}';
		}
		if (raw == null || !Reflect.isObject(raw))
			throw '$absoluteProjectPath must contain a JSON object';
		var entryValue:Dynamic = Reflect.field(raw, "entry");
		if (!Std.isOfType(entryValue, String) || (cast entryValue : String).length == 0)
			throw '$absoluteProjectPath requires a non-empty "entry" string';
		var entries = readStringArray(raw, "sources", absoluteProjectPath, []),
			roots = readStringArray(raw, "sourceRoots", absoluteProjectPath, ["src"]),
			defines = readStringArray(raw, "defines", absoluteProjectPath, []);
		if (entries.length == 0)
			throw '$absoluteProjectPath must list at least one source in "sources"';
		if (roots.length == 0)
			throw '$absoluteProjectPath must list at least one path in "sourceRoots"';
		var absoluteRoots = [for (root in roots) resolvePath(root, projectDirectory)],
			absoluteSources = [for (source in entries) resolvePath(source, projectDirectory)];
		for (source in absoluteSources)
			if (!FileSystem.exists(source))
				throw 'Android project source does not exist: $source';
		build(absoluteSources, absoluteRoots, cast entryValue, defines, outputPath);
	}

	static function build(sources:Array<String>, roots:Array<String>, entry:String, projectDefines:Array<String>, outputPath:String):Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		var defines = CompilerDriver.targetDefines("hl");
		defines.push("android");
		defines = defines.concat(projectDefines);
		compiler.configure("cli:android:" + defines.join("|"), "cli:android", defines);
		compiler.enablePublicationTracking();
		compiler.addSourceRoot(FileSystem.fullPath("stdlib"));
		for (root in roots)
			compiler.addSourceRoot(root);
		SourceManifestLoader.load(compiler, roots, sources);
		var result = compiler.compile(entry),
			mainFunction:Null<compiler.ir.IrFunction> = null;
		for (fn in result.ir.functions)
			if (fn.name == "main")
				mainFunction = fn;
		if (mainFunction == null)
			throw 'Android entry module "$entry" must define a top-level main():Void function';
		if (mainFunction.arguments.length != 0 || mainFunction.result != IrType.Void)
			throw 'Android entry function "main" must have signature main():Void';
		var entryId = result.functionIds.get("main");
		if (entryId == null)
			throw 'Android entry function "main" has no stable ID';

		var output = resolvePath(outputPath, Sys.getCwd());
		ensureDirectory(Path.directory(output));
		File.saveBytes(output, HlWriter.encode(result.module));
		File.saveBytes(sidecar(output, ".hli"), result.runtimeIdentity);
		File.saveContent(sidecar(output, ".entry"), Std.string(entryId));
		compiler.acknowledgePublication(result.revision);
		File.saveBytes(sidecar(output, ".hcs"), compiler.exportIdentityState());
		Sys.println('compiled Android entry $entry -> $output');
	}

	static function readStringArray(raw:Dynamic, field:String, path:String, fallback:Array<String>):Array<String> {
		var value:Dynamic = Reflect.field(raw, field);
		if (value == null)
			return fallback.copy();
		if (Type.getClassName(Type.getClass(value)) != "Array")
			throw '$path "$field" must be an array of strings';
		var result:Array<String> = [];
		for (item in (cast value : Array<Dynamic>)) {
			if (Type.getClassName(Type.getClass(item)) != "String" || (cast item : String).length == 0)
				throw '$path "$field" must contain only non-empty strings';
			result.push(cast item);
		}
		return result;
	}

	static function resolvePath(path:String, base:String):String
		return Path.normalize(Path.isAbsolute(path) ? path : Path.join([base, path]));

	static function ensureDirectory(path:String):Void {
		if (path == null || path == "" || path == "." || FileSystem.exists(path))
			return;
		var parent = Path.directory(path);
		if (parent != path && parent != "")
			ensureDirectory(parent);
		if (!FileSystem.exists(path))
			FileSystem.createDirectory(path);
	}

	static function sidecar(outputPath:String, suffix:String):String {
		return StringTools.endsWith(outputPath, ".hl") ? outputPath.substr(0, outputPath.length - 3) + suffix : outputPath + suffix;
	}
}
