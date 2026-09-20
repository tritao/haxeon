import compiler.ffi.CHeaderImporter;
import compiler.ffi.CxxHeaderImporter;
import compiler.ffi.CxxProjection;
import compiler.ffi.CxxThunkGenerator;
import compiler.ffi.HxiWriter;
import haxe.io.Path;
import project.FfiManifest.FfiImportManifest;
import project.FfiManifest.ResolvedFfiImport;
import sys.io.File;
import sys.FileSystem;

/** Standalone C/C++ header to raw-HXI importer. */
class FfiImportMain {
	static function main():Void {
		var args = Sys.args(), manifestPath:Null<String> = null;
		for (arg in args)
			if (StringTools.startsWith(arg, "--manifest="))
				manifestPath = arg.substring(arg.indexOf("=") + 1);
		var manifest:Null<ResolvedFfiImport> = manifestPath == null ? null : FfiImportManifest.resolve(manifestPath, Path.directory(manifestPath)),
			config = manifest == null ? null : manifest.config, target = config == null
				|| config.target == null ? "" : config.target, output = "",
			language = config == null ? "c" : config.language, standard = config == null ? "c11" : config.standard,
			clang = config == null ? "clang" : config.clang, compileCommands:Null<String> = manifest == null ? null : manifest.compileCommands,
			library:Null<String> = config == null ? null : config.library, interfaceName:Null<String> = config == null ? null : config.interfaceName,
			includes:Array<String> = manifest == null ? [] : manifest.includes.copy(), defines:Array<String> = config == null ? [] : config.defines.copy(),
			dependencies:Array<String> = config == null ? [] : config.dependencies.copy(),
			sourceLabel:Null<String> = config == null ? null : config.sourceLabel,
			excludedHeaders:Array<String> = manifest == null ? [] : manifest.excludedHeaders.copy(), paths:Array<String> = [],
			cxxSelections:Array<String> = config == null ? [] : config.cxxSelections.copy(), trivialValues = config == null ? false : config.trivialValues,
			cxxLifetimes = config == null ? false : config.lifetimes, cxxVirtual = config == null ? false : config.virtualDispatch,
			cxxOwnership:Map<String, String> = config == null ? [] : config.cxxOwnership.copy(), cxxThunksPath:Null<String> = null,
			haxeOutputDir:Null<String> = null, haxeSourceManifestPath:Null<String> = null;
		for (arg in args)
			if (StringTools.startsWith(arg, "--manifest="))
				continue;
			else if (StringTools.startsWith(arg, "--target="))
				target = arg.substring(9);
			else if (StringTools.startsWith(arg, "--language="))
				language = arg.substring(11);
			else if (StringTools.startsWith(arg, "--std="))
				standard = arg.substring(6);
			else if (StringTools.startsWith(arg, "--clang="))
				clang = arg.substring(8);
			else if (StringTools.startsWith(arg, "--output="))
				output = arg.substring(9);
			else if (StringTools.startsWith(arg, "--include="))
				includes.push(arg.substring(10));
			else if (StringTools.startsWith(arg, "--define="))
				defines.push(arg.substring(9));
			else if (StringTools.startsWith(arg, "--compile-commands="))
				compileCommands = arg.substring(arg.indexOf("=") + 1);
			else if (arg == "--cxx-trivial-values")
				trivialValues = true;
			else if (arg == "--cxx-lifetimes")
				cxxLifetimes = true;
			else if (arg == "--cxx-virtual")
				cxxVirtual = true;
			else if (StringTools.startsWith(arg, "--cxx-owned=")) {
				var mapping = arg.substring(arg.indexOf("=") + 1),
					separator = mapping.indexOf("=");
				if (separator <= 0 || separator == mapping.length - 1)
					throw 'Invalid --cxx-owned mapping "$mapping"; expected <factory>=<release>';
				cxxOwnership.set(mapping.substring(0, separator), mapping.substr(separator + 1));
			} else if (StringTools.startsWith(arg, "--cxx-thunks="))
				cxxThunksPath = arg.substring(arg.indexOf("=") + 1);
			else if (StringTools.startsWith(arg, "--library="))
				library = arg.substring(10);
			else if (StringTools.startsWith(arg, "--interface="))
				interfaceName = arg.substring(12);
			else if (StringTools.startsWith(arg, "--depends="))
				dependencies.push(arg.substring(10));
			else if (StringTools.startsWith(arg, "--source-label="))
				sourceLabel = arg.substring(15);
			else if (StringTools.startsWith(arg, "--haxe-output-dir="))
				haxeOutputDir = arg.substring(arg.indexOf("=") + 1);
			else if (StringTools.startsWith(arg, "--haxe-source-manifest="))
				haxeSourceManifestPath = arg.substring(arg.indexOf("=") + 1);
			else if (StringTools.startsWith(arg, "--cxx-select="))
				cxxSelections.push(arg.substring(arg.indexOf("=") + 1));
			else if (StringTools.startsWith(arg, "--exclude-header="))
				excludedHeaders.push(arg.substring(17));
			else if (StringTools.startsWith(arg, "--"))
				throw 'Unknown FFI import option "$arg"';
			else
				paths.push(arg);
		if (paths.length == 0 && manifest != null)
			paths.push(manifest.header);
		if (manifest != null && manifest.config.cxxThunks && cxxThunksPath == null) {
			if (output.length == 0)
				throw "FFI manifest cxxThunks requires --output so the generated source path can be derived";
			cxxThunksPath = Path.withoutExtension(output) + "-thunks.cpp";
		}
		if (language != "c" && language != "c++")
			throw 'Unsupported FFI language "$language"';
		if (cxxSelections.length != 0 && language != "c++")
			throw "--cxx-select requires --language=c++";
		if (cxxOwnership.keys().hasNext() && language != "c++")
			throw "--cxx-owned requires --language=c++";
		if (haxeOutputDir != null && language != "c++")
			throw "--haxe-output-dir requires --language=c++";
		if (cxxThunksPath != null && language != "c++")
			throw "--cxx-thunks requires --language=c++";
		if (haxeOutputDir != null && library == null)
			throw "--haxe-output-dir requires --library so generated wrappers can call the HXI interface";
		if (manifest != null && manifest.config.projection && haxeOutputDir == null)
			throw "FFI manifest projection requires --haxe-output-dir";
		if (haxeSourceManifestPath != null && haxeOutputDir == null)
			throw "--haxe-source-manifest requires --haxe-output-dir";
		if (language == "c++" && clang == "clang")
			clang = "clang++";
		if (target.length == 0 || output.length == 0 || paths.length != 1)
			throw "Usage: haxeon-ffi-import [--manifest=<file>] --target=<triple> --output=<file> [--language=c|c++] [--std=<standard>] [--clang=<path>] [--cxx-trivial-values] [--cxx-lifetimes] [--cxx-virtual] [--cxx-thunks=<file>] [--cxx-owned=<factory>=<release>] [--cxx-select=<qualified-declaration>] [--library=<name>] [--interface=<name>] [--haxe-output-dir=<directory>] [--haxe-source-manifest=<file>] [--depends=<interface>] [--include=<dir>] [--define=<name[=value]>] [--compile-commands=<path>] [--source-label=<path>] [--exclude-header=<path>] <header>";
		var cxxResult = language == "c++" ? CxxHeaderImporter.importHeader(paths[0], target, includes, clang, library, interfaceName, dependencies,
			excludedHeaders, standard, defines, compileCommands, trivialValues, cxxLifetimes, cxxVirtual, cxxThunksPath != null,
			cxxSelections.length == 0 ? null : cxxSelections, cxxOwnership) : null,
			model = cxxResult == null ? CHeaderImporter.importHeaderWithOptions(paths[0], target, includes, clang, library, interfaceName, dependencies,
				excludedHeaders, defines, compileCommands) : cxxResult.hxi,
			label = sourceLabel == null ? paths[0] : sourceLabel,
			headerComment = '// Generated by Haxeon from $label for $target. Do not edit.';
		File.saveContent(output, HxiWriter.write(model, headerComment));
		if (cxxThunksPath != null) {
			var directory = Path.directory(cxxThunksPath);
			if (directory.length > 0 && !FileSystem.exists(directory))
				FileSystem.createDirectory(directory);
			File.saveContent(cxxThunksPath, CxxThunkGenerator.source(cxxResult.model));
		}
		if (haxeOutputDir != null) {
			ensureDirectory(haxeOutputDir);
			var projectionFiles:Array<String> = [];
			for (projection in CxxProjection.sources(cxxResult.model, cxxResult.hxi, null, cxxResult.plans)) {
				var projectionPath = Path.join([haxeOutputDir, projection.file]);
				File.saveContent(projectionPath, projection.source);
				projectionFiles.push(projectionPath);
			}
			if (haxeSourceManifestPath != null) {
				projectionFiles.sort(Reflect.compare);
				ensureDirectory(Path.directory(haxeSourceManifestPath));
				File.saveContent(haxeSourceManifestPath, projectionFiles.join("\n") + "\n");
			}
		}
		Sys.println("imported " + paths[0] + " -> " + output);
	}

	static function ensureDirectory(path:String):Void {
		if (path == "" || path == "." || FileSystem.exists(path))
			return;
		var parent = Path.directory(path);
		if (parent != path && parent != "")
			ensureDirectory(parent);
		if (!FileSystem.exists(path))
			FileSystem.createDirectory(path);
	}
}
