package haxeon.ui;

import NativeKitUI;

/** Base class for immutable paint resources. */
class Paint extends NativeKitUIResource {
	function new(value:nkui_resource)
		super(value);
}

/** A uniform RGBA paint. */
class SolidPaint extends Paint {
	@:allow(haxeon.ui.SolidPaint)
	private function new(value:nkui_resource)
		super(value);

	public static function create(color:Color):SolidPaint {
		var made = NativeKitUI.nkui_paint_create_solid(color.nativeValue());
		UiResult.check(made.status, "paint.createSolid");
		return new SolidPaint(made.out_paint);
	}
}

/** Immutable linear gradient paint with up to eight color stops. */
class LinearGradientPaint extends Paint {
	@:allow(haxeon.ui.LinearGradientPaint)
	private function new(value:nkui_resource)
		super(value);

	public static function create(startX:Float, startY:Float, endX:Float, endY:Float,
			stops:Array<GradientStop>):LinearGradientPaint {
		if (stops == null || stops.length < 2 || stops.length > NativeKitUIConstants.NKUI_GRADIENT_MAX_STOPS)
			throw "Linear gradients require between two and eight stops";
		var nativeStops:Array<nkui_gradient_stop> = [];
		for (stop in stops) {
			if (stop == null)
				throw "Linear gradient stops cannot be null";
			nativeStops.push(stop.nativeValue());
		}
		var made = NativeKitUI.nkui_paint_create_linear_gradient(startX, startY, endX, endY,
			nativeStops);
		UiResult.check(made.status, "paint.createLinearGradient");
		return new LinearGradientPaint(made.out_paint);
	}
}

/** Immutable position and color pair used by a gradient paint. */
class GradientStop {
	public final offset:Float;
	public final color:Color;

	public function new(offset:Float, color:Color) {
		if (offset < 0.0 || offset > 1.0)
			throw "Gradient stop offset must be in the range 0..1";
		this.offset = offset;
		this.color = color;
	}

	@:allow(haxeon.ui.LinearGradientPaint)
	private function nativeValue():nkui_gradient_stop {
		var result = new nkui_gradient_stop();
		result.set_offset(offset);
		result.set_color(color.nativeValue());
		return result;
	}
}
