import compiler.hl.HlCode;
import compiler.hl.HlFunction;
import compiler.hl.HlFunction.HlDebugLocation;
import compiler.hl.HlFunction.HlInstruction;
import compiler.hl.HlType;
import compiler.hl.HlWriter;
import sys.io.File;

/** Exercise line runs, file changes, forward deltas and absolute line records. */
class DebugLineEncodingFixture {
	static function main():Void {
		var code = new HlCode();
		code.ints = [0];
		code.types = [Simple(HlType.I32), Function([], 0)];
		var operations:Array<HlInstruction> = [LoadInt(0, 0)];
		for (_ in 0...55) operations.push(Move(0, 0));
		operations.push(Return(0));
		var locations = [for (index in 0...operations.length) {
			var file = index == 24 ? "second.hx" : "first.hx";
			var line = index <= 20 ? 1 : index == 21 ? 32 : index == 22 ? 64 : index <= 24 ? 2 : 3;
			new HlDebugLocation(file, line, 1, line, 1, 0, -1, -1, 0);
		}];
		code.functions = [new HlFunction(1, 0, [0], operations, locations)];
		HlWriter.reportSize(code);
		File.saveBytes(Sys.args()[0], HlWriter.encode(code).flatten());
	}
}
