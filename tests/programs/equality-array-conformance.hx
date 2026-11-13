import haxeon.Equality;

struct EqualityArrayValue implements Equatable {
  public final value:Int;
  public function new(value:Int) this.value = value;
}
struct EqualityArrayContainer implements Equatable {
  public final values:Array<Int>;
  public function new(values:Array<Int>) this.values = values;
}
enum EqualityArrayChoice implements Equatable {

  Item(value:Int);
}
function genericEquality < T:Equatable > (left:T, right:T):Bool return Equality.equals(left, right);

function main():Int {
  var emptyA:Array<Int> = [], emptyB:Array<Int> = [];
  var valuesA:Array<Int> = [1, 2, 3], valuesB:Array<Int> = [1, 2, 3];
  var nestedA:Array<Array<Int>> = [[], [1, 2]], nestedB:Array<Array<Int>> = [[], [1, 2]];
  var wrong:Array<Array<Int>> = [[], [1, 3]];
  var enumA:Array<EqualityArrayChoice> = [Item(3)], enumB:Array<EqualityArrayChoice> = [Item(3)];
  var structsA:Array<EqualityArrayValue> = [new EqualityArrayValue(7)];
  var structsB:Array<EqualityArrayValue> = [new EqualityArrayValue(7)];
  var nullableValuesA:Array<Null<Int>> = [1, null, 3], nullableValuesB:Array<Null<Int>> = [1, null, 3];
  var absentA:Array<Int> = null, absentB:Array<Int> = null;
  var optionalA:Null<Array<Int>> = valuesA, optionalB:Null<Array<Int>> = valuesB;
  if (!Equality.equals(emptyA, emptyB)) return 1;
  if (!Equality.equals(valuesA, valuesB)) return 2;
  if (valuesA == valuesB || valuesA != valuesA) return 16;
  if (Equality.sameForChange(valuesA, valuesB)) return 18;
  if (!Equality.equals(nestedA, nestedB)) return 3;
  if (Equality.equals(nestedA, wrong)) return 4;
  if (Equality.equals(emptyA, valuesA)) return 5;
  if (!Equality.equals(structsA, structsB)) return 6;
  if (!Equality.equals(absentA, absentB)) return 7;
  if (Equality.equals(absentA, emptyA)) return 8;
  if (!genericEquality(valuesA, valuesB)) return 9;
  if (!Equality.equals(optionalA, optionalB)) return 10;
  if (!Equality.equals(enumA, enumB)) return 11;
  if (!Equality.equals(nullableValuesA, nullableValuesB)) return 15;
  if (!Equality.equals(new EqualityArrayContainer(valuesA), new EqualityArrayContainer(valuesB))) return 17;
  var matched = switch structsA {
    case [new EqualityArrayValue(7)]:
      true;
    default:
      false;
  };
  if (!matched) return 12;
  var nestedMatched = switch nestedA {
    case [[], [1, 2]]:
      true;
    default:
      false;
  };
  if (!nestedMatched) return 14;
  return 42;
}
