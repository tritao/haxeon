struct Value {
  public var x:Int;
  public function new(x:Int) this.x = x;
}

struct RichValue {
  public var label:String;
  public var child:Value;
  public function new(label:String, child:Value) {
    this.label = label;
    this.child = child;
  }
}

function forwarded(value:Null<Value>):Null<Value> return value;
function read(value:Null<Value>):Int return value == null ? -1 : value.x;
function equal(left:Null<Value>, right:Null<Value>):Bool return left == right;
function equalValue(left:Null<Value>, right:Value):Bool return left == right && right == left;
function missing():Null<Value> return null;

function main():Int {
  var original:Null<Value> = new Value(7);
  var copy:Null<Value> = original;
  if (copy != null) copy.x = 9;
  if (read(original) != 7 || read(copy) != 9) return 1;

  var returned = forwarded(original);
  if (returned != null) returned.x = 11;
  if (read(original) != 7 || read(returned) != 11) return 2;

  var values:Array<Null<Value>> = [original, null];
  var element = values[0];
  if (element != null) element.x = 13;
  var stored = values[0];
  if (read(stored) != 7 || read(element) != 13) return 3;
  if (values[1] != null) return 3;

  var absent:Null<Value> = null;
  var absentCopy = forwarded(absent);
  if (absentCopy != null) return 4;
  var same:Null<Value> = new Value(7);
  if (!equal(original, same) || equal(original, copy) || equal(original, absent) || !equal(absent, absentCopy)) return 5;
  if (!equalValue(original, new Value(7)) || equalValue(absent, new Value(7))) return 8;
  var rich:Null<RichValue> = new RichValue("kept", new Value(17));
  var richCopy:Null<RichValue> = rich;
  if (richCopy != null) {
    richCopy.label = "changed";
    richCopy.child.x = 19;
  }
  if (rich != null) {
    if (rich.label != "kept" || rich.child.x != 17) return 6;
  } else return 6;
  if (richCopy != null) {
    if (richCopy.label != "changed" || richCopy.child.x != 19) return 7;
  } else return 7;
  try {
    var absentValue:Value = cast missing();
    return absentValue.x;
  } catch (error:Dynamic) {}
  return 42;
}
