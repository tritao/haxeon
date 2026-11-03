enum Outcome<T> { Success(value:T); Stopped; }
typedef Result<T> = Outcome<T>;
class Base<T> { var value:Outcome<T>; public function new(v:Outcome<T>) value=v; public function get():Outcome<T> return value; }
class Derived<T> extends Base<T> { public function new(v:Outcome<T>) super(v); }
class AliasHolder<T> { var value:Result<T>; public function new(v:Result<T>) value=v; public function get():Result<T> return value; }
function main():Int { var a:Derived<String>=new Derived(Success("a")); var b:AliasHolder<String>=new AliasHolder(Success("b")); return switch [a.get(),b.get()] { case [Success("a"),Success("b")]: 42; default: 1; }; }
