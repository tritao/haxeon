struct Inner {
  public var count:Int;
  public var label:String;
  public function new(count:Int, label:String) { this.count = count; this.label = label; }
}

struct Value {
  public var inner:Inner;
  public var extra:Int;
  public function new(count:Int, label:String, extra:Int) {
    inner = new Inner(count, label);
    this.extra = extra;
  }
}

struct Pair {
  public var x:Int;
  public var y:Int;
  public function new(x:Int, y:Int) { this.x = x; this.y = y; }
  public function total():Int return x + y;
}

struct WideFloat {
  public var x:Float;
  public var y:Float;
  public var label:String;
  public function new(x:Float, y:Float, label:String) { this.x = x; this.y = y; this.label = label; }
}

function consume(value:Pair):Int {
  value.x += 1;
  return value.x + value.y;
}

function bump(value:Pair):Pair {
  value.x += 1;
  return value;
}

function recurse(value:Pair, depth:Int):Int {
  if (depth == 0) return value.x;
  value.x += 1;
  return recurse(value, depth - 1);
}

function wide(a0:Int, a1:Int, a2:Int, a3:Int, a4:Int, a5:Int, a6:Int,
    a7:Int, a8:Int, a9:Int, a10:Int, a11:Int, a12:Int, a13:Int, value:Pair):Pair {
  value.x += a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9 + a10 + a11 + a12 + a13;
  return value;
}

function veryWide(a0:Int, a1:Int, a2:Int, a3:Int, a4:Int, a5:Int, a6:Int, a7:Int,
    a8:Int, a9:Int, a10:Int, a11:Int, a12:Int, a13:Int, a14:Int, a15:Int,
    a16:Int, a17:Int, a18:Int, a19:Int, a20:Int, a21:Int, a22:Int, a23:Int,
    a24:Int, a25:Int, a26:Int, a27:Int, a28:Int, a29:Int, value:Pair):Pair {
  value.x += a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9 + a10 + a11 + a12 + a13 + a14
    + a15 + a16 + a17 + a18 + a19 + a20 + a21 + a22 + a23 + a24 + a25 + a26 + a27 + a28 + a29;
  return value;
}

function veryWideMixed(a0:Int, a1:Int, a2:Int, a3:Int, a4:Int, a5:Int, a6:Int, a7:Int,
    a8:Int, a9:Int, a10:Int, a11:Int, a12:Int, a13:Int, a14:Int, a15:Int,
    a16:Int, a17:Int, a18:Int, a19:Int, a20:Int, a21:Int, a22:Int, a23:Int,
    a24:Int, a25:Int, a26:Int, a27:Int, a28:Int, a29:Int, value:WideFloat):WideFloat {
  value.x += a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9 + a10 + a11 + a12 + a13 + a14
    + a15 + a16 + a17 + a18 + a19 + a20 + a21 + a22 + a23 + a24 + a25 + a26 + a27 + a28 + a29;
  return value;
}

class Holder {
  public var value:Value;
  public function new(value:Value) this.value = value;
}

class PairHolder {
  public var value:Pair;
  public function new(value:Pair) this.value = value;
}

class Processor {
  public function new() {}
  public function process(value:Pair):Pair { value.y += 1; return value; }
}

function mutate(holder:Holder):Int {
  holder.value.inner.count = 90;
  return 3;
}

function combine(value:Value, amount:Int):Value {
  value.inner.count += amount;
  return value;
}

function nestedRead(value:Value, amount:Int):Int {
  value.inner.count += amount;
  return value.inner.count + value.extra + value.inner.label.length;
}

function callThenThrow(value:Value, callback:Void->Void):Value {
  value.inner.count += 1;
  callback();
  throw "expected";
}

function around(value:Value, callback:Void->Void):Value {
  value.inner.count += 2;
  callback();
  return value;
}

function main():Int {
	var pair = new Pair(2, 3);
	if (consume(pair) != 6 || pair.x != 2) return 6;
	var allocatedBefore = hl.Gc.totalAllocated();
	var sum = 0;
	for (i in 0...10000) sum += consume(pair);
	var allocated = hl.Gc.totalAllocated() - allocatedBefore;
	if (sum != 60000 || pair.x != 2 || allocated > 4096) return 8;
	allocatedBefore = hl.Gc.totalAllocated();
	sum = 0;
	for (i in 0...10000) sum += pair.total();
	allocated = hl.Gc.totalAllocated() - allocatedBefore;
	if (sum != 50000 || allocated > 4096) return 17;
	allocatedBefore = hl.Gc.totalAllocated();
	sum = 0;
	for (i in 0...10000) {
		var returned = bump(pair);
		sum += returned.x;
	}
	allocated = hl.Gc.totalAllocated() - allocatedBefore;
	if (sum != 30000 || pair.x != 2 || allocated > 4096) return 9;
	var staticCall:Pair->Pair = bump;
	var step = 2;
	var capturedCall:Pair->Pair = function(value:Pair):Pair {
		value.x += step;
		return value;
	};
	allocatedBefore = hl.Gc.totalAllocated();
	sum = 0;
	for (i in 0...10000) sum += staticCall(pair).x + capturedCall(pair).x;
	allocated = hl.Gc.totalAllocated() - allocatedBefore;
	if (sum != 70000 || pair.x != 2 || allocated > 4096) return 11;
	allocatedBefore = hl.Gc.totalAllocated();
	sum = 0;
	for (i in 0...1000) sum += recurse(pair, 8);
	allocated = hl.Gc.totalAllocated() - allocatedBefore;
	if (sum != 10000 || pair.x != 2 || allocated > 4096) return 12;
	var pairHolder = new PairHolder(pair);
	allocatedBefore = hl.Gc.totalAllocated();
	for (i in 0...10000) pairHolder.value = bump(pairHolder.value);
	allocated = hl.Gc.totalAllocated() - allocatedBefore;
	if (pairHolder.value.x != 10002 || allocated > 4096) return 13;
	allocatedBefore = hl.Gc.totalAllocated();
	sum = 0;
	for (i in 0...10000) sum += wide(1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, pair).x;
	allocated = hl.Gc.totalAllocated() - allocatedBefore;
	if (sum != 160000 || allocated > 4096) return 14;
	allocatedBefore = hl.Gc.totalAllocated();
	sum = 0;
	for (i in 0...10000)
		sum += veryWide(1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
			1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, pair).x;
	allocated = hl.Gc.totalAllocated() - allocatedBefore;
	if (sum != 320000 || allocated > 4096) return 18;
	var wideFloat = new WideFloat(2.5, 3.5, "managed");
	allocatedBefore = hl.Gc.totalAllocated();
	var total = 0.0, secondTotal = 0.0;
	for (i in 0...10000) {
		var result = veryWideMixed(1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
			1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, wideFloat);
		if (result.label != "managed" || result.y != 3.5) return 19;
		total += result.x;
		secondTotal += result.y;
	}
	allocated = hl.Gc.totalAllocated() - allocatedBefore;
	if (total != 325000.0 || secondTotal != 35000.0 || allocated > 4096) return 20;
	var checkedWide = veryWideMixed(1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
		1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, wideFloat);
	if (checkedWide.label != "managed" || checkedWide.y != 3.5) return 19;
	var processor = new Processor();
	allocatedBefore = hl.Gc.totalAllocated();
	sum = 0;
	for (i in 0...10000) sum += processor.process(pair).y;
	allocated = hl.Gc.totalAllocated() - allocatedBefore;
	if (sum != 40000 || allocated > 4096) return 15;
	#if !wasm
	// The HashLink-only method specialization must retain its receiver null check.
	var absentProcessor:Processor = null;
	var caughtNull = false;
	try absentProcessor.process(pair) catch (_:Dynamic) caughtNull = true;
	if (!caughtNull) return 16;
	#end
  var holder = new Holder(new Value(7, "managed", 4));
	if (nestedRead(holder.value, mutate(holder)) != 21 || holder.value.inner.count != 90) return 7;
	holder.value = new Value(7, "managed", 4);
  // The first argument is a snapshot before evaluating the second argument.
  var result = combine(holder.value, mutate(holder));
  if (result.inner.count != 10 || holder.value.inner.count != 90 || result.inner.label != "managed") return 1;
  holder.value = result;
  result.inner.count = 11;
  if (holder.value.inner.count != 10) return 2;
  var direct:Value->Int->Value = combine;
  var captured = 2;
  var closure:Value->Value = function(value:Value):Value {
    value.extra += captured;
    return value;
  };
  var called = closure(direct(holder.value, 1));
  if (called.inner.count != 11 || called.extra != 6 || holder.value.extra != 4) return 3;
	var observed = around(holder.value, function() {
		holder.value.inner.count = 33;
		hl.Gc.major();
	});
	if (observed.inner.count != 12 || observed.inner.label != "managed" || holder.value.inner.count != 33) return 10;
	holder.value = new Value(10, "managed", 4);
  try {
    callThenThrow(holder.value, function() {
      if (holder.value.inner.count != 10) throw "snapshot changed";
      holder.value.inner.count = 20;
    });
    return 4;
  } catch (error:Dynamic) {
    if (error != "expected" || holder.value.inner.count != 20) return 5;
  }
  return 42;
}
