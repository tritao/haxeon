import compiler.Compiler;
import compiler.ir.IrInterpreter;
import compiler.ir.IrVerifier;

class EnumInterfaceIncrementalMain {
 static function main():Void {
  var compiler = new Compiler();
  compiler.update("Probe.hx", "interface Probe { function read():Int; }");
  compiler.update("Mode.hx", "enum Mode implements Probe { Value; public function read():Int return 1; }");
  compiler.update("Main.hx", "function read(value:Probe):Int return value.read(); function main():Int return read(Mode.Value);");
  var first = compiler.compile("Main");
  IrVerifier.verify(first.ir);
  if (new IrInterpreter(first.ir).run("main") != 1) throw "Initial enum interface dispatch returned the wrong value";
  compiler.update("Mode.hx", "enum Mode implements Probe { Value; public function read():Int return 2; }");
  var changed = compiler.compile("Main");
  IrVerifier.verify(changed.ir);
  if (new IrInterpreter(changed.ir).run("main") != 2) throw "Enum interface adapter retained a stale method";
  Sys.println("PASS: enum interface adapters follow incremental method changes");
 }
}
