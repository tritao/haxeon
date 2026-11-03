enum Value<T:Equatable> : Equatable { Item(value:T); }
class Holder { public var items:Array<Value<Int>>; public function new() items=[Value.Item(7),Value.Item(7)]; }
function main():Int { var raw:Dynamic=Reflect.field(new Holder(),"items"), view:Array<Dynamic>=cast raw; return view[0] == view[1] ? 42 : 1; }
