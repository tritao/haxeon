import compiler.Compiler;
import compiler.hl.HlWriter;
import runtime.PatchSet;
import runtime.Runtime;

/** Private class entries survive appended classes and subsequent redirects of their implementations. */
class TypedInterfacePatchMain {
 static function source(extra:Bool, number:Int):String return
  "struct Packet { public final number:Int; public function new(number:Int) this.number=number; }\n"+
  "interface Reader { function read():Packet; }\n"+
  "class Base implements Reader { public function new() {} public function read():Packet return new Packet(2); }\n"+
  (extra?'class Added implements Reader { public function new() {} public function read():Packet return new Packet($number); }\n':"")+
  "function value(reader:Reader):Int return reader.read().number;\n"+
  "class Store { static var saved:Reader=new Base(); public static function run():Int return value(saved)"+(extra?"+value(new Added())":"")+"; }\n"+
  "function main():Int return Store.run();\n";
 static function exercise():Void {
  var compiler=new Compiler();compiler.update("Main.hx",source(false,0));
  var first=compiler.compile("Main"),live=Runtime.load(HlWriter.encode(first.module),first.runtimeIdentity),main=first.functionIds.get("main");
  if(Runtime.callInt(live,main)!=2)throw "Initial typed class entry failed";
  compiler.update("Main.hx",source(true,9));var appended=compiler.compile("Main");
  if(appended.requiresReload || appended.patchBytes==null)throw "Adding a typed interface implementation required a reload: "+Std.string(appended.reloadReasons);
  Runtime.patchSet(live,new PatchSet(first.revision,appended.revision,appended.patchBytes,appended.changedFunctions));
  if(Runtime.callInt(live,main)!=11)throw "Appended typed class entry failed";
  compiler.update("Main.hx",source(true,10));var edited=compiler.compile("Main");
  if(edited.requiresReload || edited.patchBytes==null)throw "Editing a typed implementation required a reload";
  Runtime.patchSet(live,new PatchSet(appended.revision,edited.revision,edited.patchBytes,edited.changedFunctions));
  if(Runtime.callInt(live,main)!=12)throw "Cached typed class entry ignored a patched implementation";
  Runtime.dispose(live);
 }
 static function main():Void {
  exercise();
  // Cached entry closures belong to the class arena; the slot registry must not retain their module.
  for(_ in 0...3){hl.Gc.major();Runtime.retryRetirements();}
  if(Runtime.retryRetirements()!=0)throw "Typed method metadata retained a disposed module";
  Sys.println("PASS: appended typed method tables and cached entries remain patchable and retire");
 }
}
