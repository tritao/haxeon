package haxeon.ui;

import NativeKitUI;
import NativeKitUI.UiPathVerb;

/** Mutable encoder for immutable Path geometry. */
class PathBuilder {
	var elements:Array<nkui_path_element>;
	final elementScratch:Array<nkui_path_element> = [];

	public function new() {
		elements = [];
	}

	public function clear():PathBuilder {
		elements.resize(0);
		return this;
	}

	public function moveTo(x:Float, y:Float):PathBuilder {
		append(UiPathVerb.MoveTo, 2, x, y);
		return this;
	}

	public function lineTo(x:Float, y:Float):PathBuilder {
		append(UiPathVerb.LineTo, 2, x, y);
		return this;
	}

	/** Adds a clockwise rounded rectangle with a radius clamped to its bounds. */
	public function roundRect(x:Float, y:Float, width:Float, height:Float,
		radius:Float):PathBuilder {
		if (width <= 0.0 || height <= 0.0)
			throw "Rounded rectangle requires positive bounds";
		var value = Math.max(0.0, Math.min(radius, Math.min(width, height) * 0.5));
		if (value <= 0.0)
			return moveTo(x, y).lineTo(x + width, y).lineTo(x + width, y + height)
				.lineTo(x, y + height).close();
		var k = 0.5522848;
		var control = value * k;
		moveTo(x + value, y).lineTo(x + width - value, y)
			.cubicTo(x + width - value + control, y, x + width, y + value - control,
				x + width, y + value)
			.lineTo(x + width, y + height - value)
			.cubicTo(x + width, y + height - value + control, x + width - value + control,
				y + height, x + width - value, y + height)
			.lineTo(x + value, y + height)
			.cubicTo(x + value - control, y + height, x, y + height - value + control,
				x, y + height - value)
			.lineTo(x, y + value)
			.cubicTo(x, y + value - control, x + value - control, y, x + value, y)
			.close();
		return this;
	}

	public function quadraticTo(controlX:Float, controlY:Float, x:Float, y:Float):PathBuilder {
		append(UiPathVerb.QuadraticTo, 4, controlX, controlY, x, y);
		return this;
	}

	public function cubicTo(control1X:Float, control1Y:Float, control2X:Float, control2Y:Float, x:Float, y:Float):PathBuilder {
		append(UiPathVerb.BezierTo, 6, control1X, control1Y, control2X, control2Y, x, y);
		return this;
	}

	public function arcTo(tangent1X:Float, tangent1Y:Float, tangent2X:Float, tangent2Y:Float, radius:Float):PathBuilder {
		append(UiPathVerb.ArcTo, 5, tangent1X, tangent1Y, tangent2X, tangent2Y, radius);
		return this;
	}

	public function close():PathBuilder {
		append(UiPathVerb.Close);
		return this;
	}

	public function build():Path {
		if (elements.length == 0)
			throw "Cannot build an empty path";
		var made = NativeKitUI.nkui_path_create(elements);
		UiResult.check(made.status, "path.build");
		return new Path(made.out_path);
	}

	function append(verb:UiPathVerb, count:Int = 0, a:Float = 0.0, b:Float = 0.0, c:Float = 0.0,
			d:Float = 0.0, e:Float = 0.0, f:Float = 0.0):Void {
		var index = elements.length;
		if (index == elementScratch.length) elementScratch.push(new nkui_path_element());
		var element = elementScratch[index];
		element.set_verb(verb);
		if (count > 0) element.set_values(0, a);
		if (count > 1) element.set_values(1, b);
		if (count > 2) element.set_values(2, c);
		if (count > 3) element.set_values(3, d);
		if (count > 4) element.set_values(4, e);
		if (count > 5) element.set_values(5, f);
		elements.push(element);
	}
}
