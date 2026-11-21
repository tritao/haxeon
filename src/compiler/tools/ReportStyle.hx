package compiler.tools;

import compiler.tools.DiagnosticPrinter.DiagnosticFormat;

/**
 * How a compile presents what it says (`--verbosity=`, `--diagnostic-format=`, `--color=`, `--diagnostic-directory=`). A build
 * gives these when the compile runs, never in the action it fingerprints, since they change no output.
 */
class ReportStyle {
	public static final DEFAULT = new ReportStyle(Verbosity.Normal, DiagnosticFormat.Short, false, null);

	public final verbosity:Verbosity;
	public final diagnosticFormat:DiagnosticFormat;
	public final color:Bool;

	/** Where the user ran the command, which the full format's paths are relative to. */
	public final directory:Null<String>;

	public function new(verbosity:Verbosity, diagnosticFormat:DiagnosticFormat, color:Bool, directory:Null<String>) {
		this.verbosity = verbosity;
		this.diagnosticFormat = diagnosticFormat;
		this.color = color;
		this.directory = directory;
	}

	public function withVerbosity(level:Verbosity):ReportStyle
		return new ReportStyle(level, diagnosticFormat, color, directory);

	/** The compiler's arguments for this style. */
	public function arguments():Array<String> {
		var result = [
			"--verbosity=" + verbosity.name(),
			"--diagnostic-format=" + diagnosticFormat,
			"--color=" + (color ? "always" : "never")
		];
		var base = directory;
		if (base != null)
			result.push("--diagnostic-directory=" + base);
		return result;
	}
}
