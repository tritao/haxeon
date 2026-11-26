package haxeon.ui.core;

import haxeon.ui.style.Density;
import haxeon.reactive.ReactiveRuntime;
import haxeon.platform.Surface;
import nativekit.ffi.NativeKitTypes.WindowDecorationRegion as NativeWindowDecorationRegion;
import nativekit.ffi.NativeKitTypes;
import nativekit.ffi.NativeKitTypes.NativeCursorShape;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutSession;
import haxeon.ui.LayoutChanges;
import haxeon.ui.IntIndex;
import haxeon.ui.Canvas;
import haxeon.ui.Renderer;
import haxeon.ui.FrameInfo;
import haxeon.ui.Rect;
import haxeon.ui.ResolvedLayoutItem;
import haxeon.ui.FontCollection;
import nativekit.ffi.NativeKit;
import haxeon.ui.core.RenderNode.CursorShape as UiCursorShape;
import haxeon.ui.semantics.AccessibilityBridge;
import haxeon.ui.semantics.AccessibilityRequest;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.theme.Theme;
import haxeon.ui.style.StyleSheet;
import haxeon.ui.gestures.GestureArena;
import haxeon.ui.animation.AnimationScheduler;
import haxeon.ui.semantics.AccessibilityAudit;
import haxeon.ui.core.UiFrameMetrics;
import haxeon.ui.core.UiInspector;
import haxeon.ui.core.TreeDiff;
import haxeon.ui.core.TreeDiff.TreeDiffFrame;

import haxeon.ui.core.Command;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiEvent;
/** Owns the frame-local render tree and the Haxe-side UI subsystems. */
class UiContext implements Disposable {
	final session:LayoutSession;
	final layoutChanges:LayoutChanges = new LayoutChanges();
	final comparisonFrame:TreeDiffFrame;

	/** The state widgets keep between builds (`BuildContext.state`), by widget and scope. */
	public final stateStore:StateStore;

	/** The clipboard text fields copy to and paste from. */
	public final clipboard:ClipboardService;

	/** What views build with: the theme, the state, the services; the same for every frame of this context. */
	public final buildContext:BuildContext;

	/** Which widget has keyboard focus, and the order Tab moves it in. */
	public final focus:FocusManager;

	/** Routes pointer, key and text input to the widgets it is for. */
	public final events:EventDispatcher;

	/** Decides which gesture recognizer gets a pointer sequence when several could. */
	public final gestures:GestureArena;

	/** Runs the UI's animations and says when they need another frame. */
	public final animations:AnimationScheduler;

	/** Each widget's hovered, pressed and focused states, which styles select on. */
	public final interactionStates:InteractionStateStore;
	/** Control sizing for the input in use; the host sets Touch when touch is primary. */
	public var density:Density = Density.Pointer;

	/** Application commands and shortcut scopes owned by this UI context. */
	public final commands:CommandRegistry;

	/** Current document/selection context used by command-bound UI. */
	public var commandContext(default, null):CommandContext;

	/** The render tree of the last frame built, or null before the first. */
	public var root(default, null):Null<RenderNode>;

	/** Opt-in developer selection. Drawn after application paint and excluded from hit testing. */
	public var inspectionHighlight(default, set):Int = 0;

	/** Optional detailed paint probe. Disabled unless an inspector explicitly subscribes. */
	public var onInspectionPaint:Null<Int->Float->Void>;

	var inspectionEnabled = false;
	var inspectionNode:Null<RenderNode>;
	var pendingFocus:Null<WidgetId> = null;
	var pendingFocusLabel:Null<String> = null;
	var windowFocused:Bool = true;
	var focusBeforeWindowBlur:Null<WidgetId> = null;

	/** Called when an active animation needs another host frame. */
	public var onAnimationFrameRequested:Null<Void->Void>;

	/** Modifier observation independent of keyboard focus (for pointer affordances). */
	public var onModifiersChanged:Null<UiModifier->Void>;

	/** The modifier keys held now, as the last input reported them. */
	public var modifiers(default, null):UiModifier = UiModifier.empty();

	function updateModifiers(value:UiModifier):Void {
		if (modifiers == value) return;
		modifiers = value;
		var handler = onModifiersChanged;
		if (handler != null) handler(value);
	}

	var submittedInteractionRevision:Int;
	var submittedRetainedEditRevision:Int = 0;
	var submittedPatchRequestRevision:Int = 0;
	var submittedBindingRequestRevision:Int = 0;
	var submittedStyleRevision:Int;
	var submittedAnimationRevision:Int;
	var submittedGestureRevision:Int;
	var submittedNodeCount:Int;
	var submittedFrameWidth:Float;
	var submittedFrameHeight:Float;
	var submittedBuildKey:Null<String>;
	var submittedTheme:Null<Theme>;
	var submittedStyleSheet:Null<StyleSheet>;
	final hitTestIds:Array<Int>;

	/** Reused until releaseRetained, so a frame need not allocate another picker closure. */
	var retainedHitTestProvider:Null<Float->Float->Array<RenderNode>> = null;

	/** The dispatcher treats paths as immutable; reuse one while all of its node identities still match. */
	var retainedHitPath:Null<Array<RenderNode>> = null;

	/** Reuse the resolved-node visitor and counters across submissions. */
	final visitResolvedNode:RenderNode->Void;

	var visitResolved:Array<ResolvedLayoutItem>;
	var visitMissing = false;
	var visitMissingNode:Null<RenderNode>;
	var visitNodeCount = 0;
	var visitMountedHash = 0;
	var visitGeometryChanged = 0;
	var visitGeometryReused = 0;
	var disposed:Bool;
	final customPaint = new CustomPaintCache();
	final previousNodesById:Map<Int, RenderNode>;
	final currentNodesById:Map<Int, RenderNode>;
	final submittedNodes:Array<RenderNode> = [];
	final submittedPaintNodes:Array<RenderNode> = [];
	var submittedTopology:RenderTreeTopology = new RenderTreeTopology();
	var nextTopology:RenderTreeTopology = new RenderTreeTopology();

	/** Reuses integer storage for the current native result's ID-to-position index. */
	final resolvedById:IntIndex;

	var accessibilityBridge:Null<AccessibilityBridge>;
	var accessibilitySurface:Null<Surface>;
	var decorationWindow:Null<WindowHandle>;
	var decorationCapabilityChecked:Bool;
	var decorationAvailable:Bool;
	var cursorHandler:Null<UiCursorShape->Void>;
	var currentCursor:UiCursorShape;
	var lastFrameMetrics:Null<UiFrameMetrics>;
	var pendingReusedMetrics:Bool = false;
	var reusedMetricsSeconds:Float = 0.0;
	var reusedMetricsCachedStyles:Int = 0;
	var reusedMetricsHoverNodes:Int = -1;
	var frameNumber:Int;
	var diagnosticStage:Int = 0;

	/** The platform's text input: the on-screen keyboard, and input method composition. */
	public final textInput:TextInputBridge;

	/** Application layout to window logical coordinates for platform geometry. */
	public var platformCoordinateScale:Float = 1.0;

	/**
	 * A UI context with its own state, focus and input routing. A host makes one per window; `session`, `fonts` and
	 * `theme` default to fresh ones.
	 */
	public function new(?session:LayoutSession, ?fonts:FontCollection, ?theme:Theme) {
		visitResolvedNode = collectResolvedNode;
		this.session = session == null ? LayoutSession.create() : session;
		stateStore = new StateStore();
		clipboard = new ClipboardService();
		textInput = new TextInputBridge();
		gestures = new GestureArena();
		animations = new AnimationScheduler();
		interactionStates = new InteractionStateStore();
		commands = new CommandRegistry();
		commandContext = new CommandContext();
		buildContext = new BuildContext(stateStore,
			fonts,
			textInput,
			clipboard,
			theme,
			gestures,
			animations,
			null,
			interactionStates,
			commands);
		comparisonFrame = new TreeDiffFrame(buildContext, layoutChanges, submittedTopology);
		buildContext.setCommandContext(commandContext);
		if (fonts != null) this.session.setFonts(fonts);
		focus = new FocusManager();
		events = new EventDispatcher(focus, interactionStates, commands, commandContext);
		root = null;
		onAnimationFrameRequested = null;
		submittedInteractionRevision = -1;
		var verifyEvery = Sys.getEnv("HAXEON_UI_VERIFY_RETENTION");
		var parsedEvery:Null<Int> = verifyEvery == null ? null : Std.parseInt(verifyEvery);
		if (parsedEvery != null && parsedEvery > 0) verifyRetentionEvery = parsedEvery;
		submittedStyleRevision = -1;
		submittedAnimationRevision = -1;
		submittedGestureRevision = -1;
		submittedNodeCount = 0;
		submittedFrameWidth = -1.0;
		submittedFrameHeight = -1.0;
		submittedBuildKey = null;
		submittedTheme = null;
		submittedStyleSheet = null;
		hitTestIds = [];
		disposed = false;
		// The verification build lays out a throwaway copy of the tree: focus it asks for there (a widget that takes focus when
		// first laid out) must not move the real focus, or the compared trees differ by something no frame did.
		buildContext.setFocusRequester(function(id) {
			return !verifying && focusWidget(id);
		});
		buildContext.setDeferredFocusRequester(function(id) {
			if (verifying) return;
			ensureLive();
			pendingFocus = id;
			pendingFocusLabel = buildContext.deferredFocusLabel;
		});
		previousNodesById = new Map();
		currentNodesById = new Map();
		resolvedById = new IntIndex();
		accessibilityBridge = null;
		accessibilitySurface = null;
		decorationWindow = null;
		decorationCapabilityChecked = false;
		decorationAvailable = false;
		cursorHandler = null;
		currentCursor = UiCursorShape.Arrow;
		animations.onFrameRequested = function() {
			if (!disposed && onAnimationFrameRequested != null) onAnimationFrameRequested();
		};
		buildContext.onBindingFrameRequested = function() {
			if (!disposed && onAnimationFrameRequested != null) onAnimationFrameRequested();
		};
		lastFrameMetrics = null;
		frameNumber = 0;
	}

	/** Sets the active document/selection context for contextual commands. */
	public function setCommandContext(context:Null<CommandContext>):Void {
		commandContext = context == null ? new CommandContext() : context;
		buildContext.setCommandContext(commandContext);
		events.setCommandContext(commandContext);
	}

	/** Sets fonts for text-aware widgets and the native layout session. */
	public function setFonts(fonts:FontCollection):Void {
		ensureLive();
		if (fonts == null || fonts.isDisposed()) throw "UI context requires a live font collection";
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
	public function attachPlatformSurface(surface:Surface):Void {
		ensureLive();
		if (surface == null || surface.isDisposed()) throw "UI context requires a live NativeKit surface";
		buildContext.setPlatformSurface(surface);
	}

	/** Releases platform services for this surface when it is still attached. */
	public function detachPlatformSurface(surface:Surface):Void {
		ensureLive();
		buildContext.clearPlatformSurface(surface);
	}

	/** Attaches the NativeKit-owned window that receives declarative chrome regions. */
	public function attachPlatformWindow(window:WindowHandle):Void {
		ensureLive();
		if (window == null || !window.isValid()) throw "UI context requires a live NativeKit window";
		if (decorationWindow != null) clearWindowDecorations();
		decorationWindow = window;
		decorationCapabilityChecked = false;
		decorationAvailable = false;
		if (root != null) syncWindowDecorations(root);
	}

	/** Detaches the window and clears any regions previously projected by this context. */
	public function detachPlatformWindow():Void {
		ensureLive();
		if (decorationWindow != null) clearWindowDecorations();
		decorationWindow = null;
	}

	/** Builds a fresh view tree, resolves native layout, and reconnects geometry by stable ID. */
	public function submit(view:View, frame:LayoutFrame):RenderNode {
		var build = function() return view;
		var focusBefore = focus.focusedId;
		var result = submitInternal(frame, null, build);
		// Focus moved during this frame: the nodes take on their focused state in the next one, so this frame's tree is
		// not yet what a rebuild would give. The check waits for the following frame.
		if (focus.focusedId != focusBefore)
			return result;
		return maybeVerifyRetention(build, frame, result);
	}

	/**
	 * Submits a lazily built view and reuses the prior tree when the complete
	 * caller-provided build key and all framework revisions are unchanged.
	 */
	public function submitCached(build:Void->View, frame:LayoutFrame, cacheKey:String):RenderNode {
		if (build == null) throw "Cached UI submissions require a build callback";
		if (cacheKey == null || cacheKey.length == 0) throw "Cached UI submissions require a non-empty cache key";
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
		if (verifyRetentionEvery <= 0 || verifying) return result;
		if (pendingReusedMetrics) return result;
		var metrics = lastFrameMetrics;
		if (metrics != null && metrics.reusedSubmission) return result;
		framesSinceVerify++;
		if (framesSinceVerify < verifyRetentionEvery) return result;
		framesSinceVerify = 0;
		var difference = verifyRetention(build, frame);
		if (difference != null) {
			var report = onRetentionMismatch;
			if (report == null) throw difference;
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
		if (root == null || build == null || frame == null) return null;
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
			if (currentNodesById.get(id) != node
				|| !submittedFingerprints.exists(id) || patched.exists(id) || buildContext.editAnnounced(node)) return;
			if (submittedFingerprints.get(id) != node.submittedFingerprint()
				&& found.length < 5) found.push(stateStoreDescription(node));
		});
		if (found.length == 0) return;
		var difference = "Nodes of the submitted tree changed without willEditRetained:\n  " + found.join("\n  ");
		var report = onRetentionMismatch;
		if (report == null) throw difference;
		report(difference);
	}

	function stateStoreDescription(node:RenderNode):String return (node.styleType
		== null ? "" : node.styleType + " ") + stateStore.describe(node.id);

	function comparableDump():String return UiInspector.dump(root,
		focus.focusedId,
		haxeon.ui.style.StyleState.Hovered | haxeon.ui.style.StyleState.Pressed);

	static function describeDifference(live:String, rebuilt:String):String {
		var left = live.split("\n"), right = rebuilt.split("\n");
		var line = 0;
		while (line < left.length && line < right.length && left[line] == right[line]) line++;
		var from = line < 3 ? 0 : line - 3;
		var out = new StringBuf();
		out.add("Retained UI differs from a fresh build at line " + (line + 1) + ":\n");
		for (index in from...line) out.add("    " + left[index] + "\n");
		for (index in line...Std.int(Math.min(left.length, line + 4))) out.add("  - " + left[index] + "\n");
		for (index in line...Std.int(Math.min(right.length, line + 4))) out.add("  + " + right[index] + "\n");
		return out.toString();
	}

	function collectResolvedNode(node:RenderNode):Void {
		submittedNodes.push(node);
		visitNodeCount++;
		visitMountedHash = visitMountedHash * 31 + node.id.value;
		// Geometry is keyed by the exact LayoutNode ID serialized to NativeUI.
		var position = resolvedById.get(node.layout.id);
		var resolved:Array<ResolvedLayoutItem> = cast visitResolved;
		var item = position < 0 ? null : resolved[position];
		if (item == null) {
			visitMissing = true;
			if (visitMissingNode == null) visitMissingNode = node;
			return;
		}
		var previous = previousNodesById.get(node.id.value);
		var previousResolved:Null<ResolvedLayoutItem> = previous == null ? null : previous.resolved;
		var geometryChanged = previousResolved == null || !sameGeometry(previousResolved, item);
		if (!geometryChanged && previousResolved != null) {
			item = previousResolved;
			visitGeometryReused++;
		} else visitGeometryChanged++;
		// Resolved callbacks still run when geometry is retained.
		node.setResolved(item);
		if (node.layout.visualKind == haxeon.ui.LayoutNode.LayoutVisualKind.Custom
			|| node.cachePolicy != CachePolicy.None) submittedPaintNodes.push(node);
		nextTopology.append(node);
	}

	function submitInternal(frame:LayoutFrame,
			cacheKey:Null<String>,
			build:Void->View,
			reconcileNewFocus:Bool = true,
			buildFeedbackPass:Int = 0):RenderNode {
		try return submitFrame(frame, cacheKey, build, reconcileNewFocus, buildFeedbackPass) catch (error:Dynamic) {
			buildContext.retryTextBindings();
			throw error;
		}
	}

	function submitFrame(frame:LayoutFrame,
			cacheKey:Null<String>,
			build:Void->View,
			reconcileNewFocus:Bool = true,
			buildFeedbackPass:Int = 0):RenderNode {
		var submitStartedAt = Sys.time();
		diagnosticStage = 1;
		ensureLive();
		if (frame == null || build == null) throw "A UI frame requires a view and layout frame";
		@:privateAccess buildContext.buildFeedbackPass = buildFeedbackPass;
		// Consume the request before running user getters so a failed effect can schedule a later retry.
		var bindingAppliedRevision = buildContext.consumeBindingFrameRequest();
		ReactiveRuntime.flushEffects();
		var styleResolutionsBefore = buildContext.styleResolver.resolutions;
		var styleCacheHitsBefore = buildContext.styleResolver.cacheHits;
		var styleCacheMissesBefore = buildContext.styleResolver.cacheMisses;
		diagnosticStage = 2;
		if (reconcileNewFocus && buildFeedbackPass == 0) gestures.advance(frame.deltaSeconds);
		diagnosticStage = 3;
		if (reconcileNewFocus && buildFeedbackPass == 0) animations.advance(frame.deltaSeconds);
		buildContext.setViewport(frame.width, frame.height);
		buildContext.setEnvironmentViewport(frame.width, frame.height);
		var hoverPaintNodes = -1;
		var rootReactiveDirty = buildContext.rootDependenciesDirty();
		var reuse = buildFeedbackPass == 0
			&& reconcileNewFocus && cacheKey != null && !rootReactiveDirty && canReuseSubmittedFrame(cacheKey,
			frame);
		if (!reuse && buildFeedbackPass == 0 && reconcileNewFocus && cacheKey != null) {
			hoverPaintNodes = reuseHoverPaint(cacheKey, frame);
			reuse = hoverPaintNodes >= 0;
		}
		var localPatchPending = (buildContext.hasPendingPatches
			|| buildContext.hasPendingRenderScopes()) && !rootReactiveDirty;
		var bindingOnly = cacheKey != null && sameSubmittedInputs(cacheKey, frame) && !rootReactiveDirty
			&& buildContext.bindingRequestRevision != submittedBindingRequestRevision
			&& interactionStates.revision == submittedInteractionRevision
			&& buildContext.styleRevision == submittedStyleRevision;
		var patchOnly = !reuse && (localPatchPending || bindingOnly) && (!reconcileNewFocus || cacheKey != null);
		if (!patchOnly
			&& !reuse && reconcileNewFocus && cacheKey != null
			&& buildFeedbackPass == 0) patchOnly = planInteractionPatches(cacheKey,
			frame);
		if (reuse) {
			frameNumber++;
			lastFrameMetrics = null;
			pendingReusedMetrics = true;
			reusedMetricsSeconds = Sys.time() - submitStartedAt;
			reusedMetricsCachedStyles = buildContext.styleResolver.cachedStyleCount;
			reusedMetricsHoverNodes = hoverPaintNodes;
			diagnosticStage = 0;
			return cast root;
		}
		var buildCostStartedAt = RenderCost.time();
		// Building reparents retained children out of the old tree. Preserve that frame's complete membership before it moves.
		previousNodesById.clear();
		for (node in submittedNodes) previousNodesById.set(node.id.value, node);
		buildContext.beginLayoutSubmission(previousNodesById);
		// A patch-only frame keeps the submitted tree and rebuilds just queued self-updating widgets. Internal feedback can
		// use that path without a cache key because its outer build already ran; a new uncached submission still builds its root.
		buildContext.resetObserved();
		if (!patchOnly) {
			buildContext.beginFrame();
			queueInteractionPatches();
		} else {
			if (interactionStates.revision != submittedInteractionRevision) queueInteractionPatches();
		}
		// Announced edits precede patches: a composite rebuild must not replace their original priors with edited children.
		buildContext.takeRetainedEdits(currentNodesById);
		diagnosticStage = 4;
		var viewStartedAt = Sys.time();
		var viewAllocatedAt = AllocationProbe.now();
		var view = patchOnly ? null : buildContext.trackReads(build);
		var viewBuiltAt = Sys.time();
		var viewBuiltAllocatedAt = AllocationProbe.now();
		var next = patchOnly ? (root == null
			? null : buildContext.currentRoot(root))
			: buildContext.trackReads(function() return buildContext.withScope(new haxeon.ui.core.Key("root"),
			function() return view == null ? null : view.build(buildContext)));
		if (!patchOnly) buildContext.captureRootDependencies();
		if (next == null
			|| (!patchOnly && next.parent != null)) throw "A view must produce one unparented render tree root";
		next = settleStructure(next);
		buildContext.flushTextBindings(next);
		if (inspectionEnabled) appendInspectionOverlay(next, frame);
		// Decorations may be assigned by view wrappers after widget construction.
		// Promote those boxes before invalidation compares their native visual kind.
		next.walk(function(node) node.syncPaintKind());
		diagnosticStage = 5;
		var treeBuiltAllocatedAt = AllocationProbe.now();
		// Nodes changed in place since the last frame are compared against how they were (currentNodesById is still that frame's).
		if (verifyRetentionEvery > 0 && !verifying) checkUnannouncedEdits(next);

		buildContext.takeRetainedEdits(currentNodesById);
		layoutChanges.clear();
		comparisonFrame.topology = submittedTopology;
		comparisonFrame.preserveRevisions = false;
		var styleInvalidation = TreeDiff.compare(root,
			next,
			previousNodesById,
			currentNodesById,
			buildContext.patchedPriors(),
			comparisonFrame);
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
		var nativeLayoutReused = !verifying && !styleInvalidation.nativeLayoutRequired
			&& submittedFrameWidth == frame.width && submittedFrameHeight == frame.height;
		if (nativeLayoutReused) next.walk(function(node) {
			var previous = previousById.get(node.id.value);
			var previousResolved:Null<ResolvedLayoutItem> = previous == null ? null : previous.resolved;
			if (previousResolved == null) nativeLayoutReused = false;
		});
		var resolved:Array<ResolvedLayoutItem>;
		var nativeLayoutStartedAt = Sys.time();
		var nativeLayoutStartAllocatedAt = AllocationProbe.now();
		if (nativeLayoutReused) {
			resolved = [];
			next.walk(function(node) {
				var previous = previousById.get(node.id.value);
				var previousResolved:Null<ResolvedLayoutItem> = previous == null ? null : previous.resolved;
				if (previousResolved != null) resolved.push(previousResolved);
			});
		} else {
			session.verifyTransactions = verifyRetentionEvery > 0;
			resolved = session.submit(next.layout, frame, layoutChanges, verifying);
		}
		layoutChanges.clear();
		diagnosticStage = 6;
		var nodeCount = 0;
		var mountedHash = 0;
		var resolvedGeometryChangedNodes = 0;
		var resolvedGeometryReusedNodes = 0;
		var resolvedBuildFeedback = false;
		var layoutPass = 0;
		while (true) {
			resolvedById.clear();
			for (index in 0...resolved.length) resolvedById.set(resolved[index].id, index);
			visitMissing = false;
			visitMissingNode = null;
			visitNodeCount = 0;
			visitMountedHash = 0;
			visitGeometryChanged = 0;
			visitGeometryReused = 0;
			diagnosticStage = 7;
			submittedNodes.resize(0);
			submittedPaintNodes.resize(0);
			nextTopology.clear();
			visitResolved = resolved;
			next.walk(visitResolvedNode);
			visitResolved = null;
			nodeCount = visitNodeCount;
			mountedHash = visitMountedHash;
			resolvedGeometryChangedNodes = visitGeometryChanged;
			resolvedGeometryReusedNodes = visitGeometryReused;
			if (visitMissing) {
				var missingNode = visitMissingNode;
				diagnosticStage = 8;
				throw "Native layout did not return geometry for render node " + Std.string(missingNode
					== null ? -1 : missingNode.id.value) + " ("
					+ (missingNode == null ? "unknown" : missingNode.styleType)
					+ ")" + " pass=" + layoutPass + " reused=" + nativeLayoutReused + " resolved=" + resolved.length
					+ " nodes="
					+ nodeCount + " firstResolved=" + (resolved.length == 0 ? -1 : resolved[0].id) + " visible="
					+ (missingNode
					== null ? "?" : Std.string(missingNode.layout.style.visible)) + " parent=" + (missingNode == null
					|| missingNode.parent == null ? "?" : missingNode.parent.styleType) + " parentVisible="
					+ (missingNode == null
					|| missingNode.parent == null ? "?" : Std.string(missingNode.parent.layout.style.visible));
			}
			// Handlers may read parent, child, viewport and content geometry. Give all of them the same settled layout pass
			// before any handler changes layout inputs or requests another pass.
			for (index in 0...submittedNodes.length) submittedNodes[submittedNodes.length - 1 - index].didResolve();
			// Signal writes and explicit callback requests rebuild before another layout pass consumes stale view geometry.
			var rootDirty = buildContext.rootDependenciesDirty();
			var patchesPending = buildContext.hasPendingPatches || buildContext.hasPendingRenderScopes();
			var earlyFeedback = buildContext.consumeBuildFeedbackBeforeLayout();
			if (rootDirty || patchesPending || earlyFeedback) {
				resolvedBuildFeedback = true;
				break;
			}
			if (!buildContext.consumeLayoutFeedback()) break;
			// Dependent geometry (text reflow, scroll extent, overlay placement)
			// must settle before publishing the frame. Never silently discard
			// a requested pass; fail explicitly if callbacks cannot converge.
			if (layoutPass >= 7) throw "UI layout feedback did not converge after 8 passes";
			buildContext.takeRetainedEdits(currentNodesById);
			TreeDiff.collectLayoutEdits(currentNodesById, buildContext.patchedPriors(),
				layoutChanges);
			buildContext.endPatchFrame();
			resolved = session.submit(next.layout, frame, layoutChanges, verifying);
			layoutChanges.clear();
			layoutPass++;
		}
		var nativeLayoutEndedAt = Sys.time();
		var nativeLayoutEndAllocatedAt = AllocationProbe.now();
		if (layoutPass > 0) {
			comparisonFrame.preserveRevisions = true;
			styleInvalidation = TreeDiff.compare(root,
				next,
				previousNodesById,
				currentNodesById,
				null,
				comparisonFrame);
		}
		var previousTopology = submittedTopology;
		submittedTopology = nextTopology;
		nextTopology = previousTopology;
		// Geometry callbacks run after the tracked build. If one updates a signal read by that tree, rebuild before
		// returning so the first submitted frame reflects the synchronized value.
		var callbackBuildFeedback = buildContext.consumeBuildFeedback();
		var requestedBuildFeedback = resolvedBuildFeedback || callbackBuildFeedback;
		if (requestedBuildFeedback || buildContext.rootDependenciesDirty()
			|| buildContext.hasPendingPatches || buildContext.hasPendingRenderScopes()) {
			if (buildFeedbackPass >= 7) throw "UI build feedback did not converge after 8 passes";
			// Commit layout for the next comparison, but keep focus requests and widget resources until children settle.
			root = next;
			if (verifyRetentionEvery > 0) recordFingerprints(next);
			if (RenderCost.enabled) RenderCost.submit(submitStartedAt,
				buildCostStartedAt,
				nativeLayoutStartedAt,
				nativeLayoutEndedAt,
				Sys.time(),
				nodeCount);
			return submitInternal(frame, cacheKey, build, reconcileNewFocus, buildFeedbackPass + 1);
		}
		syncWindowDecorations(next);
		diagnosticStage = 9;
		interactionStates.acknowledge();
		var routedInteractionRevision = interactionStates.revision;
		var previousFocus = focus.focusedId;
		focus.rebuild(next);
		var requestedFocus = pendingFocus, requestedLabel = pendingFocusLabel;
		pendingFocus = null;
		pendingFocusLabel = null;
		if (requestedFocus != null && !focus.focus(requestedFocus) && requestedLabel != null) {
			// A restored context keeps rows from an earlier build, so the id asked for may belong to a build that was discarded.
			var stand = focus.eligibleTreeItemByLabel(requestedLabel);
			if (stand != null) focus.focus(stand.id);
		}
		var nextFocus = focus.focusedId;
		var focusChanged = (previousFocus == null
			&& nextFocus != null) || (previousFocus != null && (nextFocus == null || !previousFocus.equals(nextFocus)));
		if (previousFocus != null
			&& (nextFocus == null || !previousFocus.equals(nextFocus))) events.focusEvent(previousFocus,
			UiEventKind.Blur);
		root = next;
		// Do not keep an old tree alive if a cached path's nodes were replaced while the pointer was absent.
		if (retainedHitPath != null) for (node in retainedHitPath) if (nodesById.get(node.id.value) != node) {
			retainedHitPath = null;
			break;
		}
		var picker = retainedHitTestProvider;
		if (picker == null) {
			picker = function(x:Float, y:Float) {
				session.hitTestInto(x, y, hitTestIds);
				var cached = retainedHitPath;
				if (cached != null && cached.length == hitTestIds.length) {
					var same = true;
					for (index in 0...hitTestIds.length) if (currentNodesById.get(hitTestIds[index]) != cached[index]) {
						same = false;
						break;
					}
					if (same) return cached;
				}
				var path:Array<RenderNode> = [];
				path.resize(hitTestIds.length);
				for (index in 0...hitTestIds.length) {
					var node = currentNodesById.get(hitTestIds[index]);
					if (node == null) {
						retainedHitPath = null;
						return [];
					}
					path[index] = node;
				}
				retainedHitPath = path;
				return path;
			};
			retainedHitTestProvider = picker;
		}
		events.setHitTestProvider(picker);
		events.setRoot(next, nodesById);
		gestures.setRoot(next);
		updateCursor();
		if (nextFocus != null
			&& (previousFocus == null || !previousFocus.equals(nextFocus))) events.focusEvent(nextFocus,
			UiEventKind.Focus);
		// Reconcile focus before releasing resources owned by unmounted widgets.
		// Blur is the old tree's final lifecycle event, so its handlers must still
		// be able to access widget state while that event is being dispatched.
		buildContext.retainRenderScopeState(nodesById);
		stateStore.endFrame();
		buildContext.pruneSelfUpdatingBuilds(nodesById);
		buildContext.pruneRenderScopes(nodesById);
		buildContext.pruneKeyCaches(nodesById, mountedHash);
		buildContext.stateStore.prunePaths(nodesById);
		submittedInteractionRevision = interactionStates.revision;
		submittedStyleRevision = buildContext.styleRevision;
		submittedAnimationRevision = animations.revision;
		submittedRetainedEditRevision = buildContext.retainedEditRevision;
		submittedPatchRequestRevision = buildContext.patchRequestRevision;
		submittedBindingRequestRevision = bindingAppliedRevision;
		submittedGestureRevision = gestures.revision;
		submittedNodeCount = nodeCount;
		submittedFrameWidth = frame.width;
		submittedFrameHeight = frame.height;
		submittedBuildKey = cacheKey;
		submittedTheme = buildContext.theme;
		submittedStyleSheet = buildContext.styleSheet;
		if (accessibilityBridge != null && (styleInvalidation.treeChanged
			|| styleInvalidation.semanticsInvalidatedNodes > 0 || resolvedGeometryChangedNodes > 0 || focusChanged)) {
			accessibilityBridge.coordinateScale = platformCoordinateScale;
			accessibilityBridge.update(next, focus.focusedId);
		}
		// Views composed before layout can observe the new focus on the next frame.
		if (focusChanged && !verifying && onAnimationFrameRequested != null) onAnimationFrameRequested();
		// Layout can move a different node under a stationary pointer, and a newly mounted focus trap chooses its target here.
		// Settle those routed states before painting, using the same bounded feedback as viewport-dependent builds.
		// This pass is now committed, including fresh nodes. A focus pass must compare against these instances, not
		// fingerprints of the previous frame's different nodes with the same IDs.
		if (verifyRetentionEvery > 0) recordFingerprints(next);
		if ((interactionStates.revision != routedInteractionRevision && routedInteractionNeedsBuild())
			|| (reconcileNewFocus
			&& focusChanged && (nextFocus != null || (previousFocus != null && nodesById.exists(previousFocus.value)))))
			{
			if (buildFeedbackPass >= 7) throw "UI interaction feedback did not converge after 8 passes";
			if (RenderCost.enabled) RenderCost.submit(submitStartedAt,
				buildCostStartedAt,
				nativeLayoutStartedAt,
				nativeLayoutEndedAt,
				Sys.time(),
				nodeCount);
			// Re-run the original factory: its conditional reads decide which views exist.
			// A constant view here would replace root subscriptions with only View.build's
			// reads, leaving later model changes unable to invalidate the cached tree.
			return submitInternal(frame, cacheKey, build, false, buildFeedbackPass + 1);
		}
		// Routing can add changes after the build. Keep them until the feedback pass has patched their owners.
		interactionStates.acknowledge();
		frameNumber++;
		var submitEndedAt = Sys.time();
		var submitEndAllocatedAt = AllocationProbe.now();
		pendingReusedMetrics = false;
		lastFrameMetrics = new UiFrameMetrics(frameNumber,
			nodeCount,
			buildContext.styleResolver.resolutions - styleResolutionsBefore,
			buildContext.styleResolver.cacheHits - styleCacheHitsBefore,
			buildContext.styleResolver.cacheMisses - styleCacheMissesBefore,
			buildContext.styleResolver.cachedStyleCount,
			styleInvalidation.styleChangedNodes,
			styleInvalidation.styleUnchangedNodes,
			styleInvalidation.invalidationFlags,
			styleInvalidation.layoutInvalidatedNodes,
			styleInvalidation.textLayoutInvalidatedNodes,
			styleInvalidation.paintInvalidatedNodes,
			styleInvalidation.compositeInvalidatedNodes,
			styleInvalidation.semanticsInvalidatedNodes,
			styleInvalidation.hitGeometryInvalidatedNodes,
			submitEndedAt - submitStartedAt,
			!nativeLayoutReused,
			nativeLayoutReused,
			resolvedGeometryChangedNodes,
			resolvedGeometryReusedNodes,
			buildFeedbackPass + 1);
		lastFrameMetrics.setSubmitPhases(viewBuiltAt - viewStartedAt,
			nativeLayoutStartedAt - viewBuiltAt,
			nativeLayoutEndedAt - nativeLayoutStartedAt,
			submitEndedAt - nativeLayoutEndedAt);
		lastFrameMetrics.setTreeAllocations(treeBuiltAllocatedAt - viewBuiltAllocatedAt,
			compareAllocatedAt - treeBuiltAllocatedAt,
			syncAllocatedAt - compareAllocatedAt,
			nativeLayoutStartAllocatedAt - syncAllocatedAt);
		lastFrameMetrics.setSubmitAllocations(viewBuiltAllocatedAt - viewAllocatedAt,
			nativeLayoutStartAllocatedAt - viewBuiltAllocatedAt,
			nativeLayoutEndAllocatedAt - nativeLayoutStartAllocatedAt,
			submitEndAllocatedAt - nativeLayoutEndAllocatedAt);
		if (RenderCost.enabled) RenderCost.submit(submitStartedAt,
			buildCostStartedAt,
			nativeLayoutStartedAt,
			nativeLayoutEndedAt,
			submitEndedAt,
			nodeCount);
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
		submittedPaintNodes.resize(0);
		submittedTopology.clear();
		nextTopology.clear();
		inspectionNode = null;
		submittedBuildKey = null;
		previousNodesById.clear();
		currentNodesById.clear();
		resolvedById.clear();
		events.releaseTree();
		retainedHitTestProvider = null;
		retainedHitPath = null;
		focus.releaseTree();
		gestures.setRoot(null);
		buildContext.releaseRetained();
		// The painters may be new code: paint every node again instead of reusing its list by key.
		customPaint.forgetKeys();
	}

	/** How far the last frame submission got before it stopped, for a crash report: 0 when it completed. */
	internal function getDiagnosticStage():Int return diagnosticStage;

	/** Connects this frame's semantic projection to a NativeKit platform surface. */
	public function updateAccessibility(surface:Surface):Void {
		ensureLive();
		if (surface == null || surface.isDisposed()) throw "Accessibility projection requires a live NativeKit surface";
		if (accessibilitySurface != surface) {
			if (accessibilityBridge != null) accessibilityBridge.dispose();
			accessibilitySurface = surface;
			accessibilityBridge = new AccessibilityBridge(surface);
		}
		accessibilityBridge.coordinateScale = platformCoordinateScale;
		accessibilityBridge.update(root, focus.focusedId);
	}

	/** Builds, lays out and draws the UI into `surface` for `frame`. */
	public function render(renderer:Renderer, surface:Surface, frame:FrameInfo):Void {
		prepareRender(renderer, surface, null, frame);
	}

	/** Seals the retained UI over earlier work in the same surface frame. */
	public function frameStep(renderer:Renderer, acquired:haxeon.platform.SurfaceFrame,
			frame:FrameInfo):haxeon.platform.SurfaceFrameStep {
		return prepareRender(renderer, null, acquired, frame);
	}

	function prepareRender(renderer:Renderer, surface:Null<Surface>, acquired:Null<haxeon.platform.SurfaceFrame>,
			frame:FrameInfo):Null<haxeon.platform.SurfaceFrameStep> {
		RenderCost.begin();
		var renderStartedAt = Sys.time();
		var renderStartAllocatedAt = AllocationProbe.now();
		diagnosticStage = 20;
		ensureLive();
		if (root == null) throw "Submit a view before rendering the UI context";
		diagnosticStage = 21;
		diagnosticStage = 22;
		customPaint.update(session, submittedPaintNodes, currentNodesById, onInspectionPaint, inspectionNode);
		var paintedNodes = customPaint.painted;
		var paintSkippedNodes = customPaint.skipped;
		var emptyPaintNodes = customPaint.empty;
		diagnosticStage = 24;
		var nativeRenderStartedAt = Sys.time();
		var nativeRenderStartAllocatedAt = AllocationProbe.now();
		var step = null;
		if (acquired == null)
			session.render(renderer, surface, frame);
		else
			step = session.frameStep(renderer, acquired, frame);
		var renderMetrics = frameMetrics;
		if (renderMetrics != null) {
			var renderEndedAt = Sys.time();
			renderMetrics.completeRender(renderEndedAt - renderStartedAt, paintedNodes, paintSkippedNodes,
				emptyPaintNodes);
			renderMetrics.setRenderPhases(nativeRenderStartedAt - renderStartedAt,
				renderEndedAt - nativeRenderStartedAt);
			var renderEndAllocatedAt = AllocationProbe.now();
			renderMetrics.setRenderAllocations(nativeRenderStartAllocatedAt - renderStartAllocatedAt,
				renderEndAllocatedAt - nativeRenderStartAllocatedAt);
		}
		if (RenderCost.enabled) RenderCost.render(renderStartedAt, nativeRenderStartedAt, Sys.time(),
			submittedNodeCount);
		diagnosticStage = 0;
		return step;
	}

	/**
	 * Advances active animations and repaints the retained tree without relayout.
	 * Hosts should use this for animation-only frames instead of submit().
	 */
	public function renderAnimationFrame(renderer:Renderer, surface:Surface, frame:FrameInfo, deltaSeconds:Float):Void {
		ensureLive();
		animations.advance(deltaSeconds);
		render(renderer, surface, frame);
	}

	/** Moves keyboard focus to the widget `id`, if it can take focus. Returns whether it did. */
	public function focusWidget(id:WidgetId):Bool {
		ensureLive();
		var previous = focus.focusedId;
		if (!focus.focus(id)) return false;
		dispatchFocusChange(previous, focus.focusedId);
		return true;
	}

	/** Moves focus to the next focusable widget, as Tab does, and returns it; null when there is none. */
	public function focusNext():Null<WidgetId> {
		ensureLive();
		var previous = focus.focusedId;
		var next = focus.focusNext();
		dispatchFocusChange(previous, next);
		return next;
	}

	/** Moves focus to the previous focusable widget, as Shift+Tab does, and returns it; null when there is none. */
	public function focusPrevious():Null<WidgetId> {
		ensureLive();
		var previous = focus.focusedId;
		var next = focus.focusPrevious();
		dispatchFocusChange(previous, next);
		return next;
	}

	/** Leaves no widget focused. */
	public function clearFocus():Void {
		ensureLive();
		focusBeforeWindowBlur = null;
		var previous = focus.focusedId;
		focus.focus(null);
		dispatchFocusChange(previous, null);
	}

	/** Returns the eligible keyboard target retained across window deactivation. */
	public function keyboardFocusTarget():Null<WidgetId> {
		var active = focus.focusedId;
		if (active != null) return active;
		var suspended = focus.eligibleNode(focusBeforeWindowBlur);
		return suspended == null ? null : suspended.id;
	}

	/** Routes a NativeKit platform accessibility action to the addressed semantic node. */
	public function accessibilityAction(id:Int,
			action:Int,
			value:Null<String>,
			selectionStart:Int,
			selectionEnd:Int,
			granularity:Int):Bool {
		ensureLive();
		if (root == null || id <= 0) return false;
		var widgetId = new WidgetId(id);
		var node = root.find(widgetId);
		if (node == null || node.semantics == null || node.resolved == null || !node.resolved.visible) return false;
		var semantics:Semantics = cast node.semantics;
		var request = AccessibilityRequest.create(action, value, selectionStart, selectionEnd, granularity);
		if (request == null) return false;
		var enabled = enabledAlongPath(node);
		var actions = semantics.actions;
		if (node.focusable && enabled) actions |= haxeon.ui.semantics.Semantics.AccessibilityAction.Focus;
		if (!enabled) actions = haxeon.ui.semantics.Semantics.AccessibilityAction.empty();
		if (!actions.contains(request.capability)) return false;
		var geometry:ResolvedLayoutItem = cast node.resolved;
		if (action == AccessibilityRequest.Focus) return focusWidget(widgetId);
		if (action == AccessibilityRequest.ClearFocus) {
			if (focus.focusedId != null && focus.focusedId.equals(widgetId)) clearFocus();
			return true;
		}
		var deltaX = 0.0;
		var deltaY = 0.0;
		if (action == AccessibilityRequest.ScrollForward) deltaY = geometry.height;
		else if (action == AccessibilityRequest.ScrollBackward) deltaY = -geometry.height;
		if (action == AccessibilityRequest.ScrollForward
			|| action == AccessibilityRequest.ScrollBackward) return events.targetEvent(UiEventKind.Scroll,
			widgetId,
			null,
			deltaX,
			deltaY,
			new AccessibilityActionData(action, selectionStart, selectionEnd, granularity));
		return events.targetEvent(request.kind,
			widgetId,
			request.value,
			0.0,
			0.0,
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
		if (previous != null) events.focusEvent(previous, UiEventKind.FocusLost);
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

	/**
	 * Reports the pointer at (`x`, `y`) in viewport coordinates; a host calls the pointer methods from platform input.
	 */
	public function pointerMove(x:Float,
			y:Float,
			modifiers:UiModifier = UiModifier.empty(),
			pointerId:Int = 0,
			data:Dynamic = null):Void {
		ensureLive();
		updateModifiers(modifiers);
		events.pointerMove(x, y, modifiers, pointerId, data);
		updateCursor();
	}

	/** Reports `button` pressed at (`x`, `y`). */
	public function pointerDown(x:Float,
			y:Float,
			button:Int,
			modifiers:UiModifier = UiModifier.empty(),
			pointerId:Int = 0,
			data:Dynamic = null,
			timestamp:Float = -1.0):Void {
		ensureLive();
		updateModifiers(modifiers);
		events.pointerDown(x, y, button, modifiers, pointerId, data, timestamp);
		updateCursor();
	}

	/** Reports `button` released at (`x`, `y`): a release over the widget pressed also clicks it. */
	public function pointerUp(x:Float,
			y:Float,
			button:Int,
			modifiers:UiModifier = UiModifier.empty(),
			pointerId:Int = 0,
			data:Dynamic = null):Void {
		ensureLive();
		updateModifiers(modifiers);
		events.pointerUp(x, y, button, modifiers, pointerId, data);
		updateCursor();
	}

	/** Reports that the pointer `pointerId`'s sequence ended without a release. */
	public function pointerCancel(pointerId:Int,
			x:Float,
			y:Float,
			modifiers:UiModifier = UiModifier.empty(),
			data:Dynamic = null):Void {
		ensureLive();
		events.pointerCancel(pointerId, x, y, modifiers, data);
		updateCursor();
	}

	/** Reports that the pointer `pointerId` left the window: nothing is hovered by it any more. */
	public function pointerLeave(pointerId:Int = 0):Void {
		ensureLive();
		events.clearPointer(pointerId);
		updateCursor();
	}

	/** Ends a captured drag if the platform reports its button released on re-entry. */
	public function pointerReenter(buttonPressed:Bool, x:Float, y:Float, pointerId:Int = 0):Void {
		ensureLive();
		if (!buttonPressed && events.hasCapturedPointer(pointerId)) pointerCancel(pointerId, x, y);
	}

	/** Installs the platform bridge that applies the context's effective cursor. */
	public function setCursorHandler(handler:Null<UiCursorShape->Void>):Void {
		ensureLive();
		cursorHandler = handler;
		if (handler != null) handler(currentCursor);
	}

	/** Installs the host bridge used for physical window/surface pointer capture. */
	public function setPointerCaptureHandler(handler:Null<Bool->Void>):Void {
		ensureLive();
		events.setPointerCaptureHandler(handler);
	}

	/** Reports a scroll of (`deltaX`, `deltaY`) with the pointer at (`x`, `y`). */
	public function scroll(x:Float, y:Float, deltaX:Float, deltaY:Float,
			modifiers:UiModifier = UiModifier.empty()):Void {
		ensureLive();
		updateModifiers(modifiers);
		events.scroll(x, y, deltaX, deltaY, modifiers);
	}

	/**
	 * Reports a key event (`UiEventKind.KeyDown`, `KeyUp` or `KeyRepeat`) for the focused widget. Returns whether the
	 * UI used it, so the host can pass on a key it did not.
	 */
	public function key(kind:String, key:Int, modifiers:UiModifier = UiModifier.empty(), scancode:Int = 0):Bool {
		ensureLive();
		updateModifiers(modifiers);
		// NativeKit preserves the keypad key code; UI controls share Enter behavior.
		if (key == 335) key = UiKey.Enter;
		return events.key(kind, key, modifiers, scancode);
	}

	/**
	 * Reports typed text (`UiEventKind.TextInput`) or an input method's composition (`TextEdit`) for the focused
	 * widget.
	 */
	public function text(kind:String, value:Null<String>, data:Dynamic = null):Void {
		ensureLive();
		events.text(kind, value, data);
	}

	/** True when nothing but pointer state moved since the submitted frame, so retained output may be updated instead of rebuilt. */
	function steadyForInteractionReuse(cacheKey:String, frame:LayoutFrame):Bool {
		return sameSubmittedInputs(cacheKey, frame) && !buildContext.rootDependenciesDirty()
			&& submittedStyleRevision == buildContext.styleRevision && animations.rebuildingCount == 0;
	}

	/** Whether the submitted frame was built for `cacheKey` at this size, with the same animations, gestures and styles. */
	function sameSubmittedInputs(cacheKey:String, frame:LayoutFrame):Bool {
		return root != null && submittedBuildKey == cacheKey && submittedFrameWidth == frame.width
			&& submittedFrameHeight == frame.height && animations.revision == submittedAnimationRevision
			&& gestures.revision == submittedGestureRevision && buildContext.theme == submittedTheme
			&& buildContext.styleSheet == submittedStyleSheet;
	}

	/** Validate every changed widget before mutating retained paint; unknown behavior rebuilds. */
	function reuseHoverPaint(cacheKey:String, frame:LayoutFrame):Int {
		if (!steadyForInteractionReuse(cacheKey,
			frame) || buildContext.hasRetainedEdits || buildContext.hasPendingPatches
			|| buildContext.hasPendingRenderScopes()
			|| buildContext.bindingRequestRevision != submittedBindingRequestRevision) return -1;
		var changes = interactionStates.changes();
		for (change in changes) {
			if (!change.hoverOnly()) return -1;
			var node = currentNodesById.get(change.id);
			if (node == null || (node.recordsInteraction && buildContext.hoverRebuilds(node))) return -1;
		}
		var painted = 0;
		for (change in changes) {
			var node:RenderNode = cast currentNodesById.get(change.id);
			if (node.hasPaintHandler()) {
				node.invalidatePaint();
				painted++;
			}
		}
		submittedInteractionRevision = interactionStates.revision;
		interactionStates.acknowledge();
		return painted;
	}

	/** Nodes whose only change is custom paint during a patch-only frame; filled by `planInteractionPatches`. */
	final patchFramePaintNodes:Array<RenderNode> = [];

	static final patchInteractionMask:haxeon.ui.style.StyleState = haxeon.ui.style.StyleState.Hovered
		| haxeon.ui.style.StyleState.Pressed;

	/**
	 * Decides whether the pending pointer changes can be met by rebuilding just the widgets that read them (self-updating
	 * widgets, such as buttons), leaving every other node of the submitted tree as it is. Queues those rebuilds and returns true,
	 * or returns false having changed nothing, in which case the whole view rebuilds.
	 */
	function planInteractionPatches(cacheKey:String, frame:LayoutFrame):Bool {
		if (inspectionEnabled || !buildContext.updateInPlace
			|| !steadyForInteractionReuse(cacheKey, frame)) return false;
		var changes = interactionStates.changes();
		for (change in changes) {
			var bits = change.before.rawValue() ^ change.after.rawValue();
			var node = currentNodesById.get(change.id);
			if (node == null) return false;
			// Routed input contains pointer and focus flags. Direct state-store edits must also
			// agree with authored state before a frame can take the interaction-only path.
			var other = bits & ~patchInteractionMask.rawValue();
			if (other != 0 && (change.after.rawValue() & other) != (node.states.rawValue() & other)) return false;
			bits &= patchInteractionMask.rawValue();
			if (bits == 0) continue;
			if (buildContext.interactionRenderScope(node) == null
				&& buildContext.updatingOwner(node) == null && node.recordsInteraction
				&& (bits != haxeon.ui.style.StyleState.Hovered.rawValue() || buildContext.hoverRebuilds(node)))
				return false;
		}
		patchFramePaintNodes.resize(0);
		for (change in changes) {
			var node:RenderNode = cast currentNodesById.get(change.id);
			var hoverOnly = change.hoverOnly();
			if (queueNativeInteraction(node, hoverOnly)) continue;
			var owner = buildContext.updatingOwner(node);
			if (owner != null && (!hoverOnly || buildContext.hoverRebuilds(node))) {
				if (owner == node || node.recordsInteraction) buildContext.queuePatch(owner.id);
			} else if (node.hasPaintHandler()) patchFramePaintNodes.push(node);
		}
		return true;
	}

	function routedInteractionNeedsBuild():Bool {
		var rebuild = false;
		for (change in interactionStates.changes()) {
			var node = currentNodesById.get(change.id);
			if (node == null) continue;
			var hoverOnly = change.hoverOnly();
			if (node.recordsInteraction && (!hoverOnly || buildContext.hoverRebuilds(node))) rebuild = true;
			else if (node.hasPaintHandler()) {
				// Layout is already submitted; only the custom list depends on this paint-only routed change.
				customPaint.invalidate(node.id.value);
			}
		}
		return rebuild;
	}

	/** On a full rebuild, retained caches no longer notice pointer changes of self-updating widgets, so they are rebuilt here. */
	static function findInteractionNode(root:RenderNode, id:Int):Null<RenderNode> {
		if (root.id.value == id) return root;
		for (child in root.children) {
			var found = findInteractionNode(child, id);
			if (found != null) return found;
		}
		return null;
	}

	function settleStructure(next:RenderNode):RenderNode {
		var passes = 0;
		while (true) {
			buildContext.flushRenderScopes(next, true);
			next = buildContext.currentRoot(next);
			buildContext.applyPatches(next, submittedTopology);
			buildContext.flushRenderScopes(next, true);
			next = buildContext.currentRoot(next);
			if (!queueIncomingRenderScopes(next)) {
				buildContext.flushRenderScopes(next);
				if (verifyRetentionEvery > 0 || buildContext.checkComponentRoots) buildContext.verifyComponentRoots();
				return next;
			}
			if (++passes >= 8) throw "Interaction scope updates did not settle";
		}
		return next;
	}

	/** A retained incoming body can already carry routed flags without having read them. */
	function queueIncomingRenderScopes(incomingRoot:RenderNode):Bool {
		var queued = false;
		for (change in interactionStates.changes()) {
			var node = findInteractionNode(incomingRoot, change.id);
			if (node == null) continue;
			var owner = buildContext.interactionRenderScope(node);
			if (owner == null || owner.builtEpoch == buildContext.retainedEditEpoch) continue;
			var hoverOnly = change.hoverOnly();
			queueNativeInteraction(node, hoverOnly);
			if (owner.pending) queued = true;
		}
		return queued;
	}

	function queueInteractionPatches():Void {
		patchFramePaintNodes.resize(0);
		for (change in interactionStates.changes()) {
			var node = currentNodesById.get(change.id);
			if (node == null) continue;
			var hoverOnly = change.hoverOnly();
			if (queueNativeInteraction(node, hoverOnly)) continue;
			var owner = buildContext.updatingOwner(node);
			if (owner != null && (!hoverOnly || buildContext.hoverRebuilds(node))) {
				if (owner == node || node.recordsInteraction) buildContext.queuePatch(owner.id);
				// Retained caches ignore hover no rule matches, so a cached node that paints it is repainted here.
			} else if (node.recordsInteraction && node.hasPaintHandler()) patchFramePaintNodes.push(node);
		}
	}

	function queueNativeInteraction(node:RenderNode, hoverOnly:Bool):Bool {
		var owner = buildContext.interactionRenderScope(node);
		if (owner == null) return false;
		if (node.recordsInteraction && (!hoverOnly || buildContext.hoverRebuilds(node))) owner.markDirty();
		else if (node.hasPaintHandler() && patchFramePaintNodes.indexOf(node) < 0) patchFramePaintNodes.push(node);
		return true;
	}

	function canReuseSubmittedFrame(cacheKey:String, frame:LayoutFrame):Bool {
		return sameSubmittedInputs(cacheKey, frame) && dirtyFlagsWithoutRootReads() == UiDirtyFlag.None
			&& !buildContext.rootDependenciesDirty() && !buildContext.hasPendingPatches;
	}

	static function sameGeometry(left:ResolvedLayoutItem, right:ResolvedLayoutItem):Bool {
		// Everything but the id, which names the node rather than where it is. The rectangles and the transform are compared by
		// the generated equality of their structural classes.
		return left == right || left.flags == right.flags && left.x == right.x && left.y == right.y && left.width
			== right.width && left.height == right.height && left.baseline == right.baseline
			&& haxeon.Equality.equals(left.clipBounds,
			right.clipBounds) && haxeon.Equality.equals(left.contentBounds,
			right.contentBounds) && haxeon.Equality.equals(left.transform,
			right.transform);
	}

	/** Whether input or state changed something the next frame must show. */
	public function isDirty():Bool return dirtyFlags != UiDirtyFlag.None;

	/** Asks the host for a frame when input dirtied the submitted UI. */
	public function requestFrameIfDirty():Void {
		var request = onAnimationFrameRequested;
		if (request != null && isDirty())
			request();
	}

	/** Whether a running animation needs another frame. */
	public var needsAnimationFrame(get, never):Bool;

	inline function get_needsAnimationFrame():Bool return animations.needsFrame;

	/** Seconds until animations that are only waiting next need a frame, or -1 for none. */
	public function animationWaitSeconds():Float return animations.waitSeconds();

	/** Reports pending work categories without changing the current full-submit behavior. */
	public var dirtyFlags(get, never):UiDirtyFlag;

	function get_dirtyFlags():UiDirtyFlag {
		var result = dirtyFlagsWithoutRootReads();
		// Retained dependencies are validated against their tracked source versions.
		if (buildContext.rootDependenciesDirty()) result |= UiDirtyFlag.NeedsBuild
			| UiDirtyFlag.NeedsStyle | UiDirtyFlag.NeedsTextLayout | UiDirtyFlag.NeedsLayout
			| UiDirtyFlag.NeedsPaint | UiDirtyFlag.NeedsComposite | UiDirtyFlag.NeedsSemantics
			| UiDirtyFlag.NeedsHitGeometry;
		return result;
	}

	/** Dirty categories other than dependency validation, which can run model getters. */
	function dirtyFlagsWithoutRootReads():UiDirtyFlag {
		var result = UiDirtyFlag.empty();
		if (buildContext.hasPendingRenderScopes()) result |= UiDirtyFlag.NeedsBuild
			| UiDirtyFlag.NeedsLayout | UiDirtyFlag.NeedsPaint | UiDirtyFlag.NeedsSemantics
			| UiDirtyFlag.NeedsHitGeometry;
		if (interactionStates.revision != submittedInteractionRevision) result |= UiDirtyFlag.NeedsStyle
			| UiDirtyFlag.NeedsTextLayout | UiDirtyFlag.NeedsLayout
			| UiDirtyFlag.NeedsPaint | UiDirtyFlag.NeedsComposite | UiDirtyFlag.NeedsSemantics
			| UiDirtyFlag.NeedsHitGeometry;
		if (buildContext.styleRevision != submittedStyleRevision) result |= UiDirtyFlag.NeedsStyle
			| UiDirtyFlag.NeedsTextLayout | UiDirtyFlag.NeedsLayout
			| UiDirtyFlag.NeedsPaint | UiDirtyFlag.NeedsComposite | UiDirtyFlag.NeedsSemantics
			| UiDirtyFlag.NeedsHitGeometry;
		if (animations.rebuildingCount > 0) result |= UiDirtyFlag.NeedsComposite;
		if (buildContext.patchRequestRevision != submittedPatchRequestRevision) result |= UiDirtyFlag.NeedsBuild
			| UiDirtyFlag.NeedsStyle | UiDirtyFlag.NeedsTextLayout | UiDirtyFlag.NeedsLayout
			| UiDirtyFlag.NeedsPaint | UiDirtyFlag.NeedsComposite | UiDirtyFlag.NeedsSemantics
			| UiDirtyFlag.NeedsHitGeometry;
		if (buildContext.retainedEditRevision != submittedRetainedEditRevision) result |= UiDirtyFlag.NeedsStyle
			| UiDirtyFlag.NeedsLayout | UiDirtyFlag.NeedsPaint | UiDirtyFlag.NeedsComposite
			| UiDirtyFlag.NeedsHitGeometry;
		if (buildContext.bindingRequestRevision != submittedBindingRequestRevision) result |=
			UiDirtyFlag.NeedsTextLayout
			| UiDirtyFlag.NeedsLayout | UiDirtyFlag.NeedsPaint | UiDirtyFlag.NeedsSemantics;
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
		style.positioning = haxeon.ui.LayoutStyle.LayoutPositioning.Absolute;
		style.width = haxeon.ui.LayoutAxis.fixed(frame.width);
		style.height = haxeon.ui.LayoutAxis.fixed(frame.height);
		style.zIndex = 32767;
		style.clipToParent = false;
		var id = buildContext.withScope(new haxeon.ui.core.Key("__devtools_inspection"),
			function() return buildContext.id("overlay"));
		var node = new RenderNode(id, haxeon.ui.LayoutNode.LayoutVisualKind.Custom, style);
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

	function get_frameMetrics():Null<UiFrameMetrics> {
		if (pendingReusedMetrics) {
			lastFrameMetrics = new UiFrameMetrics(frameNumber,
				submittedNodeCount,
				0,
				0,
				0,
				reusedMetricsCachedStyles,
				0,
				submittedNodeCount,
				UiDirtyFlag.None,
				0,
				0,
				0,
				0,
				0,
				0,
				reusedMetricsSeconds,
				false,
				true,
				0,
				submittedNodeCount);
			lastFrameMetrics.markReusedSubmission();
			if (reusedMetricsHoverNodes >= 0) lastFrameMetrics.hoverPaintUpdatedNodes = reusedMetricsHoverNodes;
			pendingReusedMetrics = false;
		}
		return lastFrameMetrics;
	}

	/** Returns cumulative native geometric hit-test diagnostics. */
	public var hitTestMetrics(get, never):LayoutHitTestStats;

	function get_hitTestMetrics():LayoutHitTestStats return session.hitTestStats();

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
		if (disposed) return;
		pendingFocus = null;
		focusBeforeWindowBlur = null;
		customPaint.dispose(session);
		events.setHitTestProvider(null);
		retainedHitTestProvider = null;
		retainedHitPath = null;
		session.dispose();
		clipboard.dispose();
		textInput.dispose();
		gestures.cancelAll();
		if (cursorHandler != null) cursorHandler(UiCursorShape.Arrow);
		cursorHandler = null;
		events.setPointerCaptureHandler(null);
		currentCursor = UiCursorShape.Arrow;
		animations.cancelAll();
		if (accessibilityBridge != null) accessibilityBridge.dispose();
		if (decorationWindow != null) clearWindowDecorations();
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
		if (next == currentCursor) return;
		currentCursor = next;
		if (cursorHandler != null) cursorHandler(next);
	}

	function syncWindowDecorations(tree:RenderNode):Void {
		if (decorationWindow == null || !supportsWindowDecorations()) return;
		var regions:Array<NativeWindowDecorationRegion> = [];
		tree.walk(function(node) {
			if (node.windowDecoration == null || node.resolved == null || !node.resolved.visible) return;
			var bounds = node.resolved.clippedViewportBounds();
			var left = Math.max(0.0, bounds.x);
			var top = Math.max(0.0, bounds.y);
			var right = Math.min(buildContext.viewportWidth, bounds.x + bounds.width);
			var bottom = Math.min(buildContext.viewportHeight, bounds.y + bounds.height);
			if (right <= left || bottom <= top) return;
			var region = new NativeWindowDecorationRegion();
			region.set_x(left * platformCoordinateScale);
			region.set_y(top * platformCoordinateScale);
			region.set_width((right - left) * platformCoordinateScale);
			region.set_height((bottom - top) * platformCoordinateScale);
			var kind:WindowDecorationRegionKind = cast node.windowDecoration;
			region.set_kind(kind);
			region.set_cursor_shape(node.windowDecorationCursor == null
				? NativeCursorShape.Arrow : node.windowDecorationCursor);
			regions.push(region);
		});
		var window:WindowHandle = cast decorationWindow;
		NativeKit.nk_window_set_decoration_regions_checked(window, regions);
	}

	function clearWindowDecorations():Void {
		if (decorationWindow == null || !supportsWindowDecorations()) return;
		try {
			var window:WindowHandle = cast decorationWindow;
			NativeKit.nk_window_set_decoration_regions_checked(window, []);
		} catch (_:Dynamic) {
			// Context disposal must remain best-effort if the host already destroyed the window.
		}
	}

	function supportsWindowDecorations():Bool {
		if (decorationCapabilityChecked) return decorationAvailable;
		decorationCapabilityChecked = true;
		var capabilities = NativeKit.nk_get_capabilities();
		decorationAvailable = haxe.Int64.compare(haxe.Int64.and(capabilities, Capabilities.windowCustomDecorations()),
			haxe.Int64.ofInt(0)) != 0;
		return decorationAvailable;
	}

	function dispatchFocusChange(previous:Null<WidgetId>, next:Null<WidgetId>):Void {
		if (previous == null ? next == null : previous.equals(next)) return;
		if (previous != null) events.focusEvent(previous, UiEventKind.Blur);
		if (next != null) events.focusEvent(next, UiEventKind.Focus);
		if (onAnimationFrameRequested != null) onAnimationFrameRequested();
	}

	function ensureLive():Void {
		if (disposed) throw "UI context has been disposed";
	}

	static function enabledAlongPath(node:RenderNode):Bool {
		var current:Null<RenderNode> = node;
		while (current != null) {
			var present:RenderNode = cast current;
			if (!present.enabled) return false;
			current = present.parent;
		}
		return true;
	}
}
