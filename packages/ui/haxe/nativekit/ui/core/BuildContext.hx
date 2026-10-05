package nativekit.ui.core;

import FontCollection;
import NativeKitSurface;
import LayoutStyle;
import nativekit.ui.theme.Theme;
import nativekit.ui.theme.TextRole;
import nativekit.ui.style.StyleSheet;
import nativekit.ui.style.StyleResolver;
import nativekit.ui.style.StyleEnvironment;
import nativekit.ui.style.ComputedStyle;
import nativekit.ui.style.StyleTarget;
import nativekit.ui.gestures.GestureArena;
import nativekit.ui.animation.AnimationScheduler;

/** Frame-local identity scopes backed by a persistent UiContext state store. */
class BuildContext {
	public final stateStore:StateStore;
	public var fonts(default, null):Null<FontCollection>;
	public var platformSurface(default, null):Null<NativeKitSurface>;
	public final textInput:TextInputBridge;
	public final clipboard:ClipboardService;
	public final gestures:GestureArena;
	public final animations:AnimationScheduler;
	public final interactionStates:InteractionStateStore;
	/** Application commands available to command-bound widgets. */
	public final commands:CommandRegistry;
	/** Invocation context shared by command-bound widgets in this frame. */
	public var commandContext(default, null):CommandContext;
	public final styleResolver:StyleResolver;
	public final environment:StyleEnvironment;
	/** Optional diagnostic sink for named view builds: name, preparation, build, nodes. */
	public var buildProbe:Null<String->Float->Float->Int->Void> = null;
	public var theme(default, null):Theme;
	public var styleSheet(default, null):StyleSheet;
	/** Logical viewport dimensions for frame-local placement decisions. */
	public var viewportWidth(default, null):Float;
	public var viewportHeight(default, null):Float;
	/** A resolved widget can request another native layout pass in this submit. */
	public var layoutFeedbackRequested(default, null):Bool = false;
	var styleParent:Null<ComputedStyle>;
	/** Bumped when the theme or application sheet is replaced, so swaps never reuse a fingerprint. */
	var styleEpoch:Int = 0;
	var focusRequester:WidgetId->Bool;
	var deferredFocusRequester:WidgetId->Void;
	final claimed:IdSet;
	final idsByPath:Map<String, WidgetId>;
	var cachedIdCount:Int;
	var rootScope:KeyScope;
	var scope:KeyScope;
	var textStyleStack:Array<ResolvedTextStyle>;
	/** Widgets that rebuild themselves in place, by widget ID; see selfUpdating. */
	final selfUpdatingBuilds:Map<Int, SelfUpdatingBuild> = new Map();
	var pendingPatches:Array<SelfUpdatingBuild> = [];
	/** True while a patch runs: its IDs are claimed later, when the retained tree that holds them is claimed. */
	var patching:Bool = false;
	final patchPriors:Map<Int, RenderNode> = new Map();

	public function new(stateStore:StateStore, ?fonts:FontCollection, ?textInput:TextInputBridge,
			?clipboard:ClipboardService, ?theme:Theme, ?gestures:GestureArena,
			?animations:AnimationScheduler, ?styleSheet:StyleSheet,
			?interactionStates:InteractionStateStore, ?commands:CommandRegistry) {
		if (stateStore == null)
			throw "Build context requires a state store";
		this.stateStore = stateStore;
		this.fonts = fonts;
		platformSurface = null;
		this.textInput = textInput == null ? new TextInputBridge() : textInput;
		this.clipboard = clipboard == null ? new ClipboardService() : clipboard;
		this.gestures = gestures == null ? new GestureArena() : gestures;
		this.animations = animations == null ? new AnimationScheduler() : animations;
		this.interactionStates = interactionStates == null ? new InteractionStateStore() : interactionStates;
		this.commands = commands == null ? new CommandRegistry() : commands;
		this.commandContext = new CommandContext();
		this.styleResolver = new StyleResolver(this.animations);
		this.environment = new StyleEnvironment();
		this.theme = theme == null ? new Theme() : theme;
		this.theme.refreshStyles();
		this.styleSheet = styleSheet == null ? new StyleSheet("Application") : styleSheet;
		styleParent = null;
		viewportWidth = 0.0;
		viewportHeight = 0.0;
		focusRequester = function(_) { return false; };
		deferredFocusRequester = function(_) {};
		claimed = new IdSet();
		idsByPath = new Map();
		cachedIdCount = 0;
		rootScope = new KeyScope();
		scope = rootScope;
		textStyleStack = [ResolvedTextStyle.fromTheme(this.theme)];
	}

	/** Updates the context passed to command-bound widgets. */
	public function setCommandContext(context:Null<CommandContext>):Void
		commandContext = context == null ? new CommandContext() : context;

	/** Replaces the palette used by subsequently built widgets. */
	public function setTheme(theme:Theme):Void {
		if (theme == null)
			throw "Build context requires a theme";
		this.theme = theme;
		styleEpoch++;
		this.theme.refreshStyles();
		if (textStyleStack.length <= 1)
			textStyleStack = [ResolvedTextStyle.fromTheme(theme)];
	}

	/** Replaces the application stylesheet layered above the active theme. */
	public function setStyleSheet(styleSheet:StyleSheet):Void {
		if (styleSheet == null)
			throw "Build context requires a stylesheet";
		this.styleSheet = styleSheet;
		styleEpoch++;
	}

	/** Updates viewport-derived environment values for conditional style rules. */
	public function setEnvironmentViewport(width:Float, height:Float):Void
		environment.setViewport(width, height);

	/** Computed inherited style supplied by the nearest composing parent. */
	public var inheritedStyle(get, never):Null<ComputedStyle>;
	function get_inheritedStyle():Null<ComputedStyle>
		return styleParent;

	/** Builds descendants with the given computed style as their inheritance source. */
	public function withStyleParent<T>(parent:ComputedStyle, build:Void->T):T {
		if (parent == null || build == null)
			throw "A style parent and build callback are required";
		var previous = styleParent;
		styleParent = parent;
		try {
			var result = build();
			styleParent = previous;
			return result;
		} catch (error:Dynamic) {
			styleParent = previous;
			throw error;
		}
	}

	/** Resolves one node against the active inherited style and current layers. */
	public function resolveStyle(target:StyleTarget, local:Null<LayoutStyle>):ComputedStyle
		return styleResolver.resolve(target, styleParent, theme.styles, styleSheet, local, environment);

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
		if (requester == null)
			throw "Build context requires a focus request route";
		focusRequester = requester;
	}

	public function requestFocus(id:WidgetId):Bool
		return id != null && focusRequester(id);

	/** Installs the focus route for targets revealed by the next layout. */
	public function setDeferredFocusRequester(requester:WidgetId->Void):Void {
		if (requester == null) throw "Build context requires a deferred focus route";
		deferredFocusRequester = requester;
	}

	/** Focus a newly built or scrolled-into-view widget after geometry is resolved. */
	public function requestFocusAfterLayout(id:WidgetId):Void {
		if (id != null) deferredFocusRequester(id);
	}

	/** Provides the font collection used by text-layout-backed widgets. */
	public function setFonts(fonts:FontCollection):Void {
		if (fonts == null || fonts.isDisposed())
			throw "Build context requires a live font collection";
		this.fonts = fonts;
	}

	/** Provides the NativeKit surface used for IME and other platform services. */
	public function setPlatformSurface(surface:NativeKitSurface):Void {
		if (surface == null || surface.isDisposed())
			throw "Build context requires a live NativeKit surface";
		platformSurface = surface;
		textInput.attach(surface);
	}

	/** Installs the logical viewport used while building the current frame. */
	public function setViewport(width:Float, height:Float):Void {
		if (width <= 0.0 || height <= 0.0 || !finite(width) || !finite(height))
			throw "Build viewport dimensions must be positive and finite";
		viewportWidth = width;
		viewportHeight = height;
	}

	public function beginFrame():Void {
		layoutFeedbackRequested = false;
		claimed.clear();
		if (rootScope.cachedEntries() >= 8192)
			rootScope = new KeyScope();
		scope = rootScope;
		stateStore.beginFrame();
		textStyleStack = [ResolvedTextStyle.fromTheme(theme)];
	}

	public function requestLayoutFeedback():Void
		layoutFeedbackRequested = true;

	public function consumeLayoutFeedback():Bool {
		var requested = layoutFeedbackRequested;
		layoutFeedbackRequested = false;
		return requested;
	}

	/** Bounded-run diagnostics for retained key path caches. */
	public function diagnosticKeyCounts():{ids:Int, paths:Int}
		return {ids: cachedIdCount, paths: rootScope.cachedEntries()};

	/** Reports a measured subtree only when a diagnostic sink is installed. */
	public function reportBuild(name:String, preparationSeconds:Float,
			buildSeconds:Float, root:RenderNode):Void {
		var probe = buildProbe;
		if (probe == null)
			return;
		var nodes = 0;
		root.walk(function(_) nodes++);
		probe(name, preparationSeconds, buildSeconds, nodes);
	}

	/** Returns the concrete typography currently inherited by the build. */
	public function currentTextStyle():ResolvedTextStyle
		return textStyleStack[textStyleStack.length - 1];

	/** Resolves a local sparse override against the current inherited style. */
	public function resolveTextStyle(?override:TextStyleOverride):ResolvedTextStyle
		return currentTextStyle().merge(override);

	/** Resolves a semantic theme role, then applies an optional local override. */
	public function resolveTextRole(role:TextRole,
			?override:TextStyleOverride):ResolvedTextStyle {
		var resolved = role == null || role == TextRole.Body
			? currentTextStyle()
			: currentTextStyle().merge(theme.textRole(role).toOverride());
		return resolved.merge(override);
	}

	/** Builds a subtree under a nested typography scope and restores the parent scope. */
	public function withTextStyle<T>(override:TextStyleOverride, build:Void->T):T {
		if (override == null || build == null)
			throw "A text style scope requires a style and callback";
		textStyleStack.push(resolveTextStyle(override));
		try {
			var result = build();
			textStyleStack.pop();
			return result;
		} catch (error:Dynamic) {
			textStyleStack.pop();
			throw error;
		}
	}

	public function id(localKey:String):WidgetId {
		var path = scope.widgetPath(localKey);
		var id = idsByPath.get(path);
		if (id == null) {
			if (cachedIdCount >= 8192) {
				idsByPath.clear();
				cachedIdCount = 0;
			}
			id = KeyScope.widgetIdForPath(path);
			idsByPath.set(path, id);
			cachedIdCount++;
		}
		stateStore.rememberPath(id, path);
		if (patching)
			return id;
		if (!claimed.add(id.value))
			throw 'Duplicate widget ID ${id.value}; use distinct keys for sibling views';
		return id;
	}

	/**
	 * Builds a widget so that it can rebuild just itself later. `build` must be re-runnable: it creates the widget's whole
	 * subtree and is called again, in the same scope and inherited style, when the widget asks for a patch. The widget
	 * then keeps its own changing state out of the revision that ancestors' caches watch (State.updateQuietly).
	 */
	public function selfUpdating(id:WidgetId, build:Void->RenderNode):RenderNode {
		var entry = new SelfUpdatingBuild(build, scope, styleParent, textStyleStack.copy());
		selfUpdatingBuilds.set(id.value, entry);
		entry.root = build();
		return entry.root;
	}

	/**
	 * Asks for the widget to be rebuilt in place at the start of the next frame and for that frame to run. Returns false when
	 * the widget was never built as self-updating, so the caller falls back to an ordinary state update.
	 */
	public function requestPatch(id:WidgetId):Bool {
		var entry = selfUpdatingBuilds.get(id.value);
		if (entry == null || entry.root == null)
			return false;
		if (!entry.pending) {
			entry.pending = true;
			pendingPatches.push(entry);
		}
		commands.refresh();
		return true;
	}

	/** Rebuilds the pending self-updating widgets and swaps them into the retained tree; runs after beginFrame, before the root builds. */
	public function applyPatches():Void {
		if (pendingPatches.length == 0)
			return;
		var work = pendingPatches;
		pendingPatches = [];
		for (entry in work) {
			entry.pending = false;
			var old = entry.root;
			// Not in a tree any more: whatever now owns it builds a fresh one.
			if (old == null || old.parent == null)
				continue;
			// The frame comparison walks the tree it is given, which now holds the replacement, so hand it the replaced nodes.
			old.walk(function(node) {
				if (!patchPriors.exists(node.id.value))
					patchPriors.set(node.id.value, node);
			});
			var savedScope = scope, savedParent = styleParent, savedStack = textStyleStack;
			scope = entry.scope;
			styleParent = entry.styleParent;
			textStyleStack = entry.textStyleStack.copy();
			patching = true;
			try {
				var next = entry.build();
				old.replaceWith(next);
				entry.root = next;
			} catch (error:Dynamic) {
				patching = false;
				scope = savedScope;
				styleParent = savedParent;
				textStyleStack = savedStack;
				throw error;
			}
			patching = false;
			scope = savedScope;
			styleParent = savedParent;
			textStyleStack = savedStack;
		}
	}

	/** The nodes patches replaced this frame, by ID, so the frame comparison can see what changed. */
	public function patchedPriors():Map<Int, RenderNode>
		return patchPriors;

	public function endPatchFrame():Void
		patchPriors.clear();

	/** Retire builders whose widgets are absent from the committed render tree. */
	public function pruneSelfUpdatingBuilds(mounted:Map<Int, RenderNode>):Void {
		var stale:Array<Int> = [];
		for (id in selfUpdatingBuilds.keys())
			if (!mounted.exists(id)) stale.push(id);
		for (id in stale) {
			var entry = selfUpdatingBuilds.get(id);
			entry.root = null;
			entry.pending = false;
			selfUpdatingBuilds.remove(id);
		}
		if (stale.length > 0)
			pendingPatches = [for (entry in pendingPatches) if (entry.root != null) entry];
	}

	/** Releases builders and pending patches when the owning UI context is disposed. */
	public function dispose():Void {
		selfUpdatingBuilds.clear();
		pendingPatches = [];
		patchPriors.clear();
	}

	/** A retained subtree whose root was rebuilt in place since the cache saw it must return the replacement, not the old node. */
	public function currentRoot(root:RenderNode):RenderNode
		return RenderNode.latest(root);

	public function withScope<T>(key:Key, build:Void->T):T {
		if (key == null || build == null)
			throw "A scoped build requires a key and callback";
		var previous = scope;
		scope = scope.child(key);
		try {
			var result = build();
			scope = previous;
			return result;
		} catch (error:Dynamic) {
			scope = previous;
			throw error;
		}
	}

	public function state<T>(id:WidgetId, initial:T):State<T> {
		stateStore.initialize(id, initial);
		return new State<T>(stateStore, id);
	}

	/** Captures state usage so a retained subtree can keep its resources mounted. */
	public function stateUsageMarker():Int
		return stateStore.usageMarker();

	/** Returns state IDs touched after a retained subtree build marker. */
	public function stateIdsUsedSince(marker:Int):Array<Int>
		return stateStore.usedIdsSince(marker);

	/** Current change revisions of the given widget states, for detecting changes inside a retained subtree. */
	public function stateRevisions(ids:Array<Int>):Array<Int>
		return [for (id in ids) stateStore.valueRevision(id)];

	/** Keeps state-backed resources alive for a retained subtree this frame. */
	public function retainStateIds(ids:Array<Int>):Void
		stateStore.retain(ids);

	/** Claims IDs belonging to a retained render subtree without rebuilding it. */
	public function claimRetainedTree(root:RenderNode):Void {
		if (root == null)
			throw "A retained render subtree is required";
		root.walk(function(node) {
			if (!claimed.add(node.id.value))
				throw 'Duplicate retained widget ID ${node.id.value}';
		});
	}

	/** Opens an already initialized value without supplying an unused placeholder. */
	public function existingState<T>(id:WidgetId):State<T> {
		if (!stateStore.contains(id))
			throw 'Widget state has not been initialized for ${stateStore.describe(id)}';
		stateStore.touch(id);
		return new State<T>(stateStore, id);
	}

	/** Lazily creates resource-backed state and releases it when its widget unmounts. */
	public function resourceState<T>(id:WidgetId, create:Void->T,
			dispose:T->Void):State<T> {
		if (id == null || create == null || dispose == null)
			throw "Resource state requires an ID, factory, and disposer";
		if (!stateStore.contains(id)) {
			var value = create();
			stateStore.initialize(id, value);
			stateStore.onUnmount(id, function() { dispose(value); });
		} else
			stateStore.touch(id);
		var result:State<Dynamic> = new State<Dynamic>(stateStore, id);
		return cast result;
	}

	static inline function finite(value:Float):Bool
		return value == value && value - value == 0.0;
}

/** A self-updating widget's builder and the build context it needs to run again. */
private class SelfUpdatingBuild {
	public final build:Void->RenderNode;
	public final scope:KeyScope;
	public final styleParent:Null<ComputedStyle>;
	public final textStyleStack:Array<ResolvedTextStyle>;
	public var root:Null<RenderNode> = null;
	public var pending:Bool = false;

	public function new(build:Void->RenderNode, scope:KeyScope, styleParent:Null<ComputedStyle>, textStyleStack:Array<ResolvedTextStyle>) {
		this.build = build;
		this.scope = scope;
		this.styleParent = styleParent;
		this.textStyleStack = textStyleStack;
	}
}
