package tools;

import compiler.core.Diagnostic.CompileError;
import compiler.modules.ModulePath;
import compiler.service.LanguageService;
import compiler.types.TypedAst.UnboundLocal;
import compiler.types.typing.TypingFailure;
import editor.lsp.ProjectWorkspace;
import haxe.io.Path;

/**
 * The lint rule `unbound-local`: each local whose type nothing fixes (`var x;` never assigned, `var list = []` never used with a
 * type), which therefore settles to Dynamic, as in Haxe. The compiler gives no warning for one; this names them, so code can be
 * audited.
 *
 * The rule needs types, so it reads them where the editor does: each file's project is found and configured by `ProjectWorkspace`
 * (the nearest haxeon.json or .hxml) and typed by `LanguageService.analyze`, with the file's module as the entry. The typer records
 * the locals it settles (`TypedProgram.unboundLocals`), and only for bodies that typed: a body whose typing failed is not reported,
 * though the analysis that fails with it still reports the other bodies' (`TypingFailure.unboundLocals`). `haxeon lint` runs it in
 * a tool of its own (`LintMain`), since the command line does not link the compiler.
 */
class UnboundLocalLint {
	final service = new LanguageService();
	final workspace = new ProjectWorkspace();

	/** The unbound locals found so far, by the absolute path of the file declaring them, and the places already listed. */
	final found:Map<String, Array<UnboundLocal>> = [];

	final seen:Map<String, Bool> = [];

	/** The modules typed so far, by configuration: a file whose module an earlier analysis typed is not analyzed again. */
	final typed:Map<String, Bool> = [];

	final reportedErrors:Map<String, Bool> = [];

	function new() {}

	/**
	 * Reports the unbound locals of `paths` (relative ones against `base`), one line each as `path:line: ...` with the path as given,
	 * and returns 1 when it found any or a file's program did not type, else 0.
	 */
	public static function run(paths:Array<String>, base:String):Int {
		var report = find(paths, base);
		for (line in report.lines)
			Sys.println(line);
		return report.lines.length > 0 || report.failed ? 1 : 0;
	}

	/** The lines `run` prints, in file order and then source order, and whether a file's program did not type. */
	public static function find(paths:Array<String>, base:String):{lines:Array<String>, failed:Bool} {
		var lint = new UnboundLocalLint(), failed = false, lines:Array<String> = [];
		var files = [for (path in paths) {
			display:path,
				absolute:Path.normalize(Path.isAbsolute(path) ? path : Path.join([base, path]))
		}];
		for (file in files)
			if (!lint.analyze(file.absolute))
				failed = true;
		for (file in files) {
			var locals = lint.found.get(file.absolute);
			if (locals == null)
				continue;
			lint.found.remove(file.absolute);
			locals.sort((left, right) -> left.span.start - right.span.start);
			for (local in locals)
				lines.push('${file.display}:${local.span.file.lineColumnAt(local.span.start).line}: local "${local.name}" is Dynamic: '
					+ 'nothing fixes ${local.what}');
		}
		return {lines: lines, failed: failed};
	}

	/** Types the program of the file at `path` unless an earlier analysis did; false when it does not type. */
	function analyze(path:String):Bool {
		workspace.includeDocument(path, service, _ -> false);
		var compilerPath = workspace.refresh(path, service, false),
			configuration = workspace.configurationFor(path),
			scope = configuration == null ? "default" : configuration.id,
			module = ModulePath.fromFile(compilerPath);
		if (configuration == null)
			service.configure("default", "default", []);
		else
			service.configure(configuration.id, configuration.scopeId, configuration.defines.copy(), configuration.ffi,
				configuration.ffiIdentity);
		if (typed.exists(scope + ":" + module))
			return true;
		try {
			var result = service.analyze(module);
			for (name in result.moduleNames)
				typed.set(scope + ":" + name, true);
			collect(result.unboundLocals);
			return true;
		} catch (failure:TypingFailure) {
			collect(failure.unboundLocals);
			reportErrors(failure);
		} catch (error:CompileError) {
			reportErrors(error);
		}
		return false;
	}

	function collect(locals:Array<UnboundLocal>):Void
		for (local in locals) {
			var path = workspace.diskPath(local.span.file.path),
				key = '$path:${local.span.start}:${local.name}';
			if (seen.exists(key))
				continue;
			seen.set(key, true);
			var list = found.get(path);
			if (list == null)
				found.set(path, list = []);
			list.push(local);
		}

	/** A program that does not type is not linted wholly: its errors go to standard error, each once. */
	function reportErrors(error:CompileError):Void
		for (diagnostic in error.diagnostics) {
			var span = diagnostic.span,
				location = span.file.lineColumnAt(span.start),
				line =
					'${workspace.diskPath(span.file.path)}:${location.line}:${location.column}: ${diagnostic.code}: ${diagnostic.message}';
			if (reportedErrors.exists(line))
				continue;
			reportedErrors.set(line, true);
			Sys.stderr().writeString('haxeon lint: cannot type: $line\n');
		}
}
