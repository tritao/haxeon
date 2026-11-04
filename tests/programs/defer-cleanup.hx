class CleanupLog {
 public static var value:String = "";
 public static function add(value:String):Void { CleanupLog.value += value; }
}
class DeferCensus {
 public static var count:Int = 0;
 public static function perform(n:Int):Int {
  count = 0;
  var i = 0;
  while (i < n) {
   defer count++;
   i++;
  }
  return count;
 }
}
function normal():Int {
 defer CleanupLog.add("a");
 defer { CleanupLog.add("b"); }
 CleanupLog.add("c");
 return 42;
}
function failure():Void {
 defer CleanupLog.add("d");
 defer { CleanupLog.add("e"); throw "cleanup"; }
 throw "body";
}
function cleanupFailure():Int {
 defer CleanupLog.add("f");
 defer { CleanupLog.add("g"); throw "first"; }
 return 7;
}
function loops():Void {
 var i = 0;
 while (i < 3) {
  i++;
  defer CleanupLog.add("l");
  if (i < 3) continue;
  break;
 }
}
function returnValue():Int {
 var value = 4;
 defer value = 9;
 return value;
}
function handledCleanup():Void {
 try {
  defer { CleanupLog.add("h"); throw "inside"; }
  CleanupLog.add("i");
 } catch (error:Dynamic) {
  if (error == "inside") CleanupLog.add("j");
 }
}
function skipped():Void {
 if (false) { defer CleanupLog.add("x"); }
}
function laterFailure():Void {
 defer { CleanupLog.add("k"); throw "later"; }
 defer { CleanupLog.add("n"); throw "earlier"; }
}
function observesLocal():Void {
 var value = "old";
 defer CleanupLog.add(value);
 value = "new";
}
function outerLoop():Void {
 defer CleanupLog.add("z");
 var i = 0;
 while (i < 2) {
  defer CleanupLog.add("q");
  i++;
  continue;
 }
 CleanupLog.add("r");
}
function nestedCleanup():Void {
 defer {
  defer CleanupLog.add("t");
  var i = 0;
  while (i < 3) {
   i++;
   if (i == 2) break;
  }
  CleanupLog.add("s");
 }
}
function main():Int {
 if (normal() != 42 || CleanupLog.value != "cba") return 1;
 var caught:Dynamic = null;
 try failure() catch (error:Dynamic) caught = error;
 if (caught != "body" || CleanupLog.value != "cbaed") return 2;
 caught = null;
 try cleanupFailure() catch (error:Dynamic) caught = error;
 if (caught != "first" || CleanupLog.value != "cbaedgf") return 3;
 loops();
 if (CleanupLog.value != "cbaedgflll") return 4;
 if (returnValue() != 4) return 5;
 handledCleanup(); skipped();
 if (CleanupLog.value != "cbaedgflllihj") return 6;
 caught = null;
 try laterFailure() catch (error:Dynamic) caught = error;
 if (caught != "earlier" || CleanupLog.value != "cbaedgflllihjnk") return 7;
 observesLocal();
 if (CleanupLog.value != "cbaedgflllihjnknew") return 8;
 outerLoop();
 if (CleanupLog.value != "cbaedgflllihjnknewqqrz") return 9;
 nestedCleanup();
 if (CleanupLog.value != "cbaedgflllihjnknewqqrzst") return 10;
 return 42;
}
