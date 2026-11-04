// HashLink retains a per-thread exception stack. A cleanup failure must not replace the primary stack.
function primaryFailure():Void {
 throw "primary";
}

function cleanupFailure():Void {
 throw "cleanup";
}

function unwind():Void {
 defer cleanupFailure();
 primaryFailure();
}

function unwindHandledFailure():Void {
 defer {
  try cleanupFailure() catch (_:Dynamic) {}
 }
 primaryFailure();
}

function nestedFailure():Void {
 defer cleanupFailure();
 throw "nested";
}

function unwindNestedFailure():Void {
 defer {
  try nestedFailure() catch (_:Dynamic) {}
 }
 primaryFailure();
}

function retainsPrimaryStack(run:Void->Void):Bool {
 try {
  run();
 } catch (error:Dynamic) {
  #if wasm
  // Wasm does not currently expose exception stacks.
  return error == "primary";
  #else
  var stack = haxe.CallStack.toString(haxe.CallStack.exceptionStack());
  return error == "primary" && stack.indexOf("primaryFailure") >= 0 && stack.indexOf("cleanupFailure") < 0;
  #end
 }
 return false;
}

function main():Int {
 if (!retainsPrimaryStack(unwind)) return 1;
 if (!retainsPrimaryStack(unwindHandledFailure)) return 2;
 if (!retainsPrimaryStack(unwindNestedFailure)) return 3;
 return 42;
}
