class NullMapItem {
 public var value:Int;
 public function new(value:Int) this.value = value;
}
class NullStringMapCensus {
 static var values:Map<String, NullMapItem>;
 public static function prepare():Void values = ["present" => new NullMapItem(1)];
 public static function perform(count:Int):Int {
  var matched = 0;
  for (_ in 0...count) if (values.get(null) == null && !values.exists(null) && !values.remove(null)) matched++;
  return matched;
 }
}
function main():Int {
 var values:Map<String, NullMapItem> = ["present" => new NullMapItem(1)];
 if (values.get(null) != null || values.exists(null) || values.remove(null)) return 1;
 var first = new NullMapItem(2), empty = new NullMapItem(3), text = new NullMapItem(4);
 values.set(null, first); values.set("", empty); values.set("null", text);
 if (!values.exists(null) || values.get(null) != first || values.get("") != empty || values.get("null") != text) return 2;
 var replacement = new NullMapItem(5); values.set(null, replacement);
 if (values.size() != 4 || values.get(null) != replacement) return 3;
 var growth = ["k0", "k1", "k2", "k3", "k4", "k5", "k6", "k7", "k8", "k9", "k10", "k11", "k12", "k13", "k14", "k15", "k16", "k17", "k18", "k19", "k20", "k21", "k22", "k23", "k24", "k25", "k26", "k27", "k28", "k29", "k30", "k31", "k32", "k33", "k34", "k35", "k36", "k37", "k38", "k39", "k40", "k41", "k42", "k43", "k44", "k45", "k46", "k47", "k48", "k49", "k50", "k51", "k52", "k53", "k54", "k55", "k56", "k57", "k58", "k59", "k60", "k61", "k62", "k63"];
 for (key in growth) values.set(key, first);
 if (values.size() != 68 || values.get(null) != replacement || values.get("") != empty) return 4;
 var nilKeys = 0, emptyKeys = 0, textKeys = 0;
 for (key in values.keys()) {
  if (key == null) nilKeys++;
  else if (key == "") emptyKeys++;
  else if (key == "null") textKeys++;
 }
 if (nilKeys != 1 || emptyKeys != 1 || textKeys != 1) return 5;
 var listed = 0; for (value in values.values()) if (value == replacement) listed++;
 if (listed != 1) return 6;
 var copied = values.copy();
 if (!values.remove(null) || values.remove(null) || values.get(null) != null || values.get("") != empty) return 7;
 if (!copied.exists(null) || copied.get(null) != replacement) return 8;
 replacement.value = 9;
 var shared = copied.get(null);
 if (shared == null || shared.value != 9) return 9;
 copied.clear(); if (copied.size() != 0 || copied.exists(null) || copied.get(null) != null) return 10;
 values.set(null, null);
 if (!values.exists(null) || values.get(null) != null || values.size() != 68) return 11;
 var nullableCopy = values.copy();
 if (!nullableCopy.exists(null) || nullableCopy.get(null) != null) return 12;
 var ints:Map<String, Int> = ["present" => 1];
 if (ints.get(null) != null || ints.exists(null) || ints.remove(null)) return 13;
 ints.set(null, 0); ints.set("", 42); ints.set("null", -7);
 if (!ints.exists(null) || ints.get(null) != 0 || ints.get("") != 42 || ints.get("null") != -7 || ints.size() != 4) return 14;
 var intCopy = ints.copy(); ints.set(null, 8);
 if (intCopy.get(null) != 0 || ints.get(null) != 8 || !ints.remove(null) || ints.exists(null)) return 15;
 return 42;
}
