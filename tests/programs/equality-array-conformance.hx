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
abstract EqualityArrayId(Int) {
  public inline function new(value:Int) this = value;
}
abstract EqualityArrayWrapped(EqualityArrayValue) {
  public inline function new(value:EqualityArrayValue) this = value;
}
abstract EqualityArrayList(Array<Int>) {
  public inline function new(values:Array<Int>) this = values;
}
abstract EqualityArrayWrappedChoice(EqualityArrayChoice) {
  public inline function new(choice:EqualityArrayChoice) this = choice;
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
  // A plain abstract compares by its representation, as its == does.
  var idsA:Null<Array<EqualityArrayId>> = [new EqualityArrayId(1), new EqualityArrayId(2)];
  var idsB:Null<Array<EqualityArrayId>> = [new EqualityArrayId(1), new EqualityArrayId(2)];
  var idsOther:Null<Array<EqualityArrayId>> = [new EqualityArrayId(1), new EqualityArrayId(3)];
  if (!Equality.equals(idsA, idsB)) return 19;
  if (Equality.equals(idsA, idsOther)) return 20;
  var wrappedA:Array<EqualityArrayWrapped> = [new EqualityArrayWrapped(new EqualityArrayValue(7))];
  var wrappedB:Array<EqualityArrayWrapped> = [new EqualityArrayWrapped(new EqualityArrayValue(7))];
  var wrappedOther:Array<EqualityArrayWrapped> = [new EqualityArrayWrapped(new EqualityArrayValue(8))];
  if (!Equality.equals(wrappedA, wrappedB)) return 21;
  if (Equality.equals(wrappedA, wrappedOther)) return 22;
  var wrappedValue = new EqualityArrayWrapped(new EqualityArrayValue(7));
  var optionalWrapped:Null<EqualityArrayWrapped> = new EqualityArrayWrapped(new EqualityArrayValue(7));
  if (!(wrappedValue == new EqualityArrayWrapped(new EqualityArrayValue(7)))) return 23;
  if (!Equality.equals(optionalWrapped, optionalWrapped) || optionalWrapped == null) return 24;
  // An abstract over an array keeps the array's rules: identity for ==, elements for Equality.equals.
  var listA = new EqualityArrayList([1, 2]), listB = new EqualityArrayList([1, 2]);
  if (listA == listB || !Equality.equals(listA, listB)) return 25;
  var choiceA = new EqualityArrayWrappedChoice(Item(3)), choiceB = new EqualityArrayWrappedChoice(Item(3));
  if (!(choiceA == choiceB) || !Equality.equals(choiceA, choiceB)) return 26;
  if (choiceA == new EqualityArrayWrappedChoice(Item(4))) return 27;
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
