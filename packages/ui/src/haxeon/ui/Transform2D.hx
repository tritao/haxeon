package haxeon.ui;

import Diffable;
import Hashable;

/** Six-value affine transform using x'=a*x+c*y+tx and y'=b*x+d*y+ty. */
struct Transform2D implements Hashable implements Diffable {
	static inline var InvertibilityEpsilon:Float = 0.000001;

	/** The horizontal scale component. */
	public final a:Float;

	/** The vertical skew component. */
	public final b:Float;

	/** The horizontal skew component. */
	public final c:Float;

	/** The vertical scale component. */
	public final d:Float;

	/** The horizontal translation. */
	public final tx:Float;

	/** The vertical translation. */
	public final ty:Float;

	/** The matrix [a c tx; b d ty]. */
	public function new(a:Float, b:Float, c:Float, d:Float, tx:Float, ty:Float) {
		this.a = a;
		this.b = b;
		this.c = c;
		this.d = d;
		this.tx = tx;
		this.ty = ty;
	}

	/** The transform that changes nothing. */
	public static function identity():Transform2D
		return new Transform2D(1.0, 0.0, 0.0, 1.0, 0.0, 0.0);

	/** A move by (`x`, `y`). */
	public static function translation(x:Float, y:Float):Transform2D
		return new Transform2D(1.0, 0.0, 0.0, 1.0, x, y);

	/** A scale by `x` and `y`. */
	public static function scale(x:Float, y:Float):Transform2D
		return new Transform2D(x, 0.0, 0.0, y, 0.0, 0.0);

	/** A rotation by `radians`. */
	public static function rotation(radians:Float):Transform2D {
		var cosine = Math.cos(radians);
		var sine = Math.sin(radians);
		return new Transform2D(cosine, sine, -sine, cosine, 0.0, 0.0);
	}

	/** Returns this transform followed by `other` in column-vector notation. */
	public function multiply(other:Transform2D):Transform2D {
		return new Transform2D(a * other.a + c * other.b,
			b * other.a + d * other.b,
			a * other.c + c * other.d,
			b * other.c + d * other.d,
			a * other.tx + c * other.ty + tx,
			b * other.tx + d * other.ty + ty);
	}

	/** Alias for multiply, useful when composing a local transform chain. */
	public function concat(other:Transform2D):Transform2D
		return multiply(other);

	/** The matrix's determinant: 0 for a transform that cannot be undone. */
	public function determinant():Float
		return a * d - b * c;

	/** Whether the transform can be undone. */
	public function isInvertible():Bool {
		var value = determinant();
		return Math.isFinite(value) && Math.abs(value) >= InvertibilityEpsilon && Math.isFinite(a) && Math.isFinite(b)
			&& Math.isFinite(c) && Math.isFinite(d) && Math.isFinite(tx) && Math.isFinite(ty);
	}

	/** The inverse transform, or null when there is none. */
	public function tryInverse():Null<Transform2D> {
		if (!isInvertible())
			return null;
		var reciprocal = 1.0 / determinant();
		return new Transform2D(d * reciprocal, -b * reciprocal, -c * reciprocal,
			a * reciprocal, (c * ty - d * tx) * reciprocal,
			(b * tx - a * ty) * reciprocal);
	}

	/** The inverse transform. Throws when there is none. */
	public function inverse():Transform2D {
		var result = tryInverse();
		if (result == null)
			throw "Transform is not invertible";
		return result;
	}

	/** `point` transformed, translation included. */
	public function transformPoint(point:Point):Point {
		if (point == null)
			throw "Transform points cannot be null";
		return new Point(a * point.x + c * point.y + tx,
			b * point.x + d * point.y + ty);
	}

	/** The x of `(x, y)` after this transform; allocation-free counterpart of transformPoint. */
	internal inline function transformedX(x:Float, y:Float):Float
		return a * x + c * y + tx;

	internal inline function transformedY(x:Float, y:Float):Float
		return b * x + d * y + ty;

	/** The x of `(x, y)` after the inverse transform, with the same arithmetic as tryInverse().transformPoint. Requires isInvertible(). */
	internal inline function inverseTransformedX(x:Float, y:Float):Float {
		var reciprocal = 1.0 / determinant();
		return d * reciprocal * x + -c * reciprocal * y + (c * ty - d * tx) * reciprocal;
	}

	internal inline function inverseTransformedY(x:Float, y:Float):Float {
		var reciprocal = 1.0 / determinant();
		return -b * reciprocal * x + a * reciprocal * y + (b * tx - a * ty) * reciprocal;
	}

	/** `vector` transformed, without translation. */
	public function transformVector(vector:Point):Point {
		if (vector == null)
			throw "Transform vectors cannot be null";
		return new Point(a * vector.x + c * vector.y,
			b * vector.x + d * vector.y);
	}

	/** This transform followed by a move. */
	public function translated(x:Float, y:Float):Transform2D
		return multiply(Transform2D.translation(x, y));

	/** This transform followed by a scale. */
	public function scaled(x:Float, y:Float):Transform2D
		return multiply(Transform2D.scale(x, y));

	/** This transform followed by a rotation. */
	public function rotated(radians:Float):Transform2D
		return multiply(Transform2D.rotation(radians));

	/** This transform followed by a skew. */
	public function skewed(xRadians:Float, yRadians:Float):Transform2D {
		var x = Math.tan(xRadians), y = Math.tan(yRadians);
		return new Transform2D(a + c * y, b + d * y, a * x + c, b * x + d, tx, ty);
	}
}
