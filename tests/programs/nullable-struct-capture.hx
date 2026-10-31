struct EntityProbe {
  public final slot:Int32;

  public function new(slot:Int) {
    this.slot = cast slot;
  }
}

struct MutableProbe {
  public var slot:Int;
  public function new(slot:Int) this.slot = slot;
  public function bump():Void slot++;
}

class RichProbe {
  public final slot:Int;

  public function new(slot:Int) {
    this.slot = slot;
  }
}

function main():Int {
  var absent:Null<EntityProbe> = null;
  var absentRead = function():Bool return absent == null;
  if (!absentRead()) return 1;

  var present:Null<EntityProbe> = new EntityProbe(37);
  var presentRead = function():Bool return present != null && present.slot ==(cast 37);
  if (!presentRead()) return 2;

  var absentInt:Null<Int> = null;
  var readAbsentInt = function():Bool return absentInt == null;
  var scalar = 19;
  var readScalar = function():Int return scalar;
  var rich = new RichProbe(41);
  var readRich = function():Int return rich.slot;
  var absentRich:Null<RichProbe> = null;
  var readAbsentRich = function():Bool return absentRich == null;
  var nullableRich:Null<RichProbe> = rich;
  var readNullableRich = function():Int return nullableRich == null ? -1 : nullableRich.slot;
  if (!readAbsentInt()
    || readScalar() != 19 || readRich() != 41 || !readAbsentRich() || readNullableRich() != 41) return 3;
  var mutable:Null<MutableProbe> = new MutableProbe(39);
  var increment = function():Void { if (mutable != null) mutable.slot++; };
  var callMethod = function():Void { if (mutable != null) mutable.bump(); };
  increment(); callMethod();
  if (mutable == null || mutable.slot != 41) return 4;
  if (mutable != null) mutable.slot++;
  if (mutable == null || mutable.slot != 42) return 5;
  var assign = function():Void { if (mutable != null) mutable.slot = 35; };
  var add = function():Void { if (mutable != null) mutable.slot += 7; };
  assign(); add();
  if (mutable == null || mutable.slot != 42) return 7;
  var plain = new MutableProbe(10);
  var bumpPlain = function():Void plain.bump();
  bumpPlain();
  if (plain.slot != 11) return 6;
  return 42;
}
