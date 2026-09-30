@:value
class Rgb {
	public final r:Float;
	public final g:Float;

	public function new(r:Float, g:Float) {
		this.r = r;
		this.g = g;
	}

	public function sum():Float {
		return r + g;
	}
}

class Holder {
	public var color:Rgb;

	public static var shared:Null<Rgb> = null;

	public function new() {
		color = new Rgb(0.0, 0.0);
	}
}

function pick(flag:Bool):Null<Rgb> {
	return flag ? new Rgb(1.0, 2.0) : null;
}

function withGuard(?c:Rgb):Rgb {
	var h = new Holder();
	if (c != null)
		h.color = c;
	return h.color;
}

function main():Int {
	var failures = 0;
	var some = pick(true);
	var none = pick(false);
	if (some == null || some.sum() != 3.0)
		failures += 1;
	if (none != null)
		failures += 2;
	if (withGuard().sum() != 0.0 || withGuard(new Rgb(4.0, 5.0)).sum() != 9.0)
		failures += 4;
	var local:Null<Rgb> = null;
	if (local != null)
		failures += 8;
	local = new Rgb(2.0, 2.0);
	if (local == null || local.sum() != 4.0)
		failures += 16;
	if (Holder.shared != null)
		failures += 32;
	return failures == 0 ? 42 : failures;
}
