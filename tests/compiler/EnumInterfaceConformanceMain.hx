import compiler.Frontend;
import compiler.Diagnostic.CompileError;

class EnumInterfaceConformanceMain {
 static function checkError(label:String, source:String, code:String):Void {
  try Frontend.compile(source) catch (error:CompileError) {
   if (error.diagnostic.code != code)
    throw '$label: expected $code, got ${error.diagnostic.format()}';
   return;
  }
  throw '$label unexpectedly compiled';
 }
 static function main():Void {
  var contract = 'interface Step { function step(value:Int):Int; } ';
  Frontend.compile(contract + 'enum E implements Step { Case; public function step(value:Int):Int return value + 1; } '
   + 'function main():Int { var e:E = Case; return e.step(41); }');
  checkError('missing method', contract + 'enum E implements Step { Case; } function main():Int return 0;', 'E1007');
  checkError('wrong method type', contract + 'enum E implements Step { Case; public function step(value:String):Int return 0; } '
   + 'function main():Int return 0;', 'E1003');
  checkError('undeclared method', 'enum E { Case; public function step(value:Int):Int return value; } function main():Int return 0;', 'E1025');
  checkError('non-interface', 'class C {} enum E implements C { Case; } function main():Int return 0;', 'E1007');
  Sys.println('PASS: enum interface methods require matching declared contracts');
 }
}
