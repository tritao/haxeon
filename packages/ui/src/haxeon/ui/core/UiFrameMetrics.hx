package haxeon.ui.core;

import haxeon.ui.core.RenderNode;

/** Timing, style-cache, and style-invalidation counters for the most recent UI frame. */
class UiFrameMetrics {
	/** Which frame this is, counting from one. */
	public final frameNumber:Int;

	/** How many render nodes the frame had. */
	public final nodeCount:Int;

	/** How many styles were resolved. */
	public final styleResolutions:Int;

	/** Style resolutions served from the cache. */
	public final styleCacheHits:Int;

	/** Style resolutions computed afresh. */
	public final styleCacheMisses:Int;

	/** How many resolved styles the cache holds. */
	public final cachedStyleCount:Int;

	/** Nodes whose resolved style changed. */
	public final styleChangedNodes:Int;

	/** Nodes whose resolved style stayed the same. */
	public final styleUnchangedNodes:Int;

	/** What the style changes invalidated, combined over every node. */
	public final styleInvalidationFlags:UiDirtyFlag;

	/** Nodes whose layout had to be recomputed. */
	public final layoutInvalidatedNodes:Int;

	/** Nodes whose text had to be laid out again. */
	public final textLayoutInvalidatedNodes:Int;

	/** Nodes that had to be repainted. */
	public final paintInvalidatedNodes:Int;

	/** Nodes whose compositing changed. */
	public final compositeInvalidatedNodes:Int;

	/** Nodes whose accessibility information changed. */
	public final semanticsInvalidatedNodes:Int;

	/** Nodes whose hit-testing geometry changed. */
	public final hitGeometryInvalidatedNodes:Int;
	/** Whether this submit rebuilt the native layout/render snapshot. */
	public final nativeLayoutSubmitted:Bool;
	/** Whether the previous native layout/render snapshot was reused. */
	public final nativeLayoutReused:Bool;
	/** Nodes whose resolved geometry changed and notified geometry consumers. */
	public final resolvedGeometryChangedNodes:Int;
	/** Nodes whose previous resolved geometry object was retained. */
	public final resolvedGeometryReusedNodes:Int;
	/** Internal submit passes used to settle geometry, reactive state, and interaction feedback. */
	public final buildPasses:Int;

	/**
	 * Native layout solves the frame took: one, and one more for each pass that laid out again after a geometry callback
	 * edited the tree or a build pass rebuilt it; zero for a frame that reused the last layout.
	 */
	public final layoutSolves:Int;

	/** How long submitting the frame took, building through native layout. */
	public final submitSeconds:Float;

	/** Time spent building views. */
	public var viewSeconds(default, null):Float = 0.0;

	/** Time spent building the render tree and resolving styles. */
	public var treeAndStyleSeconds(default, null):Float = 0.0;

	/** Time spent in native layout. */
	public var nativeLayoutSeconds(default, null):Float = 0.0;

	/** Time spent reconciling the tree with the last one. */
	public var reconcileSeconds(default, null):Float = 0.0;

	/** Time spent in custom painters. */
	public var customPaintSeconds(default, null):Float = 0.0;

	/** Time spent in native rendering. */
	public var nativeRenderSeconds(default, null):Float = 0.0;
	/** Bytes allocated by each submit and render phase; 0 where the runtime has no allocation counter. */
	public var viewAllocatedBytes(default, null):Float = 0.0;

	/** Bytes allocated building the tree and resolving styles. */
	public var treeAndStyleAllocatedBytes(default, null):Float = 0.0;

	/** Bytes allocated during native layout. */
	public var nativeLayoutAllocatedBytes(default, null):Float = 0.0;

	/** Bytes allocated reconciling. */
	public var reconcileAllocatedBytes(default, null):Float = 0.0;

	/** Bytes allocated by custom painters. */
	public var customPaintAllocatedBytes(default, null):Float = 0.0;
	/** Split of the tree-and-style phase: building the tree, comparing it with the last one, syncing node state, and the layout-reuse check. */
	public var treeBuildAllocatedBytes(default, null):Float = 0.0;

	/** Bytes allocated comparing the tree with the last one. */
	public var treeCompareAllocatedBytes(default, null):Float = 0.0;

	/** Bytes allocated syncing node state. */
	public var treeSyncAllocatedBytes(default, null):Float = 0.0;

	/** Bytes allocated by the layout-reuse check. */
	public var layoutReuseAllocatedBytes(default, null):Float = 0.0;

	/** Bytes allocated by native rendering. */
	public var nativeRenderAllocatedBytes(default, null):Float = 0.0;

	/** Nodes painted. */
	public var paintedNodes(default, null):Int;

	/** Nodes whose painting was skipped. */
	public var paintSkippedNodes(default, null):Int;
	/** Paint-capable visible nodes skipped because either resolved axis was empty. */
	public var emptyPaintNodes(default, null):Int;

	/** Whether the previous tree and native layout were reused as they were. */
	public var reusedSubmission(default, null):Bool;
	/** Custom painters invalidated by a retained hover-only submission. */
	@:allow(haxeon.ui.core.UiContext)
	public var hoverPaintUpdatedNodes(default, null):Int = 0;

	/** How long rendering took. */
	public var renderSeconds(default, null):Float;

	/** Submitting and rendering together. */
	public var totalSeconds(default, null):Float;

	internal function new(frameNumber:Int, nodeCount:Int, styleResolutions:Int,
			styleCacheHits:Int, styleCacheMisses:Int, cachedStyleCount:Int,
			styleChangedNodes:Int, styleUnchangedNodes:Int, styleInvalidationFlags:UiDirtyFlag,
			layoutInvalidatedNodes:Int, textLayoutInvalidatedNodes:Int,
			paintInvalidatedNodes:Int, compositeInvalidatedNodes:Int,
			semanticsInvalidatedNodes:Int,
			hitGeometryInvalidatedNodes:Int,
			submitSeconds:Float, nativeLayoutSubmitted:Bool = true,
			nativeLayoutReused:Bool = false,
			resolvedGeometryChangedNodes:Int = 0,
			resolvedGeometryReusedNodes:Int = 0,
			buildPasses:Int = 1, layoutSolves:Int = 1) {
		this.frameNumber = frameNumber;
		this.nodeCount = nodeCount;
		this.styleResolutions = styleResolutions;
		this.styleCacheHits = styleCacheHits;
		this.styleCacheMisses = styleCacheMisses;
		this.cachedStyleCount = cachedStyleCount;
		this.styleChangedNodes = styleChangedNodes;
		this.styleUnchangedNodes = styleUnchangedNodes;
		this.styleInvalidationFlags = styleInvalidationFlags;
		this.layoutInvalidatedNodes = layoutInvalidatedNodes;
		this.textLayoutInvalidatedNodes = textLayoutInvalidatedNodes;
		this.paintInvalidatedNodes = paintInvalidatedNodes;
		this.compositeInvalidatedNodes = compositeInvalidatedNodes;
		this.semanticsInvalidatedNodes = semanticsInvalidatedNodes;
		this.hitGeometryInvalidatedNodes = hitGeometryInvalidatedNodes;
		this.nativeLayoutSubmitted = nativeLayoutSubmitted;
		this.nativeLayoutReused = nativeLayoutReused;
		this.resolvedGeometryChangedNodes = resolvedGeometryChangedNodes;
		this.resolvedGeometryReusedNodes = resolvedGeometryReusedNodes;
		this.buildPasses = buildPasses;
		this.layoutSolves = layoutSolves;
		this.submitSeconds = submitSeconds;
		paintedNodes = 0;
		paintSkippedNodes = 0;
		emptyPaintNodes = 0;
		reusedSubmission = false;
		renderSeconds = 0.0;
		totalSeconds = submitSeconds;
	}

	/** Completes the frame record once native paint submission has finished. */
	internal function completeRender(seconds:Float, paintedNodes:Int = 0,
			paintSkippedNodes:Int = 0, emptyPaintNodes:Int = 0):Void {
		this.paintedNodes = paintedNodes < 0 ? 0 : paintedNodes;
		this.paintSkippedNodes = paintSkippedNodes < 0 ? 0 : paintSkippedNodes;
		this.emptyPaintNodes = emptyPaintNodes < 0 ? 0 : emptyPaintNodes;
		renderSeconds = seconds < 0.0 ? 0.0 : seconds;
		totalSeconds = submitSeconds + renderSeconds;
	}

	internal function setSubmitPhases(view:Float, treeAndStyle:Float, nativeLayout:Float,
			reconcile:Float):Void {
		viewSeconds = view;
		treeAndStyleSeconds = treeAndStyle;
		nativeLayoutSeconds = nativeLayout;
		reconcileSeconds = reconcile;
	}

	internal function setSubmitAllocations(view:Float, treeAndStyle:Float, nativeLayout:Float, reconcile:Float):Void {
		viewAllocatedBytes = view;
		treeAndStyleAllocatedBytes = treeAndStyle;
		nativeLayoutAllocatedBytes = nativeLayout;
		reconcileAllocatedBytes = reconcile;
	}

	internal function setTreeAllocations(build:Float, compare:Float, sync:Float, layoutReuse:Float):Void {
		treeBuildAllocatedBytes = build;
		treeCompareAllocatedBytes = compare;
		treeSyncAllocatedBytes = sync;
		layoutReuseAllocatedBytes = layoutReuse;
	}

	internal function setRenderAllocations(customPaint:Float, nativeRender:Float):Void {
		customPaintAllocatedBytes = customPaint;
		nativeRenderAllocatedBytes = nativeRender;
	}

	internal function setRenderPhases(customPaint:Float, nativeRender:Float):Void {
		customPaintSeconds = customPaint;
		nativeRenderSeconds = nativeRender;
	}

	/** Marks a frame whose previously submitted tree and native layout were reused. */
	internal function markReusedSubmission():Void
		reusedSubmission = true;

	/** The share of style lookups served from the cache, or zero when there were none. */
	public function cacheHitRate():Float {
		var lookups = styleCacheHits + styleCacheMisses;
		return lookups == 0 ? 0.0 : styleCacheHits / lookups;
	}
}

/** Cumulative bytes allocated by the runtime, for attributing allocation to frame phases; 0 where the runtime has no counter. */
internal class AllocationProbe {
	public static inline function now():Float {
		#if wasm
		return 0.0;
		#else
		return hl.Gc.totalAllocated();
		#end
	}
}

/** Opt-in render diagnostics; counters and formatting are untouched on ordinary frames. */
internal class RenderCost {
	public static final enabled:Bool = Sys.getEnv("HAXEON_UI_RENDER_COST") == "1";
	public static var callbacks = 0.0;
	public static var encode = 0.0;
	public static var renderable = 0.0;
	public static var nativeCall = 0.0;
	/** The node types edited in place since the last submit line, which ask for another solve. */
	public static final edits:Array<String> = [];
	/** Who asked for another layout pass since the last submit line: the caller of `requestLayoutFeedback`. */
	public static final requesters:Array<String> = [];

	public static function requested(stack:Array<haxe.CallStack.StackItem>):Void {
		for (index in 1...stack.length)
			switch stack[index] {
				case FilePos(_, file, line, _):
					var name = file.substr(file.lastIndexOf("/") + 1) + ":" + line;
					if (requesters.indexOf(name) < 0) requesters.push(name);
					return;
				default:
			}
	}

	public static inline function time():Float return enabled ? Sys.time() : 0.0;

	public static function begin():Void {
		if (!enabled) return;
		callbacks = encode = renderable = nativeCall = 0.0;
	}

	public static function submit(started:Float, viewStarted:Float, nativeStarted:Float,
			nativeEnded:Float, ended:Float, nodes:Int, solves:Int):Void {
		if (!enabled) return;
		Sys.stderr().writeString('render-cost submit started=$started nodes=$nodes build=${nativeStarted - viewStarted}'
			+ ' layout=${nativeEnded - nativeStarted} other=${viewStarted - started + ended - nativeEnded}'
			+ ' solves=$solves edits=${edits.join(",")} requesters=${requesters.join(",")}\n');
		edits.resize(0);
		requesters.resize(0);
	}

	public static function render(started:Float, nativeStarted:Float, ended:Float, nodes:Int):Void {
		if (!enabled) return;
		Sys.stderr().writeString('render-cost haxe started=$started nodes=$nodes total=${ended - started}'
			+ ' walk=${nativeStarted - started} callbacks=$callbacks encode=$encode renderable=$renderable native=$nativeCall\n');
	}
}
