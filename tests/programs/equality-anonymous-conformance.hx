import haxeon.Equality;
import haxeon.Hashing;

class EqualityOrder {
  public static var visited:Int = 0;
}

struct OrderedLeaf implements Hashable {
  public final value:Int;
  public function new(value:Int) this.value = value;
  public function equals(other:OrderedLeaf):Bool {
    EqualityOrder.visited = EqualityOrder.visited * 10 + value;
    return value == other.value;
  }
  public function hash():Int {
    EqualityOrder.visited = EqualityOrder.visited * 10 + value;
    return value;
  }
}
typedef OrderedFields = {z:OrderedLeaf, a:OrderedLeaf};
struct HashableLeaf implements Hashable {
  public final value:Int;
  public function new(value:Int) this.value = value;
  public function equals(other:HashableLeaf):Bool return value % 10 == other.value % 10;
  public function hash():Int return value % 10;
}
typedef HashContainer = {value:HashableLeaf};
typedef Pair = {x:Int, y:Int};
typedef OptionalRecord = {?value:Int};
typedef Box = {pair:Pair, numbers:Array<Int>};
typedef FloatRecord = {value:Float};
typedef ReversePair = {y:Int, x:Int};
typedef Empty = {};
typedef TwoPairs = {first:Pair, second:Pair};

function equalGeneric < T:Equatable > (a:T, b:T):Bool return Equality.equals(a, b);

function hashGeneric < T:Hashable > (a:T):Int return Hashing.hash(a);

function main():Int {
  var a:Pair = {x: 0, y: 1}, b:Pair = {x: 0, y: 1}, different:Pair = {x: 1, y: 0};
  if (a == b || a != a) return 1;
  if (!Equality.equals(a, b) || Equality.equals(a, different)) return 2;
  if (Hashing.hash(a) != Hashing.hash(b)) return 3;
  if (!equalGeneric(a, b) || hashGeneric(a) != hashGeneric(b)) return 4;
  if (Equality.sameForChange(a, b)) return 9;
  var e:Box = {pair: a, numbers: [1, 2]}, f:Box = {pair: b, numbers: [1, 2]};
  if (!Equality.equals(e, f)) return 6;
  var x:Null<Pair> = null, y:Null<Pair> = null;
  if (!Equality.equals(x, y)) return 7;
  var map:Map<Pair, Int> = [];
  map.set(a, 42);
  if (!map.exists(b) || map.exists(different)) return 8;
  var nan:FloatRecord = {value: Math.NaN};
  if (Equality.equals(nan, nan)) return 10;
  var positiveZero:FloatRecord = {value: 0.0}, negativeZero:FloatRecord = {value: -0.0};
  if (!Equality.equals(positiveZero,
    negativeZero) || Hashing.hash(positiveZero) != Hashing.hash(negativeZero)) return 11;
  var reversed:ReversePair = {y: 1, x: 0};
  if (!Equality.equals(a, reversed) || Hashing.hash(a) != Hashing.hash(reversed)) return 12;
  var empty:Empty = {}, otherEmpty:Empty = {};
  if (empty == otherEmpty || !Equality.equals(empty,
    otherEmpty) || Hashing.hash(empty) != Hashing.hash(otherEmpty)) return 13;
  var maybeA:Null<Pair> = a, maybeB:Null<Pair> = b, maybeAlias:Null<Pair> = a;
  if (maybeA == maybeB || maybeA != maybeAlias || !Equality.equals(maybeA, maybeB)) return 14;
  var repeated:TwoPairs = {first: a, second: b}, repeatedCopy:TwoPairs = {first: b, second: a};
  if (!Equality.equals(repeated, repeatedCopy) || Hashing.hash(repeated) != Hashing.hash(repeatedCopy)) return 15;
  var hashLeft:HashContainer = {value: new HashableLeaf(1)};
  var hashRight:HashContainer = {value: new HashableLeaf(11)};
  if (!Equality.equals(hashLeft, hashRight) || Hashing.hash(hashLeft) != Hashing.hash(hashRight)) return 28;
  if (hashGeneric(hashLeft) != hashGeneric(hashRight)) return 29;
  var ordered:OrderedFields = {z: new OrderedLeaf(2), a: new OrderedLeaf(1)}, orderedCopy:OrderedFields = {
    a: new OrderedLeaf(1),
    z: new OrderedLeaf(2)
  };
  EqualityOrder.visited = 0;
  if (!Equality.equals(ordered, orderedCopy) || EqualityOrder.visited != 12) return 34;
  EqualityOrder.visited = 0;
  Hashing.hash(ordered);
  if (EqualityOrder.visited != 12) return 35;
  var absent:OptionalRecord = {}, explicitNull:OptionalRecord = {value: null};
  var optionalOne:OptionalRecord = {value: 1},
    optionalCopy:OptionalRecord = {value: 1}, optionalTwo:OptionalRecord = {value: 2};
  if (!Equality.equals(absent, explicitNull) || Hashing.hash(absent) != Hashing.hash(explicitNull)) return 36;
  if (!Equality.equals(optionalOne, optionalCopy) || Hashing.hash(optionalOne) != Hashing.hash(optionalCopy)) return 37;
  if (Equality.equals(optionalOne, optionalTwo) || Equality.equals(absent, optionalOne)) return 38;
  return 42;
}
