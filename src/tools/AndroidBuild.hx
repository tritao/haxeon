package tools;

import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.ir.Ir.IrType;
import compiler.modules.ModulePath;
import compiler.runtime.CompilerIntrinsics;
import compiler.tools.CompilerDriver;
import compiler.tools.SourceManifestLoader;
import compiler.tools.CompilerRequest.PackageSourceRoot;
import haxe.Json;
import haxe.io.Path;
import project.PackageLockfile;
import project.PackageResolver;
import project.ProjectSourceAcquirer;
import project.ResolvedProject;
import project.SourceCache;
import build.Target;
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
		var absoluteProjectPath = FileSystem.fullPath(projectPath),
			lockPath = Path.join([Path.directory(absoluteProjectPath), "haxeon.lock"]),
			lockfile = FileSystem.exists(lockPath) ? PackageLockfile.parse(lockPath, File.getContent(lockPath)) : null,
			project = new PackageResolver(new ProjectSourceAcquirer(SourceCache.root())).resolve(absoluteProjectPath, lockfile, lockfile != null,
				Target.parse("android"));
		buildResolved(project, outputPath);
	}

	static function buildResolved(project:ResolvedProject, outputPath:String):Void {
		var roots = [
			for (resolvedPackage in project.packages.packages)
				for (root in resolvedPackage.sourceRoots)
					root
		], sources = [
			for (resolvedPackage in project.packages.packages)
				for (source in resolvedPackage.sources)
					source
			], packageRoots:Array<PackageSourceRoot> = [], defines = project.manifest.defines.copy();
		for (resolvedPackage in project.packages.packages) {
			var shouldScopeRoot = resolvedPackage.name != project.rootPackage.name
				|| project.manifest.entry == resolvedPackage.name
				|| StringTools.startsWith(project.manifest.entry, resolvedPackage.name + ".");
			if (shouldScopeRoot)
				for (sourceRoot in resolvedPackage.sourceRoots)
					packageRoots.push({packageName: resolvedPackage.name, path: sourceRoot});
		}
		build(sources, roots, project.manifest.entry, defines, outputPath, packageRoots);
	}

	static function build(sources:Array<String>, roots:Array<String>, entry:String, projectDefines:Array<String>, outputPath:String,
			?packageRoots:Array<PackageSourceRoot>):Void {
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
		SourceManifestLoader.load(compiler, roots, sources, packageRoots);
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
