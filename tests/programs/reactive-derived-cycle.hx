import haxeon.reactive.Derived;
import haxeon.reactive.Signal;

function main():Int {
 var self:Derived<Int> = null;
 var directCalls = 0;
 var directCycle = true;
 self = new Derived<Int>(function() {
  directCalls++;
  if (directCalls > 32) throw "unbounded direct recursion";
  return directCycle ? self.value : 7;
 });
 var error:Dynamic = null;
 try { var value = self.value; } catch (caught:Dynamic) error = caught;
 if (Std.string(error) != "Cyclic Derived computation" || directCalls != 1 || self.dependencyCount() != 0) return 1;
 directCycle = false;
 if (self.value != 7 || self.value != 7) return 2;
 self.dispose();

 var left:Derived<Int> = null;
 var right:Derived<Int> = null;
 var input = new Signal<Int>(3);
 var indirectCalls = 0;
 var indirectCycle = true;
 left = new Derived<Int>(function() {
  indirectCalls++;
  if (indirectCalls > 32) throw "unbounded indirect recursion";
  return indirectCycle ? right.value : input.value;
 });
 right = new Derived<Int>(function() return left.value + 1);
 error = null;
 try { var value = left.value; } catch (caught:Dynamic) error = caught;
 if (Std.string(error) != "Cyclic Derived computation" || indirectCalls != 1 || right.dependencyCount() != 0) return 3;
 indirectCycle = false;
 if (left.value != 3 || right.value != 4) return 4;
 input.value = 8;
 if (right.value != 9) return 5;
 left.dispose(); right.dispose();

 var trigger = new Signal<Int>(0);
 var a:Derived<Int> = null;
 var b:Derived<Int> = null;
 b = new Derived<Int>(function() { var flag = trigger.value; return flag == 0 ? 1 : a.value; });
 a = new Derived<Int>(function() return b.value + 1);
 if (a.value != 2) return 6;
 trigger.value = 1;
 error = null;
 try { var value = b.value; } catch (caught:Dynamic) error = caught;
 if (Std.string(error) != "Cyclic Derived computation" || b.dependencyCount() != 1) return 7;
 trigger.value = 0;
 if (b.value != 1 || a.value != 2) return 8;
 a.dispose(); b.dispose();
 return 42;
}
