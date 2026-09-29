package build;

import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/** One member project of a workspace build. */
class WorkspaceProject {
	public final name:String;

	/** Absolute path of the project's haxeon.json. */
	public final manifestPath:String;

	public final tags:Array<String>;

	/**
	 * Whether a passing test run may be skipped while its inputs are unchanged. Turn it off for suites that
	 * are not hermetic, such as ones that depend on the clock, the network or a peer process.
	 */
	public final cacheTests:Bool;

	/**
	 * Extra files a test reads at run time, absolute. Its module, the runtime, its native libraries and its
	 * own project directory are always inputs; list data that lives elsewhere.
	 */
	public final testInputs:Array<String>;

	public function new(name:String, manifestPath:String, tags:Array<String>, cacheTests:Bool = true, ?testInputs:Array<String>) {
		this.name = name;
		this.manifestPath = manifestPath;
		this.tags = tags.copy();
		this.cacheTests = cacheTests;
		this.testInputs = testInputs == null ? [] : testInputs.copy();
	}

	public function hasTag(tag:String):Bool
		return tags.indexOf(tag) >= 0;
}

/**
 * Explicit list of projects that build as one graph:
 * `{"version": 1, "buildDir": "build/workspace", "projects": [{"path": "kit/tests/haxeon.json", "name": "kit", "tags": []}]}`.
 * Paths are relative to the workspace file. Tags let a caller skip projects that need MuJoCo, a display, or CadKit.
 */
class WorkspaceManifest {
	public final path:String;
	public final root:String;
	public final buildRoot:String;
	public final projects:Array<WorkspaceProject>;

	function new(path:String, root:String, buildRoot:String, projects:Array<WorkspaceProject>) {
		this.path = path;
		this.root = root;
		this.buildRoot = buildRoot;
		this.projects = projects.copy();
	}

	public static function load(path:String):WorkspaceManifest {
		var absolute = Path.normalize(FileSystem.fullPath(path)),
			root = Path.directory(absolute),
			document:Dynamic = try Json.parse(File.getContent(absolute)) catch (error:Dynamic) throw 'Invalid workspace file $absolute: $error';
		if (Reflect.field(document, "version") != 1)
			throw 'Workspace file $absolute must declare "version": 1';
		var buildDir:Null<String> = Reflect.field(document, "buildDir"),
			entries:Null<Array<Dynamic>> = Reflect.field(document, "projects");
		if (entries == null || entries.length == 0)
			throw 'Workspace file $absolute must list at least one project';
		var projects:Array<WorkspaceProject> = [], seen = new Map<String, Bool>();
		for (entry in entries) {
			var relative:Null<String> = Reflect.field(entry, "path");
			if (relative == null || relative.length == 0)
				throw 'Every project in $absolute needs a "path"';
			var manifestPath = Path.normalize(Path.join([root, relative])),
				declaredName:Null<String> = Reflect.field(entry, "name"),
				name = declaredName == null ? defaultName(relative) : declaredName,
				tags:Null<Array<String>> = Reflect.field(entry, "tags");
			if (!FileSystem.exists(manifestPath))
				throw 'Workspace project "$name" not found: $manifestPath';
			if (seen.exists(name))
				throw 'Duplicate workspace project name "$name"';
			seen.set(name, true);
			var cache:Null<Bool> = Reflect.field(entry, "cache"),
				inputs:Null<Array<String>> = Reflect.field(entry, "inputs"),
				projectDirectory = Path.directory(manifestPath);
			projects.push(new WorkspaceProject(name, manifestPath, tags == null ? [] : tags, cache != false,
				inputs == null ? [] : [for (input in inputs) Path.normalize(Path.join([projectDirectory, input]))]));
		}
		return new WorkspaceManifest(absolute, root, Path.normalize(Path.join([root, buildDir == null ? "build/workspace" : buildDir])), projects);
	}

	/** `animkit/tests/haxeon.json` becomes `animkit/tests`. */
	static function defaultName(relative:String):String {
		var directory = Path.directory(Path.normalize(relative));
		return directory == "" ? relative : directory;
	}
}
