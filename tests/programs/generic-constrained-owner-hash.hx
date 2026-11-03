import haxeon.Hashing;
struct Key : Hashable { public var x:Int; public function new(x:Int) this.x=x; }
class RefKey implements Hashable { public final x:Int; public function new(x:Int) this.x=x; }
struct Value { public var x:Int; public function new(x:Int) this.x=x; }
class Dense<K:Hashable,V> {
  public var keys:Array<K>; public var values:Array<V>;
  public function new() { keys=[]; values=[]; }
  public function set(key:K, value:V):Void { keys.push(key); values.push(value); }
  public function same(key:K):Bool return keys[0] == key;
  public function hash():Int return Hashing.hash(keys[0]);
  public function value():V return values[0];
}
class Derived<K:Hashable,V> extends Dense<K,V> {
  public function new() super();
}
function main():Int {
    var map = new Derived<Key,Value>(); map.set(new Key(4),new Value(7));
    var ints = new Dense<Int,Value>(); ints.set(3,new Value(5));
    var refs = new Dense<RefKey,Int>(); refs.set(new RefKey(5),8);
    var strings = new Dense<String,Int>(); strings.set("key",9);
    var erased:Dense<Dynamic,Dynamic> = cast map;
    return map.value().x==7 && map.same(new Key(4)) && map.hash()!=0 && ints.same(3) && ints.hash()!=0
       && refs.same(new RefKey(5)) && refs.hash()!=0 && strings.same("key") && strings.hash()!=0
       && (cast erased.value():Value).x==7 ? 42 : 1;
  }
