package build.shader;

import build.execution.Directories;
import build.execution.ProcessRunner;
import compiler.core.UsageError;
import haxe.Json;
import haxe.crypto.Sha256;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

class ShaderBuild {
	public static function run(args:Array<String>, home:String):Int {
		if (args.length != 6)
			throw new UsageError("Invalid shader build request");
		var project = args[0],
			output = args[1],
			target = args[2],
			style = args[3],
			variants:Dynamic = Json.parse(args[4]),
			roots:Array<String> = Json.parse(args[5]);
		var sources:Map<String, String> = [];
		for (root in roots)
			discover(root, root, sources);
		for (name in Reflect.fields(variants))
			if (!sources.exists(name))
				throw new UsageError("shaderVariants names an unknown module: " + name);
		var names = [for (name in sources.keys()) name], paths = [], dependencies:Map<String, Bool> = [];
		names.sort(Reflect.compare);
		if (names.length > 0) {
			var driver = HashLinkPath.executable(home, "nkgpu-shaders");
			var compiler = pinnedCompiler(home);
			var identity = [digest(driver), digest(compiler), digest(HashLinkPath.executable(home, "haxeon"))];
			var bytecode = Path.join([HashLinkPath.directory(home), "haxeon-cli.hl"]);
			if (FileSystem.exists(bytecode))
				identity.push(digest(bytecode));
			for (name in names) {
				var source = sources.get(name), path = Path.join([output, name.split(".").join("/") + ".hx"]);
				var emitted = generate(driver, compiler, source, name, path, target, Reflect.field(variants, name),
					identity, project, style, Path.join([output, ".shader-cache"]));
				if (emitted == null)
					return 1;
				for (dependency in emitted)
					dependencies.set(dependency, true);
				paths.push(path);
			}
		}
		var manifest = Path.join([output, "shaders.sources"]), prefix = Path.join([output, "shaders"]) + "/";
		if (FileSystem.exists(manifest))
			for (stale in File.getContent(manifest).split("\n"))
				if (StringTools.startsWith(stale, prefix) && Path.normalize(stale) == stale
					&& Path.extension(stale) == "hx"
					&& paths.indexOf(stale) < 0 && FileSystem.exists(stale))
					FileSystem.deleteFile(stale);
		publish(manifest, lines(paths));
		publish(Path.join([output, "shaders.dependencies"]), lines([for (path in dependencies.keys()) path]));
		return 0;
	}

	static function discover(root:String, directory:String, sources:Map<String, String>):Void {
		for (entry in FileSystem.readDirectory(directory)) {
			var path = Path.join([directory, entry]);
			if (FileSystem.isDirectory(path)) {
				discover(root, path, sources);
				continue;
			}
			if (Path.extension(path) != "glsl")
				continue;
			var content = ~/\/\*[\s\S]*?\*\//g.replace(File.getContent(path), "");
			if (!~/^\s*@program(?:\s|$)/m.match(content))
				continue;
			var parts = Path.withoutExtension(path.substr(root.length + 1)).split("/");
			if (!~/^[A-Z]/.match(parts[parts.length - 1])
				|| Lambda.exists(parts, part -> !~/^[A-Za-z_][A-Za-z0-9_]*$/.match(part)))
				throw new UsageError(path + ": shader paths must use Haxe identifiers with an uppercase filename");
			var name = "shaders." + parts.join("."), canonical = Path.normalize(FileSystem.fullPath(path));
			if (sources.exists(name) && sources.get(name) != canonical)
				throw new UsageError('$path: duplicate shader module $name (${sources.get(name)})');
			sources.set(name, canonical);
		}
	}

	static function generate(driver:String, compiler:String, source:String, name:String, output:String, target:String,
			spec:Dynamic, identity:Array<String>, project:String, style:String, cacheRoot:String):Null<Array<String>> {
		var settings = spec == null ? '{"default":[]}' : Json.stringify(spec);
		var key = Json.stringify([identity, source, target, settings]);
		var record = Path.join([cacheRoot, name + ".json"]);
		var old:Dynamic = try Json.parse(File.getContent(record)) catch (_:Dynamic) null;
		var previous:Array<String> = old == null ? [] : old.dependencies;
		if (previous != null && previous.indexOf(source) >= 0 && FileSystem.exists(output)
			&& old.signature == fingerprint(key, previous) && old.output == digest(output))
			return previous;
		var directory = unique(Path.join([cacheRoot, "work"]));
		var started = Sys.time() * 1000.0, before:Map<String, String> = [source => digest(source)];
		if (previous != null)
			for (path in previous)
				if (!before.exists(path) && FileSystem.exists(path))
					before.set(path, digest(path));
		Directories.ensure(directory);
		try {
			var result = ProcessRunner.capture(driver, [
				"--source",
				source,
				"--output",
				directory,
				"--target",
				target,
				"--variants",
				settings,
				"--shdc",
				compiler
			]);
			diagnostics(result.output, project, style);
			if (result.status != 0) {
				removeWork(directory);
				return null;
			}
			var files = [for (path in File.getContent(Path.join([directory, "dependencies"])).split("\n")) if (path
				!= "") path];
			files.sort(Reflect.compare);
			var text = ShaderModule.generate(name, target,
				ShaderSchema.read(Path.join([directory, "reflection.json"]), target));
			var signature = fingerprint(key, files);
			for (path in files) {
				var original = before.get(path);
				if ((original != null && original != digest(path))
					|| (original == null && FileSystem.stat(path).mtime.getTime() > started))
					throw new UsageError("Shader inputs changed during generation. Run the build again.");
			}
			publish(output, text);
			publish(record, Json.stringify({dependencies: files, signature: signature, output: Sha256.encode(text)}));
			removeWork(directory);
			return files;
		} catch (error:haxe.Exception) {
			removeWork(directory);
			throw new UsageError(source + ": " + error.message);
		}
	}

	static function diagnostics(text:String, project:String, style:String):Void {
		var pattern = ~/^(.+):(\d+):(\d+): (error|warning): (.*)$/;
		var seen:Map<String, Bool> = [];
		for (row in text.split("\n")) {
			var line = StringTools.trim(row);
			if (!pattern.match(line)) {
				if (line != "")
					Sys.stderr().writeString(line + "\n");
				continue;
			}
			var path = Path.normalize(FileSystem.fullPath(pattern.matched(1))),
				number = Std.parseInt(pattern.matched(2));
			var column = Std.parseInt(pattern.matched(3)),
				warning = pattern.matched(4) == "warning",
				message = pattern.matched(5);
			var base = Path.addTrailingSlash(Path.normalize(project)),
				name = StringTools.startsWith(path, base) ? path.substr(base.length) : path;
			var code = warning ? "W4001" : "E4001",
				label = style == "short" ? code : (warning ? "warning" : "error") + "[$code]";
			if (message.indexOf("non-opaque uniforms outside a block") >= 0)
				message = "Declare numeric uniforms inside a layout(std140, binding=N) uniform block";
			if (message.indexOf("'#version'") >= 0)
				message = "Remove #version. The shader tool sets the version for each target.";
			var rendered = '$name:${number < 1 ? 1 : number}:${column < 1 ? 1 : column}: $label: $message';
			if (seen.exists(rendered))
				continue;
			seen.set(rendered, true);
			Sys.stderr().writeString(rendered + "\n");
			if (style == "full" && number > 0 && FileSystem.exists(path)) {
				var source = File.getContent(path).split("\n");
				if (number <= source.length) {
					Sys.stderr().writeString(' $number | ${source[number - 1]}\n');
					Sys.stderr()
						.writeString(' ${StringTools.lpad("", " ", Std.string(number).length)} | ${StringTools.lpad("^", " ", column < 1 ? 1 : column)}\n');
				}
			}
		}
	}

	public static function pinnedCompiler(home:String):String {
		var driver = HashLinkPath.executable(home, "nkgpu-shaders");
		var result = ProcessRunner.capture(driver, ["--print-compiler"]);
		if (result.status != 0)
			throw new UsageError(StringTools.trim(result.output));
		return Path.normalize(StringTools.trim(result.output));
	}

	static function fingerprint(key:String, files:Array<String>):Null<String> {
		var parts = [key];
		for (path in files) {
			if (!FileSystem.exists(path))
				return null;
			parts.push(path);
			parts.push(digest(path));
		}
		return Sha256.encode(Json.stringify(parts));
	}

	static function digest(path:String):String
		return Sha256.make(File.getBytes(path)).toHex();

	static function unique(path:String):String
		return path + "." + Std.string(Sys.time()).split(".").join("") + "." + Std.random(0x3fffffff);

	static function publish(path:String, text:String):Void {
		if (FileSystem.exists(path) && File.getContent(path) == text)
			return;
		Directories.ensure(Path.directory(path));
		var temporary = unique(path);
		File.saveContent(temporary, text);
		FileSystem.rename(temporary, path);
	}

	static function lines(values:Array<String>):String {
		values.sort(Reflect.compare);
		return [for (value in values) value + "\n"].join("");
	}

	static function removeWork(directory:String):Void {
		for (entry in FileSystem.readDirectory(directory))
			FileSystem.deleteFile(Path.join([directory, entry]));
		FileSystem.deleteDirectory(directory);
	}
}
