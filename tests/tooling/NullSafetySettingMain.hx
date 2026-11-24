import build.BuildEnvironment;
import build.BuildIntent;
import build.BuildPlanner;
import build.NativeArtifactDemand.NativeArtifactDemand;
import build.TargetLayout;
import build.execution.ExecutionPlan;
import build.lowering.LoweringContext;
import build.lowering.PlanLowerer;
import compiler.CompileOptions;
import compiler.NullSafetyRule.NullSafetyMode;
import compiler.service.LanguageService;
import editor.lsp.ProjectWorkspace;
import haxe.io.Path;
import haxeon.io.FileTree;
import project.CompilerInputs;
import project.PackageManifest;
import project.ProjectDiscovery;
import sys.FileSystem;
import sys.io.File;
import tools.HaxeArguments;

/**
 * A project's `nullSafety` setting: read from haxeon.toml and haxeon.json, made into rules on each package's own paths, passed to
 * the compile as `--null-safety=` flags; and Haxe command lines' `--macro nullSafety(...)`, the one macro Haxeon takes.
 */
class NullSafetySettingMain {
	static function main():Void {
		testManifest();
		testCompilerInputs();
		testHaxeMacro();
		Sys.println("PASS: null-safety settings are read, derived per package, and passed to the compiler");
	}

	static function testManifest():Void {
		function mode(path:String, content:String):NullSafetyMode
			return PackageManifest.parse(path, content).nullSafety;
		var toml = 'version = 1\nentry = "Main"\n', json = '{"version":1,"entry":"Main"';
		expect(mode("app/haxeon.toml", toml + 'nullSafety = "strict"\n') == NullSafetyMode.Strict, "TOML strict");
		expect(mode("app/haxeon.toml", toml + 'nullSafety = "warn"\n') == NullSafetyMode.Warn, "TOML warn");
		expect(mode("app/haxeon.toml", toml) == NullSafetyMode.Off, "an absent setting is off");
		expect(mode("app/haxeon.json", json + ',"nullSafety":"loose"}') == NullSafetyMode.Loose, "JSON loose");
		expect(mode("app/haxeon.json", json + ',"nullSafety":"off"}') == NullSafetyMode.Off, "JSON off");
		for (bad in ['"strict-threaded"', '"yes"', 'true'])
			expect(failure(() -> mode("app/haxeon.json", json + ',"nullSafety":$bad}'))
				.indexOf('"nullSafety" must be one of "strict", "loose", "off", "warn"') >= 0,
				'a manifest refuses nullSafety $bad, naming the valid values');
		var migrated = PackageManifest.migrateToToml("app/haxeon.json", json + ',"inline":false,"nullSafety":"warn"}');
		expect(migrated.indexOf('nullSafety = "warn"') >= 0
			&& migrated.indexOf("inline") < migrated.indexOf("nullSafety"),
			"migrate keeps the setting, after inline: " + migrated);
	}

	static function testCompilerInputs():Void {
		var root = temporaryDirectory("null-safety-inputs"),
			app = Path.join([root, "app"]),
			lib = Path.join([root, "lib"]),
			plain = Path.join([root, "plain"]);
		// The root package is unscoped (its entry is outside it): a rule per top-level entry of its root.
		write(app, "haxeon.toml",
			'version = 1\nentry = "Main"\nsourceRoots = ["src"]\nnullSafety = "strict"\n\n[package]\nname = "app"\n\n'
			+ '[dependencies]\nlib = { path = "../lib" }\nplain = { path = "../plain" }\n');
		for (file in ["src/Main.hx", "src/Util.hx", "src/ui/Button.hx", "src/ui/widgets/Slider.hx"])
			write(app, file, "\n");
		// A dependency is scoped: its package name, and each top-level entry of its unscoped root.
		write(lib, "haxeon.json",
			'{"version":1,"package":{"name":"lib"},"sourceRoots":["src","examples"],"unscopedSourceRoots":["examples"],"nullSafety":"warn"}');
		write(lib, "src/Value.hx", "\n");
		write(lib, "examples/Example.hx", "\n");
		write(plain, "haxeon.json", '{"version":1,"package":{"name":"plain"},"sourceRoots":["src"]}');
		write(plain, "src/Plain.hx", "\n");
		var project = ProjectDiscovery.discover(Path.join([app, "haxeon.toml"])),
			environment = new BuildEnvironment(project.root, Path.join([project.root, "build"])),
			layout = new TargetLayout(environment),
			inputs = CompilerInputs.of(project, layout),
			rules = [for (rule in inputs.nullSafety) rule.argument()];
		// Packages come dependencies first; `plain` says nothing, so it has no rule.
		expect(rules.join(" ") == "warn:lib warn:Example strict:Main strict:Util strict:ui",
			"each package's rules cover its own paths: " + rules.join(" "));
		var output = layout.hashLinkModulePath("main");
		function compileArguments(selfHosted:Bool):Array<String> {
			var plan:ExecutionPlan = PlanLowerer.lower(BuildPlanner.project(project, BuildIntent.Build,
				environment.target,
				NativeArtifactDemand.Shared),
				new LoweringContext(environment, null, project, output, build.HaxeonSdk.current(), null,
				selfHosted));
			for (action in plan.actions)
				switch action.action {
					case Compiler(_, arguments, _, _, _):
						return arguments;
					default:
				}
			throw "the plan has no compile";
		}
		function nullSafetyFlags(selfHosted:Bool):Array<String>
			return [for (argument in compileArguments(selfHosted)) if (StringTools.startsWith(argument,
				"--null-safety=")) argument];
		var flags = nullSafetyFlags(false);
		expect(flags.join(" ")
			== "--null-safety=warn:lib --null-safety=warn:Example --null-safety=strict:Main --null-safety=strict:Util --null-safety=strict:ui",
			"the compile request passes the rules: " + flags.join(" "));
		expect(CompileOptions.fromArguments(flags).nullSafety.length == 5, "the compiler reads the flags back");
		expect(nullSafetyFlags(true).join(" ") == flags.join(" "),
			"a self-hosted compile, by the bootstrap compiler, passes the same rules");
		// The editor's compiler gets the same rules, so it reports what the build reports.
		var service = new LanguageService(), workspace = new ProjectWorkspace();
		workspace.initialize({rootUri: "file://" + app}, service);
		var configuration = workspace.configurationFor(Path.join([app, "src", "Main.hx"]));
		expect(configuration != null
			&& [for (rule in configuration.nullSafety) rule.argument()].join(" ") == rules.join(" "),
			"the language server's configuration has the build's rules");
		service.configure(configuration.id, configuration.scopeId, configuration.defines.copy(), configuration.ffi,
			configuration.ffiIdentity, configuration.nullSafety.copy());
		expect(service.compiler.options.nullSafety.length == 5, "the language service's compiler takes them");
		FileTree.remove(root);
	}

	static function testHaxeMacro():Void {
		function rule(call:String):String {
			var parsed = HaxeArguments.nullSafetyMacro(call);
			return parsed == null ? "none" : parsed.argument();
		}
		expect(rule('nullSafety("app", Strict)') == "strict:app", "a package in double quotes");
		expect(rule("haxe.macro.Compiler.nullSafety('pkg.sub', StrictThreaded, false)")
			== "strict-threaded:pkg.sub:shallow",
			"the qualified call, single quotes, not recursive");
		expect(rule("nullSafety('pkg')") == "loose:pkg", "the mode defaults to Loose, recursive");
		expect(rule('nullSafety("")') == "loose", "the empty path is everything");
		expect(rule("nullSafety('app.Main', NullSafetyMode.Off, true)") == "off:app.Main", "a qualified mode");
		expect(rule("nullSafety('app', haxe.macro.Compiler.NullSafetyMode.Strict)") == "strict:app",
			"a fully qualified mode");
		for (other in [
			"include('app')",
			"nullSafety('app', Bogus)",
			"nullSafety('a-b', Strict)",
			"nullSafety(app, Strict)",
			"nullSafety('app', Strict, maybe)",
			"keep('app')"
		])
			expect(rule(other) == "none", 'not the null-safety macro: $other');
		var directory = temporaryDirectory("null-safety-macro"),
			compilation = HaxeArguments.parse([
				"-cp", "src", "-main", "Main", "--hl", "out.hl", "--macro", 'nullSafety("app", Strict)', "--macro",
				"haxe.macro.Compiler.nullSafety('lib.sub', Loose, false)"
			], directory)[0];
		expect([for (rule in compilation.nullSafety) rule.argument()].join(" ") == "strict:app loose:lib.sub:shallow",
			"a compilation carries its rules in order");
		expect(HaxeArguments.parse(["-main", "Main"], directory)[0].nullSafety.length == 0,
			"a command line is off by default");
		var message = failure(() -> HaxeArguments.parse(["-main", "Main", "--macro", "include('app')"], directory));
		expect(message.indexOf("--macro include('app')") >= 0, "another macro is still unsupported: " + message);
		FileTree.remove(directory);
	}

	static function failure(run:() -> Void):String {
		try {
			run();
		} catch (error:Dynamic)
			return Std.string(error);
		return "";
	}

	static function write(root:String, path:String, content:String):Void {
		var absolute = Path.join([root, path]);
		FileSystem.createDirectory(Path.directory(absolute));
		File.saveContent(absolute, content);
	}

	static function temporaryDirectory(name:String):String {
		var base = Sys.getEnv("TMPDIR");
		if (base == null || base == "")
			base = Sys.getEnv("TEMP");
		if (base == null || base == "")
			base = ".";
		var path = Path.join([base, 'haxeon-$name-${Std.string(Date.now().getTime())}']);
		FileTree.remove(path);
		FileSystem.createDirectory(path);
		return FileSystem.fullPath(path);
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
