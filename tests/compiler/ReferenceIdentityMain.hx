import compiler.Compiler;
import compiler.Diagnostic.CompileError;
import compiler.ir.IrInterpreter;

class ReferenceIdentityMain {
 static function make(source:String):Compiler {
  var compiler = new Compiler();
  compiler.update("haxeon/Identity.hx", 'package haxeon; class Identity {} '
   + 'private extern class IdentityNative { @:hlNative("haxeon_runtime", "__reference_identity") '
   + 'public static function same(a:Dynamic, b:Dynamic):Bool; }');
  compiler.update("Main.hx", 'import haxeon.Identity; ' + source);
  return compiler;
 }
 static function rejects(source:String):Void {
  try { make(source).compile("Main"); throw "expected identity argument rejection"; }
  catch (e:CompileError) if (e.diagnostic.message.indexOf("Identity.same requires class instances") < 0) throw e;
 }
 static function main():Void {
  var hashCompiler = new Compiler();
  hashCompiler.update("haxeon/reactive/ReactiveHash.hx", sys.io.File.getContent("stdlib/haxeon/reactive/ReactiveHash.hx"));
  hashCompiler.update("haxeon/reactive/ReactiveSource.hx", 'package haxeon.reactive; class ReactiveSource { '
   + 'public final hash:Int; public function new() hash = ReactiveHash.next(this); }');
  hashCompiler.update("Main.hx", 'import haxeon.reactive.ReactiveSource; '
   + 'function main():Int { var source = new ReactiveSource(); return source.hash == source.hash ? 42 : 1; }');
  if (new IrInterpreter(hashCompiler.compile("Main").ir).run("main") != 42)
   throw "reactive identity hashes did not execute in the interpreter";
  for (inlineEnabled in [false, true]) {
   var compiler = make('class Item { public function new() {} } '
    + 'function main():Int { var a = new Item(), b = new Item(); '
    + 'return Identity.same(a,a) && !Identity.same(a,b) ? 42 : 0; }');
   compiler.configure("reference-identity", "test", ["haxeon-inline=" + (inlineEnabled ? "1" : "0")]);
   var result = new IrInterpreter(compiler.compile("Main").ir).run("main");
   if (result != 42) throw 'reference identity returned $result (inline=$inlineEnabled)';
  }
  rejects('function main():Int return Identity.same(1, 2) ? 1 : 0;');
  rejects('class Item { public function new() {} } function main():Int return Identity.same(new Item(), 1) ? 1 : 0;');
  rejects('enum E { A; B; } function main():Int return Identity.same(A, B) ? 1 : 0;');
  rejects('struct S { public var x:Int; public function new(x:Int) this.x = x; } '
   + 'function main():Int return Identity.same(new S(1), new S(2)) ? 1 : 0;');
  rejects('function main():Int { var a:Dynamic = 1; return Identity.same(a, a) ? 1 : 0; }');
  Sys.println("PASS: identity accepts class references and rejects value types");
 }
}
