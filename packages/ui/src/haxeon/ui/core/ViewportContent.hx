package haxeon.ui.core;

import haxeon.ui.Canvas;
import haxeon.ui.Rect;

/** Renderable content contract consumed by the shared GPU viewport node. */
interface ViewportContent {
	/** The content width, in logical pixels. */
	function width():Float;

	/** The content height, in logical pixels. */
	function height():Float;

	/** Changes whenever the content does, so a viewport repaints only then. */
	function revision():Int;

	/** Draws the content scaled into `destination` on `canvas`. */
	function paint(canvas:Canvas, destination:Rect):Void;
}
