package tools;

import build.Target;
import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.ir.Ir.IrType;
import compiler.modules.ModulePath;
import compiler.runtime.CompilerIntrinsics;
import compiler.tools.CompilerDriver;
import compiler.tools.CompilerRequest.PackageSourceRoot;
import compiler.tools.SourceManifestLoader;
import haxe.io.Bytes;
import haxe.io.BytesOutput;
import haxe.io.Path;
import project.PackageLockfile;
import project.PackageResolver;
import project.ProjectSourceAcquirer;
import project.SourceCache;
import sys.FileSystem;
import sys.io.File;

/** What an Android build compiles: the sources, their roots and the entry module. */
private typedef AndroidSources = {
	final sources:Array<String>;
	final roots:Array<String>;
	final entry:String;
	final defines:Array<String>;
	final packageRoots:Array<PackageSourceRoot>;
}

/**
 * Builds an Android HLB asset and its hot-reload sidecars, and compiles later edits against them:
 *
 *   tools.AndroidBuild INPUT <output.hl>        the asset, with .hli (runtime identity), .entry (the main stable ID)
 *                                               and .hcs (the compiler baseline the device's module was built from)
 *   tools.AndroidBuild edit INPUT <output.hl>   compile the sources as they are now against that baseline, into
 *                                               <output>.hlp (a body patch the running module applies) or <output>.hxr
 *                                               (a domain reload bundle, for structural edits), with the new baseline
 *                                               in <output>.hcs.pending until the device acknowledges it; prints
 *                                               "patch", "reload" or "unchanged" as its last line
 *
 * INPUT is one source file or `--project <haxeon.json>`. `haxeon run --target android --watch` runs both.
 */
class AndroidBuild {
	public static function main():Void {
		var arguments = Sys.args(), edit = arguments.length > 0 && arguments[0] == "edit";
		if (edit)
			arguments.shift();
		var sources = switch arguments {
			case [source, _]: singleSources(source);
			case ["--project", project, _]: projectSources(project);
			case _: throw "Usage: tools.AndroidBuild [edit] (<source.hx> | --project <haxeon.json>) <output.hl>";
		}, output = resolvePath(arguments[arguments.length - 1], Sys.getCwd());
		// A compile error is reported as the compiler reports it, without the tool's stack.
		try {
			if (edit)
				compileEdit(sources, output);
			else
				build(sources, output);
		} catch (error:haxe.Exception) {
			Sys.stderr().writeString(error.message + "\n");
			Sys.exit(1);
		}
	}

	static function singleSources(sourcePath:String):AndroidSources {
		var source = FileSystem.fullPath(sourcePath);
		return {sources: [source], roots: [], entry: ModulePath.fromFile(source), defines: [], packageRoots: []};
	}

	static function projectSources(projectPath:String):AndroidSources {
		var absoluteProjectPath = FileSystem.fullPath(projectPath),
			lockPath = Path.join([Path.directory(absoluteProjectPath), "haxeon.lock"]),
			lockfile = FileSystem.exists(lockPath) ? PackageLockfile.parse(lockPath, File.getContent(lockPath)) : null,
			project = new PackageResolver(new ProjectSourceAcquirer(SourceCache.root())).resolve(absoluteProjectPath,
				lockfile, lockfile != null, Target.parse("android")),
			packageRoots:Array<PackageSourceRoot> = [];
		for (resolvedPackage in project.packages.packages) {
			var shouldScopeRoot = resolvedPackage.name != project.rootPackage.name
				|| project.manifest.entry == resolvedPackage.name
				|| StringTools.startsWith(project.manifest.entry, resolvedPackage.name + ".");
			if (shouldScopeRoot)
				for (sourceRoot in resolvedPackage.sourceRoots)
					packageRoots.push({packageName: resolvedPackage.name, path: sourceRoot});
		}
		return {
			sources: [for (resolvedPackage in project.packages.packages) for (source in resolvedPackage.sources)
				source],
			roots: [for (resolvedPackage in project.packages.packages) for (root in resolvedPackage.sourceRoots) root],
			entry: project.manifest.entry,
			defines: project.manifest.defines.copy(),
			packageRoots: packageRoots
		};
	}

	/** A compiler set up the same way for a build and for an edit, from `baseline` when there is one. */
	static function prepare(sources:AndroidSources, ?baseline:Bytes):Compiler {
		var compiler = new Compiler(baseline, CompilerIntrinsics.configuration()),
			defines = CompilerDriver.targetDefines("hl");
		defines.push("android");
		defines = defines.concat(sources.defines);
		compiler.configure("cli:android:" + defines.join("|"), "cli:android", defines);
		compiler.enablePublicationTracking();
		compiler.addStandardLibrarySourceRoot(FileSystem.fullPath("stdlib"));
		for (root in sources.roots)
			compiler.addSourceRoot(root);
		SourceManifestLoader.load(compiler, sources.roots, sources.sources, sources.packageRoots);
		return compiler;
	}

	static function build(sources:AndroidSources, output:String):Void {
		var compiler = prepare(sources),
			result = compiler.compile(sources.entry),
			mainFunction:Null<compiler.ir.IrFunction> = null;
		for (fn in result.ir.functions)
			if (fn.name == "main")
				mainFunction = fn;
		if (mainFunction == null)
			throw 'Android entry module "${sources.entry}" must define a top-level main():Void function';
		if (mainFunction.arguments.length != 0 || mainFunction.result != IrType.Void)
			throw 'Android entry function "main" must have signature main():Void';
		var entryId = result.functionIds.get("main");
		if (entryId == null)
			throw 'Android entry function "main" has no stable ID';

		FileSystem.createDirectory(Path.directory(output));
		File.saveBytes(output, HlWriter.encode(result.module).flatten());
		File.saveBytes(sidecar(output, ".hli"), result.runtimeIdentity);
		File.saveContent(sidecar(output, ".entry"), Std.string(entryId));
		compiler.acknowledgePublication(result.revision);
		File.saveBytes(sidecar(output, ".hcs"), compiler.exportIdentityState());
		Sys.println('compiled Android entry ${sources.entry} -> $output');
	}

	/** Compiles the current sources against the baseline into a patch or a reload bundle, and stages the next baseline. */
	static function compileEdit(sources:AndroidSources, output:String):Void {
		var baselinePath = sidecar(output, ".hcs"),
			patchPath = sidecar(output, ".hlp"),
			reloadPath = sidecar(output, ".hxr"),
			pendingPath = baselinePath + ".pending";
		if (!FileSystem.exists(baselinePath))
			throw 'No Android baseline at $baselinePath: build and install the app first';
		for (stale in [patchPath, reloadPath, pendingPath])
			if (FileSystem.exists(stale))
				FileSystem.deleteFile(stale);
		var compiler = prepare(sources, File.getBytes(baselinePath)),
			result = compiler.compile(sources.entry),
			kind:String;
		if (result.requiresReload) {
			var entry = result.functionIds.get("main");
			if (entry == null)
				throw "Android reload module has no main function";
			var bundle = reloadBundle(HlWriter.encode(result.module).flatten(), result.runtimeIdentity, entry);
			File.saveBytes(reloadPath, bundle);
			Sys.println('compiled Android reload revision ${result.revision} (${bundle.length} bytes) -> $reloadPath');
			kind = "reload";
		} else if (result.patchBytes != null && result.patchBytes.length > 0) {
			File.saveBytes(patchPath, result.patchBytes);
			Sys.println('compiled Android patch revision ${result.revision} (${result.patchBytes.length} bytes) -> $patchPath');
			kind = "patch";
		} else {
			Sys.println("unchanged");
			return;
		}
		compiler.acknowledgePublication(result.revision);
		File.saveBytes(pendingPath, compiler.exportIdentityState());
		Sys.println(kind);
	}

	/** HXR v1: magic, version, then little-endian HLB and HLI lengths and the main stable ID, then the HLB and the HLI. */
	static function reloadBundle(module:Bytes, identity:Bytes, entry:Int):Bytes {
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

	static function resolvePath(path:String, base:String):String
		return Path.normalize(Path.isAbsolute(path) ? path : Path.join([base, path]));

	static function sidecar(outputPath:String, suffix:String):String {
		return StringTools.endsWith(outputPath, ".hl") ? outputPath.substr(0,
			outputPath.length - 3) + suffix : outputPath + suffix;
	}
}
