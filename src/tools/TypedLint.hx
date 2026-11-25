package tools;

import compiler.Compiler.AnalysisResult;
import compiler.core.Diagnostic.CompileError;
import compiler.core.InternalError;
import compiler.core.Source.SourceSpan;
import compiler.modules.ModulePath;
import compiler.semantic.AliasTable.ModuleNamespaceUse;
import compiler.service.LanguageService;
import compiler.types.TypedAst.NonExceptionThrow;
import compiler.types.TypedAst.UnboundLocal;
import compiler.types.typing.TypingFailure;
import editor.lsp.ProjectWorkspace;
import haxe.io.Path;

/** One thing a typed rule reports: where, and what it says there. */
typedef TypedFinding = {
	final span:SourceSpan;
	final message:String;
}

/**
 * The lint rules that need the compiler's analysis, one per run:
 *
 * - `unbound-local`: each local whose type nothing fixes (`var x;` never assigned, `var list = []` never used with a type), which
 *   therefore settles to Dynamic, as in Haxe. The compiler gives no warning for one; this names them, so code can be audited.
 * - `module-namespace`: each module-level variable or function named through its module's name (`Settings.hits` with
 *   `import pack.Settings`), a Haxeon extension Haxe rejects (AliasTable.ModuleNamespaceUse). Haxe's forms are an import of the
 *   member or its full path, so code that must also compile with Haxe can find each use.
 * - `throw-non-exception`: each `throw` whose value's static type is not haxe.Exception or a subclass of it (a String, Dynamic, an
 *   enum), which a catch of haxe.Exception sees wrapped in a ValueException. Code that throws only exceptions never needs the wrap.
 *
 * The rules read the analysis where the editor does: each file's project is found and configured by `ProjectWorkspace` (the nearest
 * haxeon.toml, haxeon.json or .hxml) and analyzed by `LanguageService.analyze`, with the file's module as the entry. The typer records the locals it
 * settles (`TypedProgram.unboundLocals`) and the throws of a non-exception (`TypedProgram.nonExceptionThrows`), and only for bodies
 * that typed: a body whose typing failed is not reported, though the analysis that fails with it still reports the other bodies'
 * (`TypingFailure`). Module-namespace uses come from the
 * canonical code of the analyzed modules, which a failed analysis does not give. `haxeon lint` runs these in a tool of its own
 * (`LintMain`), since the command line does not link the compiler.
 */
class TypedLint {
	final service:LanguageService;
	final workspace = new ProjectWorkspace();

	/** The typed rules, by name. */
	public static final RULES = ["unbound-local", "module-namespace", "throw-non-exception"];

	final rule:String;

	/** The findings so far, by the absolute path of the file they are in, and the places already listed. */
	final found:Map<String, Array<TypedFinding>> = [];

	final seen:Map<String, Bool> = [];

	/** The modules typed so far, by configuration: a file whose module an earlier analysis typed is not analyzed again. */
	final typed:Map<String, Bool> = [];

	final reportedErrors:Map<String, Bool> = [];

	function new(rule:String, stdlib:String) {
		if (RULES.indexOf(rule) < 0)
			throw new InternalError('Unknown typed lint rule "$rule"');
		this.rule = rule;
		service = new LanguageService(null, stdlib);
	}

	/**
	 * Reports what `rule` finds in `paths` (relative ones against `base`), one line each as `path:line: ...` with the path as given,
	 * and returns 1 when it found anything or a file's program did not type, else 0. The programs are typed with the standard library
	 * at `stdlib`.
	 */
	public static function run(rule:String, paths:Array<String>, base:String, stdlib:String = "stdlib"):Int {
		var report = find(rule, paths, base, stdlib);
		for (line in report.lines)
			Sys.println(line);
		return report.lines.length > 0 || report.failed ? 1 : 0;
	}

	/** The lines `run` prints, in file order and then source order, and whether a file's program did not type. */
	public static function find(rule:String, paths:Array<String>, base:String,
			stdlib:String = "stdlib"):{
				lines:Array<String>,
				failed:Bool
			} {
		var lint = new TypedLint(rule, stdlib), failed = false, lines:Array<String> = [];
		var files = [for (path in paths) {
			display: path,
			absolute: Path.normalize(Path.isAbsolute(path) ? path : Path.join([base, path]))
		}];
		for (file in files)
			if (!lint.analyze(file.absolute))
				failed = true;
		for (file in files) {
			var findings = lint.found.get(file.absolute);
			if (findings == null)
				continue;
			lint.found.remove(file.absolute);
			findings.sort((left, right) -> left.span.start - right.span.start);
			for (finding in findings)
				lines.push('${file.display}:${finding.span.file.lineColumnAt(finding.span.start).line}: ${finding.message}');
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
				configuration.ffiIdentity, configuration.nullSafety.copy());
		if (typed.exists(scope + ":" + module))
			return true;
		try {
			var result = service.analyze(module);
			for (name in result.moduleNames)
				typed.set(scope + ":" + name, true);
			collect(findings(result));
			return true;
		} catch (failure:TypingFailure) {
			switch rule {
				case "unbound-local": collect(unbound(failure.unboundLocals));
				case "throw-non-exception": collect(nonExceptions(failure.nonExceptionThrows));
				default:
			}
			reportErrors(failure);
		} catch (error:CompileError) {
			reportErrors(error);
		}
		return false;
	}

	/** What this run's rule finds in `result`. */
	function findings(result:AnalysisResult):Array<TypedFinding>
		return switch rule {
			case "unbound-local": unbound(result.unboundLocals);
			case "throw-non-exception": nonExceptions(result.nonExceptionThrows);
			default: namespaceUses(result.moduleNamespaceUses);
		};

	static function unbound(locals:Array<UnboundLocal>):Array<TypedFinding>
		return [for (local in locals)
			{
				span: local.span, message: 'local "${local.name}" is Dynamic: nothing fixes ${local.what}'
			}];

	static function nonExceptions(throws:Array<NonExceptionThrow>):Array<TypedFinding>
		return [for (thrown in throws)
			{
				span: thrown.span,
				message: 'throw of ${thrown.thrown}, not a haxe.Exception: throw an Exception subclass'
			}];

	static function namespaceUses(uses:Array<ModuleNamespaceUse>):Array<TypedFinding>
		return [for (use in uses)
			{
				span: use.span,
				message: '"${use.written}" names ${use.member} through its module\'s name, which Haxe rejects: '
					+ 'import ${use.member} or write it in full'
			}];

	function collect(findings:Array<TypedFinding>):Void
		for (finding in findings) {
			var path = workspace.diskPath(finding.span.file.path),
				key = '$path:${finding.span.start}:${finding.message}';
			if (seen.exists(key))
				continue;
			seen.set(key, true);
			var list = found.get(path);
			if (list == null)
				found.set(path, list = []);
			list.push(finding);
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
