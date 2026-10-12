package haxeon.animation.rig;

/** Column-major 4x4 matrix helpers over Array<Float>, using column vectors. */
class Mat4 {
	public static function identity():Array<Float>
		return [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0];

	public static function translation(x:Float, y:Float, z:Float):Array<Float> {
		var m = identity();
		m[12] = x;
		m[13] = y;
		m[14] = z;
		return m;
	}

	/** A rigid frame from an origin and unit x and y axes; z completes a right-handed basis. */
	public static function frame(origin:Array<Float>, x:Array<Float>, y:Array<Float>):Array<Float> {
		var z = cross(x, y);
		return [x[0], x[1], x[2], 0.0, y[0], y[1], y[2], 0.0, z[0], z[1], z[2], 0.0, origin[0], origin[1], origin[2], 1.0];
	}

	public static function multiply(a:Array<Float>, b:Array<Float>):Array<Float> {
		var result:Array<Float> = [for (i in 0...16) 0.0];
		for (column in 0...4)
			for (row in 0...4) {
				var sum = 0.0;
				for (k in 0...4)
					sum += a[k * 4 + row] * b[column * 4 + k];
				result[column * 4 + row] = sum;
			}
		return result;
	}

	/** Inverse of a rigid transform (orthonormal rotation plus translation). */
	public static function rigidInverse(m:Array<Float>):Array<Float> {
		var result = identity();
		for (row in 0...3)
			for (column in 0...3)
				result[column * 4 + row] = m[row * 4 + column];
		for (row in 0...3)
			result[12 + row] = -(result[row] * m[12] + result[4 + row] * m[13] + result[8 + row] * m[14]);
		return result;
	}

	/**
	 * Removes scale and shear, keeping the x axis direction and translation.
	 * Exporters often bake unit scale (such as Mixamo's 0.01) into bones, which
	 * rigid attachments must not inherit.
	 */
	public static function orthonormalized(m:Array<Float>):Array<Float> {
		var x = normalize([m[0], m[1], m[2]]);
		var y = [m[4], m[5], m[6]];
		var along = dot(y, x);
		y = normalize([y[0] - x[0] * along, y[1] - x[1] * along, y[2] - x[2] * along]);
		return frame([m[12], m[13], m[14]], x, y);
	}

	public static function position(m:Array<Float>):Array<Float>
		return [m[12], m[13], m[14]];

	public static function dot(a:Array<Float>, b:Array<Float>):Float
		return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];

	public static function cross(a:Array<Float>, b:Array<Float>):Array<Float>
		return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];

	public static function subtract(a:Array<Float>, b:Array<Float>):Array<Float>
		return [a[0] - b[0], a[1] - b[1], a[2] - b[2]];

	public static function normalize(v:Array<Float>):Array<Float> {
		var length = Math.sqrt(dot(v, v));
		return length > 1e-12 ? [v[0] / length, v[1] / length, v[2] / length] : [1.0, 0.0, 0.0];
	}
}
