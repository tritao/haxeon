package haxeon.ui;

import NativeKitUI;
import haxe.io.Bytes;
import haxeon.platform.Surface;
import haxeon.platform.SurfaceFrame;
import haxeon.platform.SurfaceFrameStep;
import haxeon.ui.LayoutContent;
import haxeon.ui.LayoutNode;
import haxeon.ui.core.UiFrameMetrics;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;

/** Batched bridge from a Haxe-owned render tree to NativeKit layout/rendering. */
class LayoutSession implements Disposable {
	static final measureCost:Bool = Sys.getEnv("HAXEON_UI_LAYOUT_COST") == "1";
	static final EmptyBytes:Bytes = Bytes.alloc(0);
	/** Lays each submitted tree out; native builds the scene from its geometry (ADR 0009). */
	final solver:haxeon.ui.layout.LayoutSolver = new haxeon.ui.layout.LayoutSolver();
	var value:nkui_layout_session;
	var disposed:Bool;
	final transaction:LayoutTransaction;
	var resolved:Array<ResolvedLayoutItem>;
	final referenceTransaction:LayoutTransaction = new LayoutTransaction();
	/** Compare the retained native tree with a full encode after every submit while retention verification is enabled. */
	public var verifyTransactions:Bool = false;

	/** Compare each retained solve with a full one of the same tree, throwing where they differ. */
	public var verifyLayout:Bool = false;

	var referenceSolver:Null<haxeon.ui.layout.LayoutSolver> = null;

	/** Nodes the last solve laid out again; the others kept their layout from the solve before. */
	public var lastNodesLaidOut(default, null):Int = 0;
	var measureFunction:Null<LayoutMeasureCallback>;
	final renderableContents:Map<Int, LayoutRenderableContent>;

	private function new(value:nkui_layout_session) {
		this.value = value;
		disposed = false;
		transaction = new LayoutTransaction();
		resolved = [];
		measureFunction = null;
		renderableContents = new Map();
	}

	/** A new session, with its own native layout state. */
	public static function create():LayoutSession {
		var made = NativeKitUI.nkui_layout_session_create();
		UiResult.check(made.status, "layoutSession.create");
		return new LayoutSession(made.out_session);
	}

	/** Copies font paths/data and fallback policy into this session. */
	public function setFonts(fonts:FontCollection):Void {
		ensureLive();
		UiResult.check(NativeKitUI.nkui_layout_session_set_font_collection(value,
			fonts.nativeHandle()), "layoutSession.setFonts");
		solver.invalidate();
	}

	/** Measures Custom nodes without content of their own while a submit lays them out; null measures none. */
	public function setMeasureCallback(callback:Null<LayoutMeasureCallback>):Void {
		ensureLive();
		measureFunction = callback;
	}

	/** Measures `text` with this session's fonts into `out`: unwrapped when `width` is zero, else laid out at `width`. */
	public function measureText(text:Null<String>, width:Float, textStyle:TextStyle, paragraphStyle:ParagraphStyle,
			out:haxeon.ui.layout.TextMeasure):Void {
		ensureLive();
		var result = NativeKitUI.nkui_layout_session_measure_text(value, text == null ? "" : text, width,
			TextLayout.nativeTextStyle(textStyle), TextLayout.nativeParagraphStyle(paragraphStyle));
		UiResult.check(result.status, "layoutSession.measureText");
		var measured = result.out_measure;
		out.width = measured.get_width();
		out.height = measured.get_height();
		out.baseline = measured.get_baseline();
		out.hasBaseline = measured.get_has_baseline() != 0;
	}

	/**
	 * Lays `root` out and returns its resolved geometry, in tree order, without telling NativeKit: a frame may lay its tree
	 * out several times while geometry callbacks settle, and `publish` sends the one it settles on. With `changes`, the
	 * nodes the frame comparison found changed since the last solve, only what they reach is laid out again.
	 */
	internal function solve(root:LayoutNode, frame:LayoutFrame, ?changes:LayoutChanges):Array<ResolvedLayoutItem> {
		ensureLive();
		if (frame == null) throw "Layout session frame cannot be null";
		var started = measureCost ? Sys.time() : 0.0;
		solver.attach(this, measureFunction);
		solver.solve(root, frame.width, frame.height, changes);
		if (verifyLayout && changes != null) {
			var reference = referenceSolver;
			if (reference == null) referenceSolver = reference = new haxeon.ui.layout.LayoutSolver();
			reference.attach(this, measureFunction);
			reference.solve(root, frame.width, frame.height);
			reference.takeChanged(null);
			var difference = solver.differenceFrom(reference);
			if (difference != null) throw "The retained layout differs from a full solve: " + difference;
		}
		lastNodesLaidOut = solver.nodesLaidOut;
		resolved = solver.resolve();
		if (measureCost)
			Sys.stderr().writeString("layout-cost solve nodes=" + solver.nodes + " laidOut=" + solver.nodesLaidOut
				+ " solve=" + solver.solveSeconds
				+ " text="
				+ solver.textSeconds + " total=" + (Sys.time() - started) + "\n");
		return resolved;
	}

	/**
	 * Sends NativeKit the tree last laid out by `solve` and its geometry: the nodes in `changes` since the last publish,
	 * or every node when `forceFull`.
	 */
	internal function publish(root:LayoutNode, frame:LayoutFrame, ?changes:LayoutChanges, forceFull:Bool = false):Void {
		ensureLive();
		var encodeStarted = measureCost ? Sys.time() : 0.0;
		solver.takeChanged(forceFull ? null : changes);
		var transactionBytes:Bytes = transaction.encodeInto(root, forceFull ? null : changes, true, solver);
		collectRenderableContents();
		var encodeFinished = measureCost ? Sys.time() : 0.0;
		UiResult.check(NativeKitUI.nkui_layout_session_submit_slice(value, transactionBytes, 0,
			transaction.byteLength(),
			frame.nativeValue()), "layoutSession.submit");
		if (verifyTransactions) verifyTree(root);
		transaction.commit();
		if (measureCost) {
			Sys.stderr().writeString("layout-cost haxe nodes=" + resolved.length + " started=" + encodeStarted
				+ " encode="
				+ (encodeFinished - encodeStarted) + " decode=0\n");
			Sys.stderr().writeString("layout-delta updated=" + transaction.updatedCount() + " removed="
				+ transaction.removedCount() + " parents=" + transaction.parentCount() + "\n");
		}
	}

	/** Lays `root` out, sends it to NativeKit and returns its resolved geometry, in tree order. */
	internal function submit(root:LayoutNode, frame:LayoutFrame, ?changes:LayoutChanges,
			forceFull:Bool = false):Array<ResolvedLayoutItem> {
		var items = solve(root, frame);
		publish(root, frame, changes, forceFull);
		return items;
	}

	/** Compare a retained native tree against its complete Haxe input, without replacing the native tree. */
	public function verifyTree(root:LayoutNode):Void {
		ensureLive();
		var reference = referenceTransaction.encodeInto(root, null, false, solver);
		UiResult.check(NativeKitUI.nkui_layout_session_verify_tree_slice(value, reference, 0,
			referenceTransaction.byteLength()), "layoutSession.verifyIncrementalTree");
	}

	/** The IDs of the nodes from the root down to the topmost one under (`x`, `y`) that takes the pointer, as last laid out. */
	public function hitTest(x:Float, y:Float):Array<Int> {
		var path:Array<Int> = [];
		hitTestInto(x, y, path);
		return path;
	}

	/** `hitTest` into caller-owned storage. */
	public function hitTestInto(x:Float, y:Float, path:Array<Int>):Void {
		ensureLive();
		if (path == null) throw "Hit-test output storage cannot be null";
		solver.hitTest(x, y, path);
	}

	/** Returns pre-transform layout bounds of a node after the latest submission. */
	public function item(node:LayoutNode):Rect {
		ensureLive();
		if (node == null)
			throw "Layout item node cannot be null";
		for (item in resolved)
			if (item.id == node.id)
				return item.bounds();
		throw 'Layout item ${node.id} is not present in the latest resolved frame';
	}

	/** Content measurements this session's layout asked for, answered from earlier ones, and made. */
	public function measureStats():LayoutMeasureStats {
		ensureLive();
		return new LayoutMeasureStats(solver.measureRequests, solver.measureHits, solver.measureCalls);
	}

	/** Removes all Haxe custom-paint display lists from this session. */
	public function clearCustomPaints():Void {
		ensureLive();
		UiResult.check(NativeKitUI.nkui_layout_session_clear_custom_paints(value),
			"layoutSession.clearCustomPaints");
	}

	/** Removes one retained custom content display list without disturbing its composite plane. */
	public function clearCustomPaint(nodeId:Int):Void {
		ensureLive();
		if (nodeId <= 0)
			throw "Custom paint node ID must be positive";
		UiResult.check(NativeKitUI.nkui_layout_session_clear_custom_paint(value, nodeId),
			"layoutSession.clearCustomPaint");
	}

	/** Removes one retained custom composite display list without disturbing its content plane. */
	public function clearCustomPaintComposite(nodeId:Int):Void {
		ensureLive();
		if (nodeId <= 0)
			throw "Custom paint node ID must be positive";
		UiResult.check(NativeKitUI.nkui_layout_session_clear_custom_paint_composite(value, nodeId),
			"layoutSession.clearCustomPaintComposite");
	}

	/** Attaches a custom display list to a Custom layout node for ordered rendering. */
	public function setCustomPaint(nodeId:Int, displayList:DisplayList):Void {
		ensureLive();
		if (nodeId <= 0 || displayList == null || displayList.isDisposed())
			throw "Custom paint requires a live display list and node ID";
		UiResult.check(NativeKitUI.nkui_layout_session_set_custom_paint(value, nodeId,
			displayList.nativeHandle()), "layoutSession.setCustomPaint");
	}

	/** Attaches framework-owned composite metadata around retained custom pixels. */
	public function setCustomPaintComposite(nodeId:Int, displayList:DisplayList):Void {
		ensureLive();
		if (nodeId <= 0 || displayList == null || displayList.isDisposed())
			throw "Custom paint composite requires a live display list and node ID";
		UiResult.check(NativeKitUI.nkui_layout_session_set_custom_paint_composite(value, nodeId,
			displayList.nativeHandle()), "layoutSession.setCustomPaintComposite");
	}

	/** Selects vector or persistent GPU-raster rendering for a custom paint plane. */
	public function setCustomPaintCachePolicy(nodeId:Int, policy:NativeKitUI.UiLayoutCachePolicy):Void {
		ensureLive();
		if (nodeId <= 0)
			throw "Custom paint cache policy is invalid";
		UiResult.check(NativeKitUI.nkui_layout_session_set_custom_paint_cache_policy(value,
			nodeId, policy), "layoutSession.setCustomPaintCachePolicy");
	}

	/** Selects vector or persistent GPU-raster rendering for a render-node subtree. */
	public function setCachePolicy(nodeId:Int, policy:NativeKitUI.UiLayoutCachePolicy):Void {
		ensureLive();
		if (nodeId <= 0)
			throw "Render subtree cache policy is invalid";
		UiResult.check(NativeKitUI.nkui_layout_session_set_cache_policy(value, nodeId, policy),
			"layoutSession.setCachePolicy");
	}

	/** Executes the last submitted tree through the existing renderer backend. */
	public function render(renderer:Renderer, surface:Surface, frame:FrameInfo):Void {
		ensureLive();
		var started = RenderCost.time();
		updateRenderablePaints();
		if (RenderCost.enabled) RenderCost.renderable += Sys.time() - started;
		var nativeStarted = RenderCost.time();
		UiResult.check(NativeKitUI.nkui_layout_session_render_frame(renderer.nativeHandle(), value,
			surface.nativeHandle(), frame.nativeValue(), false), "layoutSession.render");
		if (RenderCost.enabled) RenderCost.nativeCall += Sys.time() - nativeStarted;
	}

	/** Composites the last submitted tree over the current surface contents. */
	public function renderOverlay(renderer:Renderer, surface:Surface, frame:FrameInfo):Void {
		ensureLive();
		var started = RenderCost.time();
		updateRenderablePaints();
		if (RenderCost.enabled) RenderCost.renderable += Sys.time() - started;
		var nativeStarted = RenderCost.time();
		UiResult.check(NativeKitUI.nkui_layout_session_render_frame(renderer.nativeHandle(), value,
			surface.nativeHandle(), frame.nativeValue(), true), "layoutSession.renderOverlay");
		if (RenderCost.enabled) RenderCost.nativeCall += Sys.time() - nativeStarted;
	}

	/** Seals the submitted layout for ordered rendering into the acquired frame. */
	public function frameStep(renderer:Renderer, frame:SurfaceFrame, info:FrameInfo,
			loadExisting:Bool = true):SurfaceFrameStep {
		ensureLive();
		updateRenderablePaints();
		var made = NativeKitUI.nkui_frame_step_layout(renderer.nativeHandle(), value, frame.nativeHandle(),
			info.nativeValue(), loadExisting);
		UiResult.check(made.status, "layoutSession.frameStep");
		return new SurfaceFrameStep(made.out_step);
	}

	public function dispose():Void {
		if (disposed)
			return;
		var status = NativeKitUI.nkui_layout_session_destroy(value);
		disposed = true;
		UiResult.check(status, "layoutSession.dispose");
	}

	/** Whether it was disposed. */
	public function isDisposed():Bool
		return disposed;

	function ensureLive():Void {
		if (disposed)
			throw "Layout session has been disposed";
	}

	function collectRenderableContents():Void {
		renderableContents.clear();
		// The transaction already visited every node in tree order and noted the ones with content.
		for (node in transaction.nodesWithIntrinsicContent()) {
			var content = node.intrinsicContent;
			if (content == null)
				continue;
			if (node.visualKind != LayoutVisualKind.Custom)
				throw "Intrinsic content requires a Custom layout node";
			var renderable = content.asRenderable();
			if (renderable != null)
				renderableContents.set(node.id, renderable);
		}
	}

	function updateRenderablePaints():Void {
		for (nodeId in renderableContents.keys()) {
			var content = renderableContents.get(nodeId);
			if (content == null)
				continue;
			var geometry:Null<ResolvedLayoutItem> = null;
			for (item in resolved)
				if (item.id == nodeId) {
					geometry = item;
					break;
				}
			if (geometry == null || !geometry.visible || geometry.width <= 0.0 || geometry.height <= 0.0
				|| geometry.clipBounds.width <= 0.0 || geometry.clipBounds.height <= 0.0)
				continue;
			var started = RenderCost.time(), encodedBefore = RenderCost.encode;
			var displayList = content.paint(geometry);
			if (RenderCost.enabled) RenderCost.callbacks += Sys.time() - started - (RenderCost.encode - encodedBefore);
			setCustomPaint(nodeId, displayList);
		}
	}

}
