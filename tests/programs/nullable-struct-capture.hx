struct EntityProbe {
  public final slot:Int32;

  public function new(slot:Int) {
    this.slot = cast slot;
  }
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
  return 42;
}
