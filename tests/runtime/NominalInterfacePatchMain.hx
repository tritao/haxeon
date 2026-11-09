import compiler.Compiler;
import compiler.hl.HlWriter;
import runtime.PatchSet;
import runtime.Runtime;

class NominalInterfacePatchMain {
 static function configuredCompiler():Compiler {
  var result=new Compiler(null,compiler.runtime.CompilerIntrinsics.configuration());
  result.addStandardLibrarySourceRoot("stdlib");
  return result;
 }
 static function contract(version:Int):String return
  "interface BaseReader { function score():Int; }\n" +
  "interface Reader extends BaseReader {}\n" +
  "interface Other { function score():Int; }\n" +
  'function contractVersion():Int return $version;\n';
 static function source(extra:Bool, version:Int):String return
  "import Contract.Reader; import Contract.BaseReader; import Contract.Other; import Contract.contractVersion;\n" +
  "class Owner implements Reader { public var saved:Reader; public function new() { saved=this; } public function score():Int return 7; }\n" +
  (extra ? "class Added implements Reader { public function new() {} public function score():Int return 9; }\n" : "") +
  "function make():Owner return new Owner();\n" +
  "function probe(value:Dynamic):Int {\n" +
  " if (!Std.isOfType(value, Reader) || !Std.isOfType(value, BaseReader)) return 1;\n" +
  " if (Std.isOfType(value, Other)) return 2;\n" +
  " var cached:Reader=cast Reflect.field(value,\"saved\"); if (!Std.isOfType(cached,Reader) || !Std.isOfType(cached,BaseReader) || Std.isOfType(cached,Other)) return 4;\n" +
  " var view:Reader=cast value;\n" +
  ' return view.score()==7 && contractVersion()==$version ? 42 : 3;\n}\n' +
  (extra ? "function added():Int { var value:Dynamic=new Added(); if (!Std.isOfType(value,Reader) || Std.isOfType(value,Other)) return 1; var view:Reader=cast value; return view.score()==9?42:2; }\n" : "") +
  "function main():Int return probe(make())" +
  (extra ? "+(added()==42?0:10)" : "") + ";\n";
 static function main():Void {
  var compiler=configuredCompiler();
  compiler.update("Contract.hx",contract(1)); compiler.update("Main.hx",source(false,1));
  var first=compiler.compile("Main"), live=Runtime.load(HlWriter.encode(first.module),first.runtimeIdentity);
  var retained=Runtime.retainObject(live,first.functionIds.get("Main.make"));
  if(Runtime.callIntObject(live,first.functionIds.get("Main.probe"),retained)!=42) throw "Initial conformance failed";
  compiler.update("Contract.hx",contract(2)); compiler.update("Main.hx",source(false,2));
  var changed=compiler.compile("Main");
  if(changed.requiresReload || changed.patchBytes==null) throw "Re-emitting the interface module required reload";
  Runtime.patchSet(live,new PatchSet(first.revision,changed.revision,changed.patchBytes,changed.changedFunctions));
  if(Runtime.callIntObject(live,changed.functionIds.get("Main.probe"),retained)!=42) throw "Pre-patch object lost conformance";
  compiler.update("Main.hx",source(true,2)); var appended=compiler.compile("Main");
  if(appended.requiresReload || appended.patchBytes==null) throw "Added implementation required reload";
  Runtime.patchSet(live,new PatchSet(changed.revision,appended.revision,appended.patchBytes,appended.changedFunctions));
  if(Runtime.callIntObject(live,appended.functionIds.get("Main.probe"),retained)!=42 || Runtime.callInt(live,appended.functionIds.get("main"))!=42)
   throw "Appending an implementation changed interface identity";
  Runtime.dispose(live);
  var freshCompiler=configuredCompiler(); freshCompiler.update("Contract.hx",contract(3)); freshCompiler.update("Main.hx",source(true,3));
  var fresh=freshCompiler.compile("Main"), reloaded=Runtime.load(HlWriter.encode(fresh.module),fresh.runtimeIdentity);
  hl.Gc.major(); Runtime.retryRetirements();
  var result=Runtime.callIntObject(reloaded,fresh.functionIds.get("Main.probe"),retained);
  if(result!=42) throw "Old object lost conformance after reload: "+result;
  var changedCompiler=configuredCompiler();
  changedCompiler.update("Contract.hx",contract(4).split("score():Int").join("score(extra:Int):Int"));
  changedCompiler.update("Main.hx",source(true,4).split("score():Int").join("score(extra:Int):Int").split(".score()").join(".score(0)")
   +"function reject(value:Dynamic):Int return Std.isOfType(value,Reader)?1:42;\n");
  var incompatible=changedCompiler.compile("Main"), replacement=Runtime.load(HlWriter.encode(incompatible.module),incompatible.runtimeIdentity);
  if(Runtime.callIntObject(replacement,incompatible.functionIds.get("Main.reject"),retained)!=42)
   throw "An incompatible reloaded interface accepted the old object";
  retained.release(); Runtime.dispose(reloaded); Runtime.dispose(replacement);
  for(_ in 0...3) {hl.Gc.major();Runtime.retryRetirements();}
  if(Runtime.retryRetirements()!=0) throw "Interface identity retained a retired module";
  Sys.println("PASS: interface identity survives patches, appended implementations and reloads");
 }
}
