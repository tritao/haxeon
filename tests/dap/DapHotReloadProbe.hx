import compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.Compiler; // @formatter:off: the DAP tests address this file by line
import compiler.hl.HlWriter;
import runtime.PatchSet;
import runtime.Runtime;

class DapHotReloadProbe {
	static function disposeLoaded(loaded:runtime.LoadedModule):Void
		Runtime.dispose(loaded);

	// Where a DAP driver breaks to look at the module before the probe goes on (the DAP hot-reload test). The runtime itself needs no
	// pause: loading, patching and retiring a module each wait for the attached debugger to acknowledge the change.
	static function checkpoint(stage:String):Void {}

	static function main() {
		var compiler = new Compiler();
		compiler.update("Value.hx",
			"function value():Int {\n  var result = 42;\n  if (true) {\n    var scoped = result + 100;\n    result = scoped - 99;\n    scoped = scoped + 0;\n  }\n  result = result - 1;\n  try {\n    throw \"patched-probe\";\n  } catch (error:Int) {\n    result = 0;\n  } catch (error:String) {\n    result = result + 0;\n  }\n  return result;\n}");
		compiler.update("Main.hx", "function main():Int { return Value.value(); }");
		var initial = compiler.compile("Main");
		var functionIndex = BackendArtifacts.hashLink(initial.artifact).functionIds.get("Value.value");
		var loaded = Runtime.load(HlWriter.encode(BackendArtifacts.hashLink(initial.artifact).module).flatten(), BackendArtifacts.hashLink(initial.artifact).runtimeIdentity);
		checkpoint("loaded");
		var initialValue = Runtime.callInt(loaded, functionIndex);

		compiler.update("Value.hx",
			StringTools.replace("function value():Int {\n  var result = 43;\n  if (true) {\n    var scoped = result + 100;\n    result = scoped - 99;\n    scoped = scoped + 0;\n  }\n  result = result - 1;\n  try {\n    throw \"patched-probe\";\n  } catch (error:Int) {\n    result = 0;\n  } catch (error:String) {\n    result = result + 0;\n  }\n  return result;\n}",
				"\n  ", "\n    "));
		var changed = compiler.compile("Main");
		compiler.update("Value.hx",
			StringTools.replace("function value():Int {\n  var result = 44;\n  if (true) {\n    var scoped = result + 100;\n    result = scoped - 99;\n    scoped = scoped + 0;\n  }\n  result = result - 1;\n  try {\n    throw \"patched-probe\";\n  } catch (error:Int) {\n    result = 0;\n  } catch (error:String) {\n    result = result + 0;\n  }\n  return result;\n}",
				"\n  ", "\n    "));
		var changedAgain = compiler.compile("Main");
		Runtime.patchSet(loaded, new PatchSet(initial.revision, changed.revision, BackendArtifacts.hashLink(changed.artifact).patchBytes, changed.changedFunctions));
		checkpoint("patched");
		var patchedValue = Runtime.callInt(loaded, functionIndex);

		Runtime.patchSet(loaded, new PatchSet(changed.revision, changedAgain.revision, BackendArtifacts.hashLink(changedAgain.artifact).patchBytes, changedAgain.changedFunctions));
		checkpoint("patchedAgain");
		var patchedAgainValue = Runtime.callInt(loaded, functionIndex);
		disposeLoaded(loaded);
		Runtime.retryRetirements();
		checkpoint("retired");
		Sys.println('$initialValue -> $patchedValue -> $patchedAgainValue');
	}
}
