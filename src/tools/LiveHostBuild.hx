package tools;

import build.AotCompiler;
import build.BuildScope;
import build.BuildSession;
import build.HaxeonProjectBuild;
import build.HaxeonSdk;
import compiler.core.InternalError;
import compiler.core.Source.SourceFile;
import compiler.syntax.ConditionalCompilation;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.tools.ReportStyle;
import haxe.Json;
import haxe.io.Path;
import project.ProjectDiscovery;
import project.ResolvedProject;
import sys.FileSystem;
import sys.io.File;

/**
 * The live development host (`tools.LiveHost`) that `haxeon run --watch` runs an app in when it can host it
 * (`missingEntryPoints`): a module built with Haxeon from the compiler's sources, in the ordinary flavor or, under
 * `--profile`, the instrumented one, so a capture shows the host's polling and patching beside the app's calls. A release
 * ships both beside its VM (`AotCompiler.shipped`, which `haxeon dev package` builds with `build`), as it has no sources to
 * build them from; a checkout builds the one it needs.
 */
class LiveHostBuild {
	/** The name of a flavor's host beside the VM. */
	public static function name(instrument:Bool):String
		return instrument ? "haxeon-live-host-instrument.hl" : "haxeon-live-host.hl";

	/** The host to run: the one beside the SDK's VM while it is current, else one built from the SDK's checkout. */
	public static function program(home:String, jobs:Int, instrument:Bool, ?session:BuildSession,
			?style:ReportStyle):String {
		var shipped = AotCompiler.currentShipped(home, name(instrument), null,
			session == null ? null : session.digests);
		return shipped != null ? shipped : build(home, jobs, instrument, session, style);
	}

	/**
	 * Builds the host from the sources of the SDK's checkout, as a project of its own under the checkout's `out/live-host`, and
	 * returns the module.
	 */
	public static function build(home:String, jobs:Int, instrument:Bool, ?session:BuildSession,
			?style:ReportStyle):String {
		var source = HaxeonSdk.requireSource(home, "Building the live development host"),
			root = Path.join([source, "out", "live-host"]),
			manifestPath = Path.join([root, "haxeon.json"]);
		FileSystem.createDirectory(root);
		var manifest = Json.stringify({
			version: 1,
			"package": {name: "haxeon-live-host"},
			entry: "tools.LiveHost",
			sourceRoots: [Path.join([source, "src"])],
			scopeSourceRoots: false,
			target: "host",
			outputDir: "build"
		}, null, "  ");
		if (!FileSystem.exists(manifestPath) || File.getContent(manifestPath) != manifest)
			File.saveContent(manifestPath, manifest);
		var project = ProjectDiscovery.resolve(manifestPath),
			output = Path.join([HaxeonProjectBuild.outputDirectory(project, instrument), "host", "live-host.hl"]);
		if (HaxeonProjectBuild.build(project, home, output, [], jobs, false, false, false, 0.0, false, BuildScope.Full,
			false,
			instrument, session, true, null, null, style) != 0)
			throw new InternalError("Could not build the live development host");
		return output;
	}

	/**
	 * The entry points the live host calls (`LiveEntryPoints.REQUIRED`) that the project's entry class does not declare as static
	 * functions; `haxeon run --watch` patches the app in the live host when none is missing, and relaunches it otherwise. They are
	 * read from the entry module's source, with no defines set, before anything is built; a module the source roots do not hold,
	 * or one that does not parse, is missing them all.
	 */
	public static function missingEntryPoints(project:ResolvedProject):Array<String> {
		var entry = project.manifest.entry, declared:Array<String> = [];
		if (entry != null) {
			var parts = entry.split("."),
				name = parts[parts.length - 1],
				module = parts.join("/") + ".hx";
			for (root in project.rootPackage.sourceRoots) {
				var path = Path.join([root, module]);
				if (!FileSystem.exists(path))
					continue;
				try {
					var file = new SourceFile(path, File.getContent(path)),
						program =
							new Parser(new Lexer(new SourceFile(path,
							ConditionalCompilation.process(file, [], false).text))
							.tokenize()).parseProgram();
					// A module's own functions are static functions of the class named like it.
					for (method in program.functions)
						declared.push(method.name);
					for (declaration in program.classes)
						if (declaration.name == name)
							for (method in declaration.methods)
								if (method.isStatic)
									declared.push(method.name);
				} catch (_:Dynamic)
					declared = [];
				break;
			}
		}
		return [for (point in LiveEntryPoints.REQUIRED) if (declared.indexOf(point) < 0) point];
	}
}
