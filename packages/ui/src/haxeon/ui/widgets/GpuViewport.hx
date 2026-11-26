package haxeon.ui.widgets;

import Observable;
import haxeon.ui.Canvas;
import haxeon.ui.Color;
import haxeon.ui.GraphicsSurface;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.Paint;
import haxeon.ui.Path;
import haxeon.ui.Point;
import haxeon.ui.Rect;
import haxeon.ui.ResolvedLayoutItem;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.View;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.style.StyleTarget;

/**
 * Shared editor viewport node for GPU-produced content.
 *
 * The GPU renderer remains application-owned; this node owns compositing,
 * camera navigation, retained invalidation, and pointer interaction. That
 * keeps simulation/CAD renderers independent from the UI tree.
 */
class GpuViewport implements View {
	/** Identifies the viewport among its siblings, so its state survives rebuilds: required, and never empty. */
	public final key:String;

	/** What the viewport shows: its size, revision and painting. */
	public final content:ViewportContent;

	/** The pan and zoom, which a caller can share to read or move it. */
	public final camera:ViewportCamera;

	/** The viewport's box. */
	public final style:LayoutStyle;

	/** The flat background, behind the content. */
	public var background(default, null):Color;

	/** The background gradient's top color. */
	public var backgroundTop(default, null):Color;

	/** The background gradient's bottom color. */
	public var backgroundBottom(default, null):Color;

	/** The color of the background grid's lines. */
	public var gridColor(default, null):Color;

	/** The spacing of the grid's lines, in content units. */
	public var gridSize(default, null):Float;

	/** Whether the grid is drawn. */
	public var gridEnabled(default, null):Bool;
	/** Native pointer button used to pan; defaults to the primary button. */
	public var panButton:Int = 0;

	/** Whether the viewport takes input: panning, zooming and the added handlers. */
	public var enabled:Bool;

	/** Its accessible name; without one, assistive technology skips it. */
	public var label:Null<String>;

	/** Paints over the content, in viewport coordinates; set with `setOverlay`. */
	public var overlay(default, null):Null<Canvas->ResolvedLayoutItem->Void>;
	var overlayRevision:Int;
	final handlers:Map<String, Array<UiEvent->Void>>;
	var draggingPointer:Null<Int>;
	var lastPointerX:Float;
	var lastPointerY:Float;
	/** While set, paints through `fitted`, fitted to the laid-out size with this margin. */
	var fitMargin:Null<Float> = null;
	final fitted:ViewportCamera;
	var paintedWidth = 0.0;
	var paintedHeight = 0.0;

	/** A viewport showing `content` through `camera`. Throws when `key` is empty or there is no content. */
	public function new(key:String, content:ViewportContent, ?camera:ViewportCamera, ?style:LayoutStyle,
			?label:String) {
		if (key == null || key.length == 0 || content == null) throw "GPU viewports require a stable key and content";
		this.key = key;
		this.content = content;
		this.camera = camera == null ? new ViewportCamera() : camera;
		fitted = new ViewportCamera(1.0, 0.0, 0.0, this.camera.minZoom, this.camera.maxZoom);
		this.style = style == null ? defaultStyle() : style.copy();
		this.background = Color.rgba(0.055, 0.065, 0.08, 1.0);
		this.backgroundTop = Color.rgba(0.894, 0.910, 0.922, 1.0);
		this.backgroundBottom = Color.rgba(0.847, 0.867, 0.882, 1.0);
		this.gridColor = Color.rgba(0.18, 0.21, 0.26, 0.7);
		this.gridSize = 1.0;
		this.gridEnabled = true;
		this.enabled = true;
		this.label = label == null ? "GPU viewport" : label;
		this.overlay = null;
		overlayRevision = 1;
		handlers = new Map();
		draggingPointer = null;
		lastPointerX = 0.0;
		lastPointerY = 0.0;
	}

	/** A viewport showing a GPU `surface` whose content is `width` by `height`. */
	public static function fromSurface(key:String,
			surface:GraphicsSurface,
			width:Float,
			height:Float,
			?camera:ViewportCamera,
			?style:LayoutStyle,
			?label:String):GpuViewport return new GpuViewport(key,
		new GraphicsSurfaceViewportContent(surface, width, height),
		camera,
		style,
		label);

	/** Adds `handler` for events of `kind` on the viewport, and returns it, for chaining. */
	public function on(kind:String, handler:UiEvent->Void):GpuViewport {
		if (kind == null
			|| kind.length == 0 || handler == null) throw "GPU viewport handlers require an event kind and callback";
		var values = handlers.get(kind);
		if (values == null) {
			values = [];
			handlers.set(kind, values);
		}
		values.push(handler);
		return this;
	}

	/** Fits the content once on `camera`, ending any fitToView. */
	public function fit(width:Float, height:Float, margin:Float = 16.0):Bool {
		fitMargin = null;
		return camera.fit(content.width(), content.height(), width, height, margin);
	}

	/**
	 * Fits the content to the viewport's laid-out size and keeps it fitted as
	 * the viewport resizes. The first pan or zoom continues from the fitted view
	 * on `camera` and ends the fitting.
	 */
	public function fitToView(margin:Float = 16.0):GpuViewport {
		if (!finite(margin) || margin < 0.0) throw "Viewport fit margin must be finite and non-negative";
		fitMargin = margin;
		return this;
	}

	/** Sets the flat background and the grid. Throws when `gridSize` is not positive and finite. */
	public function setAppearance(background:Color, gridColor:Color, gridSize:Float = 1.0,
			gridEnabled:Bool = true):Void {
		if (!finite(gridSize) || gridSize <= 0.0) throw "Viewport appearance values are invalid";
		this.background = background;
		this.backgroundTop = background;
		this.backgroundBottom = background;
		this.gridColor = gridColor;
		this.gridSize = gridSize;
		this.gridEnabled = gridEnabled;
	}

	/** Sets a vertical top-to-bottom viewport background gradient. */
	public function setBackgroundGradient(top:Color, bottom:Color):Void {
		if (top == null || bottom == null) throw "Viewport gradient colors are required";
		backgroundTop = top;
		backgroundBottom = bottom;
	}

	/** Sets what is painted over the content, or removes it with null. */
	public function setOverlay(overlay:Null<Canvas->ResolvedLayoutItem->Void>):Void {
		this.overlay = overlay;
		overlayRevision++;
	}

	public function build(context:BuildContext):RenderNode {
		return context.withScope(new Key(key), function() {
			var nodeId = context.rootId("viewport");
			var computed = context.resolveStyle(new StyleTarget("gpu-viewport", key, key, null, ["gpu-viewport"],
				context.interactionStates.get(nodeId)),
				style);
			var node = context.createNode(nodeId, LayoutVisualKind.Custom, computed.toLayoutStyle());
			node.setStyleIdentity("gpu-viewport", key, key, null, ["gpu-viewport"]);
			node.states = context.interactionStates.get(nodeId);
			node.enabled = enabled;
			node.hitTestSelf = enabled;
			node.cachePolicy = CachePolicy.Raster;
			node.computedStyle = computed;
			node.semantics = new Semantics(AccessibilityRole.Group, label == null ? "GPU viewport" : label);
			var cacheKey = "viewport:" + content.revision()
				+ ":camera:" + camera.revision + ":fit:" + (fitMargin == null ? "off" : Std.string(fitMargin))
				+ ":appearance:" + appearanceKey() + ":overlay:" + overlayRevision;
			node.onPaint(function(canvas, geometry) paint(canvas, geometry), cacheKey);
			node.on(UiEventKind.PointerDown, function(event) {
				if (!enabled || event.button != panButton) return;
				draggingPointer = event.pointerId;
				lastPointerX = event.localX;
				lastPointerY = event.localY;
				event.capturePointer();
				event.stopPropagation();
			});
			node.on(UiEventKind.PointerMove, function(event) {
				if (draggingPointer == null || event.pointerId != draggingPointer) return;
				takeCamera();
				camera.panByScreen(event.localX - lastPointerX, event.localY - lastPointerY);
				lastPointerX = event.localX;
				lastPointerY = event.localY;

			});
			node.on(UiEventKind.PointerUp, finishPointer);
			node.on(UiEventKind.PointerCancel, finishPointer);
			node.on(UiEventKind.Scroll, function(event) {
				if (!enabled || event.deltaY == 0.0) return;
				takeCamera();
				camera.zoomAt(Math.pow(1.1, -event.deltaY / 100.0), event.localX, event.localY);

				event.stopPropagation();
			});
			for (kind in handlers.keys()) for (handler in handlers.get(kind)) node.on(kind, handler);
			return node;
		});
	}

	/** Hands navigation to `camera`, starting from the fitted view the user is looking at. */
	function takeCamera():Void {
		if (fitMargin == null) return;
		if (paintedWidth > 0.0 && paintedHeight > 0.0)
			camera.fit(content.width(), content.height(), paintedWidth, paintedHeight, fitMargin);
		fitMargin = null;
	}

	function view():ViewportCamera return fitMargin == null ? camera : fitted;

	function finishPointer(event:UiEvent):Void {
		if (draggingPointer == null || event.pointerId != draggingPointer) return;
		draggingPointer = null;
		event.releasePointer();
	}

	function paint(canvas:Canvas, geometry:ResolvedLayoutItem):Void {
		paintedWidth = geometry.width;
		paintedHeight = geometry.height;
		var fitMargin = fitMargin;
		if (fitMargin != null && geometry.width > 0.0 && geometry.height > 0.0 && content.width() > 0.0
			&& content.height() > 0.0)
			fitted.fit(content.width(), content.height(), geometry.width, geometry.height, fitMargin);
		var shown = view();
		canvas.fillLinearGradientRect(new Rect(0.0, 0.0, geometry.width, geometry.height),
			0.0,
			0.0,
			0.0,
			geometry.height,
			[
				new GradientStop(0.0, backgroundTop),
				new GradientStop(1.0, backgroundBottom)
			]);
		canvas.withState(function(viewCanvas) {
			viewCanvas.translate(-shown.panX * shown.zoom, -shown.panY * shown.zoom);
			viewCanvas.scale(shown.zoom, shown.zoom);
			if (gridEnabled) paintGrid(viewCanvas, geometry);
			content.paint(viewCanvas, new Rect(0.0, 0.0, content.width(), content.height()));
		});
		if (overlay != null) overlay(canvas, geometry);
	}

	function paintGrid(canvas:Canvas, geometry:ResolvedLayoutItem):Void {
		if (gridSize <= 0.0 || !finite(gridSize)) return;
		var shown = view();
		var topLeft = shown.viewportToWorld(0.0, 0.0);
		var bottomRight = shown.viewportToWorld(geometry.width, geometry.height);
		var startX = Math.floor(topLeft.x / gridSize) * gridSize;
		var startY = Math.floor(topLeft.y / gridSize) * gridSize;
		var endX = Math.ceil(bottomRight.x / gridSize) * gridSize;
		var endY = Math.ceil(bottomRight.y / gridSize) * gridSize;
		var path = new PathBuilder();
		var count = 0;
		var x = startX;
		while (x <= endX && count < 512) {
			path.moveTo(x, startY).lineTo(x, endY);
			x += gridSize;
			count++;
		}
		var y = startY;
		count = 0;
		while (y <= endY && count < 512) {
			path.moveTo(startX, y).lineTo(endX, y);
			y += gridSize;
			count++;
		}
		if (x != startX || y != startY) canvas.strokeTransient(path.build(),
			gridColor,
			1.0 / shown.zoom,
			LineCap.Butt,
			LineJoin.Miter);
	}

	/** Fills the space its parent leaves, beside other views in a row or column or alone. */
	static function defaultStyle():LayoutStyle {
		var result = new LayoutStyle();
		result.width = LayoutAxis.grow();
		result.height = LayoutAxis.grow();
		return result;
	}

	static inline function finite(value:Float):Bool return value == value && value - value == 0.0;

	function appearanceKey():String return background.red + ":" + background.green + ":" + background.blue
		+ ":" + background.alpha + ":" + backgroundTop.red + ":" + backgroundTop.green + ":" + backgroundTop.blue + ":"
		+ backgroundBottom.red + ":" + backgroundBottom.green + ":" + backgroundBottom.blue + ":" + gridColor.red + ":"
		+ gridColor.green + ":" + gridColor.blue + ":" + gridColor.alpha + ":" + gridSize + ":"
		+ (gridEnabled ? "1" : "0");
}

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

/** Camera state shared by GPU viewport widgets and application overlays. */
class ViewportCamera implements Observable {
	/** The smallest zoom allowed. */
	public final minZoom:Float;

	/** The largest zoom allowed. */
	public final maxZoom:Float;

	/** How many viewport pixels one world unit spans. */
	public var zoom(default, null):Float;

	/** The world x at the viewport's left edge. */
	public var panX(default, null):Float;

	/** The world y at the viewport's top edge. */
	public var panY(default, null):Float;

	/** Counts the camera's changes, so a viewport redraws only when it moved. */
	public var revision(default, null):Int;

	/**
	 * A camera at `zoom`, clamped into `minZoom`...`maxZoom`, panned to (`panX`, `panY`). Throws when a value is not
	 * finite or the zoom range is empty.
	 */
	public function new(zoom:Float = 1.0, panX:Float = 0.0, panY:Float = 0.0,
			minZoom:Float = 0.01, maxZoom:Float = 100.0) {
		if (!finite(zoom) || !finite(panX) || !finite(panY) || !finite(minZoom) || !finite(maxZoom) || minZoom <= 0.0
			|| maxZoom < minZoom)
			throw "Viewport camera values must be finite and ordered";
		this.minZoom = minZoom;
		this.maxZoom = maxZoom;
		this.zoom = clamp(zoom, minZoom, maxZoom);
		this.panX = panX;
		this.panY = panY;
		revision = 1;
	}

	/** Sets the zoom, clamped into range. Returns whether it changed. Throws when `value` is not finite. */
	public function setZoom(value:Float):Bool {
		if (!finite(value))
			throw "Viewport zoom must be finite";
		var next = clamp(value, minZoom, maxZoom);
		if (next == zoom)
			return false;
		zoom = next;
		revision++;
		return true;
	}

	/** Sets the pan. Returns whether it changed. */
	public function setPan(x:Float, y:Float):Bool {
		if (!finite(x) || !finite(y))
			throw "Viewport pan must be finite";
		if (x == panX && y == panY)
			return false;
		panX = x;
		panY = y;
		revision++;
		return true;
	}

	/** Moves the world under the pointer by a screen-space delta. */
	public function panByScreen(deltaX:Float, deltaY:Float):Bool
		return setPan(panX - deltaX / zoom, panY - deltaY / zoom);

	/** Keeps the world point under the given viewport point fixed while zooming. */
	public function zoomAt(factor:Float, viewportX:Float, viewportY:Float):Bool {
		if (!finite(factor) || factor <= 0.0 || !finite(viewportX) || !finite(viewportY))
			throw "Viewport zoom gesture values must be finite and positive";
		var worldX = panX + viewportX / zoom;
		var worldY = panY + viewportY / zoom;
		var nextZoom = clamp(zoom * factor, minZoom, maxZoom);
		if (nextZoom == zoom)
			return false;
		zoom = nextZoom;
		panX = worldX - viewportX / zoom;
		panY = worldY - viewportY / zoom;
		revision++;
		return true;
	}

	/** Fits a content rectangle into a viewport, preserving its center. */
	public function fit(contentWidth:Float, contentHeight:Float, viewportWidth:Float,
			viewportHeight:Float, margin:Float = 16.0):Bool {
		if (!finite(contentWidth) || !finite(contentHeight) || !finite(viewportWidth) || !finite(viewportHeight)
			|| contentWidth <= 0.0 || contentHeight <= 0.0 || viewportWidth <= 0.0 || viewportHeight <= 0.0
			|| margin < 0.0)
			throw "Viewport fit dimensions must be finite and positive";
		var availableWidth = Math.max(1.0, viewportWidth - margin * 2.0);
		var availableHeight = Math.max(1.0, viewportHeight - margin * 2.0);
		var nextZoom = clamp(Math.min(availableWidth / contentWidth,
			availableHeight / contentHeight), minZoom, maxZoom);
		var worldWidth = viewportWidth / nextZoom;
		var worldHeight = viewportHeight / nextZoom;
		var nextPanX = (contentWidth - worldWidth) * 0.5;
		var nextPanY = (contentHeight - worldHeight) * 0.5;
		if (nextZoom == zoom && nextPanX == panX && nextPanY == panY)
			return false;
		zoom = nextZoom;
		panX = nextPanX;
		panY = nextPanY;
		revision++;
		return true;
	}

	/** Where the world point (`x`, `y`) appears in the viewport. */
	public function worldToViewport(x:Float, y:Float):Point
		return new Point((x - panX) * zoom, (y - panY) * zoom);

	/** The world point under the viewport point (`x`, `y`). */
	public function viewportToWorld(x:Float, y:Float):Point
		return new Point(panX + x / zoom, panY + y / zoom);

	static inline function clamp(value:Float, minimum:Float, maximum:Float):Float
		return Math.max(minimum, Math.min(maximum, value));

	static inline function finite(value:Float):Bool
		return value == value && value - value == 0.0;
}

/** Adapts a retained NativeKit GPU image/surface to a viewport content plane. */
class GraphicsSurfaceViewportContent implements ViewportContent {
	/** The GPU surface shown. */
	public final surface:GraphicsSurface;

	/** The content width, in logical pixels. */
	public final contentWidth:Float;

	/** The content height, in logical pixels. */
	public final contentHeight:Float;

	/** Counts the changes `invalidate` reports. */
	public var contentRevision(default, null):Int;

	/** Viewport content showing `surface` at `width` by `height` logical pixels. */
	public function new(surface:GraphicsSurface, width:Float, height:Float) {
		if (surface == null || surface.isDisposed() || width <= 0.0 || height <= 0.0 || !finite(width)
			|| !finite(height))
			throw "Graphics viewport content requires a live surface and positive dimensions";
		this.surface = surface;
		contentWidth = width;
		contentHeight = height;
		contentRevision = 1;
	}

	/** The content width, in logical pixels. */
	public function width():Float
		return contentWidth;

	/** The content height, in logical pixels. */
	public function height():Float
		return contentHeight;

	/** Changes whenever the surface's pixels do. */
	public function revision():Int
		return contentRevision;

	/** Marks the surface pixels as changed without replacing the GPU resource. */
	public function invalidate():Void
		contentRevision++;

	/** Draws the surface scaled into `destination`. */
	public function paint(canvas:Canvas, destination:Rect):Void {
		if (canvas == null || destination == null)
			throw "Graphics viewport painting requires a canvas and destination";
		canvas.drawSurface(surface, destination);
	}

	static inline function finite(value:Float):Bool
		return value == value && value - value == 0.0;
}
