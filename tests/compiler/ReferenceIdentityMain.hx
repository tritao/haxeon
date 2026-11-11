import compiler.Compiler;
import compiler.Diagnostic.CompileError;
import compiler.ir.IrInterpreter;
import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrVerifier;
import compiler.ir.IrReferenceIdentity;

class ReferenceIdentityMain {
 static function make(source:String):Compiler {
  var compiler = new Compiler(); compiler.update("Main.hx",source); return compiler;
 }
 static function rejects(source:String, message:String):Void {
  try { make(source).compile("Main"); throw "expected value capability rejection"; }
  catch(e:CompileError) if(e.diagnostic.message.indexOf(message)<0) throw e;
 }
 static function invalidIdentity(type:IrType):Void {
  var b=new IrBuilder(), a=b.argument("a",type), z=b.argument("z",type);
  b.returnValue(b.call(IrReferenceIdentity.NAME,[a,z],Bool));
  var p=new IrProgram("main"); p.functions=[new IrFunction("main",b.arguments,Bool,b.blocks, Ordinary)];
  p.objects=[{name:"Value",isValue:true,base:null,interfaces:[],fields:[],methods:[]}];
  try { IrVerifier.verify(p); throw "reference identity accepted a value carrier"; }
  catch(error:Dynamic) if(Std.string(error).indexOf("Reference identity requires class or interface references")<0) throw error;
 }
 static function main():Void {
  var hashCompiler = new Compiler();
  hashCompiler.update("haxeon/reactive/ReactiveHash.hx", sys.io.File.getContent("stdlib/haxeon/reactive/ReactiveHash.hx"));
  hashCompiler.update("haxeon/reactive/ReactiveSource.hx", 'package haxeon.reactive; class ReactiveSource { '
   + 'public final hash:Int; public function new() hash = ReactiveHash.next(this); }');
  hashCompiler.update("Main.hx", 'import haxeon.reactive.ReactiveSource; '
   + 'function main():Int { var source = new ReactiveSource(); return source.hash == source.hash ? 42 : 1; }');
  if(new IrInterpreter(hashCompiler.compile("Main").ir).run("main")!=42) throw "interpreter object hash is unstable";
  for(inlineEnabled in [false,true]) {
   var compiler=make('interface Equatable {} interface View { function value():Int; } '
    + 'class Box<T> { public function new() {} } '
    + 'function sameBox(a:Box<Int>,b:Box<Int>):Bool return a==b; '
    + 'function absentBox(a:Null<Box<Int>>):Bool return a==null; '
   + 'class Item implements View { public function new() {} public function value():Int return 1; '
    + 'public function equals(other:Item):Bool return true; public function __compare(other:Item):Int return 0; } '
    + 'struct S implements Equatable { public final x:Int; public function new(x:Int) this.x=x; } '
    + 'function main():Int { var a=new Item(), b=new Item(); var va:View=a; var vb:View=b; var alias:View=a; '
    + 'var x:Equatable=new S(1), y:Equatable=new S(1), same=x; '
    + 'var box=new Box<Int>(); if(!sameBox(box,box) || sameBox(box,new Box<Int>()) || !absentBox(null)) return 2; '
    + 'return a!=b && a==a && a.equals(b) && va==alias && va!=vb && va==a && x!=y && x==same ? 42 : 0; }');
   compiler.configure("reference-identity","test",["haxeon-inline="+(inlineEnabled?"1":"0")]);
   var p=compiler.compile("Main").ir;
   if(new IrInterpreter(p).run("main")!=42) throw 'class/interface identity failed (inline=$inlineEnabled)';
  }
  for(capability in ["Equatable","Hashable"]) {
   var header='interface Equatable {} interface Hashable extends Equatable {} ';
   rejects(header+'class Bad implements '+capability+' {} function main():Int return 42;',"use a struct for value equality");
   rejects(header+'class Bad implements '+capability+' { public static var cache:Map<Bad,Int> = new Map(); } '
    +'function main():Int return 42;',"use a struct for value equality");
   rejects(header+'interface ValueOnly extends '+capability+' {} class Bad implements ValueOnly {} function main():Int return 42;',"use a struct for value equality");
   rejects(header+'class Item { public function new() {} } class Box<T:'+capability+'> { public function new() {} } '
    +'function main():Int { var box=new Box<Item>(); return 42; }',capability);
   rejects(header+'class Item { public function new() {} } function accept<T:'+capability+'>(value:T):Int return 42; '
    +'function main():Int return accept(new Item());',capability);
   rejects(header+'class Box<T:'+capability+'> { public function new() {} } '
    +'function main():Int { var box=new Box<'+capability+'>(); return 42; }',capability);
  }
  for(type in [I32,Obj("Value")]) invalidIdentity(type);
  Sys.println("PASS: classes and interfaces compare by identity; value bounds reject classes and identity rejects value carriers");
 }
}
