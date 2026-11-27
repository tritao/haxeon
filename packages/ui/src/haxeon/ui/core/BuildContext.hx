package haxeon.ui.core;

import haxeon.platform.Surface;
import haxeon.reactive.Derived;
import haxeon.reactive.ReactiveRuntime;
import haxeon.ui.FontCollection;
import haxeon.ui.LayoutStyle;
import haxeon.ui.animation.AnimationScheduler;
import haxeon.ui.gestures.GestureArena;
import haxeon.ui.style.ComputedStyle;
import haxeon.ui.style.StyleEnvironment;
import haxeon.ui.style.StyleResolver;
import haxeon.ui.style.StyleSheet;
import haxeon.ui.style.StyleState;
import haxeon.ui.style.StyleTarget;
import haxeon.ui.theme.TextRole;
import haxeon.ui.theme.Theme;

import haxeon.ui.core.Command;
import haxeon.ui.core.Key;
import haxeon.ui.core.LiveTextBinding;
import haxeon.ui.core.RenderScope;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.WidgetId;
/** Frame-local identity scopes backed by a persistent UiContext state store. */
class BuildContext implements Disposable {
	/** The state widgets keep between builds; `state` reads it for the widget being built. */
	public final stateStore:StateStore;

	/** The fonts text is shaped with, or null before the host gives them. */
	public var fonts(default, null):Null<FontCollection>;
	internal var platformSurface(default, null):Null<Surface>;

	/** The platform's text input: the on-screen keyboard and input method composition, for text fields. */
	public final textInput:TextInputBridge;

	/** The clipboard text fields copy to and paste from. */
	public final clipboard:ClipboardService;

	/** Where a widget's gesture recognizers compete for a pointer sequence. */
	public final gestures:GestureArena;

	/** Runs the animations widgets start, and asks for frames while they run. */
	public final animations:AnimationScheduler;

	/** Each widget's hovered, pressed and focused states, which its style selects on. */
	public final interactionStates:InteractionStateStore;

	/** Application commands available to command-bound widgets. */
	public final commands:CommandRegistry;

	/** Invocation context shared by command-bound widgets in this frame. */
	final commandContextState:CommandContextState = new CommandContextState();

	final commandFlagEntries:Array<{registry:CommandRegistry, id:String, value:Derived<Int>}> = [];

	/** What commands act on now: the current document and selection. */
	public var commandContext(get, never):CommandContext;

	function get_commandContext():CommandContext return commandContextState.value;

	/**
	 * Resolves a widget's computed style from the theme, the style sheet and its own style; a widget calls it while it
	 * builds.
	 */
	internal final styleResolver:StyleResolver;

	/** What styles can depend on: the viewport's size, the pointer in use, reduced motion and the like. */
	public final environment:StyleEnvironment;

	/** Optional diagnostic sink for named view builds: name, preparation, build, nodes. */
	public var buildProbe:Null<String->Float->Float->Int->Void> = null;

	/** The theme widgets draw with: its colors, type scale and generated style rules. */
	public var theme(default, null):Theme;

	/** The application's style rules, applied over the theme's. */
	public var styleSheet(default, null):StyleSheet;

	/** Logical viewport dimensions for frame-local placement decisions. */
	public var viewportWidth(default, null):Float;

	/** The height of the viewport the UI is built for, in logical pixels. */
	public var viewportHeight(default, null):Float;

	/** A resolved widget can request another native layout pass in this submit. */
	public var layoutFeedbackRequested(default, null):Bool = false;

	var styleParent:Null<ComputedStyle>;

	/** Bumped when the theme or application sheet is replaced, so swaps never reuse a fingerprint. */
	var styleEpoch:Int = 0;

	var focusRequester:WidgetId->Bool;
	var deferredFocusRequester:WidgetId->Void;
	final claimed:IdSet;
	final idsByPath:WidgetIdCache;

	static inline var SCOPE_GROWTH_PRUNE = 256;

	// What pruneKeyCaches last saw, so it can tell when nothing could have gone stale.
	var prunedMountedHash:Int;
	var prunedIdCount:Int;
	var prunedScopeEntries:Int;

	/** How many times pruneKeyCaches walked the caches, rather than finding nothing changed. */
	public var keyCachePrunes(default, null):Int;

	var rootScope:KeyScope;
	var scope:KeyScope;
	var textStyleStack:Array<ResolvedTextStyle>;

	/**
	 * When false, every submit rebuilds the whole view instead of running only what changed. Tests turn it off to build a
	 * reference tree to compare the updated one against.
	 */
	public var updateInPlace:Bool = true;

	/** While set, retained caches build their subtree afresh instead of reusing it; UiContext.verifyRetention sets it. */
	public var bypassRetention:Bool = false;

	final patchPriors:Map<Int, RenderNode> = new Map();

	/** Borrowed for this submission; cached instances with equal IDs are not previous-frame nodes. */
	var submittedInstances:Null<Map<Int, RenderNode>>;

	final renderScopes:Array<RenderScope> = [];
	var textBindings:Null<Array<LiveTextBinding>>;
	var buildingRenderScope:Bool = false;
	var activeRenderScope:Null<RenderScope>;
	var pendingScopeRootId:Null<WidgetId>;
	var activeBuildRootId:Null<WidgetId>;
	var buildingRoot:Null<RenderNode>;

	/** The build context of a UI; `UiContext` makes it, so an application rarely does. */
	public function new(stateStore:StateStore,
			?fonts:FontCollection,
			?textInput:TextInputBridge,
			?clipboard:ClipboardService,
			?theme:Theme,
			?gestures:GestureArena,
			?animations:AnimationScheduler,
			?styleSheet:StyleSheet,
			?interactionStates:InteractionStateStore,
			?commands:CommandRegistry) {
		if (stateStore == null) throw "Build context requires a state store";
		this.stateStore = stateStore;
		activeObserved = observed;
		this.fonts = fonts;
		platformSurface = null;
		this.textInput = textInput == null ? new TextInputBridge() : textInput;
		this.clipboard = clipboard == null ? new ClipboardService() : clipboard;
		this.gestures = gestures == null ? new GestureArena() : gestures;
		this.animations = animations == null ? new AnimationScheduler() : animations;
		this.interactionStates = interactionStates == null ? new InteractionStateStore() : interactionStates;
		this.commands = commands == null ? new CommandRegistry() : commands;
		commandContextState.value = new CommandContext();
		this.styleResolver = new StyleResolver(this.animations);
		this.environment = new StyleEnvironment();
		this.theme = theme == null ? new Theme() : theme;
		this.theme.refreshStyles();
		this.styleSheet = styleSheet == null ? new StyleSheet("Application") : styleSheet;
		styleParent = null;
		viewportWidth = 0.0;
		viewportHeight = 0.0;
		focusRequester = function(_) {
			return false;
		};
		deferredFocusRequester = function(_) {};
		claimed = new IdSet();
		idsByPath = new WidgetIdCache();
		prunedMountedHash = 0;
		prunedIdCount = -1;
		prunedScopeEntries = -1;
		keyCachePrunes = 0;
		rootScope = new KeyScope();
		scope = rootScope;
		textStyleStack = [ResolvedTextStyle.fromTheme(this.theme)];
	}

	/** Updates the context passed to command-bound widgets. */
	public function setCommandContext(context:Null<CommandContext>):Void commandContextState.value = context == null
		? new CommandContext() : context;

	/** Command presentation changes only when its enabled or checked result changes. */
	public function commandFlags(registry:CommandRegistry, id:String):Int {
		for (entry in commandFlagEntries) if (entry.registry == registry && entry.id == id) return entry.value.value;
		var value = new Derived(function() {
			var command = registry.get(id);
			if (command == null) return -1;
			var invocation = commandContextState.value;
			return (command.isEnabled(invocation) ? 1 : 0) | (command.isChecked(invocation) ? 2 : 0);
		});
		commandFlagEntries.push({registry: registry, id: id, value: value});
		return value.value;
	}

	function clearCommandFlags():Void {
		for (entry in commandFlagEntries) entry.value.dispose();
		commandFlagEntries.resize(0);
	}

	/** Replaces the palette used by subsequently built widgets. */
	public function setTheme(theme:Theme):Void {
		if (theme == null) throw "Build context requires a theme";
		this.theme = theme;
		styleEpoch++;
		this.theme.refreshStyles();
		if (textStyleStack.length <= 1) textStyleStack = [ResolvedTextStyle.fromTheme(theme)];
	}

	/** Replaces the application stylesheet layered above the active theme. */
	public function setStyleSheet(styleSheet:StyleSheet):Void {
		if (styleSheet == null) throw "Build context requires a stylesheet";
		this.styleSheet = styleSheet;
		styleEpoch++;
	}

	/** Updates viewport-derived environment values for conditional style rules. */
	public function setEnvironmentViewport(width:Float, height:Float):Void environment.setViewport(width, height);

	/** Computed inherited style supplied by the nearest composing parent. */
	public var inheritedStyle(get, never):Null<ComputedStyle>;

	function get_inheritedStyle():Null<ComputedStyle> return styleParent;

	/** Builds descendants with the given computed style as their inheritance source. */
	public function withStyleParent<T>(parent:ComputedStyle, build:Void->T):T {
		if (parent == null || build == null) throw "A style parent and build callback are required";
		var previous = styleParent;
		styleParent = parent;
		defer styleParent = previous;
		return build();
	}

	/** Resolves one node against the active inherited style and current layers. */
	public function resolveStyle(target:StyleTarget,
			local:Null<LayoutStyle>, ?localTextColor:haxeon.ui.Color):ComputedStyle return styleResolver.resolve(target,
		styleParent,
		theme.styles,
		styleSheet,
		local,
		environment,
		localTextColor);

	/**
	 * The widget `id`'s states, to style it with this identity. A build that calls this depends only on the states some rule
	 * for the identity selects on, since no other change can restyle it; the rest are returned to be recorded on the node.
	 */
	public function styleStates(id:WidgetId, type:String, ?key:String, ?styleId:String, ?classes:Array<String>,
			?tags:Array<String>):StyleState {
		return interactionStates.read(id, stateRules.states(theme.styles, styleSheet, styleRevision, type, key, styleId,
			StyleTarget.shared(classes), StyleTarget.shared(tags)));
	}

	/** A style target for the widget `id` with this identity and its styleStates. */
	public function styleTarget(id:WidgetId, type:String, ?key:String, ?styleId:String, ?classes:Array<String>,
			?tags:Array<String>):StyleTarget {
		return new StyleTarget(type, key, styleId, classes, tags, styleStates(id, type, key, styleId, classes, tags));
	}

	final stateRules = new StateRuleIndex();

	/** Revision fingerprint used to classify style work before the next submission. */
	public var styleRevision(get, never):Int;

	function get_styleRevision():Int {
		// Swapping the theme or application sheet bumps the epoch, so the fingerprint changes even when
		// the replacement has taken the same number of edits (light to dark) as the sheet it replaced.
		var result = styleEpoch * 1000003 + theme.styles.revision;
		result = result * 1000003 + styleSheet.revision * 1009 + environment.revision;
		return result;
	}

	/** Installs the UiContext focus route used by composite keyboard widgets. */
	public function setFocusRequester(requester:WidgetId->Bool):Void {
		if (requester == null) throw "Build context requires a focus request route";
		focusRequester = requester;
	}

	/** Asks for keyboard focus to move to the widget `id`. Returns whether it did. */
	public function requestFocus(id:WidgetId):Bool return id != null && focusRequester(id);

	/** Installs the focus route for targets revealed by the next layout. */
	public function setDeferredFocusRequester(requester:WidgetId->Void):Void {
		if (requester == null) throw "Build context requires a deferred focus route";
		deferredFocusRequester = requester;
	}

	/** Focus a newly built or scrolled-into-view widget after geometry is resolved. */
	public function requestFocusAfterLayout(id:WidgetId, ?label:String):Void {
		deferredFocusLabel = label;
		if (id != null) deferredFocusRequester(id);
	}

	/** The accessibility label given with the latest deferred focus request: a stand-in when the widget's id does not survive. */
	public var deferredFocusLabel(default, null):Null<String>;

	/** Provides the font collection used by text-layout-backed widgets. */
	public function setFonts(fonts:FontCollection):Void {
		if (fonts == null || fonts.isDisposed()) throw "Build context requires a live font collection";
		this.fonts = fonts;
	}

	/** Provides the NativeKit surface used for IME and other platform services. */
	public function setPlatformSurface(surface:Surface):Void {
		if (surface == null || surface.isDisposed()) throw "Build context requires a live NativeKit surface";
		platformSurface = surface;
		textInput.attach(surface);
	}

	internal function clearPlatformSurface(surface:Surface):Void {
		if (platformSurface == surface) {
			textInput.detach();
			platformSurface = null;
		}
	}

	/** Installs the logical viewport used while building the current frame. */
	public function setViewport(width:Float, height:Float):Void {
		if (width <= 0.0 || height <= 0.0
			|| !finite(width) || !finite(height)) throw "Build viewport dimensions must be positive and finite";
		viewportWidth = width;
		viewportHeight = height;
	}

	internal function beginFrame():Void {
		layoutFeedbackRequested = false;
		buildBeforeLayoutFeedbackRequested = false;
		localObserved.clear();
		claimed.clear();
		if (rootScope.cachedEntries() >= 8192) rootScope = new KeyScope();
		scope = rootScope;
		stateStore.beginFrame();
		textStyleStack = [ResolvedTextStyle.fromTheme(theme)];
	}

	var buildFeedbackRequested = false;
	var buildBeforeLayoutFeedbackRequested = false;

	/**
	 * Which build of the current submit this is: 0 for the frame's first build, then one more for every feedback
	 * rebuild. Views that request feedback from geometry use it to settle within a bounded number of passes.
	 */
	public var buildFeedbackPass(default, null):Int = 0;

	/** Resolved constraints changed which children a view must build; settle them before publishing the frame. */
	public function requestBuildFeedback():Void buildFeedbackRequested = true;

	/** Requests a rebuild before another layout pass can consume geometry from a view the callback just changed. */
	public function requestBuildFeedbackBeforeLayout():Void {
		buildFeedbackRequested = true;
		buildBeforeLayoutFeedbackRequested = true;
	}

	internal function consumeBuildFeedbackBeforeLayout():Bool {
		var requested = buildBeforeLayoutFeedbackRequested;
		buildBeforeLayoutFeedbackRequested = false;
		return requested;
	}

	internal function consumeBuildFeedback():Bool {
		var requested = buildFeedbackRequested;
		buildFeedbackRequested = false;
		return requested;
	}

	/** Asks for the frame to be built again after layout, for a widget whose content depends on its laid-out size. */
	public function requestLayoutFeedback():Void layoutFeedbackRequested = true;

	internal function consumeLayoutFeedback():Bool {
		var requested = layoutFeedbackRequested;
		layoutFeedbackRequested = false;
		return requested;
	}

	/** Bounded-run diagnostics for retained key path caches. */
	public function diagnosticKeyCounts():{ids:Int, paths:Int} return {
		ids: idsByPath.count,
		paths: rootScope.cachedEntries()
	};

	/** Reports a measured subtree only when a diagnostic sink is installed. */
	public function reportBuild(name:String, preparationSeconds:Float, buildSeconds:Float, root:ViewRoot):Void {
		var probe = buildProbe;
		if (probe == null) return;
		var nodes = 0;
		root.node().walk(function(_) nodes++);
		probe(name, preparationSeconds, buildSeconds, nodes);
	}

	/** Returns the concrete typography currently inherited by the build. */
	public function currentTextStyle():ResolvedTextStyle return textStyleStack[textStyleStack.length - 1];

	/** Resolves a local sparse override against the current inherited style. */
	public function resolveTextStyle(?override:TextStyleOverride):ResolvedTextStyle return currentTextStyle()
		.merge(override);

	/** Resolves a semantic theme role, then applies an optional local override. */
	public function resolveTextRole(role:TextRole, ?override:TextStyleOverride):ResolvedTextStyle {
		var resolved = role == null
			|| role == TextRole.Body ? currentTextStyle() : currentTextStyle().merge(theme.textRole(role).toOverride());
		return resolved.merge(override);
	}

	/** Builds a subtree under a nested typography scope and restores the parent scope. */
	public function withTextStyle<T>(override:TextStyleOverride, build:Void->T):T {
		if (override == null || build == null) throw "A text style scope requires a style and callback";
		textStyleStack.push(resolveTextStyle(override));
		defer textStyleStack.pop();
		return build();
	}

	/** Reserve the body's identity before any child builds or interaction/style reads. */
	public function rootId(localKey:String):WidgetId {
		var reserved = pendingScopeRootId;
		if (reserved == null) return id(localKey);
		pendingScopeRootId = null;
		claimId(reserved, localKey);
		return reserved;
	}

	/** Scope ownership is stored only on actual body roots, without an additional render/layout node. */
	public function createNode(id:WidgetId,
			kind:haxeon.ui.LayoutNode.LayoutVisualKind = haxeon.ui.LayoutNode.LayoutVisualKind.Box,
			?style:LayoutStyle):RenderNode {
		var owner = rootOwner(id);
		var node = owner != null ? new ScopeRootNode(id, kind, style, owner) : new RenderNode(id, kind, style);
		if (owner != null) buildingRoot = node;
		return node;
	}

	/** Live text roots keep the same ownership protocol without adding a field to ordinary text leaves. */
	internal function createLiveTextNode(id:WidgetId, style:LayoutStyle, value:String):LiveTextNode {
		var owner = rootOwner(id);
		var node:LiveTextNode = owner == null ? new LiveTextNode(id, style, value) : new ScopeTextRootNode(id,
			style,
			value,
			owner);
		if (owner != null) buildingRoot = node;
		return node;
	}

	function rootOwner(id:WidgetId):Null<RenderScope> return activeRenderScope != null
		&& activeBuildRootId != null && activeBuildRootId.equals(id) ? activeRenderScope : null;

	@:allow(haxeon.ui.core.RenderScope) function isBuildingRoot(node:RenderNode):Bool return buildingRoot == node;

	/**
	 * The id of the widget `localKey` names within the current scope, claimed for this build: two widgets of one scope
	 * cannot share a key.
	 */
	public function id(localKey:String):WidgetId {
		var result = resolveId(localKey);
		claimId(result, localKey);
		return result;
	}

	function claimId(id:WidgetId, localKey:String):Void {
		if (!buildingRenderScope && !claimed.add(id.value))
			throw 'Duplicate widget ID ${id.value}; existing=${stateStore.describe(id)} current=${scope.widgetPath(localKey)}';
	}

	/** Logical owner/resource identities need not introduce a render node or claim a retained body's root twice. */
	function resolveId(localKey:String):WidgetId {
		var path = scope.widgetPath(localKey);
		var id = idsByPath.get(path);
		if (id == null) {
			if (idsByPath.count >= 8192) {
				idsByPath.clear();
			}
			id = stateStore.resolveWidgetId(path);
			idsByPath.set(path, id);
		}
		stateStore.rememberPath(id, path);
		return id;
	}

	/** Pending run-once binding work asks the host for a frame without rebuilding its owner. */
	public var bindingRequestRevision(default, null):Int = 0;

	internal var onBindingFrameRequested:Null<Void->Void>;

	var bindingFrameRequested:Bool = false;

	/** Asks the host for a frame because bound state changed outside any build, as a `BoundText` does. */
	public function requestBindingFrame():Void {
		if (bindingFrameRequested) return;
		bindingFrameRequested = true;
		bindingRequestRevision++;
		if (onBindingFrameRequested != null) onBindingFrameRequested();
	}

	internal function consumeBindingFrameRequest():Int {
		bindingFrameRequested = false;
		return bindingRequestRevision;
	}

	/** The native owner is carried by the actual component body root. */
	internal function renderScopeAt(node:RenderNode):Null<RenderScope> {
		var owner = node.scopeOwner();
		return owner != null && owner.root == node && !owner.disposed ? owner : null;
	}

	/**
	 * Called with the root of each component body that ran again on its own, once it is in the tree. It builds outside the
	 * view, so a view wrapper that moves nodes after building (TooltipOverlayHost lifts tooltips) uses this to do the same for
	 * what it made.
	 */
	public var onPatched:Null<RenderNode->Void> = null;

	@:allow(haxeon.ui.core.RenderScope) function renderScopeRebuilt(root:RenderNode):Void {
		var patched = onPatched;
		if (patched != null) patched(root);
	}

	@:allow(haxeon.ui.core.RenderScope) @:allow(haxeon.ui.core.LiveTextBinding) function attachedToRoot(node:RenderNode,
			submittedRoot:Null<RenderNode>):Bool {
		if (node == null || submittedRoot == null) return false;
		while (node.parent != null) node = node.parent;
		return node == currentRoot(submittedRoot);
	}

	@:allow(haxeon.ui.core.LiveTextBinding) function registerTextBinding(binding:LiveTextBinding):Void {
		if (textBindings == null) textBindings = [];
		textBindings.push(binding);
	}

	@:allow(haxeon.ui.core.LiveTextBinding) function unregisterTextBinding(binding:LiveTextBinding):Void {
		if (textBindings != null) textBindings.remove(binding);
	}

	/** Hidden retained bindings keep dirty dependencies until their nodes are mounted again. */
	public function flushTextBindings(root:RenderNode):Void {
		var bindings = textBindings;
		if (bindings == null) return;
		var index = 0, failed = false;
		var firstError:Dynamic = null;
		while (index < bindings.length) {
			var binding = bindings[index];
			try binding.flush(root) catch (error:Dynamic) {
				if (!failed) firstError = error;
				failed = true;
			}
			if (index < bindings.length && bindings[index] == binding) index++;
		}
		if (failed) throw firstError;
	}

	@:allow(haxeon.ui.core.UiContext) function retryTextBindings():Void {
		if (textBindings != null) for (binding in textBindings) binding.retryAfterFailedFrame();
	}

	/** Keeps the nodes of `node`'s subtree as priors for the frame comparison, except `root` itself when `skipRoot`. */
	inline function wasSubmitted(node:RenderNode):Bool return submittedInstances != null
		&& submittedInstances.get(node.id.value) == node;

	function recordPriors(node:RenderNode, root:RenderNode, skipRoot:Bool):Void {
		if ((node != root || !skipRoot) && wasSubmitted(node)
			&& !patchPriors.exists(node.id.value)) patchPriors.set(node.id.value,
			node);
		for (child in node.children) recordPriors(child, root, skipRoot);
	}

	/** Nodes of the submitted tree changed directly since it was submitted, with how each looked before; see willEditRetained. */
	final retainedEdits:Array<RenderNode> = [];

	var retainedEditEpoch:Int = 0;
	final retainedEditCaches:Map<Int, RetainedEditCache> = new Map();
	final retainedEditCacheIds:Array<Int> = [];

	/** Start the lifetime of geometry feedback priors after event edits for this submission have been captured. */
	public function beginLayoutSubmission(previousInstances:Map<Int, RenderNode>):Void {
		if (previousInstances == null) throw "A layout submission requires its previous physical instances";
		submittedInstances = previousInstances;
		retainedEditEpoch++;
	}

	final retainedEditPriors:Array<RenderNode> = [];

	/** Bumped by each first edit of a node between frames; a different value from the submitted one means a frame is due. */
	public var retainedEditRevision(default, null):Int = 0;

	/**
	 * Call just before changing a node of the submitted tree in place, outside a build: its style, hit testing or paint. The next
	 * frame compares the node against how it was now and lays out and paints the change, without rebuilding the view. Repeated
	 * calls for the same node before that frame keep the first state.
	 */
	public function willEditRetained(node:RenderNode):Void {
		if (retainedEdits.indexOf(node) >= 0) return;
		retainedEdits.push(node);
		retainedEditPriors.push(captureEditPrior(node, retainedEditEpoch));
		retainedEditRevision++;
	}

	/** Input normalization runs after fingerprint checks, but its prior still belongs to the pre-feedback phase. */
	public function comparisonPrior(node:RenderNode):RenderNode return captureEditPrior(node, retainedEditEpoch - 1);

	function captureEditPrior(node:RenderNode, epoch:Int):RenderNode {
		var cache = retainedEditCaches.get(node.id.value);
		if (cache == null) {
			cache = new RetainedEditCache();
			retainedEditCaches.set(node.id.value, cache);
			retainedEditCacheIds.push(node.id.value);
		}
		return cache.capture(node, epoch);
	}

	/** Whether `node` was announced with willEditRetained since the last frame. */
	public function editAnnounced(node:RenderNode):Bool return retainedEdits.indexOf(node) >= 0;

	internal var hasRetainedEdits(get, never):Bool;

	inline function get_hasRetainedEdits():Bool return retainedEdits.length > 0;

	/** Hands the frame comparison the prior state of edited nodes still in the submitted tree, and forgets the rest. */
	public function takeRetainedEdits(mounted:Map<Int, RenderNode>):Void {
		for (index in 0...retainedEdits.length) {
			var node = retainedEdits[index];
			if (mounted.get(node.id.value) == node && !patchPriors.exists(node.id.value)) patchPriors.set(node.id.value,
				retainedEditPriors[index]);
		}
		retainedEdits.resize(0);
		retainedEditPriors.resize(0);
	}

	/** The nodes component reruns and announced edits replaced this frame, by ID, so the frame comparison can see what changed. */
	public function patchedPriors():Map<Int, RenderNode> return patchPriors;

	internal function endPatchFrame():Void {
		patchPriors.clear();
		submittedInstances = null;
	}

	/** Forgets the edit priors of nodes absent from the committed render tree. */
	public function pruneRetainedEdits(mounted:Map<Int, RenderNode>):Void {
		var cacheIndex = 0;
		while (cacheIndex < retainedEditCacheIds.length) {
			var id = retainedEditCacheIds[cacheIndex];
			if (mounted.exists(id)) {
				cacheIndex++;
				continue;
			}
			retainedEditCaches.remove(id);
			retainedEditCacheIds[cacheIndex] = retainedEditCacheIds[retainedEditCacheIds.length - 1];
			retainedEditCacheIds.pop();
		}
	}

	/** Cache identities only for the committed tree and retained application state. */
	/**
	 * Drops the cached IDs and key paths of widgets that are no longer mounted. `mountedHash` summarizes which nodes are
	 * mounted (any hash of their IDs in tree order will do). A cache entry only becomes stale when the mounted nodes change,
	 * so with the same hash and the same cached IDs since the last walk there is nothing to find, and the walk over cached
	 * keys is skipped. Scopes that hold no widget are created and dropped again by a build, a few
	 * every frame, and are left until `SCOPE_GROWTH_PRUNE` of them have collected: they only cache path strings. A change that
	 * goes unnoticed (a hash collision, or state released for a widget that stays unmounted) only leaves an entry cached until
	 * the next change.
	 */
	public function pruneKeyCaches(mounted:Map<Int, RenderNode>, mountedHash:Int):Void {
		var scopeEntries = rootScope.cachedEntries();
		if (mountedHash == prunedMountedHash && idsByPath.count == prunedIdCount
			&& scopeEntries >= prunedScopeEntries && scopeEntries - prunedScopeEntries < SCOPE_GROWTH_PRUNE) return;
		keyCachePrunes++;
		idsByPath.prune(mounted, stateStore);
		rootScope.prune(function(path) return idsByPath.exists(path));
		prunedMountedHash = mountedHash;
		prunedIdCount = idsByPath.count;
		prunedScopeEntries = rootScope.cachedEntries();
	}

	/** Drops the component bodies, which hold the build closures of the retained tree; the next frame builds afresh. */
	public function releaseRetained():Void {
		clearRenderScopes();
		clearCommandFlags();
		retainedEditCaches.clear();
		retainedEditCacheIds.resize(0);
		retainedEdits.resize(0);
		retainedEditPriors.resize(0);
		patchPriors.clear();
		rootDependencies.clearDependencies();
	}

	/** Releases the component bodies and edit priors when the owning UI context is disposed. */
	public function dispose():Void {
		clearRenderScopes();
		clearCommandFlags();
		retainedEditCaches.clear();
		retainedEditCacheIds.resize(0);
		rootDependencies.dispose();
		patchPriors.clear();
	}

	/** A retained subtree whose root was rebuilt in place since the cache saw it must return the replacement, not the old node. */
	public function currentRoot(root:RenderNode):RenderNode {
		var owner = root.scopeOwner();
		return owner == null ? RenderNode.latest(root) : owner.currentRoot(root);
	}

	/**
	 * Builds `build` in the scope `key` names within the current one, so the ids and state of what it builds are its
	 * own.
	 */
	public function withScope<T>(key:Key, build:Void->T):T return withScopeUnder(scope, key, build);

	/** The scope widgets built now are keyed under; withScopeUnder keys a deeper subtree by it. */
	public function currentScope():KeyScope return scope;

	/**
	 * Builds `view` with `modifier` added to its root. A component's root belongs to its body, so callers place, flag or
	 * decorate it this way instead of editing what `build` returned: the modifier is applied after each body run.
	 */
	public function build(view:View, ?modifier:RootModifier):ViewRoot {
		if (view == null) throw "A view is required";
		if (modifier == null) return view.build(this);
		if (!Std.isOfType(view, haxeon.ui.core.RenderScope.ScopeView)) {
			var node = view.build(this).node();
			// A plain view that returned a component's root unchanged, such as a wrapper: the component applies the
			// modifier after each body run, with its direct caller's.
			var owner = renderScopeAt(node);
			if (owner != null) owner.addModifier(modifier);
			else modifier.apply(node);
			return node;
		}
		// A component's build mounts it before building anything else, which takes the modifier.
		pendingModifier = modifier;
		var node = view.build(this);
		if (pendingModifier != null) {
			pendingModifier = null;
			throw "A component's build must mount it with mountComponent";
		}
		return node;
	}

	var pendingModifier:Null<RootModifier> = null;

	/**
	 * Debug check that every caller left component roots to their bodies, passing a modifier instead of editing one. It runs
	 * with retention verification, or always when this is set; HAXEON_UI_CHECK_COMPONENT_ROOTS=1 sets it.
	 */
	public var checkComponentRoots:Bool = Sys.getEnv("HAXEON_UI_CHECK_COMPONENT_ROOTS") == "1";

	@:allow(haxeon.ui.core.UiContext) function verifyComponentRoots():Void {
		for (owner in renderScopes) {
			if (owner.disposed || !owner.mounted) continue;
			var change = owner.callerChanges();
			if (change != null)
				throw 'A caller changed the ${change} of component root ${stateStore.describe(owner.root.id)}; pass a RootModifier to BuildContext.build instead';
		}
	}

	/** Capture inherited values on the native owner, with no mount-path build closures or layout wrapper. */
	public function mountComponent(component:haxeon.ui.core.RenderScope.ScopeView):RenderNode {
		var modifier = pendingModifier;
		pendingModifier = null;
		var previousScope = scope;
		scope = scope.child(new Key(component.scopeKey()));
		defer scope = previousScope;
		// Widget IDs occupy the positive 31-bit namespace. Native owners use the
		// negative half, so a stateful body can use its own root ID independently.
		var identity = resolveId("scope");
		var rootId = pendingScopeRootId == null ? identity : pendingScopeRootId;
		pendingScopeRootId = null;
		var text = textStyleStack.length == 1 ? textStyleStack : textStyleStack.copy();
		var previous = mountedScopes.get(identity.value);
		if (previous != null && canReuseScope(previous, component, rootId, text)) {
			// Equal inputs under an equal context build the same body: keep it, its subscriptions and the instance they
			// observe. Its handlers call the new description's callbacks through latestOf; the caller's modifier is swapped.
			stateStore.touchScope(previous.resourceId);
			previous.keep(component, scope, styleParent, text);
			// The body's subtree keeps its IDs; the new modifier's children were claimed as the caller built them.
			var root = previous.root;
			// Swapping the modifier edits a submitted root: announce it so the frame compares it with what was shown.
			if (previous.hasModifier() || modifier != null) willEditRetained(root);
			previous.setModifier(null);
			root.detach();
			claimRetainedTree(root);
			previous.setModifier(modifier);
			return root;
		}
		var resourceId = stateStore.beginScope();
		var owner = new RenderScope(resourceId, identity.value, this, component, scope, styleParent, text);
		owner.parentScope = activeRenderScope;
		renderScopes.push(owner);
		try {
			owner.mount(rootId);
			stateStore.installScope(owner);
			mountedScopes.set(identity.value, owner);
			if (modifier != null) owner.setModifier(modifier);
		} catch (error:Dynamic) {
			owner.dispose();
			renderScopes.remove(owner);
			// A failed description did not replace the mounted instance. Its distinct
			// lifetime ticket must still be touched before the frame's resource sweep.
			for (previous in renderScopes) if (!previous.disposed
				&& previous.mounted && previous.sameSlot(owner)) stateStore.touchScope(previous.resourceId);
			throw error;
		}
		return owner.root;
	}

	/** The latest mounted scope of each component identity, for keeping a body whose inputs are equal. */
	final mountedScopes:Map<Int, RenderScope> = new Map();

	function canReuseScope(previous:RenderScope, component:haxeon.ui.core.RenderScope.ScopeView, rootId:WidgetId,
			text:Array<ResolvedTextStyle>):Bool {
		var root = previous.root;
		// A root this build already claimed is a second mount of one identity, which must be rejected, not kept.
		return !bypassRetention && !previous.disposed && !previous.pending && root != null && root.id.equals(rootId)
			&& (buildingRenderScope || !claimed.has(root.id.value))
			&& previous.builtStyleRevision == styleRevision && previous.builtWidth == viewportWidth
			&& previous.builtHeight == viewportHeight
			&& !StyleDiff.compare(previous.capturedParent, styleParent).changed
			&& sameTextStack(previous.capturedText, text) && component.inputsEqual(previous.latest);
	}

	static function sameTextStack(left:Array<ResolvedTextStyle>, right:Array<ResolvedTextStyle>):Bool {
		if (left == right) return true;
		if (left.length != right.length) return false;
		for (index in 0...left.length) {
			var a = left[index], b = right[index];
			if (a != b && (a.textStyle != b.textStyle || a.paragraphStyle != b.paragraphStyle
				|| a.textColor != b.textColor)) return false;
		}
		return true;
	}

	@:allow(haxeon.ui.core.RenderScope) function forgetScope(owner:RenderScope):Void {
		if (mountedScopes.get(owner.identityId) == owner) mountedScopes.remove(owner.identityId);
	}

	/** The instance mounted for a root `mountComponent` returned: an equal description keeps the earlier one. */
	public function mountedComponent(root:RenderNode):Null<haxeon.ui.core.RenderScope.ScopeView> {
		var owner = root.scopeOwner();
		return owner == null ? null : owner.component;
	}

	/**
	 * For a component's body: the newest description of `component`, as handlers that outlive this run must read callbacks.
	 * A parent run with equal inputs keeps the body and only records its new description.
	 */
	public function latestOf<T:haxeon.ui.core.RenderScope.ScopeView>(component:T):Void->T {
		var owner = activeRenderScope;
		if (owner == null || owner.component != component) return () -> component;
		return () -> cast owner.latest;
	}

	@:allow(haxeon.ui.component.TrackedScope) function deferRootIdentity():Null<WidgetId> {
		var reserved = pendingScopeRootId;
		pendingScopeRootId = null;
		return reserved;
	}

	@:allow(haxeon.ui.component.TrackedScope) function restoreRootIdentity(id:Null<WidgetId>):Void pendingScopeRootId =
		id;

	@:allow(haxeon.ui.core.RenderScope) function beforeRenderScopeChange(root:RenderNode):Void recordPriors(root,
		root,
		false);

	@:allow(haxeon.ui.core.RenderScope) function buildRenderScope(owner:RenderScope, rootId:WidgetId):RenderNode {
		var previousBuilding = buildingRenderScope;
		// A direct owner.refresh is an independent update too; its mounted IDs are claimed by
		// the enclosing retained tree, while an initial mount must still enforce duplicate IDs.
		if (owner.root != null) buildingRenderScope = true;
		var marker = stateStore.beginUsage();
		var previous = activeRenderScope;
		var previousObserved = activeObserved;
		var previousScope = scope, previousParent = styleParent, previousText = textStyleStack;
		var previousRoot = pendingScopeRootId;
		var previousBuildId = activeBuildRootId, previousBuildingRoot = buildingRoot;
		pendingScopeRootId = rootId;
		activeBuildRootId = rootId;
		buildingRoot = null;
		var capture = previousObserved == observed ? localObserved : previousObserved;
		var dependencyMark = capture.dependencyMarker();
		scope = owner.capturedScope;
		styleParent = owner.capturedParent;
		textStyleStack = owner.capturedText;
		activeObserved = capture;
		activeRenderScope = owner;
		var completed = false;
		defer {
			if (!completed) {
				// Failed bodies must keep the reads that can make the next attempt succeed.
				for (index in dependencyMark...capture.pendingCount()) owner.trackField(capture.pendingSourceAt(index),
					capture.pendingFieldBitAt(index));
				stateStore.finishUsage(marker);
			}
			capture.truncate(dependencyMark);
			activeObserved = previousObserved;
			activeRenderScope = previous;
			scope = previousScope;
			styleParent = previousParent;
			textStyleStack = previousText;
			pendingScopeRootId = previousRoot;
			activeBuildRootId = previousBuildId;
			buildingRoot = previousBuildingRoot;
			buildingRenderScope = previousBuilding;
		}
		var result = readComponentBody(owner.component, capture);
		owner.builtStyleRevision = styleRevision;
		owner.builtWidth = viewportWidth;
		owner.builtHeight = viewportHeight;
		for (index in dependencyMark...capture.pendingCount()) owner.trackField(capture.pendingSourceAt(index),
			capture.pendingFieldBitAt(index));
		var ownedIds = stateStore.usageMarker() == marker ? null : stateStore.usedIdsSince(marker,
			stateStore.ownedStateIds(ResourceId.scope(owner.resourceId)));
		stateStore.setOwnedStates(ResourceId.scope(owner.resourceId), ownedIds);
		stateStore.finishUsage(marker);
		completed = true;
		stateStore.retain(ownedIds, false);
		return result;
	}

	/** Keep tracking cleanup local to the direct call, including a throwing body. */
	function readComponentBody(component:haxeon.ui.core.RenderScope.ScopeView, capture:Dependencies):RenderNode {
		var frame = ReactiveRuntime.enterTracking(capture);
		defer ReactiveRuntime.leaveTracking(frame);
		return component.buildBody(this).node();
	}

	/** Resource liveness follows the current mounted tree, including bodies rerun outside a full build. */
	public function retainRenderScopeState(mounted:Map<Int, RenderNode>):Void {
		for (owner in renderScopes) if (!owner.disposed
			&& mounted.get(owner.root.id.value) == owner.root) stateStore.touchScope(owner.resourceId);
	}

	/** Runs scheduled structural computations before submitting their changed trees. */
	public function hasPendingRenderScopes():Bool {
		for (owner in renderScopes) if (owner.mounted && !owner.disposed && owner.pending) return true;
		return false;
	}

	internal function flushRenderScopes(submittedRoot:Null<RenderNode>, deferUnmount:Bool = false):Void {
		var previous = buildingRenderScope;
		buildingRenderScope = true;
		defer buildingRenderScope = previous;
		var progressed = true;
		while (progressed) {
			progressed = false;
			var index = 0;
			while (index < renderScopes.length) {
				var owner = renderScopes[index++];
				if (owner.disposed) continue;
				if (stateStore.scopeOwner(owner.resourceId) != owner) {
					owner.dispose();
					progressed = true;
				} else if (owner.mounted && owner.attached(submittedRoot)
					&& owner.pending && !hasPendingScopeAncestor(owner)) {
					owner.refresh();
					progressed = true;
				}
			}
		}
		if (deferUnmount) return;
		// Pending ancestors can adopt cached children; sweep only after structure settles.
		if (stateStore.frameActive || buildFeedbackRequested) {
			for (owner in renderScopes) if (!owner.disposed && owner.mounted && !owner.attached(submittedRoot))
				owner.mounted = false;
			return;
		}
		// A detached scope a detached parent still owns goes once that parent is disposed, whatever their storage order.
		var disposed = true;
		while (disposed) {
			disposed = false;
			for (owner in renderScopes) if (!owner.disposed && owner.mounted && !owner.attached(submittedRoot)
				&& !owner.retainedByParent()) {
				owner.dispose();
				disposed = true;
			}
		}
		for (owner in renderScopes) if (!owner.disposed && owner.mounted && !owner.attached(submittedRoot))
			owner.mounted = false;
	}

	/** Remounting a scope can put a retained child earlier in storage; ancestors still run first. */
	function hasPendingScopeAncestor(owner:RenderScope):Bool {
		var ancestor = owner.parentScope;
		while (ancestor != null) {
			if (!ancestor.disposed && ancestor.mounted && ancestor.pending) return true;
			ancestor = ancestor.parentScope;
		}
		return false;
	}

	/** Releases subscriptions when the owning state is no longer retained by mounted or cached bodies. */
	public function pruneRenderScopes(mounted:Map<Int, RenderNode>):Void {
		var index = 0;
		while (index < renderScopes.length) {
			var owner = renderScopes[index];
			owner.mounted = mounted.get(owner.root.id.value) == owner.root;
			if (!owner.disposed && stateStore.scopeOwner(owner.resourceId) == owner) {
				index++;
				continue;
			}
			owner.dispose();
			renderScopes[index] = renderScopes[renderScopes.length - 1];
			renderScopes.pop();
		}
	}

	function clearRenderScopes():Void {
		for (owner in renderScopes) owner.dispose();
		renderScopes.resize(0);
		mountedScopes.clear();
	}

	function adoptRenderScopes(node:RenderNode, parent:Null<RenderScope>):Void {
		var owner = node.scopeOwner();
		if (owner != null && parent != null && (owner.disposed || owner.sameSlot(parent))) {
			node.setScopeOwner(parent);
			owner = parent;
		}
		if (owner != null && !owner.disposed && (owner.root == node || owner == parent)) {
			var outer = owner;
			outer.mounted = true;
			while (outer.parentScope != null && outer.parentScope.root == node) {
				var ancestor = outer.parentScope;
				if (ancestor.disposed || parent != null && ancestor.sameSlot(parent)) {
					outer.parentScope = ancestor.parentScope;
					continue;
				}
				outer = ancestor;
				outer.mounted = true;
			}
			if (outer != parent) outer.parentScope = parent;
			parent = owner;
		}
		for (child in node.children) adoptRenderScopes(child, parent);
	}

	/**
		Builds under `base`'s child `key` rather than the current scope's, so a subtree placed anywhere below `base`
		keeps one identity, and its state, wherever it moves. Keys must be unique among the subtrees built under `base`.
	**/
	public function withScopeUnder<T>(base:KeyScope, key:Key, build:Void->T):T {
		if (base == null || key == null || build == null) throw "A scoped build requires a scope, a key and a callback";
		var previous = scope;
		scope = base.child(key);
		defer scope = previous;
		return build();
	}

	/** The state the widget `id` keeps across builds, made with `initial` on its first build. */
	public function state<T>(id:WidgetId, initial:T):State<T> {
		stateStore.initialize(id, initial);
		return stateStore.handle(id);
	}

	/** Like `state`, but calls `create` only when the state is first initialized, so later builds allocate no discarded value. */
	public function lazyState<T>(id:WidgetId, create:Void->T):State<T> {
		if (stateStore.contains(id)) stateStore.touch(id);
		else stateStore.initialize(id, create());
		return stateStore.handle(id);
	}

	/** Captures state usage so a retained subtree can keep its resources mounted. */
	public function stateUsageMarker():Int return stateStore.usageMarker();

	/** Signal and observable-field reads captured by the current frame. */
	final observed:Dependencies = new Dependencies(true);

	/** The read log of component bodies: the root must not subscribe to what a body reads. */
	final localObserved:Dependencies = new Dependencies(true);

	var activeObserved:Dependencies;

	/** Root subscription schedules a frame for any signal read in the mounted tree. */
	final rootDependencies:Dependencies = new Dependencies();

	/** Runs a build or getter as a read-only reactive tracking scope. */
	public function trackReads<T>(run:Void->T):T return ReactiveRuntime.withTracking(activeObserved, run);

	/** Marks the current dependency log for a retained subtree. */
	public function dependencyMarker():Int return activeObserved.dependencyMarker();

	/** Captures tracked reads since the marker into a reusable retained dependency record. */
	public function dependenciesSince(marker:Int, ?target:Dependencies):Dependencies {
		var result = target == null ? new Dependencies() : target;
		result.replaceSlice(activeObserved, marker);
		return result;
	}

	/** Replaces the root subscriptions after a successful full build. */
	public function captureRootDependencies():Void {
		rootDependencies.replaceSlice(observed, 0);
		observed.markClean();
	}

	internal function rootDependenciesDirty():Bool return rootDependencies.dirty;

	/** Records a reused subtree's reads again, so an enclosing cache depends on them too. */
	public function retainDependencies(dependencies:Dependencies):Void activeObserved.addAll(dependencies);

	/** Called as a frame starts: the log only links reads to the subtrees built in one frame. */
	public function resetObserved():Void {
		observed.clear();
		localObserved.clear();
	}

	/** Returns state IDs touched after a retained subtree build marker. */
	internal function stateIdsUsedSince(marker:Int,
			?previous:Array<ResourceId>):Array<ResourceId> return stateStore.usedIdsSince(marker,
		previous);

	/** Keeps state-backed resources alive for a retained subtree this frame. */
	internal function retainStateIds(ids:Array<ResourceId>):Void stateStore.retain(ids, true);

	/** Claims IDs belonging to a retained render subtree without rebuilding it. */
	public function claimRetainedTree(root:RenderNode):Void {
		if (root == null) throw "A retained render subtree is required";
		adoptRenderScopes(root, activeRenderScope);
		// Independent builds claim their completed tree when it returns to the enclosing build.
		if (buildingRenderScope) return;
		claimRetainedIds(root);
	}

	function claimRetainedIds(node:RenderNode):Void {
		if (!claimed.add(node.id.value)) throw 'Duplicate retained widget ID ${node.id.value}';
		for (child in node.children) claimRetainedIds(child);
	}

	/** Opens an already initialized value without supplying an unused placeholder. */
	public function existingState<T>(id:WidgetId):State<T> {
		if (!stateStore.contains(id)) throw 'Widget state has not been initialized for ${stateStore.describe(id)}';
		stateStore.touch(id);
		return stateStore.handle(id);
	}

	/** Lazily creates resource-backed state and releases it when its widget unmounts. */
	public function resourceState<T>(id:WidgetId, create:Void->T, dispose:T->Void):State<T> {
		if (id == null || create == null
			|| dispose == null) throw "Resource state requires an ID, factory, and disposer";
		if (!stateStore.contains(id)) {
			var value = create();
			stateStore.initialize(id, value);
			stateStore.onUnmount(id, function() {
				dispose(value);
			});
		} else stateStore.touch(id);
		var result:State<Dynamic> = stateStore.handle(id);
		return cast result;
	}

	static inline function finite(value:Float):Bool return value == value && value - value == 0.0;
}

/** Only announced editors need priors. A frame's input prior and its later geometry-feedback prior have separate lifetimes. */
private class RetainedEditCache {
	var prior:Null<RenderNode> = null;
	var spare:Null<RenderNode> = null;
	var owner:Null<RenderNode> = null;
	var epoch:Int = -1;

	public function new() {}

	public function capture(node:RenderNode, epoch:Int):RenderNode {
		if (this.epoch != epoch) {
			var previous = prior;
			prior = spare;
			spare = previous;
			this.epoch = epoch;
		} else if (owner != node && owner != null) {
			// Two instances with the same ID can be edited while a build replaces one; the first prior must stay intact.
			return node.snapshotForCompare();
		}
		owner = node;
		var result = node.snapshotForCompare(false, prior);
		prior = result;
		return result;
	}
}
