package haxeon.ui.core;

import haxeon.ui.Canvas;
import haxeon.ui.Rect;

/** Renderable content contract consumed by the shared GPU viewport node. */
interface ViewportContent {
	function width():Float;
	function height():Float;
	function revision():Int;
	function paint(canvas:Canvas, destination:Rect):Void;
}
