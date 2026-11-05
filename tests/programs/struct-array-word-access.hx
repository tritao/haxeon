struct ArrayWordRect {
	public var x:Float;
	public var y:Float;
	public var width:Float;
	public var height:Float;
	public function new(n:Int) { x=n; y=n+1; width=n+2; height=n+3; }
}

struct ArrayWordTiny {
	public var a:UInt8;
	public var b:UInt8;
	public var c:UInt8;
	public function new(n:Int) { a=cast n; b=cast(n+1); c=cast(n+2); }
}

/** Exports also serve the paired scalar-lane microbenchmark. Preparation is outside its allocation window. */
class ArrayWordBench {
	static var rects:Array<ArrayWordRect>;
	static var tiny:Array<ArrayWordTiny>;
	public static function prepare(n:Int):Void {
		rects=[]; tiny=[];
		for(i in 0...n) { rects.push(new ArrayWordRect(i)); tiny.push(new ArrayWordTiny(i)); }
	}
	public static function readRects(rounds:Int):Float {
		var sum=0.0;
		for(round in 0...rounds) for(i in 0...rects.length) {
			var r=rects[i]; sum+=r.x+r.y+r.width+r.height;
		}
		return sum;
	}
	public static function readTiny(rounds:Int):Float {
		var sum=0.0;
		for(round in 0...rounds) for(i in 0...tiny.length) {
			var t=tiny[i]; sum+=(cast t.a:Int)+(cast t.b:Int)+(cast t.c:Int);
		}
		return sum;
	}
	public static function writeRects(rounds:Int):Int {
		for(round in 0...rounds) for(i in 0...rects.length) {
			rects[i].x=i+round; rects[i].y=i+round+1; rects[i].width=i+round+2; rects[i].height=i+round+3;
		}
		return rects.length*rounds;
	}
	public static function writeTiny(rounds:Int):Int {
		for(round in 0...rounds) for(i in 0...tiny.length) {
			tiny[i].a=cast(i+round); tiny[i].b=cast(i+round+1); tiny[i].c=cast(i+round+2);
		}
		return tiny.length*rounds;
	}
	public static function reverseRects(rounds:Int):Int {
		for(round in 0...rounds) rects.reverse();
		return rects.length*rounds;
	}
	public static function reverseTiny(rounds:Int):Int {
		for(round in 0...rounds) tiny.reverse();
		return tiny.length*rounds;
	}
	public static function perform():Int {
		var n=rects.length;
		if(writeRects(3)!=n*3 || writeTiny(3)!=n*3 || reverseRects(2)!=n*2 || reverseTiny(2)!=n*2) return 1;
		var rectSum=0.0, tinySum=0.0;
		for(i in 0...n) { rectSum+=4*i+14; tinySum+=((i+2)&255)+((i+3)&255)+((i+4)&255); }
		if(readRects(1)!=rectSum || readTiny(1)!=tinySum) return 2;
		return 42;
	}
}

function main():Int {
	for(n in [1,2,3,4,5,7,8,9,31,32,33,63,64,65,1024]) {
		ArrayWordBench.prepare(n);
		#if !wasm
		var before=hl.Gc.totalAllocated();
		#end
		if(ArrayWordBench.perform()!=42) return 1;
		#if !wasm
		if(hl.Gc.totalAllocated()!=before) return 2;
		#end
	}
	return 42;
}
