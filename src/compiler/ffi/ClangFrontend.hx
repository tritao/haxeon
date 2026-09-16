package compiler.ffi;

import haxe.Json;
import compiler.ffi.ClangInvocation.ClangInvocationOptions;
import compiler.ffi.ClangRecordLayouts.RecordLayout;

typedef ClangFrontendResult = {
	final ast:Dynamic;
	final layouts:Map<String, RecordLayout>;
}

/** Runs Clang once for AST semantics and once for complete record layouts. */
class ClangFrontend {
	public static function run(options:ClangInvocationOptions):ClangFrontendResult {
		var invocation = new ClangInvocation(options),
			base = invocation.arguments(),
			astProcess = ProcessOutputCapture.capture(options.clang, base.concat(["-Xclang", "-ast-dump=json", "-fsyntax-only", options.header]),
				ProcessOutputCapture.defaultDiagnosticLimit);
		if (astProcess.exitCode != 0)
			throw 'Clang could not import ${options.header}:\n${diagnostics(astProcess.stderr, astProcess.stderrTruncated)}';
		var layoutProcess = ProcessOutputCapture.capture(options.clang,
			base.concat(["-Xclang", "-fdump-record-layouts-complete", "-fsyntax-only", options.header]), null);
		if (layoutProcess.exitCode != 0)
			throw 'Clang could not calculate layouts for ${options.header}:\n${diagnostics(layoutProcess.stderr, layoutProcess.stderrTruncated)}';
		return {
			ast: Json.parse(astProcess.stdout),
			layouts: ClangRecordLayouts.parse(layoutProcess.stdout + layoutProcess.stderr)
		};
	}

	static function diagnostics(text:String, truncated:Bool):String
		return truncated ? '$text\n[Clang diagnostics truncated after ${ProcessOutputCapture.defaultDiagnosticLimit} bytes]' : text;
}
