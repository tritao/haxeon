package haxeon.ui.core;

import haxeon.platform.Surface as PlatformSurface;
import nativekit.ffi.NativeKitTypes.WindowDecorationRegion as NativeWindowDecorationRegion;

import haxeon.ui.widgets.text.Text;

import nativekit.ffi.NativeKitTypes;

import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutSession;
import haxeon.ui.LayoutChanges;
import haxeon.ui.LayoutHitTestStats;
import haxeon.ui.Canvas;
import haxeon.ui.DisplayList;
import haxeon.ui.Renderer;
import haxeon.ui.Surface;
import haxeon.ui.FrameInfo;
import haxeon.ui.Rect;
import haxeon.ui.ResolvedLayoutItem;
import haxeon.ui.FontCollection;
import nativekit.ffi.NativeKit;
import haxeon.ui.core.CursorShape as UiCursorShape;
import haxeon.ui.semantics.AccessibilityBridge;
import haxeon.ui.semantics.AccessibilityActionData;
import haxeon.ui.semantics.AccessibilityRequest;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.theme.Theme;
import haxeon.ui.style.StyleSheet;
import haxeon.ui.gestures.GestureArena;
import haxeon.ui.animation.AnimationScheduler;
import haxeon.ui.debug.AccessibilityAudit;
import haxeon.ui.debug.AccessibilityIssue;
import haxeon.ui.debug.AllocationProbe;
import haxeon.ui.debug.UiFrameMetrics;
import haxeon.ui.debug.UiInspector;
import haxeon.ui.debug.UiNodeSnapshot;
import haxeon.ui.debug.UiStyleInvalidationMetrics;
import haxeon.ui.debug.UiStyleInvalidationMetrics.UiStyleInvalidationFrame;

/** Owns the frame-local render tree and the Haxe-side UI subsystems. */
class UiContext {
	final session:LayoutSession;
	final layoutChanges:LayoutChanges = new LayoutChanges();
	final comparisonFrame:UiStyleInvalidationFrame;
	public final stateStore:StateStore;
	public final clipboard:ClipboardService;
	public final buildContext:BuildContext;
	public final focus:FocusManager;
	public final events:EventDispatcher;
	public final gestures:GestureArena;
	public final animations:AnimationScheduler;
	public final interactionStates:InteractionStateStore;
	/** Application commands and shortcut scopes owned by this UI context. */
	public final commands:CommandRegistry;
	/** Current document/selection context used by command-bound UI. */
	public var commandContext(default, null):CommandContext;
	public var root(default, null):Null<RenderNode>;
	/** Opt-in developer selection. Drawn after application paint and excluded from hit testing. */
	public var inspectionHighlight(default, set):Int = 0;
	/** Optional detailed paint probe. Disabled unless an inspector explicitly subscribes. */
	public var onInspectionPaint:Null<Int->Float->Void>;
	var inspectionEnabled = false;
	var inspectionNode:Null<RenderNode>;
	var pendingFocus:Null<WidgetId> = null;
	var windowFocused:Bool = true;
	var focusBeforeWindowBlur:Null<WidgetId> = null;
	/** Called when an active animation needs another host frame. */
	public var onAnimationFrameRequested:Null<Void->Void>;
	/** Modifier observation independent of keyboard focus (for pointer affordances). */
	public var onModifiersChanged:Null<Int->Void>;
	public var modifiers(default, null):Int = 0;

	function updateModifiers(value:Int):Void {
		if (modifiers == value) return;
		modifiers = value;
		var handler = onModifiersChanged;
		if (handler != null) handler(value);
	}
	var submittedStateRevision:Int;
	var submittedInteractionRevision:Int;
	var submittedRetainedEditRevision:Int = 0;
	var submittedPatchRequestRevision:Int = 0;
	var submittedStyleRevision:Int;
	var submittedAnimationRevision:Int;
	var submittedGestureRevision:Int;
	var submittedCommandRevision:Int;
	var submittedNodeCount:Int;
	var submittedFrameWidth:Float;
	var submittedFrameHeight:Float;
	var submittedBuildKey:Null<String>;
	var submittedTheme:Null<Theme>;
	var submittedStyleSheet:Null<StyleSheet>;
	final hitTestIds:Array<Int>;
	var disposed:Bool;
	final stalePaintNodes:Array<Int> = [];
	var customCanvases:Map<Int, Canvas>;
	var customLists:Map<Int, DisplayList>;
	var customGeometries:Map<Int, ResolvedLayoutItem>;
	var customPaintKeys:Map<Int, String>;
	var customContentRevisions:Map<Int, Int>;
	var customListHasCommands:Map<Int, Bool>;
	var customPaintBound:Map<Int, Bool>;
	var customCompositeCanvases:Map<Int, Canvas>;
	var customCompositeLists:Map<Int, DisplayList>;
	var customCompositeKeys:Map<Int, String>;
	var customCompositeGeometries:Map<Int, ResolvedLayoutItem>;
	var customCompositeBound:Map<Int, Bool>;
	final previousNodesById:Map<Int, RenderNode>;
	final currentNodesById:Map<Int, RenderNode>;
	final submittedNodes:Array<RenderNode> = [];
	var submittedTopology:RenderTreeTopology = new RenderTreeTopology();
	var nextTopology:RenderTreeTopology = new RenderTreeTopology();
	final resolvedById:Map<Int, ResolvedLayoutItem>;
	var accessibilityBridge:Null<AccessibilityBridge>;
	var accessibilitySurface:Null<PlatformSurface>;
	var decorationWindow:Null<WindowHandle>;
	var decorationCapabilityChecked:Bool;
	var decorationAvailable:Bool;
	var cursorHandler:Null<CursorShape->Void>;
	var currentCursor:CursorShape;
	var lastFrameMetrics:Null<UiFrameMetrics>;
	var frameNumber:Int;
	var diagnosticStage:Int = 0;
	public final textInput:TextInputBridge;
	/** Application layout to window logical coordinates for platform geometry. */
	public var platformCoordinateScale:Float = 1.0;

	public function new(?session:LayoutSession, ?fonts:FontCollection, ?theme:Theme) {
		this.session = session == null ? LayoutSession.create() : session;
		stateStore = new StateStore();
		clipboard = new ClipboardService();
		textInput = new TextInputBridge();
		gestures = new GestureArena();
		animations = new AnimationScheduler();
		interactionStates = new InteractionStateStore();
		commands = new CommandRegistry();
		commandContext = new CommandContext();
		buildContext = new BuildContext(stateStore, fonts, textInput, clipboard, theme,
			gestures, animations, null, interactionStates, commands);
		comparisonFrame = new UiStyleInvalidationFrame(buildContext, layoutChanges, submittedTopology);
		buildContext.setCommandContext(commandContext);
		if (fonts != null)
			this.session.setFonts(fonts);
		focus = new FocusManager();
		events = new EventDispatcher(focus, interactionStates, commands, commandContext);
		root = null;
		onAnimationFrameRequested = null;
		submittedStateRevision = -1;
		submittedInteractionRevision = -1;
		var verifyEvery = Sys.getEnv("HAXEON_UI_VERIFY_RETENTION");
		var parsedEvery:Null<Int> = verifyEvery == null ? null : Std.parseInt(verifyEvery);
		if (parsedEvery != null && parsedEvery > 0)
			verifyRetentionEvery = parsedEvery;
		submittedStyleRevision = -1;
		submittedAnimationRevision = -1;
		submittedGestureRevision = -1;
		submittedCommandRevision = -1;
		submittedNodeCount = 0;
		submittedFrameWidth = -1.0;
		submittedFrameHeight = -1.0;
		submittedBuildKey = null;
		submittedTheme = null;
		submittedStyleSheet = null;
		hitTestIds = [];
		disposed = false;
		buildContext.setFocusRequester(function(id) { return focusWidget(id); });
		buildContext.setDeferredFocusRequester(function(id) { ensureLive(); pendingFocus = id; commands.refresh(); });
		customCanvases = new Map();
		customLists = new Map();
		customGeometries = new Map();
		customPaintKeys = new Map();
		customContentRevisions = new Map();
		customListHasCommands = new Map();
		customPaintBound = new Map();
		customCompositeCanvases = new Map();
		customCompositeLists = new Map();
		customCompositeKeys = new Map();
		customCompositeGeometries = new Map();
		customCompositeBound = new Map();
		previousNodesById = new Map();
		currentNodesById = new Map();
		resolvedById = new Map();
		accessibilityBridge = null;
		accessibilitySurface = null;
		decorationWindow = null;
		decorationCapabilityChecked = false;
		decorationAvailable = false;
		cursorHandler = null;
		currentCursor = CursorShape.Arrow;
		animations.onFrameRequested = function() {
			if (!disposed && onAnimationFrameRequested != null)
				onAnimationFrameRequested();
		};
		lastFrameMetrics = null;
		frameNumber = 0;
	}

	/** Sets the active document/selection context for contextual commands. */
	public function setCommandContext(context:Null<CommandContext>):Void {
		commandContext = context == null ? new CommandContext() : context;
		buildContext.setCommandContext(commandContext);
		events.setCommandContext(commandContext);
		commands.refresh();
	}

	/** Sets fonts for text-aware widgets and the native layout session. */
	public function setFonts(fonts:FontCollection):Void {
		ensureLive();
		if (fonts == null || fonts.isDisposed())
			throw "UI context requires a live font collection";
		session.setFonts(fonts);
		buildContext.setFonts(fonts);
		submittedStyleRevision = -1;
	}

	/** Sets the palette used by subsequent view builds. */
	public function setTheme(theme:Theme):Void {
		ensureLive();
		buildContext.setTheme(theme);
	}

	/** Sets the application rules layered above the active theme stylesheet. */
	public function setStyleSheet(styleSheet:StyleSheet):Void {
		ensureLive();
		buildContext.setStyleSheet(styleSheet);
	}

	/** Attaches the host surface used by platform text-input synchronization. */
	public function attachPlatformSurface(surface:PlatformSurface):Void {
		ensureLive();
		if (surface == null || surface.isDisposed())
			throw "UI context requires a live NativeKit surface";
		buildContext.setPlatformSurface(surface);
	}

	/** Attaches the NativeKit-owned window that receives declarative chrome regions. */
	public function attachPlatformWindow(window:WindowHandle):Void {
		ensureLive();
		if (window == null || !window.isValid())
			throw "UI context requires a live NativeKit window";
		if (decorationWindow != null)
			clearWindowDecorations();
		decorationWindow = window;
		decorationCapabilityChecked = false;
		decorationAvailable = false;
		if (root != null)
			syncWindowDecorations(root);
	}

	/** Detaches the window and clears any regions previously projected by this context. */
	public function detachPlatformWindow():Void {
		ensureLive();
		if (decorationWindow != null)
			clearWindowDecorations();
		decorationWindow = null;
	}

	/** Builds a fresh view tree, resolves native layout, and reconnects geometry by stable ID. */
	public function submit(view:View, frame:LayoutFrame):RenderNode {
		var build = function() return view;
		var result = submitInternal(frame, null, build);
		return maybeVerifyRetention(build, frame, result);
	}

	/**
	 * Submits a lazily built view and reuses the prior tree when the complete
	 * caller-provided build key and all framework revisions are unchanged.
	 */
	public function submitCached(build:Void->View, frame:LayoutFrame,
			cacheKey:String):RenderNode {
		if (build == null)
			throw "Cached UI submissions require a build callback";
		if (cacheKey == null || cacheKey.length == 0)
			throw "Cached UI submissions require a non-empty cache key";
		var result = submitInternal(frame, cacheKey, build);
		return maybeVerifyRetention(build, frame, result);
	}

	/**
	 * Debug check that retention is invisible. Every `verifyRetentionEvery` frames that did work, the view is built again from
	 * scratch, bypassing every retained cache, patch and in-place edit, and must give the same tree; see verifyRetention. 0 turns
	 * it off. The environment variable HAXEON_UI_VERIFY_RETENTION sets it when the context is created.
	 */
	public var verifyRetentionEvery:Int = 0;
	/** Called with the difference when a check fails; by default the check throws it. */
	public var onRetentionMismatch:Null<String->Void> = null;
	var framesSinceVerify:Int = 0;
	var verifying:Bool = false;

	function maybeVerifyRetention(build:Void->View, frame:LayoutFrame, result:RenderNode):RenderNode {
		if (verifyRetentionEvery <= 0 || verifying)
			return result;
		var metrics = lastFrameMetrics;
		if (metrics != null && metrics.reusedSubmission)
			return result;
		framesSinceVerify++;
		if (framesSinceVerify < verifyRetentionEvery)
			return result;
		framesSinceVerify = 0;
		var difference = verifyRetention(build, frame);
		if (difference != null) {
			var report = onRetentionMismatch;
			if (report == null)
				throw difference;
			report(difference);
		}
		return cast root;
	}

	/**
	 * Builds the view again from scratch, with every retained cache, patch and in-place edit bypassed and no time passing, and
	 * compares the result with the tree that was live. Returns null when they match, or the first lines that differ. Hover and
	 * press flags are not compared: routing writes them onto live nodes that no widget built from them. The rebuilt tree stays
	 * live, which is harmless when they match.
	 */
	public function verifyRetention(build:Void->View, frame:LayoutFrame):Null<String> {
		ensureLive();
		if (root == null || build == null || frame == null)
			return null;
		session.verifyTree(root.layout);
		var live = comparableDump();
		var savedKey = submittedBuildKey;
		var delta = frame.deltaSeconds;
		frame.deltaSeconds = 0.0;
		verifying = true;
		buildContext.bypassRetention = true;
		try {
			submitInternal(frame, null, build, false);
		} catch (error:Dynamic) {
			buildContext.bypassRetention = false;
			verifying = false;
			frame.deltaSeconds = delta;
			throw error;
		}
		buildContext.bypassRetention = false;
		verifying = false;
		frame.deltaSeconds = delta;
		// The tree is equivalent when the check passes, so the next frame may reuse it as before.
		submittedBuildKey = savedKey;
		var rebuilt = comparableDump();
		return live == rebuilt ? null : describeDifference(live, rebuilt);
	}

	/** Fingerprints of the submitted tree's nodes, by widget ID, while verification is on. */
	final submittedFingerprints:Map<Int, Int> = new Map();

	function recordFingerprints(tree:RenderNode):Void {
		submittedFingerprints.clear();
		tree.walk(function(node) submittedFingerprints.set(node.id.value, node.fingerprint()));
	}

	/**
	 * Finds nodes of the submitted tree that are still in the new one and were changed in between without willEditRetained
	 * or a patch: a frame cannot see such a change, so it is shown only by chance. Reported like a retention mismatch.
	 */
	function checkUnannouncedEdits(tree:RenderNode):Void {
		var patched = buildContext.patchedPriors();
		var found:Array<String> = [];
		tree.walk(function(node) {
			var id = node.id.value;
			if (currentNodesById.get(id) != node || !submittedFingerprints.exists(id) || patched.exists(id) ||
				buildContext.editAnnounced(node))
				return;
			if (submittedFingerprints.get(id) != node.fingerprint() && found.length < 5)
				found.push(stateStoreDescription(node));
		});
		if (found.length == 0)
			return;
		var difference = "Nodes of the submitted tree changed without willEditRetained:\n  " + found.join("\n  ");
		var report = onRetentionMismatch;
		if (report == null)
			throw difference;
		report(difference);
	}

	function stateStoreDescription(node:RenderNode):String
		return (node.styleType == null ? "" : node.styleType + " ") + stateStore.describe(node.id);

	function comparableDump():String
		return UiInspector.dump(root, focus.focusedId,
			haxeon.ui.style.StyleState.Hovered | haxeon.ui.style.StyleState.Pressed);

	static function describeDifference(live:String, rebuilt:String):String {
		var left = live.split("\n"), right = rebuilt.split("\n");
		var line = 0;
		while (line < left.length && line < right.length && left[line] == right[line])
			line++;
		var from = line < 3 ? 0 : line - 3;
		var out = new StringBuf();
		out.add("Retained UI differs from a fresh build at line " + (line + 1) + ":\n");
		for (index in from...line)
			out.add("    " + left[index] + "\n");
		for (index in line...Std.int(Math.min(left.length, line + 4)))
			out.add("  - " + left[index] + "\n");
		for (index in line...Std.int(Math.min(right.length, line + 4)))
			out.add("  + " + right[index] + "\n");
		return out.toString();
	}

	function submitInternal(frame:LayoutFrame, cacheKey:Null<String>, build:Void->View,
			reconcileNewFocus:Bool = true, buildFeedbackPass:Int = 0):RenderNode {
		var submitStartedAt = Sys.time();
		diagnosticStage = 1;
		ensureLive();
		if (frame == null || build == null)
			throw "A UI frame requires a view and layout frame";
		var styleResolutionsBefore = buildContext.styleResolver.resolutions;
		var styleCacheHitsBefore = buildContext.styleResolver.cacheHits;
		var styleCacheMissesBefore = buildContext.styleResolver.cacheMisses;
		diagnosticStage = 2;
		if (reconcileNewFocus && buildFeedbackPass == 0)
			gestures.advance(frame.deltaSeconds);
		diagnosticStage = 3;
		if (reconcileNewFocus && buildFeedbackPass == 0)
			animations.advance(frame.deltaSeconds);
		buildContext.setViewport(frame.width, frame.height);
		buildContext.setEnvironmentViewport(frame.width, frame.height);
		var hoverPaintNodes = -1;
		var reuse = buildFeedbackPass == 0 && reconcileNewFocus && cacheKey != null && canReuseSubmittedFrame(cacheKey, frame);
		if (!reuse && buildFeedbackPass == 0 && reconcileNewFocus && cacheKey != null) {
			hoverPaintNodes = reuseHoverPaint(cacheKey, frame);
			reuse = hoverPaintNodes >= 0;
		}
		var patchOnly = !reuse && buildFeedbackPass == 0 && reconcileNewFocus && cacheKey != null && planInteractionPatches(cacheKey, frame);
		if (reuse) {
			frameNumber++;
			lastFrameMetrics = new UiFrameMetrics(frameNumber, submittedNodeCount, 0, 0, 0,
				buildContext.styleResolver.cachedStyleCount, 0, submittedNodeCount, UiDirtyFlag.None,
				0, 0, 0, 0, 0, 0, Sys.time() - submitStartedAt, false, true, 0,
				submittedNodeCount);
			lastFrameMetrics.markReusedSubmission();
			if (hoverPaintNodes >= 0) lastFrameMetrics.hoverPaintUpdatedNodes = hoverPaintNodes;
			diagnosticStage = 0;
			return cast root;
		}
		buildContext.beginLayoutSubmission();
		// Building reparents retained children out of the old tree. Preserve that frame's complete membership before it moves.
		previousNodesById.clear();
		for (node in submittedNodes) previousNodesById.set(node.id.value, node);
		// A patch-only frame keeps the submitted tree and rebuilds just the widgets that read the pointer change.
		buildContext.resetObserved();
		if (!patchOnly) {
			buildContext.beginFrame();
			queueInteractionPatches();
		}
		// Announced edits precede patches: a composite rebuild must not replace their original priors with edited children.
		buildContext.takeRetainedEdits(currentNodesById);
		buildContext.applyPatches(submittedTopology);
		diagnosticStage = 4;
		var viewStartedAt = Sys.time();
		var viewAllocatedAt = AllocationProbe.now();
		var view = patchOnly ? null : build();
		var viewBuiltAt = Sys.time();
		var viewBuiltAllocatedAt = AllocationProbe.now();
		var next = patchOnly ? root : buildContext.withScope(new haxeon.ui.core.Key("root"), function() return view == null ? null : view.build(buildContext));
		if (next == null || (!patchOnly && next.parent != null))
			throw "A view must produce one unparented render tree root";
		if (inspectionEnabled) appendInspectionOverlay(next, frame);
		// Decorations may be assigned by view wrappers after widget construction.
		// Promote those boxes before invalidation compares their native visual kind.
		next.walk(function(node) node.syncPaintKind());
		diagnosticStage = 5;
		var treeBuiltAllocatedAt = AllocationProbe.now();
		// Nodes changed in place since the last frame are compared against how they were (currentNodesById is still that frame's).
		if (verifyRetentionEvery > 0 && !verifying)
			checkUnannouncedEdits(next);

		buildContext.takeRetainedEdits(currentNodesById);
		layoutChanges.clear();
		comparisonFrame.topology = submittedTopology;
		comparisonFrame.preserveRevisions = false;
		var styleInvalidation = UiStyleInvalidationMetrics.compare(root, next,
			previousNodesById, currentNodesById, buildContext.patchedPriors(), comparisonFrame);
		buildContext.endPatchFrame();
		// The comparison above resets paint revisions, so custom paint that only reacts to hover is invalidated after it. On a
		// full rebuild a node may have been replaced by a fresh one, which paints anyway; invalidating the old one is harmless.
		for (node in patchFramePaintNodes) node.invalidatePaint();
		patchFramePaintNodes.resize(0);
		var compareAllocatedAt = AllocationProbe.now();
		next.syncLayoutInputs(layoutChanges);
		var syncAllocatedAt = AllocationProbe.now();
		var previousById = previousNodesById;
		var nodesById = currentNodesById;
		var nativeLayoutReused = !verifying && !styleInvalidation.nativeLayoutRequired &&
			submittedFrameWidth == frame.width && submittedFrameHeight == frame.height;
		if (nativeLayoutReused)
			next.walk(function(node) {
				var previous = previousById.get(node.id.value);
				var previousResolved:Null<ResolvedLayoutItem> = previous == null ? null : previous.resolved;
				if (previousResolved == null)
					nativeLayoutReused = false;
			});
		var resolved:Array<ResolvedLayoutItem>;
		var nativeLayoutStartedAt = Sys.time();
		var nativeLayoutStartAllocatedAt = AllocationProbe.now();
		if (nativeLayoutReused) {
			resolved = [];
			next.walk(function(node) {
				var previous = previousById.get(node.id.value);
				var previousResolved:Null<ResolvedLayoutItem> = previous == null ? null : previous.resolved;
				if (previousResolved != null)
					resolved.push(previousResolved);
			});
		} else {
			session.verifyTransactions = verifyRetentionEvery > 0;
			resolved = session.submit(next.layout, frame, layoutChanges, verifying);
		}
		layoutChanges.clear();
		diagnosticStage = 6;
		var resolvedStateRevision = stateStore.revision;
		var missing = false;
		var missingNode:Null<RenderNode> = null;
		var nodeCount = 0;
		// Which nodes are mounted, in tree order, for the key caches' pruning.
		var mountedHash = 0;
		var resolvedGeometryChangedNodes = 0;
		var resolvedGeometryReusedNodes = 0;
		var layoutPass = 0;
		while (true) {
			resolvedById.clear();
			for (item in resolved)
				resolvedById.set(item.id, item);
			missing = false;
			missingNode = null;
			nodeCount = 0;
			mountedHash = 0;
			resolvedGeometryChangedNodes = 0;
			resolvedGeometryReusedNodes = 0;
			diagnosticStage = 7;
			submittedNodes.resize(0);
			nextTopology.clear();
			next.walk(function(node) {
				submittedNodes.push(node);
				nodeCount++;
				mountedHash = mountedHash * 31 + node.id.value;
				// Geometry is keyed by the exact LayoutNode ID serialized to NativeUI.
				var item = resolvedById.get(node.layout.id);
				if (item == null) {
					missing = true;
					if (missingNode == null) missingNode = node;
					return;
				}
				var previous = previousById.get(node.id.value);
				var previousResolved:Null<ResolvedLayoutItem> = previous == null ? null : previous.resolved;
				var geometryChanged = previousResolved == null || !sameGeometry(previousResolved, item);
				if (!geometryChanged && previousResolved != null) {
					item = previousResolved;
					resolvedGeometryReusedNodes++;
				} else
					resolvedGeometryChangedNodes++;
				// Resolved callbacks still run when geometry is retained.
				node.setResolved(item);
				nextTopology.append(node);
			});
			if (missing) {
				diagnosticStage = 8;
				throw "Native layout did not return geometry for render node " +
					Std.string(missingNode == null ? -1 : missingNode.id.value) + " (" +
					(missingNode == null ? "unknown" : missingNode.styleType) + ")" +
					" pass=" + layoutPass + " reused=" + nativeLayoutReused +
					" resolved=" + resolved.length + " nodes=" + nodeCount +
					" firstResolved=" + (resolved.length == 0 ? -1 : resolved[0].id) +
					" visible=" + (missingNode == null ? "?" : Std.string(missingNode.layout.style.visible)) +
					" parent=" + (missingNode == null || missingNode.parent == null ? "?" : missingNode.parent.styleType) +
					" parentVisible=" + (missingNode == null || missingNode.parent == null ? "?" : Std.string(missingNode.parent.layout.style.visible));
			}
			if (!buildContext.consumeLayoutFeedback())
				break;
			// Dependent geometry (text reflow, scroll extent, overlay placement)
			// must settle before publishing the frame. Never silently discard
			// a requested pass; fail explicitly if callbacks cannot converge.
			if (layoutPass >= 7)
				throw "UI layout feedback did not converge after 8 passes";
			buildContext.takeRetainedEdits(currentNodesById);
			UiStyleInvalidationMetrics.collectLayoutEdits(currentNodesById, buildContext.patchedPriors(), layoutChanges);
			buildContext.endPatchFrame();
			resolved = session.submit(next.layout, frame, layoutChanges, verifying);
			layoutChanges.clear();
			layoutPass++;
		}
		var nativeLayoutEndedAt = Sys.time();
		var nativeLayoutEndAllocatedAt = AllocationProbe.now();
		if (layoutPass > 0) {
			comparisonFrame.preserveRevisions = true;
			styleInvalidation = UiStyleInvalidationMetrics.compare(root, next,
				previousNodesById, currentNodesById, null, comparisonFrame);
		}
		var previousTopology = submittedTopology;
		submittedTopology = nextTopology;
		nextTopology = previousTopology;
		if (buildContext.consumeBuildFeedback()) {
			if (buildFeedbackPass >= 7) throw "UI build feedback did not converge after 8 passes";
			// Commit layout for the next comparison, but keep focus requests and widget resources until children settle.
			root = next;
			if (verifyRetentionEvery > 0) recordFingerprints(next);
			return submitInternal(frame, cacheKey, build, reconcileNewFocus, buildFeedbackPass + 1);
		}
		syncWindowDecorations(next);
		diagnosticStage = 9;
		var previousFocus = focus.focusedId;
		focus.rebuild(next);
		var requestedFocus = pendingFocus;
		pendingFocus = null;
		if (requestedFocus != null) focus.focus(requestedFocus);
		var nextFocus = focus.focusedId;
		var focusChanged = (previousFocus == null && nextFocus != null) ||
			(previousFocus != null && (nextFocus == null || !previousFocus.equals(nextFocus)));
		if (previousFocus != null && (nextFocus == null || !previousFocus.equals(nextFocus)))
			events.focusEvent(previousFocus, UiEventKind.Blur);
		root = next;
		events.setHitTestProvider(function(x:Float, y:Float) {
			session.hitTestInto(x, y, hitTestIds);
			var path:Array<RenderNode> = [];
			path.resize(hitTestIds.length);
			for (index in 0...hitTestIds.length) {
				var node = nodesById.get(hitTestIds[index]);
				if (node == null)
					return [];
				path[index] = node;
			}
			return path;
		});
		events.setRoot(next);
		gestures.setRoot(next);
		updateCursor();
		if (nextFocus != null && (previousFocus == null || !previousFocus.equals(nextFocus)))
			events.focusEvent(nextFocus, UiEventKind.Focus);
		// Reconcile focus before releasing resources owned by unmounted widgets.
		// Blur is the old tree's final lifecycle event, so its handlers must still
		// be able to access widget state while that event is being dispatched.
		stateStore.endFrame();
		buildContext.pruneSelfUpdatingBuilds(nodesById);
		buildContext.pruneKeyCaches(nodesById, mountedHash);
		buildContext.stateStore.prunePaths(nodesById);
		submittedStateRevision = resolvedStateRevision;
		submittedInteractionRevision = interactionStates.revision;
		submittedStyleRevision = buildContext.styleRevision;
		submittedAnimationRevision = animations.revision;
		submittedRetainedEditRevision = buildContext.retainedEditRevision;
		submittedPatchRequestRevision = buildContext.patchRequestRevision;
		submittedGestureRevision = gestures.revision;
		submittedCommandRevision = commands.revision;
		submittedNodeCount = nodeCount;
		submittedFrameWidth = frame.width;
		submittedFrameHeight = frame.height;
		submittedBuildKey = cacheKey;
		submittedTheme = buildContext.theme;
		submittedStyleSheet = buildContext.styleSheet;
		if (accessibilityBridge != null && (styleInvalidation.treeChanged ||
			styleInvalidation.semanticsInvalidatedNodes > 0 ||
			resolvedGeometryChangedNodes > 0 || focusChanged)) {
			accessibilityBridge.coordinateScale = platformCoordinateScale;
			accessibilityBridge.update(next, focus.focusedId);
		}
		// A newly mounted focus trap chooses its first target after layout, and a widget that stopped being focusable (disabled)
		// loses focus here while still on screen. Rebuild once with that focus state before returning the frame for painting;
		// a widget that left the tree shows nothing stale, so losing its focus needs no second build.
		// This pass is now committed, including fresh nodes. A focus pass must compare against these instances, not
		// fingerprints of the previous frame's different nodes with the same IDs.
		if (verifyRetentionEvery > 0)
			recordFingerprints(next);
		if (reconcileNewFocus && focusChanged && (nextFocus != null ||
			(previousFocus != null && nodesById.exists(previousFocus.value))))
			return submitInternal(frame, cacheKey, function() return view, false, buildFeedbackPass);
		// Focus routing can add changes after the build. Keep them until the focus pass has patched their owners.
		interactionStates.acknowledge();
		frameNumber++;
		var submitEndedAt = Sys.time();
		var submitEndAllocatedAt = AllocationProbe.now();
		lastFrameMetrics = new UiFrameMetrics(frameNumber, nodeCount,
			buildContext.styleResolver.resolutions - styleResolutionsBefore,
			buildContext.styleResolver.cacheHits - styleCacheHitsBefore,
			buildContext.styleResolver.cacheMisses - styleCacheMissesBefore,
			buildContext.styleResolver.cachedStyleCount,
			styleInvalidation.styleChangedNodes, styleInvalidation.styleUnchangedNodes,
			styleInvalidation.invalidationFlags, styleInvalidation.layoutInvalidatedNodes,
			styleInvalidation.textLayoutInvalidatedNodes, styleInvalidation.paintInvalidatedNodes,
			styleInvalidation.compositeInvalidatedNodes, styleInvalidation.semanticsInvalidatedNodes,
			styleInvalidation.hitGeometryInvalidatedNodes,
				submitEndedAt - submitStartedAt, !nativeLayoutReused, nativeLayoutReused,
				resolvedGeometryChangedNodes, resolvedGeometryReusedNodes);
		lastFrameMetrics.setSubmitPhases(viewBuiltAt - viewStartedAt,
			nativeLayoutStartedAt - viewBuiltAt, nativeLayoutEndedAt - nativeLayoutStartedAt,
			submitEndedAt - nativeLayoutEndedAt);
		lastFrameMetrics.setTreeAllocations(treeBuiltAllocatedAt - viewBuiltAllocatedAt, compareAllocatedAt - treeBuiltAllocatedAt,
			syncAllocatedAt - compareAllocatedAt, nativeLayoutStartAllocatedAt - syncAllocatedAt);
		lastFrameMetrics.setSubmitAllocations(viewBuiltAllocatedAt - viewAllocatedAt, nativeLayoutStartAllocatedAt - viewBuiltAllocatedAt,
			nativeLayoutEndAllocatedAt - nativeLayoutStartAllocatedAt, submitEndAllocatedAt - nativeLayoutEndAllocatedAt);
		diagnosticStage = 0;
		return next;
	}

	/**
	 * Lets go of the retained render tree and everything that holds its nodes or their handler closures: the root, the
	 * node maps, the hit-test picker, hover paths, focus order, in-flight gestures and self-updating builders. Interaction
	 * state that holds no code stays: focus by ID, pointer presses and captures by ID, widget state, the key caches and the
	 * native paint lists (repainted, not reused, by the next frame). Until the next submit, input finds no target and the
	 * context must not be rendered; the next submit builds the whole tree afresh. A live host calls this before a patch that
	 * drops functions, so stored closures only the old tree held no longer reach them.
	 */
	public function releaseRetained():Void {
		ensureLive();
		root = null;
		submittedNodes.resize(0);
		submittedTopology.clear();
		nextTopology.clear();
		inspectionNode = null;
		submittedBuildKey = null;
		previousNodesById.clear();
		currentNodesById.clear();
		resolvedById.clear();
		events.releaseTree();
		focus.releaseTree();
		gestures.setRoot(null);
		buildContext.releaseRetained();
		// The painters may be new code: paint every node again instead of reusing its list by key.
		customPaintKeys.clear();
		customCompositeKeys.clear();
	}

	public function getDiagnosticStage():Int
		return diagnosticStage;

	/** Connects this frame's semantic projection to a NativeKit platform surface. */
	public function updateAccessibility(surface:PlatformSurface):Void {
		ensureLive();
		if (surface == null || surface.isDisposed())
			throw "Accessibility projection requires a live NativeKit surface";
		if (accessibilitySurface != surface) {
			if (accessibilityBridge != null)
				accessibilityBridge.dispose();
			accessibilitySurface = surface;
			accessibilityBridge = new AccessibilityBridge(surface);
		}
		accessibilityBridge.coordinateScale = platformCoordinateScale;
		accessibilityBridge.update(root, focus.focusedId);
	}

	/** Matches the render traversal's eligibility checks without a second node map. */
	function hasCurrentCustomPaint(nodeId:Int):Bool {
		var node = currentNodesById.get(nodeId);
		if (node == null || !node.hasPaintHandler() || node.resolved == null) return false;
		var geometry = node.resolved;
		return geometry.width > 0.0 && geometry.height > 0.0 &&
			geometry.clipBounds.width > 0.0 && geometry.clipBounds.height > 0.0;
	}

	public function render(renderer:Renderer, surface:Surface, frame:FrameInfo):Void {
		var renderStartedAt = Sys.time();
		var renderStartAllocatedAt = AllocationProbe.now();
		diagnosticStage = 20;
		ensureLive();
		if (root == null)
			throw "Submit a view before rendering the UI context";
		diagnosticStage = 21;
		var paintedNodes = 0;
		var paintSkippedNodes = 0;
		var emptyPaintNodes = 0;
		diagnosticStage = 22;
		root.walk(function(node) {
			var nodeId = node.id.value;
			if (node.resolved != null && node.cachePolicy != CachePolicy.None)
				session.setCachePolicy(node.id.value, node.cachePolicy);
			if (!node.hasPaintHandler() || node.resolved == null) {
				clearCustomPaintBindings(node.id.value);
				return;
			}
			if (node.resolved.visible &&
				(node.resolved.width <= 0.0 || node.resolved.height <= 0.0))
				emptyPaintNodes++;
			// A hidden painter records nothing; do not cache that empty result as its content.
			// Keep any existing local list so it can be rebound when the node becomes visible.
			if (!node.resolved.visible || node.resolved.width <= 0.0 || node.resolved.height <= 0.0 ||
				node.resolved.clipBounds.width <= 0.0 || node.resolved.clipBounds.height <= 0.0) {
				clearCustomPaintBindings(nodeId);
				return;
			}
			var displayList = customLists.get(nodeId);
			var contentReused = displayList != null && canReuseCustomPaint(node);
			if (contentReused) {
				if (customListHasCommands.get(nodeId) == true) {
					if (customPaintBound.get(nodeId) != true) {
						session.setCustomPaint(nodeId, displayList);
						customPaintBound.set(nodeId, true);
					}
					if (node.cachePolicy != CachePolicy.None)
						session.setCustomPaintCachePolicy(nodeId, node.cachePolicy);
				}
			} else {
				var canvas = customCanvases.get(nodeId);
				if (canvas == null) {
					canvas = new Canvas();
					canvas.retainRectangles = true;
					customCanvases.set(nodeId, canvas);
				}
				canvas.reset();
				var geometry:ResolvedLayoutItem = cast node.resolved;
				var inspectionStarted = onInspectionPaint == null || node == inspectionNode ? 0.0 : Sys.time();
				canvas.withState(function(target) {
					target.resetTransform();
					// Custom painters own only node-local pixels. Native layout and
					// compositing apply the resolved position, transform, and ancestor
					// clips when the retained list is embedded.
					target.clip(new Rect(0.0, 0.0, geometry.width, geometry.height));
					node.paintContent(target);
				});
				if (displayList == null) {
					displayList = DisplayList.create();
					customLists.set(nodeId, displayList);
				}
				canvas.update(displayList);
				if (onInspectionPaint != null && node != inspectionNode) onInspectionPaint(nodeId, Sys.time() - inspectionStarted);
				var hasCommands = displayList.info().commandCount > 0;
				customListHasCommands.set(nodeId, hasCommands);
				if (hasCommands) {
					session.setCustomPaint(nodeId, displayList);
					customPaintBound.set(nodeId, true);
				} else {
					session.clearCustomPaint(nodeId);
					customPaintBound.set(nodeId, false);
				}
				if (hasCommands && node.cachePolicy != CachePolicy.None)
					session.setCustomPaintCachePolicy(nodeId, node.cachePolicy);
				customGeometries.set(nodeId, geometry);
				customPaintKeys.set(nodeId, node.retainedPaintKey());
				customContentRevisions.set(nodeId, node.contentRevision);
				paintedNodes++;
			}

			var compositeList = customCompositeLists.get(nodeId);
			if (node.hasCompositePaint() && customListHasCommands.get(nodeId) == true) {
				var compositeRebuilt = false;
				if (compositeList == null || !canReuseCustomComposite(node)) {
					compositeRebuilt = true;
					var compositeCanvas = customCompositeCanvases.get(nodeId);
					if (compositeCanvas == null) {
						compositeCanvas = new Canvas();
						customCompositeCanvases.set(nodeId, compositeCanvas);
					}
					compositeCanvas.reset();
					node.paintComposite(compositeCanvas);
					if (compositeList == null) {
						compositeList = DisplayList.create();
						customCompositeLists.set(nodeId, compositeList);
					}
					compositeCanvas.update(compositeList);
					customCompositeKeys.set(nodeId, node.retainedCompositeKey());
					customCompositeGeometries.set(nodeId, cast node.resolved);
				}
				if (compositeList != null && compositeList.info().commandCount > 0) {
					if (compositeRebuilt || customCompositeBound.get(nodeId) != true)
						session.setCustomPaintComposite(nodeId, compositeList);
					customCompositeBound.set(nodeId, true);
				} else if (customCompositeBound.get(nodeId) == true) {
					session.clearCustomPaintComposite(nodeId);
					customCompositeBound.set(nodeId, false);
				}
			} else if (customCompositeBound.get(nodeId) == true) {
				session.clearCustomPaintComposite(nodeId);
				customCompositeBound.set(nodeId, false);
			}
			if (contentReused)
				paintSkippedNodes++;
		});
		diagnosticStage = 23;
		var stale = stalePaintNodes;
		stale.resize(0);
		for (nodeId in customLists.keys())
			if (!hasCurrentCustomPaint(nodeId)) stale.push(nodeId);
		for (nodeId in customCompositeLists.keys())
			if (!customLists.exists(nodeId) && !hasCurrentCustomPaint(nodeId)) stale.push(nodeId);
		for (nodeId in stale) {
			clearCustomPaintBindings(nodeId);
			var canvas = customCanvases.get(nodeId);
			if (canvas != null) {
				canvas.reset();
				canvas.releaseRetained();
			}
			var displayList = customLists.get(nodeId);
			if (displayList != null)
				displayList.dispose();
			customCanvases.remove(nodeId);
			customLists.remove(nodeId);
			customGeometries.remove(nodeId);
			customPaintKeys.remove(nodeId);
			customContentRevisions.remove(nodeId);
			customPaintBound.remove(nodeId);
			var compositeCanvas = customCompositeCanvases.get(nodeId);
			if (compositeCanvas != null)
				compositeCanvas.reset();
			var compositeList = customCompositeLists.get(nodeId);
			if (compositeList != null)
				compositeList.dispose();
			customCompositeCanvases.remove(nodeId);
			customCompositeLists.remove(nodeId);
			customCompositeKeys.remove(nodeId);
			customCompositeGeometries.remove(nodeId);
			customCompositeBound.remove(nodeId);
			customListHasCommands.remove(nodeId);
		}
		diagnosticStage = 24;
		var nativeRenderStartedAt = Sys.time();
		var nativeRenderStartAllocatedAt = AllocationProbe.now();
		session.render(renderer, surface, frame);
		if (lastFrameMetrics != null) {
			var renderEndedAt = Sys.time();
			lastFrameMetrics.completeRender(renderEndedAt - renderStartedAt, paintedNodes,
				paintSkippedNodes, emptyPaintNodes);
			lastFrameMetrics.setRenderPhases(nativeRenderStartedAt - renderStartedAt,
				renderEndedAt - nativeRenderStartedAt);
			var renderEndAllocatedAt = AllocationProbe.now();
			lastFrameMetrics.setRenderAllocations(nativeRenderStartAllocatedAt - renderStartAllocatedAt,
				renderEndAllocatedAt - nativeRenderStartAllocatedAt);
		}
		diagnosticStage = 0;
	}

	/**
	 * Advances active animations and repaints the retained tree without relayout.
	 * Hosts should use this for animation-only frames instead of submit().
	 */
	public function renderAnimationFrame(renderer:Renderer, surface:Surface,
			frame:FrameInfo, deltaSeconds:Float):Void {
		ensureLive();
		animations.advance(deltaSeconds);
		render(renderer, surface, frame);
	}

	public function focusWidget(id:WidgetId):Bool {
		ensureLive();
		var previous = focus.focusedId;
		if (!focus.focus(id))
			return false;
		dispatchFocusChange(previous, focus.focusedId);
		return true;
	}

	public function focusNext():Null<WidgetId> {
		ensureLive();
		var previous = focus.focusedId;
		var next = focus.focusNext();
		dispatchFocusChange(previous, next);
		return next;
	}

	public function focusPrevious():Null<WidgetId> {
		ensureLive();
		var previous = focus.focusedId;
		var next = focus.focusPrevious();
		dispatchFocusChange(previous, next);
		return next;
	}

	public function clearFocus():Void {
		ensureLive();
		focusBeforeWindowBlur = null;
		var previous = focus.focusedId;
		focus.focus(null);
		dispatchFocusChange(previous, null);
	}

	/** Routes a NativeKit platform accessibility action to the addressed semantic node. */
	public function accessibilityAction(id:Int, action:Int, value:Null<String>,
			selectionStart:Int, selectionEnd:Int, granularity:Int):Bool {
		ensureLive();
		if (root == null || id <= 0)
			return false;
		var widgetId = new WidgetId(id);
		var node = root.find(widgetId);
		if (node == null || node.semantics == null || node.resolved == null || !node.resolved.visible)
			return false;
		var semantics:Semantics = cast node.semantics;
		var request = AccessibilityRequest.create(action, value, selectionStart,
			selectionEnd, granularity);
		if (request == null)
			return false;
		var enabled = enabledAlongPath(node);
		var actions = semantics.actions;
		if (node.focusable && enabled)
			actions |= haxeon.ui.semantics.AccessibilityAction.Focus;
		if (!enabled)
			actions = 0;
		if ((actions & request.capability) == 0)
			return false;
		var geometry:ResolvedLayoutItem = cast node.resolved;
		if (action == AccessibilityRequest.Focus)
			return focusWidget(widgetId);
		if (action == AccessibilityRequest.ClearFocus) {
			if (focus.focusedId != null && focus.focusedId.equals(widgetId))
				clearFocus();
			return true;
		}
		var deltaX = 0.0;
		var deltaY = 0.0;
		if (action == AccessibilityRequest.ScrollForward)
			deltaY = geometry.height;
		else if (action == AccessibilityRequest.ScrollBackward)
			deltaY = -geometry.height;
		if (action == AccessibilityRequest.ScrollForward ||
			action == AccessibilityRequest.ScrollBackward)
			return events.targetEvent(UiEventKind.Scroll, widgetId, null, deltaX,
				deltaY, new AccessibilityActionData(action, selectionStart, selectionEnd, granularity));
		return events.targetEvent(request.kind, widgetId, request.value, 0.0, 0.0,
			new AccessibilityActionData(action, selectionStart, selectionEnd, granularity));
	}

	/** Clears transient pointer state and reports loss of platform window focus. */
	public function windowFocusLost():Void {
		ensureLive();
		if (windowFocused) focusBeforeWindowBlur = focus.focusedId;
		windowFocused = false;
		events.cancelPointers();
		updateCursor();
		gestures.cancelAll();
		var previous = focus.focusedId;
		if (previous != null)
			events.focusEvent(previous, UiEventKind.FocusLost);
		focus.focus(null);
		dispatchFocusChange(previous, null);
	}

	/** Restore keyboard ownership after activation, subject to current focus eligibility. */
	public function windowFocusGained():Void {
		ensureLive();
		if (windowFocused) return;
		windowFocused = true;
		var restore = focusBeforeWindowBlur;
		focusBeforeWindowBlur = null;
		// A background change may have selected another widget or opened a modal.
		// focusWidget also rejects removed, hidden, disabled and trapped-out nodes.
		// With the tree released, the next submit restores it.
		if (focus.focusedId == null && restore != null) {
			if (root == null) pendingFocus = restore;
			else focusWidget(restore);
		}
	}

	public function pointerMove(x:Float, y:Float, modifiers:Int = 0,
			pointerId:Int = 0, data:Dynamic = null):Void {
		ensureLive();
		updateModifiers(modifiers);
		events.pointerMove(x, y, modifiers, pointerId, data);
		updateCursor();
	}

	public function pointerDown(x:Float, y:Float, button:Int, modifiers:Int = 0,
			pointerId:Int = 0, data:Dynamic = null, timestamp:Float = -1.0):Void {
		ensureLive();
		updateModifiers(modifiers);
		events.pointerDown(x, y, button, modifiers, pointerId, data, timestamp);
		updateCursor();
	}

	public function pointerUp(x:Float, y:Float, button:Int, modifiers:Int = 0,
			pointerId:Int = 0, data:Dynamic = null):Void {
		ensureLive();
		updateModifiers(modifiers);
		events.pointerUp(x, y, button, modifiers, pointerId, data);
		updateCursor();
	}

	public function pointerCancel(pointerId:Int, x:Float, y:Float,
			modifiers:Int = 0, data:Dynamic = null):Void {
		ensureLive();
		events.pointerCancel(pointerId, x, y, modifiers, data);
		updateCursor();
	}

	public function pointerLeave(pointerId:Int = 0):Void {
		ensureLive();
		events.clearPointer(pointerId);
		updateCursor();
	}

	/** Ends a captured drag if the platform reports its button released on re-entry. */
	public function pointerReenter(buttonPressed:Bool, x:Float, y:Float,
			pointerId:Int = 0):Void {
		ensureLive();
		if (!buttonPressed && events.hasCapturedPointer(pointerId))
			pointerCancel(pointerId, x, y);
	}

	/** Installs the platform bridge that applies the context's effective cursor. */
	public function setCursorHandler(handler:Null<CursorShape->Void>):Void {
		ensureLive();
		cursorHandler = handler;
		if (handler != null)
			handler(currentCursor);
	}

	/** Installs the host bridge used for physical window/surface pointer capture. */
	public function setPointerCaptureHandler(handler:Null<Bool->Void>):Void {
		ensureLive();
		events.setPointerCaptureHandler(handler);
	}

	public function scroll(x:Float, y:Float, deltaX:Float, deltaY:Float, modifiers:Int = 0):Void {
		ensureLive();
		updateModifiers(modifiers);
		events.scroll(x, y, deltaX, deltaY, modifiers);
	}

	public function key(kind:String, key:Int, modifiers:Int = 0, scancode:Int = 0):Void {
		ensureLive();
		updateModifiers(modifiers);
		// NativeKit preserves the keypad key code; UI controls share Enter behavior.
		if (key == 335) key = UiKey.Enter;
		events.key(kind, key, modifiers, scancode);
	}

	public function text(kind:String, value:Null<String>, data:Dynamic = null):Void {
		ensureLive();
		events.text(kind, value, data);
	}

	/** True when nothing but pointer state moved since the submitted frame, so retained output may be updated instead of rebuilt. */
	function steadyForInteractionReuse(cacheKey:String, frame:LayoutFrame):Bool {
		return root != null && submittedBuildKey == cacheKey && submittedStateRevision == stateStore.revision &&
			submittedStyleRevision == buildContext.styleRevision && submittedFrameWidth == frame.width &&
			submittedFrameHeight == frame.height && animations.rebuildingCount == 0 &&
			animations.revision == submittedAnimationRevision && gestures.revision == submittedGestureRevision &&
			commands.revision == submittedCommandRevision && buildContext.theme == submittedTheme &&
			buildContext.styleSheet == submittedStyleSheet;
	}

	/** Validate every changed widget before mutating retained paint; unknown behavior rebuilds. */
	function reuseHoverPaint(cacheKey:String, frame:LayoutFrame):Int {
		if (!steadyForInteractionReuse(cacheKey, frame) || buildContext.hasRetainedEdits || buildContext.hasPendingPatches) return -1;
		var changes = interactionStates.changes();
		for (change in changes) {
			if (((change.before ^ change.after) & ~haxeon.ui.style.StyleState.Hovered) != 0) return -1;
			var node = currentNodesById.get(change.id);
			if (node == null || (node.recordsInteraction && buildContext.hoverRebuilds(node))) return -1;
		}
		var painted = 0;
		for (change in changes) {
			var node:RenderNode = cast currentNodesById.get(change.id);
			if (node.hasPaintHandler()) { node.invalidatePaint(); painted++; }
		}
		submittedInteractionRevision = interactionStates.revision;
		interactionStates.acknowledge();
		return painted;
	}

	/** Nodes whose only change is custom paint during a patch-only frame; filled by `planInteractionPatches`. */
	final patchFramePaintNodes:Array<RenderNode> = [];
	static final patchInteractionMask:Int = haxeon.ui.style.StyleState.Hovered | haxeon.ui.style.StyleState.Pressed;

	/**
	 * Decides whether the pending pointer changes can be met by rebuilding just the widgets that read them (self-updating
	 * widgets, such as buttons), leaving every other node of the submitted tree as it is. Queues those rebuilds and returns true,
	 * or returns false having changed nothing, in which case the whole view rebuilds.
	 */
	function planInteractionPatches(cacheKey:String, frame:LayoutFrame):Bool {
		if (inspectionEnabled || !buildContext.updateInPlace || !steadyForInteractionReuse(cacheKey, frame)) return false;
		var changes = interactionStates.changes();
		for (change in changes) {
			var bits = change.before ^ change.after;
			var node = currentNodesById.get(change.id);
			if (node == null) return false;
			// Routing stores the state a node was built with (Selected, Disabled) alongside the pointer bits, so the first pointer
			// change of a node appears to set those too. Only a pointer bit, or a disagreement with the built state, is a change.
			var other = bits & ~patchInteractionMask;
			if (other != 0 && (change.after & other) != (node.states & other)) return false;
			bits &= patchInteractionMask;
			if (bits == 0) continue;
			if (buildContext.updatingOwner(node) == null && node.recordsInteraction && (bits != haxeon.ui.style.StyleState.Hovered || buildContext.hoverRebuilds(node))) return false;
		}
		patchFramePaintNodes.resize(0);
		for (change in changes) {
			var node:RenderNode = cast currentNodesById.get(change.id);
			var owner = buildContext.updatingOwner(node);
			if (owner != null) {
				if (owner == node || node.recordsInteraction) buildContext.queuePatch(owner.id);
			} else if (node.hasPaintHandler()) patchFramePaintNodes.push(node);
		}
		return true;
	}

	/** On a full rebuild, retained caches no longer notice pointer changes of self-updating widgets, so they are rebuilt here. */
	function queueInteractionPatches():Void {
		patchFramePaintNodes.resize(0);
		for (change in interactionStates.changes()) {
			var node = currentNodesById.get(change.id);
			if (node == null) continue;
			var owner = buildContext.updatingOwner(node);
			if (owner != null) {
				if (owner == node || node.recordsInteraction) buildContext.queuePatch(owner.id);
			// Retained caches ignore hover no rule matches, so a cached node that paints it is repainted here.
			} else if (node.recordsInteraction && node.hasPaintHandler()) patchFramePaintNodes.push(node);
		}
	}

	function canReuseSubmittedFrame(cacheKey:String, frame:LayoutFrame):Bool {
		return root != null && submittedBuildKey == cacheKey && dirtyFlags == UiDirtyFlag.None &&
			submittedFrameWidth == frame.width && submittedFrameHeight == frame.height &&
			animations.revision == submittedAnimationRevision && gestures.revision == submittedGestureRevision &&
			commands.revision == submittedCommandRevision &&
			buildContext.theme == submittedTheme &&
			buildContext.styleSheet == submittedStyleSheet;
	}

	function canReuseCustomPaint(node:RenderNode):Bool {
		var nodeId = node.id.value;
		var key = node.retainedPaintKey();
		if (key == null || !customPaintKeys.exists(nodeId) ||
			!customListHasCommands.exists(nodeId) || customPaintKeys.get(nodeId) != key)
			return false;
		if (customContentRevisions.get(nodeId) != node.contentRevision)
			return false;
		var previousGeometry = customGeometries.get(nodeId);
		if (previousGeometry == null || node.resolved == null ||
			!samePaintGeometry(previousGeometry, node.resolved))
			return false;
		return true;
	}

	function canReuseCustomComposite(node:RenderNode):Bool {
		var nodeId = node.id.value;
		if (!customCompositeLists.exists(nodeId) ||
			customCompositeKeys.get(nodeId) != node.retainedCompositeKey())
			return false;
		var previousGeometry = customCompositeGeometries.get(nodeId);
		return previousGeometry != null && node.resolved != null &&
			samePaintGeometry(previousGeometry, node.resolved);
	}

	/** Local custom display lists only depend on the size of their paint plane. */
	static function samePaintGeometry(left:ResolvedLayoutItem, right:ResolvedLayoutItem):Bool
		return left.width == right.width && left.height == right.height;

	function clearCustomPaintBindings(nodeId:Int):Void {
		if (customPaintBound.get(nodeId) == true) {
			session.clearCustomPaint(nodeId);
			customPaintBound.set(nodeId, false);
		}
		if (customCompositeBound.get(nodeId) == true) {
			session.clearCustomPaintComposite(nodeId);
			customCompositeBound.set(nodeId, false);
		}
	}

	static function sameGeometry(left:ResolvedLayoutItem, right:ResolvedLayoutItem):Bool {
		// Everything but the id, which names the node rather than where it is. The rectangles and the transform are compared by
		// the generated equality of their structural classes.
		return left == right || left.flags == right.flags && left.x == right.x && left.y == right.y &&
			left.width == right.width && left.height == right.height && left.baseline == right.baseline &&
			haxeon.Equality.equals(left.clipBounds, right.clipBounds) &&
			haxeon.Equality.equals(left.contentBounds, right.contentBounds) &&
			haxeon.Equality.equals(left.transform, right.transform);
	}

	public function isDirty():Bool
		return dirtyFlags != UiDirtyFlag.None;

	public var needsAnimationFrame(get, never):Bool;
	inline function get_needsAnimationFrame():Bool
		return animations.needsFrame;

	/** Seconds until animations that are only waiting next need a frame, or -1 for none. */
	public function animationWaitSeconds():Float
		return animations.waitSeconds();

	/** Reports pending work categories without changing the current full-submit behavior. */
	public var dirtyFlags(get, never):Int;
	function get_dirtyFlags():Int {
		var result = 0;
		if (stateStore.revision != submittedStateRevision)
			result |= UiDirtyFlag.NeedsBuild | UiDirtyFlag.NeedsStyle | UiDirtyFlag.NeedsTextLayout |
				UiDirtyFlag.NeedsLayout | UiDirtyFlag.NeedsPaint | UiDirtyFlag.NeedsComposite |
				UiDirtyFlag.NeedsSemantics | UiDirtyFlag.NeedsHitGeometry;
		if (interactionStates.revision != submittedInteractionRevision)
			result |= UiDirtyFlag.NeedsStyle | UiDirtyFlag.NeedsTextLayout | UiDirtyFlag.NeedsLayout |
				UiDirtyFlag.NeedsPaint | UiDirtyFlag.NeedsComposite | UiDirtyFlag.NeedsSemantics |
				UiDirtyFlag.NeedsHitGeometry;
		if (buildContext.styleRevision != submittedStyleRevision)
			result |= UiDirtyFlag.NeedsStyle | UiDirtyFlag.NeedsTextLayout | UiDirtyFlag.NeedsLayout |
				UiDirtyFlag.NeedsPaint | UiDirtyFlag.NeedsComposite | UiDirtyFlag.NeedsSemantics |
				UiDirtyFlag.NeedsHitGeometry;
		if (commands.revision != submittedCommandRevision)
			result |= UiDirtyFlag.NeedsBuild | UiDirtyFlag.NeedsStyle | UiDirtyFlag.NeedsTextLayout |
				UiDirtyFlag.NeedsLayout | UiDirtyFlag.NeedsPaint | UiDirtyFlag.NeedsComposite |
				UiDirtyFlag.NeedsSemantics | UiDirtyFlag.NeedsHitGeometry;
		if (animations.rebuildingCount > 0)
			result |= UiDirtyFlag.NeedsComposite;
		if (buildContext.patchRequestRevision != submittedPatchRequestRevision)
			result |= UiDirtyFlag.NeedsBuild | UiDirtyFlag.NeedsStyle | UiDirtyFlag.NeedsTextLayout |
				UiDirtyFlag.NeedsLayout | UiDirtyFlag.NeedsPaint | UiDirtyFlag.NeedsComposite |
				UiDirtyFlag.NeedsSemantics | UiDirtyFlag.NeedsHitGeometry;
		if (buildContext.retainedEditRevision != submittedRetainedEditRevision)
			result |= UiDirtyFlag.NeedsStyle | UiDirtyFlag.NeedsLayout | UiDirtyFlag.NeedsPaint |
				UiDirtyFlag.NeedsComposite | UiDirtyFlag.NeedsHitGeometry;
		return result;
	}

	function set_inspectionHighlight(value:Int):Int {
		if (value != inspectionHighlight) submittedBuildKey = null;
		if (value > 0) inspectionEnabled = true;
		return inspectionHighlight = value;
	}

	/** A final retained paint plane shares the application's frame acquisition and presentation. */
	function appendInspectionOverlay(tree:RenderNode, frame:LayoutFrame):Void {
		if (inspectionNode != null && inspectionNode.parent == tree) return;
		var style = new haxeon.ui.LayoutStyle();
		style.positioning = haxeon.ui.LayoutPositioning.Absolute;
		style.width = haxeon.ui.LayoutAxis.fixed(frame.width);
		style.height = haxeon.ui.LayoutAxis.fixed(frame.height);
		style.zIndex = 32767;
		style.clipToParent = false;
		var id = buildContext.withScope(new haxeon.ui.core.Key("__devtools_inspection"), function() return buildContext.id("overlay"));
		var node = new RenderNode(id, haxeon.ui.LayoutVisualKind.Custom, style);
		node.setStyleIdentity("devtools-overlay", null, null);
		node.hitTestSelf = false;
		node.onPaint(function(canvas, geometry) {
			if (inspectionHighlight <= 0 || root == null) return;
			var inspected = root.find(new WidgetId(inspectionHighlight));
			if (inspected == null || inspected.resolved == null || !inspected.resolved.visible) return;
			var bounds = inspected.resolved.clippedViewportBounds();
			var x = bounds.x - geometry.x, y = bounds.y - geometry.y;
			var color = haxeon.ui.Color.fromBytes(80, 180, 255, 220);
			canvas.fillRectIfPositive(new Rect(x, y, bounds.width, 2), color);
			canvas.fillRectIfPositive(new Rect(x, y + bounds.height - 2, bounds.width, 2), color);
			canvas.fillRectIfPositive(new Rect(x, y, 2, bounds.height), color);
			canvas.fillRectIfPositive(new Rect(x + bounds.width - 2, y, 2, bounds.height), color);
		});
		inspectionNode = node;
		tree.add(node);
	}

	/** Returns a deterministic headless snapshot of the most recently submitted tree. */
	public function inspect():Array<UiNodeSnapshot> {
		ensureLive();
		return UiInspector.snapshot(root, focus.focusedId, events.hoveredId(), events.pressedId());
	}

	/** Timing and style-cache counters captured during the latest submit/render. */
	public var frameMetrics(get, never):Null<UiFrameMetrics>;
	function get_frameMetrics():Null<UiFrameMetrics>
		return lastFrameMetrics;

	/** Returns cumulative native geometric hit-test diagnostics. */
	public var hitTestMetrics(get, never):LayoutHitTestStats;
	function get_hitTestMetrics():LayoutHitTestStats
		return session.hitTestStats();

	/** Formats the current render and semantic tree for logs or developer tools. */
	public function dumpTree():String {
		ensureLive();
		return UiInspector.dump(root, focus.focusedId);
	}

	/** Audits common accessibility naming and focus-geometry mistakes. */
	public function auditAccessibility():Array<AccessibilityIssue> {
		ensureLive();
		return AccessibilityAudit.inspect(root);
	}

	public function dispose():Void {
		if (disposed)
			return;
		pendingFocus = null;
		focusBeforeWindowBlur = null;
		session.clearCustomPaints();
		for (nodeId in customCanvases.keys()) {
			var canvas = customCanvases.get(nodeId);
			if (canvas != null) {
				canvas.reset();
				canvas.releaseRetained();
			}
		}
		for (nodeId in customLists.keys()) {
			var displayList = customLists.get(nodeId);
			if (displayList != null)
				displayList.dispose();
		}
		for (nodeId in customCompositeLists.keys()) {
			var displayList = customCompositeLists.get(nodeId);
			if (displayList != null)
				displayList.dispose();
		}
		customCanvases = new Map();
		customLists = new Map();
		customGeometries = new Map();
		customPaintKeys = new Map();
		customContentRevisions = new Map();
		customListHasCommands = new Map();
		customPaintBound = new Map();
		customCompositeCanvases = new Map();
		customCompositeLists = new Map();
		customCompositeKeys = new Map();
		customCompositeGeometries = new Map();
		customCompositeBound = new Map();
		events.setHitTestProvider(null);
		session.dispose();
		clipboard.dispose();
		textInput.dispose();
		gestures.cancelAll();
		if (cursorHandler != null)
			cursorHandler(CursorShape.Arrow);
		cursorHandler = null;
		events.setPointerCaptureHandler(null);
		currentCursor = CursorShape.Arrow;
		animations.cancelAll();
		if (accessibilityBridge != null)
			accessibilityBridge.dispose();
		if (decorationWindow != null)
			clearWindowDecorations();
		decorationWindow = null;
		stateStore.dispose();
		buildContext.dispose();
		interactionStates.dispose();
		disposed = true;
		root = null;
		accessibilityBridge = null;
		accessibilitySurface = null;
	}

	function updateCursor():Void {
		var next = events.cursorShape();
		if (next == currentCursor)
			return;
		currentCursor = next;
		if (cursorHandler != null)
			cursorHandler(next);
	}

	function syncWindowDecorations(tree:RenderNode):Void {
		if (decorationWindow == null || !supportsWindowDecorations())
			return;
		var regions:Array<NativeWindowDecorationRegion> = [];
		tree.walk(function(node) {
			if (node.windowDecoration == null || node.resolved == null ||
				!node.resolved.visible)
				return;
			var bounds = node.resolved.clippedViewportBounds();
			var left = Math.max(0.0, bounds.x);
			var top = Math.max(0.0, bounds.y);
			var right = Math.min(buildContext.viewportWidth, bounds.x + bounds.width);
			var bottom = Math.min(buildContext.viewportHeight, bounds.y + bounds.height);
			if (right <= left || bottom <= top)
				return;
			var region = new NativeWindowDecorationRegion();
			region.set_x(left * platformCoordinateScale);
			region.set_y(top * platformCoordinateScale);
			region.set_width((right - left) * platformCoordinateScale);
			region.set_height((bottom - top) * platformCoordinateScale);
			var kind:WindowDecorationRegionKind = cast node.windowDecoration;
			region.set_kind(kind);
			region.set_cursor_shape(node.windowDecorationCursor == null
				? 0 : nativeCursorShape(node.windowDecorationCursor));
			regions.push(region);
		});
		var window:WindowHandle = cast decorationWindow;
		NativeKit.nk_window_set_decoration_regions_checked(window, regions);
	}

	function clearWindowDecorations():Void {
		if (decorationWindow == null || !supportsWindowDecorations())
			return;
		try {
			var window:WindowHandle = cast decorationWindow;
			NativeKit.nk_window_set_decoration_regions_checked(window, []);
		} catch (_:Dynamic) {
			// Context disposal must remain best-effort if the host already destroyed the window.
		}
	}

	function supportsWindowDecorations():Bool {
		if (decorationCapabilityChecked)
			return decorationAvailable;
		decorationCapabilityChecked = true;
		var capabilities = NativeKit.nk_get_capabilities();
		decorationAvailable = haxe.Int64.compare(
			haxe.Int64.and(capabilities, Capabilities.windowCustomDecorations()),
			haxe.Int64.ofInt(0)) != 0;
		return decorationAvailable;
	}

	static function nativeCursorShape(shape:UiCursorShape):Int {
		return cast switch shape {
			case UiCursorShape.Arrow: CursorShape.Arrow;
			case UiCursorShape.Text: CursorShape.Ibeam;
			case UiCursorShape.Crosshair: CursorShape.Crosshair;
			case UiCursorShape.Hand: CursorShape.Hand;
			case UiCursorShape.HorizontalResize: CursorShape.HorizontalResize;
			case UiCursorShape.VerticalResize: CursorShape.VerticalResize;
			case UiCursorShape.DiagonalResize: CursorShape.NwseResize;
			case UiCursorShape.DiagonalResizeNesw: CursorShape.NeswResize;
			case UiCursorShape.Move: CursorShape.Move;
			case UiCursorShape.NotAllowed: CursorShape.NotAllowed;
			case _: CursorShape.Arrow;
		};
	}

	function dispatchFocusChange(previous:Null<WidgetId>, next:Null<WidgetId>):Void {
		if (previous != null && (next == null || !previous.equals(next)))
			events.focusEvent(previous, UiEventKind.Blur);
		if (next != null && (previous == null || !previous.equals(next)))
			events.focusEvent(next, UiEventKind.Focus);
	}

	function ensureLive():Void {
		if (disposed)
			throw "UI context has been disposed";
	}

	static function enabledAlongPath(node:RenderNode):Bool {
		var current:Null<RenderNode> = node;
		while (current != null) {
			var present:RenderNode = cast current;
			if (!present.enabled)
				return false;
			current = present.parent;
		}
		return true;
	}
}
