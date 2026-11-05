import compiler.Frontend;

/** Polymorphic owner recursion must fail with a diagnostic instead of filling the specialization queue forever. */
class GenericOwnerRecursionMain {
  static function main():Void {
    var source = 'interface RecursiveOwner {} class Box<T:RecursiveOwner> implements RecursiveOwner { '
      + 'public final value:T; public function new(value:T) this.value=value; '
      + 'public function wrap():Box<Box<T>> return new Box(this); } '
      + 'struct Value implements RecursiveOwner { public final n:Int; public function new(n:Int) this.n=n; } '
      + 'function main():Int { var box=new Box(new Value(42)); return box.value.n; }';
    var failure:Null<String> = null;
    try Frontend.compile(source) catch (error:Dynamic) failure = Std.string(error);
    if (failure == null || failure.indexOf("E1028") < 0 || failure.indexOf("Box") < 0)
      throw 'expected a generic-owner specialization limit for Box, got $failure';
    var broad = 'interface RecursiveOwner {} '
      + 'class Pair<A:RecursiveOwner,B:RecursiveOwner> implements RecursiveOwner { public final a:A; public final b:B; '
      + 'public function new(a:A,b:B) { this.a=a; this.b=b; } } '
      + 'class Box<T:RecursiveOwner> implements RecursiveOwner { public final value:T; public function new(value:T) this.value=value; '
      + 'public function wrap():Box<Pair<T,T>> throw "unused"; } '
      + 'struct Value implements RecursiveOwner { public final n:Int; public function new(n:Int) this.n=n; } '
      + 'function main():Int { var box=new Box(new Value(42)); return box.value.n; }';
    failure = null;
    try Frontend.compile(broad) catch (error:Dynamic) failure = Std.string(error);
    if (failure == null || failure.indexOf("E1028") < 0 || failure.indexOf("Box") < 0)
      throw 'expected a breadth limit for Box, got $failure';
    var finite = 'interface RecursiveOwner {} class Box<T:RecursiveOwner> implements RecursiveOwner { '
      + 'public final value:T; public function new(value:T) this.value=value; '
      + 'public function again():Box<T> return this; } '
      + 'struct Value implements RecursiveOwner { public final n:Int; public function new(n:Int) this.n=n; } '
      + 'function main():Int { var box=new Box(new Value(42)); return box.again().value.n; }';
    Frontend.compile(finite);
    Sys.println("PASS: recursive generic owners fail with a bounded diagnostic");
  }
}
