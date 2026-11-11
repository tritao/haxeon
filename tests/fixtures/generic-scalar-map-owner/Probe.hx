class ReadView<V> {
 final values:Map<String,V>;
 public function new(values:Map<String,V>) this.values=values;
 public function read(key:String):Null<V> return values.get(key);
}
class Probe {
 public static function main():Int {
  var values:Map<String,Bool>=[]; values.set("x",false);
  var view=new ReadView<Bool>(values);
  return view.read("x")==false ? 42 : 0;
 }
}
