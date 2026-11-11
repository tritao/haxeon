package haxeon.ui;

/** Native-memory paint inputs. Field order is shared with the native layout backend. */
@:portable
struct PaintRecord {
	public var backgroundRed:Float;
	public var backgroundGreen:Float;
	public var backgroundBlue:Float;
	public var backgroundAlpha:Float;
	public var radiusTopLeft:Float;
	public var radiusTopRight:Float;
	public var radiusBottomLeft:Float;
	public var radiusBottomRight:Float;
	public var textRed:Float;
	public var textGreen:Float;
	public var textBlue:Float;
	public var textAlpha:Float;
	public var generation:Int;
	/** Live and dirty bits for occupied slots; the next free index for vacant slots. */
	public var flags:Int;
}
