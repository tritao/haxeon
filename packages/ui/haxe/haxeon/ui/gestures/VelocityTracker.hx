package haxeon.ui.gestures;

/** Pointer velocity in px/s from the samples of the last 100 ms. */
class VelocityTracker {
	public static inline var WindowSeconds:Float = 0.1;
	final times:Array<Float> = [];
	final xs:Array<Float> = [];
	final ys:Array<Float> = [];
	public var velocityX(default, null):Float = 0.0;
	public var velocityY(default, null):Float = 0.0;

	public function new() {}

	public function reset():Void {
		times.resize(0);
		xs.resize(0);
		ys.resize(0);
		velocityX = 0.0;
		velocityY = 0.0;
	}

	public function add(time:Float, x:Float, y:Float):Void {
		times.push(time);
		xs.push(x);
		ys.push(y);
		while (times.length > 2 && time - times[0] > WindowSeconds) {
			times.shift();
			xs.shift();
			ys.shift();
		}
	}

	/** Updates velocityX and velocityY; a pointer that has rested for the whole window has none. */
	public function compute(now:Float):Void {
		velocityX = 0.0;
		velocityY = 0.0;
		var count = times.length;
		if (count < 2 || now - times[count - 1] > WindowSeconds)
			return;
		var first = 0;
		while (first < count - 1 && times[count - 1] - times[first] > WindowSeconds)
			first++;
		var elapsed = times[count - 1] - times[first];
		if (elapsed < 0.004)
			return;
		velocityX = (xs[count - 1] - xs[first]) / elapsed;
		velocityY = (ys[count - 1] - ys[first]) / elapsed;
	}
}
