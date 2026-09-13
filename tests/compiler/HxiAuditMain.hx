import compiler.ffi.HxiAudit;
import compiler.ffi.HxiAbi;
import compiler.ffi.HxiParser;

class HxiAuditMain {
	static function main():Void {
		var targets = ["x86_64-linux-gnu", "x86_64-w64-windows-gnu"],
			portable = HxiAudit.audit("tests/ffi/audit_portable.h", targets, ["tests/ffi"], "portable-abi64"),
			drift = HxiAudit.audit("tests/ffi/audit_drift.h", targets, ["tests/ffi"], "portable-abi64"),
			portable32Targets = ["wasm32-unknown-wasi", "wasm32-unknown-emscripten"],
			portable32 = HxiAudit.audit("tests/ffi/audit_portable.h", portable32Targets, ["tests/ffi"], "portable-abi32");
		if (!portable.identical || portable.issues.length != 0)
			throw "portable ABI fixture should pass";
		if (drift.identical || drift.issues.length == 0 || drift.issues[0].kind != "abi-drift")
			throw "target ABI drift should be diagnosed";
		if (!portable32.identical || portable32.issues.length != 0)
			throw "portable 32-bit ABI fixture should pass";
		var wrongWidth = HxiAudit.audit("tests/ffi/audit_portable.h", ["x86_64-linux-gnu", "i686-linux-gnu"], ["tests/ffi"], "portable-abi64");
		if (wrongWidth.identical || wrongWidth.issues.filter(issue -> issue.kind == "non-portable-target").length != 1)
			throw "portable-abi64 should reject 32-bit targets";
		var canonical = HxiParser.parse("canonical.hxi", HxiAudit.canonical("tests/ffi/audit_portable.h", targets[0], ["tests/ffi"]));
		if (canonical.target != "portable-abi64" || HxiAbi.forInterface(canonical).pointerBits != 64)
			throw "canonical audit output should carry the portable 64-bit target contract";
		var canonical32 = HxiParser.parse("canonical32.hxi",
			HxiAudit.canonical("tests/ffi/audit_portable.h", portable32Targets[0], ["tests/ffi"], null, null, null, null, null, "portable-abi32"));
		if (canonical32.target != "portable-abi32" || HxiAbi.forInterface(canonical32).pointerBits != 32)
			throw "canonical audit output should carry the portable 32-bit target contract";
		if (canonical.documentation.get("audit_open").raw.indexOf("fixture handle") < 0)
			throw "canonical audit output should preserve Doxygen comments";
		Sys.println("PASS: C header ABI audit compares normalized target models");
	}
}
