package haxeon.ui.plotting;

import Observable;
import haxeon.ui.Color;

/** Shared plotting model with explicit or data-derived ranges. */
class PlotModel implements Observable {
	var values:Array<PlotSeries>;
	public var minimumX(default, null):Null<Float>;
	public var maximumX(default, null):Null<Float>;
	public var minimumY(default, null):Null<Float>;
	public var maximumY(default, null):Null<Float>;

	public function new() {
		values = [];
		minimumX = null;
		maximumX = null;
		minimumY = null;
		maximumY = null;
	}

	public function addSeries(series:PlotSeries):Void {
		if (series == null || seriesById(series.id) != null)
			throw "Plot series IDs must be unique and non-null";
		var next = values.copy();
		next.push(series);
		values = next;
	}

	public function removeSeries(id:String):Bool {
		var series = seriesById(id);
		if (series == null)
			return false;
		var next = values.copy();
		next.remove(series);
		values = next;
		return true;
	}

	public function series():Array<PlotSeries>
		return values.copy();

	public function seriesById(id:String):Null<PlotSeries> {
		for (series in values)
			if (series.id == id)
				return series;
		return null;
	}

	/** Sets any combination of fixed axis bounds; null keeps that bound data-derived. */
	public function setRange(minimumX:Null<Float>, maximumX:Null<Float>,
			minimumY:Null<Float>, maximumY:Null<Float>):Void {
		validateBound(minimumX, "minimumX");
		validateBound(maximumX, "maximumX");
		validateBound(minimumY, "minimumY");
		validateBound(maximumY, "maximumY");
		if (minimumX != null && maximumX != null && minimumX >= maximumX)
			throw "Plot X range must be increasing";
		if (minimumY != null && maximumY != null && minimumY >= maximumY)
			throw "Plot Y range must be increasing";
		if (this.minimumX == minimumX && this.maximumX == maximumX && this.minimumY == minimumY
			&& this.maximumY == maximumY)
			return;
		this.minimumX = minimumX;
		this.maximumX = maximumX;
		this.minimumY = minimumY;
		this.maximumY = maximumY;
	}

	public function clearRange():Void
		setRange(null, null, null, null);

	/** Reads every paint input while a reactive effect captures the model and series fields. */
	public function trackPaintData():Void {
		var bounds = minimumX + ":" + maximumX + ":" + minimumY + ":" + maximumY;
		for (series in values) {
			var visible = series.visible;
			var count = series.pointCount;
		}
	}

	public function range():Null<PlotRange> {
		var lowX:Null<Float> = minimumX;
		var highX:Null<Float> = maximumX;
		var lowY:Null<Float> = minimumY;
		var highY:Null<Float> = maximumY;
		var deriveLowX = lowX == null;
		var deriveHighX = highX == null;
		var deriveLowY = lowY == null;
		var deriveHighY = highY == null;
		for (series in values)
			if (series.visible)
				for (index in 0...series.pointCount) {
					var point = series.pointAt(index);
					if (deriveLowX)
						lowX = lowX == null ? point.x : Math.min(lowX, point.x);
					if (deriveHighX)
						highX = highX == null ? point.x : Math.max(highX, point.x);
					if (deriveLowY)
						lowY = lowY == null ? point.y : Math.min(lowY, point.y);
					if (deriveHighY)
						highY = highY == null ? point.y : Math.max(highY, point.y);
				}
		if (lowX == null || highX == null || lowY == null || highY == null)
			return null;
		if (deriveLowX && deriveHighX && lowX == highX) {
			lowX -= 0.5;
			highX += 0.5;
		}
		if (deriveLowY && deriveHighY && lowY == highY) {
			lowY -= 0.5;
			highY += 0.5;
		}
		return new PlotRange(lowX, highX, lowY, highY);
	}

	static function validateBound(value:Null<Float>, name:String):Void {
		if (value != null && !finite(value))
			throw 'Plot bound "$name" must be finite';
	}

	static inline function finite(value:Float):Bool
		return value == value && value - value == 0.0;
}

/** Application-owned samples and presentation for one plot line. */
class PlotSeries implements Observable {
	public final id:String;
	public final label:String;
	public final color:Color;
	public final lineWidth:Float;
	public var visible(default, null):Bool;
	var values:Array<PlotPoint>;

	public function new(id:String, label:String, color:Color, ?lineWidth:Float = 1.5) {
		if (id == null || id.length == 0 || label == null || label.length == 0 || !finite(lineWidth)
			|| lineWidth <= 0.0)
			throw "Plot series require stable labels, a color, and positive line width";
		this.id = id;
		this.label = label;
		this.color = color;
		this.lineWidth = lineWidth;
		visible = true;
		values = [];
	}

	public function points():Array<PlotPoint>
		return values.copy();

	public var pointCount(get, never):Int;
	inline function get_pointCount():Int
		return values.length;

	public function pointAt(index:Int):PlotPoint {
		if (index < 0 || index >= values.length)
			throw "Plot point index is out of range";
		return values[index];
	}

	public function setVisible(value:Bool):Bool {
		if (visible == value)
			return false;
		visible = value;
		return true;
	}

	public function setPoints(points:Array<PlotPoint>):Void {
		var next:Array<PlotPoint> = [];
		if (points != null)
			for (point in points) {
				if (point == null)
					throw "Plot series cannot contain null points";
				next.push(point);
			}
		values = next;
	}

	public function add(point:PlotPoint):Void {
		if (point == null)
			throw "Plot series cannot contain null points";
		var next = values.copy();
		next.push(point);
		values = next;
	}

	public function clear():Void {
		if (values.length == 0)
			return;
		values = [];
	}

	static inline function finite(value:Float):Bool
		return value == value && value - value == 0.0;
}

/** One immutable sample in a telemetry/debug plot series. */
class PlotPoint {
	public final x:Float;
	public final y:Float;

	public function new(x:Float, y:Float) {
		if (!finite(x) || !finite(y))
			throw "Plot points must be finite";
		this.x = x;
		this.y = y;
	}

	static inline function finite(value:Float):Bool
		return value == value && value - value == 0.0;
}

/** Finite data range used to map plot samples into a viewport. */
class PlotRange {
	public final minimumX:Float;
	public final maximumX:Float;
	public final minimumY:Float;
	public final maximumY:Float;

	public function new(minimumX:Float, maximumX:Float, minimumY:Float, maximumY:Float) {
		this.minimumX = minimumX;
		this.maximumX = maximumX;
		this.minimumY = minimumY;
		this.maximumY = maximumY;
	}
}
