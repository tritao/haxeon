/**
 * A local passed by reference keeps the value a callee writes through the reference, also where the JIT turns a known
 * constant into a shared box: `var len = 0; f(len); (len:Dynamic)` boxes what f wrote, not 0. EReg.matched relies on it
 * (its length comes back through a reference and is passed as an optional Int). Compiled by Haxe, not by Haxeon.
 */
class JitReferencedConstantMain {
	@:noInline static function setInt(target:hl.Ref<Int>, value:Int):Void
		target.set(value);

	@:noInline static function setBool(target:hl.Ref<Bool>):Void
		target.set(true);

	static function check(ok:Bool, message:String):Void {
		if (!ok) {
			Sys.println("FAIL: " + message);
			Sys.exit(1);
		}
	}

	static function main():Void {
		var pattern = ~/(\w+)=(\d+)/;
		check(pattern.match("key=42") && pattern.matched(1) == "key" && pattern.matched(2) == "42", "EReg.matched lost its length");
		var len = 0;
		setInt(len, 24);
		var boxed:Dynamic = len, optional:Null<Int> = len;
		check(boxed == 24 && optional == 24, 'a referenced Int boxed as $boxed and $optional, not 24');
		// The reference is taken after the box in the loop body, so the second pass must box the new value.
		var seen = [], counter = 0;
		for (i in 0...2) {
			var value:Dynamic = counter;
			seen.push(value);
			setInt(counter, i + 5);
		}
		check(seen[0] == 0 && seen[1] == 5, 'boxes in a loop saw ${seen}, not [0,5]');
		var flag = false;
		setBool(flag);
		var flagged:Dynamic = flag;
		check(flagged == true, "a referenced Bool boxed as its earlier constant");
		Sys.println("PASS: referenced locals box the values written through their references");
	}
}
