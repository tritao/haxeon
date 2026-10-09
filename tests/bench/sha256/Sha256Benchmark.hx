import haxe.crypto.Sha256;
import haxe.io.Bytes;

class Sha256Benchmark {
	static var input:Bytes;
	static function main():Int {
		#if !wasm
		initialize(17000000);
		var start = Sys.time();
		fast(3);
		var fastSeconds = Sys.time() - start;
		start = Sys.time();
		portable(3);
		Sys.println("sha256-benchmark fast=" + fastSeconds + " portable=" + (Sys.time() - start));
		#end
		return 42;
	}
	@:expose public static function initialize(length:Int):Int {
		input = Bytes.alloc(length);
		for (i in 0...length) input.set(i, (i * 37 + 11) & 255);
		return length;
	}
	@:expose public static function fast(rounds:Int):Int {
		var result = 0;
		for (i in 0...rounds) result ^= Sha256.make(input).get(0);
		return result;
	}
	@:expose public static function portable(rounds:Int):Int {
		var result = 0;
		for (i in 0...rounds) result ^= Sha256.portableMake(input).get(0);
		return result;
	}
}
