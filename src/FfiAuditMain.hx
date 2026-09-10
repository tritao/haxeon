import compiler.ffi.HxiAudit;
import haxe.Json;

/** Standalone cross-target C ABI auditor. */
class FfiAuditMain {
	static function main():Void {
		var targets:Array<String> = [], includes:Array<String> = [], paths:Array<String> = [], format = "text", profile:Null<String> = null;
		for (argument in Sys.args())
			if (StringTools.startsWith(argument, "--target=")) targets.push(argument.substring(9));
			else if (StringTools.startsWith(argument, "--include=")) includes.push(argument.substring(10));
			else if (StringTools.startsWith(argument, "--format=")) format = argument.substring(9);
			else if (StringTools.startsWith(argument, "--profile=")) profile = argument.substring(10);
			else if (StringTools.startsWith(argument, "--")) throw 'Unknown FFI audit option "$argument"';
			else paths.push(argument);
		if (paths.length != 1 || targets.length < 2 || (format != "text" && format != "json"))
			throw "Usage: haxeon-ffi-audit --target=<triple> --target=<triple> [--profile=portable-abi64] [--format=text|json] [--include=<dir>] <header>";
		var report = HxiAudit.audit(paths[0], targets, includes, profile);
		if (format == "json") Sys.println(Json.stringify(report, null, "  ")); else {
			Sys.println('${report.identical ? "PASS" : "FAIL"}: ${report.header} across ${report.targets.join(", ")}');
			for (issue in report.issues) Sys.println('  ${issue.target} [${issue.kind}]: ${issue.message}');
		}
		if (!report.identical) Sys.exit(1);
	}
}
