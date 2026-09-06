import compiler.Compiler;
import compiler.hl.HlWriter;
import runtime.PatchSet;
import runtime.Runtime;

class DapHotReloadProbe {
	static function main() {
		var compiler = new Compiler();
		compiler.update("Value.hx",
			"function value():Int {\n  var result = 42;\n  if (true) {\n    var scoped = result + 100;\n    result = scoped - 99;\n    scoped = scoped + 0;\n  }\n  result = result - 1;\n  try {\n    throw \"patched-probe\";\n  } catch (error:Int) {\n    result = 0;\n  } catch (error:String) {\n    result = result + 0;\n  }\n  return result;\n}");
		compiler.update("Main.hx", "function main():Int { return Value.value(); }");
		var initial = compiler.compile("Main");
		var functionIndex = initial.functionIds.get("Value.value");
		var loaded = Runtime.load(HlWriter.encode(initial.module), initial.runtimeIdentity);
		for (gate in 0...100)
			Sys.sleep(0.02);
		var initialValue = Runtime.callInt(loaded, functionIndex);

		compiler.update("Value.hx",
			"function value():Int {\n  var result = 43;\n  if (true) {\n    var scoped = result + 100;\n    result = scoped - 99;\n    scoped = scoped + 0;\n  }\n  result = result - 1;\n  try {\n    throw \"patched-probe\";\n  } catch (error:Int) {\n    result = 0;\n  } catch (error:String) {\n    result = result + 0;\n  }\n  return result;\n}");
		var changed = compiler.compile("Main");
		Runtime.patchSet(loaded, new PatchSet(initial.revision, changed.revision, changed.patchBytes, changed.changedFunctions));
		for (gate in 0...100)
			Sys.sleep(0.02);
		var patchedValue = Runtime.callInt(loaded, functionIndex);
		Sys.println('$initialValue -> $patchedValue');
	}
}
