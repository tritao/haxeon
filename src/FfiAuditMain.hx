import compiler.ffi.HxiAudit;
import haxe.Json;
import sys.FileSystem;
import sys.io.File;

/** Standalone cross-target C ABI auditor. */
class FfiAuditMain {
	static function main():Void {
		var targets:Array<String> = [], includes:Array<String> = [], paths:Array<String> = [], format = "text", profile:Null<String> = null,
			output:Null<String> = null, library:Null<String> = null, interfaceName:Null<String> = null;
		for (argument in Sys.args())
			if (StringTools.startsWith(argument, "--target=")) targets.push(argument.substring(9));
			else if (StringTools.startsWith(argument, "--include=")) includes.push(argument.substring(10));
			else if (StringTools.startsWith(argument, "--format=")) format = argument.substring(9);
			else if (StringTools.startsWith(argument, "--profile=")) profile = argument.substring(10);
			else if (StringTools.startsWith(argument, "--output=")) output = argument.substring(9);
			else if (StringTools.startsWith(argument, "--library=")) library = argument.substring(10);
			else if (StringTools.startsWith(argument, "--interface=")) interfaceName = argument.substring(12);
			else if (StringTools.startsWith(argument, "--")) throw 'Unknown FFI audit option "$argument"';
			else paths.push(argument);
		if (paths.length != 1 || targets.length < 2 || (format != "text" && format != "json"))
			throw "Usage: haxeon-ffi-audit --target=<triple> --target=<triple> [--profile=portable-abi64] [--format=text|json] [--output=<file>] [--library=<name>] [--interface=<name>] [--include=<dir>] <header>";
		var report = HxiAudit.audit(paths[0], targets, includes, profile, library, interfaceName);
		if (format == "json") Sys.println(Json.stringify(report, null, "  ")); else {
			Sys.println('${report.identical ? "PASS" : "FAIL"}: ${report.header} across ${report.targets.join(", ")}');
			for (issue in report.issues) Sys.println('  ${issue.target} [${issue.kind}]: ${issue.message}');
		}
		if (!report.identical) Sys.exit(1);
		if (output != null) {
			var temporary = output + ".tmp." + Std.int(Sys.time() * 1000000);
			File.saveContent(temporary, HxiAudit.canonical(paths[0], targets[0], includes, library, interfaceName));
			FileSystem.rename(temporary, output);
			Sys.println('wrote canonical ABI -> $output');
		}
	}
}
