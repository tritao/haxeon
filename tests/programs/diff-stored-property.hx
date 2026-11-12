class DiffStoredProperty implements Diffable {
  @:isVar public var value(get, set):Int;
  public var other(default, set):Int;
  public function new() {
    value = 1;
    other = 2;
  }
  function get_value():Int return value;
  function set_value(next:Int):Int return value = next;
  function set_other(next:Int):Int return other = next;
}

function main():Int {
  var first = new DiffStoredProperty(), second = haxeon.Diff.copy(first);
  if (haxeon.Diff.bit(\DiffStoredProperty.value) != 1
    || haxeon.Diff.bit(\DiffStoredProperty.other) != 2 || haxeon.Diff.all(DiffStoredProperty) != 3) return 1;
  second.value = 5;
  if (haxeon.Diff.mask(first, second) != 1) return 2;
  second.other = 6;
  return haxeon.Diff.mask(first, second) == 3 ? 42 : 3;
}
