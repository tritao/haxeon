import compiler.Diagnostic.CompileError;
import compiler.Source.SourceFile;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.types.analysis.ScopedEscapeChecker;
import compiler.Frontend;

class ScopedEscapeCheckerMain {
 static function check(body:String):Void {
  var source = 'function main():Void { $body }';
  var fn = new Parser(new Lexer(new SourceFile("ScopedEscape.hx", source)).tokenize()).parseProgram().functions[0];
  ScopedEscapeChecker.check(fn.arguments, fn.statements);
 }
 static function main():Void {
  check('scoped var item = open(); consume(item); item.read(); { var item = 1; item++; }');
  check('scoped var item = open(); return { var item = 1; item; };');
  check('scoped var item = open(); var values = [for (item in items) item];');
  for (tail in ['return item;', 'var other = item;', 'sink.value = item;', 'items[0] = item;',
    'return { item; };', 'return true ? item : null;', 'return switch (1) { case 1: item; default: null; };',
    'item = open();', 'var callback = function() item.read();',
    'var boxed = cast(item, Dynamic);', 'var items = [item];', 'var items = [for (i in values) item];',
    'var map = [for (i in values) i => item];']) {
   var rejected = false;
   try check('scoped var item = open(); $tail') catch (_:CompileError) rejected = true;
   if (!rejected) throw 'Scoped escape was accepted: $tail';
  }
  check('var callback = function() { scoped var item = open(); consume(item); };');
  var contract = 'interface Disposable { function dispose():Void; } '
   + 'class Resource implements Disposable { public function new() {} public function dispose():Void {} } '
   + 'function use(value:Resource):Void {} function dynamicUse(value:Dynamic):Void {} ';
  Frontend.compile(contract + 'function main():Void { scoped var item = new Resource(); use(item); }');
  for (body in ['return item;', 'var alias = item;', 'var callback = function() use(item);', 'dynamicUse(item);']) {
   var rejected = false;
   try Frontend.compile(contract + 'function main():Void { scoped var item = new Resource(); $body }') catch (error:CompileError) {
    if (error.diagnostic.code != 'E1002') throw error;
    rejected = true;
   }
   if (!rejected) throw 'Compiler accepted scoped escape: $body';
  }
  Sys.println('PASS: scoped direct escapes and helper calls');
 }
}
