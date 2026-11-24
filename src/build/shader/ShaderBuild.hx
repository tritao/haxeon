package build.shader;

import build.execution.Directories;
import build.Target.TargetOs;
import build.Target.TargetArch;
import build.execution.ProcessRunner;
import compiler.core.UsageError;
import haxe.Json;
import haxe.crypto.Sha256;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import build.shader.ShaderReflection.rows;

class ShaderBuild {
	static final pins = [
		"linux" => "2554534631a7c7c6c2261dc6d20a603cdabf0cc1390e293f5ca06d345bb48c13",
		"linux_arm64" => "da5e56ec9dc736b9fb7b43c881b2fe5616b2dd4beef7518dcfb5d60deb0eb50c",
		"osx" => "8d8b74e0f612f556a0f57ea5a49c1c64bf990eed518001db626332a9ef887afc",
		"osx_arm64" => "54b98765886f4abd3bb86ffcf8c75c5073073a7fb009e7f693fb2f4d9ce3baa6",
		"win32" => "10bd643a869cbacff606c28aa44f79a55ad545981c907889b6fb28bc8977b380"
	];
	static inline final REVISION = "4f5b2796806875dcf0a5a5dfa9f9dab462726a5e";

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
			var compiler = pinnedCompiler(home);
			var identity = [digest(compiler), digest(HashLinkPath.executable(home, "haxeon"))];
			var bytecode = Path.join([HashLinkPath.directory(home), "haxeon-cli.hl"]);
			if (FileSystem.exists(bytecode))
				identity.push(digest(bytecode));
			for (name in names) {
				var source = sources.get(name), path = Path.join([output, name.split(".").join("/") + ".hx"]);
				var emitted = generate(compiler, source, name, path, target, Reflect.field(variants, name),
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

	static function generate(compiler:String, source:String, name:String, output:String, target:String,
			spec:Dynamic, identity:Array<String>, project:String, style:String, cacheRoot:String):Null<Array<String>> {
		var variants = spec == null ? ["default"] : Reflect.fields(spec);
		variants.sort(Reflect.compare);
		var defines = [for (variant in variants) spec == null ? [] : (cast Reflect.field(spec, variant):Array<String>)];
		var key = Json.stringify([identity, source, target, variants, defines]),
			record = Path.join([
				cacheRoot,
				name + ".json"
			]);
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
		var dependencies:Map<String, Bool> = [source => true], compiled:Array<ShaderModule.ShaderVariant> = [];
		var succeeded = true;
		try {
			for (index => variant in variants) {
				var prefix = Path.join([directory, "shader" + index]), depfile = prefix + ".d";
				var slangs = StringTools.startsWith(target, "glsl") ? target : target + ":glsl410";
				var arguments = [
					"-i",
					source,
					"-o",
					prefix,
					"-l",
					slangs,
					"-f",
					"bare_yaml",
					"--no-log-cmdline",
					"--save-intermediate-spirv",
					"--dependency-file=" + depfile
				];
				if (defines[index].length > 0)
					arguments.push("--defines=" + defines[index].join(":"));
				var result = ProcessRunner.capture(compiler, arguments);
				diagnostics(result.output, project, style);
				if (result.status != 0) {
					succeeded = false;
					break;
				}
				var deps = File.getContent(depfile).split("\r\n").join("\n");
				deps = deps.substr(deps.indexOf(": ") + 2);
				for (entry in deps.split("\\\n")) {
					var path = StringTools.trim(entry);
					if (path != "")
						dependencies.set(Path.normalize(FileSystem.fullPath(path)), true);
				}
				var reflected = ShaderReflection.read(prefix + "_reflection.yaml"),
					canonical = StringTools.startsWith(target, "glsl") ? target : "glsl410";
				var byTarget:Map<String, Array<Dynamic>> = [];
				for (row in rows(reflected, "shaders"))
					byTarget.set(row.slang, rows(row, "programs"));
				var programs = byTarget.get(target);
				if (target != canonical) {
					var names:Map<String, Map<Int, String>> = [];
					for (program in byTarget.get(canonical)) {
						var slots:Map<Int, String> = [];
						for (attr in rows(program, "attrs"))
							slots.set(attr.slot, attr.glsl_name);
						names.set(program.name, slots);
					}
					for (program in programs)
						for (attr in rows(program, "attrs"))
							attr.glsl_name = names.get(program.name).get(attr.slot);
				}
				var members:Map<String, Array<Dynamic>> = [],
					stem = Path.withoutDirectory(prefix) + "_" + canonical + "_";
				for (entry in FileSystem.readDirectory(directory))
					if (StringTools.startsWith(entry, stem) && Path.extension(entry) == "spv")
						for (block => fields in ShaderReflection.uniformMembers(Path.join([directory, entry]))) {
							if (members.exists(block) && Json.stringify(members.get(block)) != Json.stringify(fields))
								throw "Ambiguous shader uniform block " + block;
							members.set(block, fields);
						}
				compiled.push({name: variant, programs: programs, members: members});
			}
			if (succeeded) {
				var text = ShaderModule.generate(name, target, compiled),
					files = [for (path in dependencies.keys()) path];
				files.sort(Reflect.compare);
				var signature = fingerprint(key, files);
				for (path in files) {
					var original = before.get(path);
					if ((original != null && original != digest(path))
						|| (original == null && FileSystem.stat(path).mtime.getTime() > started))
						throw "Shader inputs changed during generation. Run the build again.";
				}
				publish(output, text);
				publish(record,
					Json.stringify({dependencies: files, signature: signature, output: Sha256.encode(text)}));
			}
		} catch (error:haxe.Exception) {
			removeWork(directory);
			throw new UsageError(source + ": " + error.message);
		}
		removeWork(directory);
		return succeeded ? [for (path in dependencies.keys()) path] : null;
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
		var host = Target.detectHost(), folder = switch {
			os:host.os, arch:host.arch
		}
		{
			case {
				os:Linux, arch:X64
			}
			: "linux";
			case {
				os:Linux, arch:Arm64
			}
			: "linux_arm64";
			case {
				os:MacOS, arch:X64
			}
			: "osx";
			case {
				os:MacOS, arch:Arm64
			}
			: "osx_arm64";
			case {
				os:Windows, arch:X64
			}
			: "win32";
			case _: throw new UsageError("No pinned shader compiler for " + host);
		};
		var installed = HashLinkPath.executable(home, "sokol-shdc"), configured = Sys.getEnv("SOKOL_SHDC");
		var user = Sys.getEnv(folder == "win32" ? "USERPROFILE" : "HOME");
		var cached = Path.join([
			user == null ? home : user,
			".cache",
			"nativekit",
			REVISION,
			folder,
			Path.withoutDirectory(installed)
		]);
		var path = configured != null
			&& configured != "" ? configured : FileSystem.exists(installed) ? installed : cached;
		if (!FileSystem.exists(path) && path == cached) {
			Directories.ensure(Path.directory(path));
			var tmp = unique(path);
			var url =
				'https://raw.githubusercontent.com/floooh/sokol-tools-bin/$REVISION/bin/$folder/${Path.withoutDirectory(path)}';
			var status = Sys.command("curl", ["-fsSL", "--max-time", "60", url, "-o", tmp]);
			if (status != 0 || !FileSystem.exists(tmp) || digest(tmp) != pins.get(folder)) {
				if (FileSystem.exists(tmp))
					FileSystem.deleteFile(tmp);
				throw new UsageError("Could not download and verify the pinned shader compiler");
			}
			if (folder != "win32" && Sys.command("chmod", ["755", tmp]) != 0)
				throw new UsageError("Could not set shader compiler permissions");
			FileSystem.rename(tmp, path);
		}
		if (!FileSystem.exists(path) || digest(path) != pins.get(folder))
			throw new UsageError("SHA-256 mismatch or missing shader compiler: " + path);
		return Path.normalize(FileSystem.fullPath(path));
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
