package tools;

import compiler.core.UsageError;
import haxe.io.Path;
import project.PackageManifest;
import project.PackageManifest.AppManifest;
import sys.FileSystem;
import sys.io.File;

private typedef CreateOptions = {
	final directory:String;
	final template:String;
	final platforms:Null<Array<String>>;
	final org:String;
}

/**
 * `haxeon create DIRECTORY [--template app|console] [--platforms LIST] [--org PREFIX]`: makes a project from a template in
 * the SDK's templates (`HaxeonSdk.templates`, templates/README.md), or, in a directory that has some of it, adds the files it lacks and leaves every file
 * there as it is (docs/design/PROJECT_BUILDS.md).
 */
class ProjectCreator {
	public static final TEMPLATES = ["app", "console"];

	public static function run(arguments:Array<String>, home:String):Int {
		var options = parse(arguments),
			templateDirectory = Path.join([build.HaxeonSdk.templates(home), options.template]);
		if (!FileSystem.exists(templateDirectory))
			throw new UsageError('This Haxeon has no "${options.template}" template ($templateDirectory)');
		var target = FileSystem.absolutePath(options.directory),
			packageName = Path.withoutDirectory(Path.removeTrailingSlashes(Path.normalize(target)));
		if (!isPackageName(packageName))
			throw new UsageError('"$packageName" cannot name a package: use letters, digits, "-" and "_", starting with a letter');
		var existing = FileSystem.exists(target) ? PackageManifest.find(target) : null;
		if (existing != null && options.platforms != null)
			throw new UsageError('Adding platforms to an existing project is not supported yet; edit [app].platforms in $existing');
		// An existing app keeps its platforms; a new one takes --platforms, or every platform the template has a runner for, so
		// a project made on one machine builds on the others as it is.
		var existingApp = existing == null ? null : PackageManifest.parse(existing, File.getContent(existing)).app,
			platforms = existingApp != null ? existingApp.platforms : options.platforms == null
				? runnerPlatforms(templateDirectory) : options.platforms,
			values = [
				"package" => packageName,
				"name" => displayName(packageName),
				"id" => options.org + "." + identifierPart(packageName),
				"platforms" => "[" + [for (platform in platforms) '"$platform"'].join(", ") + "]",
				// The major and minor version the runner finds the SDK at (find_package(Haxeon 0.3)).
				"haxeon_version" => project.PackageCompatibility.CURRENT_HAXEON.split(".").slice(0, 2).join(".")
			];
		// The template's runners are its platforms (docs/design/PROJECT_BUILDS.md): an app for one it has none for could not build.
		if (existingApp == null && options.template == "app")
			for (platform in platforms)
				if (!FileSystem.exists(Path.join([templateDirectory, platform])))
					throw new UsageError('The app template has no $platform runner yet, so an app cannot build for $platform; it has: '
						+ runnerPlatforms(templateDirectory).join(", "));
		var created:Array<String> = [], kept:Array<String> = [];
		copy(templateDirectory, target, "", values, created, kept, platforms);
		var shown = options.directory == "." ? "this directory" : options.directory;
		if (created.length == 0) {
			Sys.println('Nothing to add: $shown already has every file of the ${options.template} template');
			return 0;
		}
		Sys.println('Created ${options.template == "app" ? "an app" : "a console program"} in $shown: ${created.join(", ")}');
		if (kept.length > 0)
			Sys.println('Kept as they are: ${kept.join(", ")}');
		Sys.println("Next:");
		if (options.directory != ".")
			Sys.println('  cd ${options.directory}');
		if (options.template == "console" || platforms.contains(AppRunner.hostPlatform())) {
			Sys.println("  haxeon run");
			if (options.template == "app")
				Sys.println("  haxeon run --watch             (edit src/Main.hx while it runs)");
		} else if (platforms.contains("android")) {
			Sys.println("  haxeon build --target android");
			Sys.println("  haxeon run --target android --watch");
		} else if (platforms.contains("web")) {
			Sys.println("  haxeon build --target wasm32");
		}
		return 0;
	}

	static function parse(arguments:Array<String>):CreateOptions {
		var directory:Null<String> = null, template = "app", platforms:Null<Array<String>> = null, org = "com.example";
		var index = 0;
		while (index < arguments.length) {
			var argument = arguments[index++], name = argument, value:Null<String> = null;
			var separator = argument.indexOf("=");
			if (StringTools.startsWith(argument, "--") && separator > 0) {
				name = argument.substr(0, separator);
				value = argument.substr(separator + 1);
			}
			// -t is --template's short spelling, as dart create -t spells it.
			if (name == "-t")
				name = "--template";
			switch name {
				case "--template" | "--platforms" | "--org":
					if (value == null) {
						if (index >= arguments.length)
							throw new UsageError('Option "$name" requires a value');
						value = arguments[index++];
					}
					switch name {
						case "--template":
							if (TEMPLATES.indexOf(value) < 0)
								throw new UsageError('Unknown template "$value". Valid: ${TEMPLATES.join(", ")}');
							template = value;
						case "--platforms":
							platforms = [for (platform in value.split(",")) StringTools.trim(platform)];
							for (platform in platforms)
								if (AppManifest.PLATFORMS.indexOf(platform) < 0)
									throw new UsageError('Unknown platform "$platform". Valid: ${AppManifest.PLATFORMS.join(", ")}');
						case _:
							if (!isOrg(value))
								throw new UsageError('Option "--org" takes a reverse-domain prefix, such as "com.example"');
							org = value;
					}
				case _ if (StringTools.startsWith(argument, "-")):
					throw new UsageError('Unknown create option "$argument"');
				case _ if (directory == null):
					directory = argument;
				case _:
					throw new UsageError('Unexpected create argument "$argument"');
			}
		}
		if (directory == null)
			throw new UsageError("haxeon create needs a directory: haxeon create my_app, or haxeon create . for this one");
		if (template != "app" && platforms != null)
			throw new UsageError('Option "--platforms" is for apps; a console program has no platforms');
		return {
			directory: directory,
			template: template,
			platforms: platforms,
			org: org
		};
	}

	/** Copies the template's files that `target` lacks, replacing placeholders; a file `target` has is kept as it is. */
	static function copy(source:String, target:String, relative:String, values:Map<String, String>,
			created:Array<String>, kept:Array<String>, platforms:Array<String>):Void {
		var names = FileSystem.readDirectory(source);
		names.sort(Reflect.compare);
		for (name in names) {
			var from = Path.join([source, name]),
				targetName = StringTools.endsWith(name, ".template") ? name.substr(0,
					name.length - ".template".length) : name,
				to = Path.join([target, targetName]),
				shown = relative == "" ? targetName : relative + "/" + targetName;
			if (FileSystem.isDirectory(from)) {
				// A runner directory is copied for the app's platforms only.
				if (relative == "" && AppManifest.PLATFORMS.indexOf(name) >= 0 && platforms.indexOf(name) < 0)
					continue;
				copy(from, to, shown, values, created, kept, platforms);
				continue;
			}
			if (FileSystem.exists(to)) {
				kept.push(shown);
				continue;
			}
			FileSystem.createDirectory(Path.directory(to));
			if (Path.extension(name) == "jar")
				File.copy(from, to);
			else
				File.saveContent(to, fill(File.getContent(from), values, shown));
			if (shown == "android/gradlew" && Sys.systemName() != "Windows")
				if (Sys.command("chmod", ["+x", to]) != 0)
					throw new UsageError('Could not make $shown executable');
			created.push(shown);
		}
	}

	/** `text` with each `{{NAME}}` replaced by its value; a placeholder with no value is an error in the template. */
	static function fill(text:String, values:Map<String, String>, file:String):String {
		var result = new StringBuf(), position = 0;
		while (true) {
			var start = text.indexOf("{{", position);
			if (start < 0)
				break;
			var end = text.indexOf("}}", start);
			if (end < 0)
				break;
			var key = text.substring(start + 2, end), value = values.get(key);
			if (value == null)
				throw new UsageError('Template file $file has an unknown placeholder {{$key}}');
			result.add(text.substring(position, start));
			result.add(value);
			position = end + 2;
		}
		result.add(text.substr(position));
		return result.toString();
	}

	/** The platforms whose runner directories `templateDirectory` has, by name. */
	static function runnerPlatforms(templateDirectory:String):Array<String> {
		var names = [
			for (name in FileSystem.readDirectory(templateDirectory))
				if (AppManifest.PLATFORMS.indexOf(name) >= 0 && FileSystem.isDirectory(Path.join([
					templateDirectory,
					name
				]))) name
		];
		names.sort(Reflect.compare);
		return names;
	}

	/** `my_app` and `my-app` as "My App". */
	static function displayName(packageName:String):String
		return [
			for (word in ~/[-_]+/g.split(packageName))
				if (word.length > 0) word.charAt(0).toUpperCase() + word.substr(1)
		].join(" ");

	/** The package name as the last part of an identifier: `my-app` as `my_app`. */
	static function identifierPart(packageName:String):String
		return packageName.split("-").join("_").toLowerCase();

	static function isPackageName(name:String):Bool
		return ~/^[A-Za-z][A-Za-z0-9_-]*$/.match(name);

	static function isOrg(org:String):Bool
		return ~/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)*$/.match(org);
}
