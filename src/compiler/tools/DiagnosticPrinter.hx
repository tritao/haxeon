package compiler.tools;

import compiler.core.Diagnostic;
import compiler.core.Source.SourceSpan;
import haxe.io.Path;
import sys.FileSystem;

/** How a compile prints its diagnostics (`--diagnostic-format=`). */
enum abstract DiagnosticFormat(String) to String {
	/** One line each, `Main.hx:2:14: E1002: message`, the path under its source root: what tools and tests read. The default. */
	var Short = "short";

	/** For people: `src/Main.hx:2:14: error[E1002]: message`, the path from `--diagnostic-directory`, the line with a caret, and a count. */
	var Full = "full";

	public static final NAMES = ["short", "full"];

	public static function parse(name:String):Null<DiagnosticFormat>
		return switch name {
			case "short": Short;
			case "full": Full;
			case _: null;
		};
}

/** Renders a compile's diagnostics in the format its request asks for. */
class DiagnosticPrinter {
	static inline final RESET = "\x1b[0m";
	static inline final BOLD = "\x1b[1m";
	static inline final RED = "\x1b[1;31m";
	static inline final YELLOW = "\x1b[1;33m";
	static inline final BLUE = "\x1b[1;34m";
	static inline final TAB_WIDTH = 4;

	final request:CompilerRequest;
	var physicalPaths:Null<Map<String, String>> = null;

	public function new(request:CompilerRequest)
		this.request = request;

	/** Diagnostics that failed the compile; the full format ends them with how many errors there were. */
	public function errors(diagnostics:Array<Diagnostic>):String {
		if (request.diagnosticFormat == DiagnosticFormat.Short)
			return [for (item in diagnostics) item.format()].join("\n");
		var count = 0;
		for (item in diagnostics)
			if (item.severity == DiagnosticSeverity.Error)
				count++;
		return [for (item in diagnostics) render(item)].join("\n\n") + "\n\n"
			+ paint(BOLD, count == 1 ? "1 error" : '$count errors');
	}

	/** One diagnostic that did not fail the compile, a warning. */
	public function warning(diagnostic:Diagnostic):String
		return request.diagnosticFormat == DiagnosticFormat.Short ? diagnostic.format() : render(diagnostic) + "\n";

	function render(diagnostic:Diagnostic):String {
		var error = diagnostic.severity == DiagnosticSeverity.Error,
			accent = error ? RED : YELLOW,
			label = paint(accent, (error ? "error" : "warning") + "[" + diagnostic.code + "]") + ": "
				+ paint(BOLD, diagnostic.message),
			span = diagnostic.span;
		if (span == null || span.file.text.length == 0)
			return label;
		var location = span.file.lineColumnAt(span.start);
		return paint(BOLD, '${displayPath(span.file.path)}:${location.line}:${location.column}:') + " " + label + "\n"
			+ snippet(span, location.line, location.column, accent);
	}

	/** The span's first line, its tabs expanded, with carets under the span (to the line's end when it goes on). */
	function snippet(span:SourceSpan, line:Int, column:Int, accent:String):String {
		var bytes = span.file.bytes,
			lineStart = span.start - (column - 1),
			lineEnd = lineStart;
		while (lineEnd < bytes.length && bytes.get(lineEnd) != "\n".code && bytes.get(lineEnd) != "\r".code)
			lineEnd++;
		var spanEnd = span.end > lineEnd ? lineEnd : (span.end < span.start ? span.start : span.end),
			before = expandTabs(bytes.getString(lineStart, span.start - lineStart), 0),
			marked = expandTabs(bytes.getString(span.start, spanEnd - span.start), before.length),
			after = expandTabs(bytes.getString(spanEnd, lineEnd - spanEnd), before.length + marked.length),
			number = Std.string(line),
			gutter = StringTools.lpad("", " ", number.length);
		return paint(BLUE, ' $number | ') + before + marked + after + "\n" + paint(BLUE, ' $gutter | ')
			+ StringTools.lpad("", " ", before.length) + paint(accent,
			StringTools.lpad("", "^", marked.length < 1 ? 1 : marked.length));
	}

	/** `text` with each tab replaced by the spaces to the next stop, for text that starts at display column `column`. */
	static function expandTabs(text:String, column:Int):String {
		if (text.indexOf("\t") < 0)
			return text;
		var result = new StringBuf(), position = column;
		for (index in 0...text.length) {
			var character = text.charAt(index);
			if (character == "\t") {
				var width = TAB_WIDTH - (position % TAB_WIDTH);
				result.add(StringTools.lpad("", " ", width));
				position += width;
			} else {
				result.add(character);
				position++;
			}
		}
		return result.toString();
	}

	function paint(style:String, text:String):String
		return request.color ? style + text + RESET : text;

	/**
	 * Where a diagnostic's file is, as the user names it: diagnostics carry the path under its source root, so this finds the
	 * file the request compiled, and gives it relative to `--diagnostic-directory` when it lies below that.
	 */
	function displayPath(projectPath:String):String {
		var mapped = physicalPaths;
		if (mapped == null) {
			mapped = [];
			for (path in request.paths)
				mapped.set(SourceManifestLoader.projectPath(path, request.roots, request.packageRoots), path);
			physicalPaths = mapped;
		}
		var physical = mapped.get(projectPath);
		if (physical == null) {
			var standard = Path.join([request.stdlib, projectPath]);
			physical = !Path.isAbsolute(projectPath) && FileSystem.exists(standard) ? standard : projectPath;
		}
		var directory = request.diagnosticDirectory;
		if (directory == null || !FileSystem.exists(physical))
			return physical;
		var full = Path.normalize(FileSystem.fullPath(physical)),
			base = Path.removeTrailingSlashes(Path.normalize(directory));
		return StringTools.startsWith(full, base + "/") ? full.substr(base.length + 1) : full;
	}
}
