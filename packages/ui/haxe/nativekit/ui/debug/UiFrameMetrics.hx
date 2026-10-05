package nativekit.ui.debug;

/** Timing, style-cache, and style-invalidation counters for the most recent UI frame. */
class UiFrameMetrics {
	public final frameNumber:Int;
	public final nodeCount:Int;
	public final styleResolutions:Int;
	public final styleCacheHits:Int;
	public final styleCacheMisses:Int;
	public final cachedStyleCount:Int;
	public final styleChangedNodes:Int;
	public final styleUnchangedNodes:Int;
	public final styleInvalidationFlags:Int;
	public final layoutInvalidatedNodes:Int;
	public final textLayoutInvalidatedNodes:Int;
	public final paintInvalidatedNodes:Int;
	public final compositeInvalidatedNodes:Int;
	public final semanticsInvalidatedNodes:Int;
	public final hitGeometryInvalidatedNodes:Int;
	/** Whether this submit rebuilt the native layout/render snapshot. */
	public final nativeLayoutSubmitted:Bool;
	/** Whether the previous native layout/render snapshot was reused. */
	public final nativeLayoutReused:Bool;
	/** Nodes whose resolved geometry changed and notified geometry consumers. */
	public final resolvedGeometryChangedNodes:Int;
	/** Nodes whose previous resolved geometry object was retained. */
	public final resolvedGeometryReusedNodes:Int;
	public final submitSeconds:Float;
	public var viewSeconds(default, null):Float = 0.0;
	public var treeAndStyleSeconds(default, null):Float = 0.0;
	public var nativeLayoutSeconds(default, null):Float = 0.0;
	public var reconcileSeconds(default, null):Float = 0.0;
	public var customPaintSeconds(default, null):Float = 0.0;
	public var nativeRenderSeconds(default, null):Float = 0.0;
	/** Bytes allocated by each submit and render phase; 0 where the runtime has no allocation counter. */
	public var viewAllocatedBytes(default, null):Float = 0.0;
	public var treeAndStyleAllocatedBytes(default, null):Float = 0.0;
	public var nativeLayoutAllocatedBytes(default, null):Float = 0.0;
	public var reconcileAllocatedBytes(default, null):Float = 0.0;
	public var customPaintAllocatedBytes(default, null):Float = 0.0;
	/** Split of the tree-and-style phase: building the tree, comparing it with the last one, syncing node state, and the layout-reuse check. */
	public var treeBuildAllocatedBytes(default, null):Float = 0.0;
	public var treeCompareAllocatedBytes(default, null):Float = 0.0;
	public var treeSyncAllocatedBytes(default, null):Float = 0.0;
	public var layoutReuseAllocatedBytes(default, null):Float = 0.0;
	public var nativeRenderAllocatedBytes(default, null):Float = 0.0;
	public var paintedNodes(default, null):Int;
	public var paintSkippedNodes(default, null):Int;
	/** Paint-capable visible nodes skipped because either resolved axis was empty. */
	public var emptyPaintNodes(default, null):Int;
	public var reusedSubmission(default, null):Bool;
	public var renderSeconds(default, null):Float;
	public var totalSeconds(default, null):Float;

	public function new(frameNumber:Int, nodeCount:Int, styleResolutions:Int,
			styleCacheHits:Int, styleCacheMisses:Int, cachedStyleCount:Int,
			styleChangedNodes:Int, styleUnchangedNodes:Int, styleInvalidationFlags:Int,
			layoutInvalidatedNodes:Int, textLayoutInvalidatedNodes:Int,
			paintInvalidatedNodes:Int, compositeInvalidatedNodes:Int,
			semanticsInvalidatedNodes:Int,
			hitGeometryInvalidatedNodes:Int,
			submitSeconds:Float, nativeLayoutSubmitted:Bool = true,
			nativeLayoutReused:Bool = false,
			resolvedGeometryChangedNodes:Int = 0,
			resolvedGeometryReusedNodes:Int = 0) {
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
		this.submitSeconds = submitSeconds;
		paintedNodes = 0;
		paintSkippedNodes = 0;
		emptyPaintNodes = 0;
		reusedSubmission = false;
		renderSeconds = 0.0;
		totalSeconds = submitSeconds;
	}

	/** Completes the frame record once native paint submission has finished. */
	public function completeRender(seconds:Float, paintedNodes:Int = 0,
			paintSkippedNodes:Int = 0, emptyPaintNodes:Int = 0):Void {
		this.paintedNodes = paintedNodes < 0 ? 0 : paintedNodes;
		this.paintSkippedNodes = paintSkippedNodes < 0 ? 0 : paintSkippedNodes;
		this.emptyPaintNodes = emptyPaintNodes < 0 ? 0 : emptyPaintNodes;
		renderSeconds = seconds < 0.0 ? 0.0 : seconds;
		totalSeconds = submitSeconds + renderSeconds;
	}

	public function setSubmitPhases(view:Float, treeAndStyle:Float, nativeLayout:Float,
			reconcile:Float):Void {
		viewSeconds = view;
		treeAndStyleSeconds = treeAndStyle;
		nativeLayoutSeconds = nativeLayout;
		reconcileSeconds = reconcile;
	}

	public function setSubmitAllocations(view:Float, treeAndStyle:Float, nativeLayout:Float, reconcile:Float):Void {
		viewAllocatedBytes = view;
		treeAndStyleAllocatedBytes = treeAndStyle;
		nativeLayoutAllocatedBytes = nativeLayout;
		reconcileAllocatedBytes = reconcile;
	}

	public function setTreeAllocations(build:Float, compare:Float, sync:Float, layoutReuse:Float):Void {
		treeBuildAllocatedBytes = build;
		treeCompareAllocatedBytes = compare;
		treeSyncAllocatedBytes = sync;
		layoutReuseAllocatedBytes = layoutReuse;
	}

	public function setRenderAllocations(customPaint:Float, nativeRender:Float):Void {
		customPaintAllocatedBytes = customPaint;
		nativeRenderAllocatedBytes = nativeRender;
	}

	public function setRenderPhases(customPaint:Float, nativeRender:Float):Void {
		customPaintSeconds = customPaint;
		nativeRenderSeconds = nativeRender;
	}

	/** Marks a frame whose previously submitted tree and native layout were reused. */
	public function markReusedSubmission():Void
		reusedSubmission = true;

	public function cacheHitRate():Float {
		var lookups = styleCacheHits + styleCacheMisses;
		return lookups == 0 ? 0.0 : styleCacheHits / lookups;
	}
}
