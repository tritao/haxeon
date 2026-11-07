class IteratorOwner {
 public var offset:Int;
 public function new(offset:Int) { this.offset = offset; }
}

enum IteratorChoice {
 Empty;
 Item(value:Int, owner:IteratorOwner);
}

function score(value:IteratorChoice):Int {
 return switch value {
  case Empty: 0;
  case Item(number, owner): number + owner.offset;
 };
}

function main():Int {
 var values:Array<IteratorChoice> = [Item(40, new IteratorOwner(2)), Empty, Item(7, new IteratorOwner(0))];
 var iterator:Iterator<IteratorChoice> = values.iterator();
 if (!iterator.hasNext()) return 1;
 var snapshot = iterator.next();
 values[0] = Empty;
 if (score(snapshot) != 42) return 2;
 values.push(Item(3, new IteratorOwner(0)));
 var sum = 0;
 while (iterator.hasNext()) sum += score(iterator.next());
 if (sum != 10) return 3;
 var exhausted = false;
 try iterator.next() catch (_:Dynamic) exhausted = true;
 if (!exhausted) return 4;
 var second = values.iterator();
 var all = 0;
 while (second.hasNext()) all += score(second.next());
 if (all != 10) return 5;
 var optional:Array<Null<IteratorChoice>> = [null, Item(42, new IteratorOwner(0))];
 var optionalIterator = optional.iterator();
 if (optionalIterator.next() != null) return 6;
 var present = optionalIterator.next();
 if (present == null || score(present) != 42 || optionalIterator.hasNext()) return 7;
 var map:Map<Int, IteratorChoice> = new Map();
 map.set(1, Item(42, new IteratorOwner(0)));
 var mapIterator = map.iterator();
 if (!mapIterator.hasNext() || score(mapIterator.next()) != 42 || mapIterator.hasNext()) return 8;
 return 42;
}
