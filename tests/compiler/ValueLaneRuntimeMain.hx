import compiler.ir.IrValueLaneRuntime;
import compiler.runtime.ValueLaneNativeSource;
import sys.io.File;

/** Native and Wasm policy cannot silently diverge when the portable SSA changes. */
class ValueLaneRuntimeMain {
	static function main():Void {
		IrValueLaneRuntime.program(); // Includes full SSA and native signature verification.
		IrValueLaneRuntime.program(false);
		var expected = ValueLaneNativeSource.generate();
		if (expected != File.getContent("native/runtime/value_lane_policy.h"))
			throw "Regenerate native/runtime/value_lane_policy.h with compiler.tools.GenerateValueLaneRuntime";
		if (expected != ValueLaneNativeSource.generate()) throw "Lane policy generation must be deterministic";
		Sys.println("PASS: portable lane policy verifies and its native C artifact is current and deterministic");
	}
}
