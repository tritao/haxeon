class LaneOwner {
	public var id:Int;
	public function new(id:Int) this.id=id;
}

/** Three bytes: consecutive elements cross both 32-bit and 64-bit lane words. */
struct LaneTiny {
	public var a:UInt8;
	public var b:UInt8;
	public var c:UInt8;
	public function new(n:Int) { a=cast n; b=cast(n+1); c=cast(n+2); }
}

struct LaneMixed {
	public var number:Int;
	public var owner:LaneOwner;
	public var optional:Null<LaneTiny>;
	public function new(n:Int, owner:LaneOwner) {
		number=n; this.owner=owner; optional=n%2==0 ? new LaneTiny(n+5) : null;
	}
}

class LanePolicyRandom {
	static var seed:Int=17;
	public static function next(limit:Int):Int {
		seed=seed*1664525+1013904223;
		return (seed>>>1)%limit;
	}
}

function checkLanes(expected:Array<Int>, tiny:Array<LaneTiny>, mixed:Array<LaneMixed>, nullable:Array<Null<LaneMixed>>, owner:LaneOwner):Bool {
	if(tiny.length!=expected.length || mixed.length!=expected.length || nullable.length!=expected.length) return false;
	for(i in 0...expected.length) {
		var n=expected[i];
		if(n<0) {
			var tinyFailed=false, mixedFailed=false;
			try { var value=tiny[i].a; } catch(_:Dynamic) { tinyFailed=true; }
			try { var value=mixed[i].number; } catch(_:Dynamic) { mixedFailed=true; }
			if(!tinyFailed || !mixedFailed || nullable[i]!=null) return false;
		} else {
			var t=tiny[i];
			var m=mixed[i], optional=m.optional;
			if((cast t.a:Int)!=(n&255) || (cast t.b:Int)!=((n+1)&255) || (cast t.c:Int)!=((n+2)&255) || m.number!=n || m.owner!=owner) return false;
			if(n%2==0) { if(optional==null || (cast optional.a:Int)!=((n+5)&255)) return false; }
			else if(optional!=null) return false;
			var value=nullable[i];
			if(n%3==0) { if(value!=null) return false; }
			else if(value==null || value.number!=n || value.owner!=owner) return false;
		}
	}
	return true;
}

class LanePolicyCensus {
	static var tiny:Array<LaneTiny>;
	static var mixed:Array<LaneMixed>;
	static var owner:LaneOwner;
	public static function prepare(n:Int):Void {
		owner=new LaneOwner(7); tiny=[]; mixed=[];
		for(i in 0...n) { tiny.push(new LaneTiny(i)); mixed.push(new LaneMixed(i,owner)); }
	}
	public static function perform():Int {
		tiny.reverse(); mixed.reverse(); tiny.reverse(); mixed.reverse();
		var total=0;
		for(i in 0...tiny.length) {
			if((cast tiny[i].a:Int)!=(i&255) || mixed[i].number!=i || mixed[i].owner!=owner) return 0;
			total++;
		}
		return total;
	}
}

function main():Int {
	var owner=new LaneOwner(7), expected:Array<Int>=[], tiny:Array<LaneTiny>=[], mixed:Array<LaneMixed>=[], nullable:Array<Null<LaneMixed>>=[];
	for(step in 0...128) {
		var operation=LanePolicyRandom.next(7), n=step+1;

		switch(operation) {
			case 0:
				var length=LanePolicyRandom.next(34), old=expected.length;
				expected.resize(length); tiny.resize(length); mixed.resize(length); nullable.resize(length);
				for(i in old...length) expected[i]=-1;
			case 1:
				var position=LanePolicyRandom.next(81)-40;
				expected.insert(position,n);
				tiny.insert(position,new LaneTiny(n));
				mixed.insert(position,new LaneMixed(n,owner));

				nullable.insert(position,n%3==0 ? null : new LaneMixed(n,owner));
			case 2:
				expected.reverse(); tiny.reverse(); mixed.reverse(); nullable.reverse();
			case 3:
				var position=LanePolicyRandom.next(81)-40, count=LanePolicyRandom.next(23)-2,
					e=expected.splice(position,count), t=tiny.splice(position,count), m=mixed.splice(position,count), z=nullable.splice(position,count);
				if(!checkLanes(e,t,m,z,owner)) return 3;
			case 4:
				var first=LanePolicyRandom.next(81)-40, end=LanePolicyRandom.next(81)-40;
				if(!checkLanes(expected.slice(first,end),tiny.slice(first,end),mixed.slice(first,end),nullable.slice(first,end),owner)) return 4;
				if(!checkLanes(expected.copy(),tiny.copy(),mixed.copy(),nullable.copy(),owner)) return 5;
			case 5:
				var end=expected.length/2;
				if(!checkLanes(expected.concat(expected.slice(0,Std.int(end))),tiny.concat(tiny.slice(0,Std.int(end))),
					mixed.concat(mixed.slice(0,Std.int(end))),nullable.concat(nullable.slice(0,Std.int(end))),owner)) return 6;
			case 6:
				var index=LanePolicyRandom.next(60), old=expected.length;
				expected[index]=n; tiny[index]=new LaneTiny(n); mixed[index]=new LaneMixed(n,owner); nullable[index]=n%3==0 ? null : new LaneMixed(n,owner);
				for(i in old...index) expected[i]=-1;
		}
		if(!checkLanes(expected,tiny,mixed,nullable,owner)) return 7;
		if(step%16==0) hl.Gc.major();
	}
	for(n in [8,1024]) {
		LanePolicyCensus.prepare(n);
		#if !wasm
		var before=hl.Gc.totalAllocated();
		#end
		if(LanePolicyCensus.perform()!=n) return 8;
		#if !wasm
		if(hl.Gc.totalAllocated()!=before) return 9;
		#end
	}
	return 42;
}
