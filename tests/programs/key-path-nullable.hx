struct Point { public var x:Int; public function new(x:Int) this.x=x; }
class Root { public var point:Null<Point>; public function new() point=new Point(1); }
class NullableKeyPath {
 static var root:Root;
 static var path:WritableKeyPath<Root,Null<Point>>;
 public static function prepare():Void { root=new Root(); var paths=[\Root.point]; path=paths[0]; }
 public static function perform(n:Int):Int { var total=0; for(i in 0...n){ var value=path.get(root); path.set(root,value); if(value!=null) total+=value.x; } return total; }
}
function main():Int { NullableKeyPath.prepare(); return NullableKeyPath.perform(42); }
