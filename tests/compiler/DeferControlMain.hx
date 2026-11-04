import compiler.Frontend;
import compiler.Diagnostic.CompileError;

class DeferControlMain {
 static function reject(source:String):Void {
  try Frontend.compile(source) catch (error:CompileError) {
   if (error.diagnostic.code != "E1019") throw error;
   return;
  }
  throw "Nonlocal control transfer from deferred code was accepted";
 }
 static function main():Void {
  reject('function main():Int { defer { return 1; } return 42; }');
  reject('function main():Int { while (true) { defer { break; } break; } return 42; }');
  reject('function main():Int { while (true) { defer { continue; } break; } return 42; }');
  reject('function main():Int { defer { var value = { return 1; 0; }; } return 42; }');
  Frontend.compile('function main():Int { defer { var f = function():Int { return 1; }; f(); while (true) { break; } } return 42; }');
  var guardedBegin:compiler.ir.Ir.IrInstruction = BeginTry(3, 4, true);
  var guardedEnd:compiler.ir.Ir.IrInstruction = EndTry(3, true);
  for (instruction in [guardedBegin, guardedEnd]) {
   var decoded = compiler.ir.codec.IrInstructionCodec.decode(compiler.ir.codec.IrInstructionCodec.encode(instruction), []);
   if (Std.string(decoded) != Std.string(instruction)) throw "Cleanup guard did not survive IR serialization";
  }
  var out = new compiler.ir.Ir.IrValue(1, "result", compiler.ir.Ir.IrType.Void);
  var receiver = new compiler.ir.Ir.IrValue(2, "receiver", compiler.ir.Ir.IrType.Obj("Resource"));
  var terminal:compiler.ir.Ir.IrInstruction = MethodCall(out, receiver, "dispose", [], true);
  var values:Map<Int, compiler.ir.Ir.IrValue> = [1 => out, 2 => receiver];
  var restored = compiler.ir.codec.IrInstructionCodec.decode(compiler.ir.codec.IrInstructionCodec.encode(terminal), values);
  if (Std.string(restored) != Std.string(terminal)) throw "Terminal disposal did not survive IR serialization";
  Sys.println('PASS: deferred control transfers stay inside their own body');
 }
}
