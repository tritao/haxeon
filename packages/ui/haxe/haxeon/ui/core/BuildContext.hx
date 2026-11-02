package haxeon.ui.core;

import haxeon.reactive.Derived;
import haxeon.reactive.ReactiveRuntime;

import haxeon.platform.Surface;

import haxeon.ui.FontCollection;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.RenderNode.BuiltNode;
import haxeon.ui.theme.Theme;
import haxeon.ui.theme.TextRole;
import haxeon.ui.style.StyleSheet;
import haxeon.ui.style.StyleResolver;
import haxeon.ui.style.StyleEnvironment;
import haxeon.ui.style.ComputedStyle;
import haxeon.ui.style.StyleTarget;
import haxeon.ui.gestures.GestureArena;
import haxeon.ui.animation.AnimationScheduler;

/** Frame-local identity scopes backed by a persistent UiContext state store. */
class BuildContext {
	public final stateStore:StateStore;
	public var fonts(default, null):Null<FontCollection>;
	public var platformSurface(default, null):Null<Surface>;
	public final textInput:TextInputBridge;
	public final clipboard:ClipboardService;
	public final gestures:GestureArena;
	public final animations:AnimationScheduler;
	public final interactionStates:InteractionStateStore;
	/** Application commands available to command-bound widgets. */
	public final commands:CommandRegistry;
	/** Invocation context shared by command-bound widgets in this frame. */
	final commandContextState:CommandContextState = new CommandContextState();
	final commandFlagEntries:Array<{registry:CommandRegistry, id:String, value:Derived<Int>}> = [];
	public var commandContext(get, never):CommandContext;
	function get_commandContext():CommandContext return commandContextState.value;
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
	/** The paths in `idsByPath`, oldest first, so a prune can walk them in place instead of snapshotting the map's keys. */
	final pathOrder:Array<String> = [];
	var cachedIdCount:Int;
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
	 * When false, pointer and focus changes rebuild every cache that holds the widget, as before widgets updated themselves
	 * (selfUpdating) and hover that no rule matches was ignored. Tests turn it off to build a reference tree to compare the
	 * updated one against.
	 */
	public var updateInPlace:Bool = true;
	/** While set, retained caches build their subtree afresh instead of reusing it; UiContext.verifyRetention sets it. */
	public var bypassRetention:Bool = false;
	/** Bumped when the retained tree is released, so self-updating builds made before it are not registered again. */
	var updatingEpoch:Int = 0;
	/** Widgets that rebuild themselves in place, by widget ID; see selfUpdating. */
	final selfUpdatingBuilds:Map<Int, SelfUpdatingBuild> = new Map();
	/** Stable membership storage: iterating the map would copy its keys on every frame. */
	final selfUpdatingIds:Array<Int> = [];
	var updatingRegistrations:Int = 0;
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
		focusRequester = function(_) { return false; };
		deferredFocusRequester = function(_) {};
		claimed = new IdSet();
		idsByPath = new Map();
		cachedIdCount = 0;
		prunedMountedHash = 0;
		prunedIdCount = -1;
		prunedScopeEntries = -1;
		keyCachePrunes = 0;
		rootScope = new KeyScope();
		scope = rootScope;
		textStyleStack = [ResolvedTextStyle.fromTheme(this.theme)];
	}

	/** Updates the context passed to command-bound widgets. */
	public function setCommandContext(context:Null<CommandContext>):Void
		commandContextState.value = context == null ? new CommandContext() : context;

	/** Command presentation changes only when its enabled or checked result changes. */
	public function commandFlags(registry:CommandRegistry, id:String):Int {
		for (entry in commandFlagEntries)
			if (entry.registry == registry && entry.id == id) return entry.value.value;
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
	public function resolveStyle(target:StyleTarget, local:Null<LayoutStyle>, ?localTextColor:haxeon.ui.Color):ComputedStyle
		return styleResolver.resolve(target, styleParent, theme.styles, styleSheet, local, environment, localTextColor);

	/**
	 * Whether a change of this node's hover, alone, can change what its widget built. A widget reads hover to resolve its style, so
	 * unless a stylesheet rule matches the node on hover it builds the same; one that does more with hover updates itself
	 * (selfUpdating). Custom paint that reads hover as it paints is repainted by the frame instead (UiContext).
	 */
	public function hoverRebuilds(node:RenderNode):Bool {
		var owner = updatingOwner(node);
		var entry = owner == null ? null : updatingBuild(owner);
		return !updateInPlace || (entry != null && entry.buildsFromHover) || hasHoverStyle(node);
	}

	/** Conservative guard for retained hover. Conditional rules are included even when inactive. */
	public function hasHoverStyle(node:RenderNode):Bool {
		if (node.styleType == null) return false;
		// Most node types no hover rule names: answered from the types the current sheets name, without building a target.
		var revision = styleRevision;
		if (hoverTypesRevision != revision) {
			hoverTypesRevision = revision;
			hoverTypes.clear();
			hoverAnyType = false;
			collectHoverTypes(theme.styles);
			collectHoverTypes(styleSheet);
		}
		if (!hoverAnyType && !hoverTypes.exists(node.styleType)) return false;
		var target = new StyleTarget(node.styleType, node.styleKey, node.styleId,
			node.styleClasses, node.styleTags, -1);
		return sheetHasHoverRule(theme.styles, target) || sheetHasHoverRule(styleSheet, target);
	}

	/** The style revision `hoverTypes` was collected at, and the widget types of the rules that match on hover (any, if one names none). */
	var hoverTypesRevision:Int = -1;
	final hoverTypes:Map<String, Bool> = new Map();
	var hoverAnyType:Bool = false;

	function collectHoverTypes(sheet:haxeon.ui.style.StyleSheet):Void {
		for (rule in sheet.rules)
			if ((rule.selector.stateMask & haxeon.ui.style.StyleState.Hovered) != 0) {
				var type = rule.selector.widgetType;
				if (type == null) hoverAnyType = true;
				else hoverTypes.set(type, true);
			}
	}

	static function sheetHasHoverRule(sheet:haxeon.ui.style.StyleSheet, target:StyleTarget):Bool {
		for (rule in sheet.rules)
			if ((rule.selector.stateMask & haxeon.ui.style.StyleState.Hovered) != 0 && rule.selector.matches(target)) return true;
		return false;
	}

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
	public function setPlatformSurface(surface:Surface):Void {
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
		buildBeforeLayoutFeedbackRequested = false;
		localObserved.clear();
		claimed.clear();
		if (rootScope.cachedEntries() >= 8192)
			rootScope = new KeyScope();
		scope = rootScope;
		stateStore.beginFrame();
		textStyleStack = [ResolvedTextStyle.fromTheme(theme)];
	}

	var buildFeedbackRequested = false;
	var buildBeforeLayoutFeedbackRequested = false;
	var reactiveBuildPending = false;

	/** Resolved constraints changed which children a view must build; settle them before publishing the frame. */
	public function requestBuildFeedback():Void
		buildFeedbackRequested = true;

	/** Requests a rebuild before another layout pass can consume geometry from a view the callback just changed. */
	public function requestBuildFeedbackBeforeLayout():Void {
		buildFeedbackRequested = true;
		buildBeforeLayoutFeedbackRequested = true;
	}

	public function consumeBuildFeedbackBeforeLayout():Bool {
		var requested = buildBeforeLayoutFeedbackRequested;
		buildBeforeLayoutFeedbackRequested = false;
		return requested;
	}

	public function consumeBuildFeedback():Bool {
		var requested = buildFeedbackRequested;
		buildFeedbackRequested = false;
		return requested;
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
				pathOrder.resize(0);
				cachedIdCount = 0;
			}
			id = stateStore.resolveWidgetId(path);
			idsByPath.set(path, id);
			pathOrder.push(path);
			cachedIdCount++;
		}
		if (!patching && !claimed.add(id.value))
			throw 'Duplicate widget ID ${id.value}; existing=${stateStore.describe(id)} current=$path';
		stateStore.rememberPath(id, path);
		return id;
	}

	/**
	 * Builds a widget so that it can rebuild just itself later, on a pointer change or when it asks (requestPatch). `build` must
	 * be re-runnable: it creates the widget's whole subtree and is called again, in the same scope and inherited style. The
	 * rebuild is reconciled with the node returned here (RenderNode.reconcile): the node stays, with the listeners, style
	 * changes and children callers added to it after this call, and takes the style, state, semantics, callbacks and children of
	 * the new build. So `build` must not leave state in closures that outlives the build, other than through the nodes it makes,
	 * and a closure that captures the root resolves it through RenderNode.latest when it runs: reconcile keeps the old root.
	 * A widget that changes its own tracked state during interaction invalidates the subtrees that read it. Set
	 * buildsFromHover=false when hover is read only by style resolution or live paint.
	 */
	public function selfUpdating(id:WidgetId, build:Void->RenderNode, buildsFromHover:Bool = true):RenderNode {
		// Old entries can still belong to hidden caches; only their immutable state snapshots are reused.
		var previous = selfUpdatingBuilds.get(id.value);
		var entry = new SelfUpdatingBuild(id, build, scope, styleParent, textStyleStack.length == 1 ? textStyleStack : textStyleStack.copy());
		entry.buildsFromHover = buildsFromHover;
		entry.epoch = updatingEpoch;
		registerSelfUpdatingBuild(id.value, entry);
		var root = buildUpdating(entry, previous == null ? null : previous.dependencies);
		if (root.id.value != id.value)
			throw 'Self-updating root ID ${root.id.value} differs from its registered ID ${id.value}';
		// A retained alternative may still hold the old registration. A complete rebuild also changes its snapshot.
		if (previous != null) previous.buildRevision++;
		entry.root = root;
		// Taken now, before the caller touches the node: later rebuilds are applied as the difference from this.
		entry.built = root.snapshotBuilt();
		return root;
	}

	/**
	 * Asks for the widget to be rebuilt in place at the start of the next frame and for that frame to run. Returns false when
	 * the widget was never built as self-updating, so the caller falls back to an ordinary state update.
	 */
	public function requestPatch(id:WidgetId):Bool {
		if (!queuePatch(id))
			return false;
		var entry = selfUpdatingBuilds.get(id.value);
		if (entry != null) entry.reactivePending = false;
		// Its own revision, not a command refresh: a frame with nothing but patches pending rebuilds only the patched widgets.
		patchRequestRevision++;
		return true;
	}

	/** Queues a maybe-stale reactive reader; its sources are checked before the widget is rebuilt. */
	public function requestReactivePatch(id:WidgetId):Bool {
		if (id == null) return false;
		if (!updateInPlace) {
			if (!reactiveBuildPending) patchRequestRevision++;
			reactiveBuildPending = true;
			return true;
		}
		var entry = selfUpdatingBuilds.get(id.value);
		if (entry == null || entry.root == null) return false;
		if (!entry.pending) {
			entry.pending = true;
			pendingPatches.push(entry);
			patchRequestRevision++;
		}
		if (!entry.forcePending) entry.reactivePending = true;
		return true;
	}

	/** Bumped by requestPatch; a different value from the submitted one means a frame is due. */
	public var patchRequestRevision(default, null):Int = 0;

	public var hasPendingPatches(get, never):Bool;
	inline function get_hasPendingPatches():Bool
		return pendingPatches.length > 0;

	/** Queues the patch without asking for a frame; the caller already has one running. False when the widget is not self-updating. */
	public function queuePatch(id:WidgetId):Bool {
		var entry = selfUpdatingBuilds.get(id.value);
		if (entry == null || entry.root == null)
			return false;
		entry.forcePending = true;
		entry.reactivePending = false;
		if (!entry.pending) {
			entry.pending = true;
			pendingPatches.push(entry);
		}
		return true;
	}

	/** Whether this mounted node is a self-updating widget, so a pointer change can be met by rebuilding just it. */
	public function canPatch(node:RenderNode):Bool {
		if (!updateInPlace) return false;
		var entry = selfUpdatingBuilds.get(node.id.value);
		return entry != null && entry.root == node;
	}

	/** The node itself or its nearest ancestor that updates itself: the one to rebuild when this node's pointer state changes. */
	public function updatingOwner(node:RenderNode):Null<RenderNode> {
		var current:Null<RenderNode> = node;
		while (current != null) {
			if (canPatch(current)) return current;
			current = current.parent;
		}
		return null;
	}

	/** The self-updating build for a node, while it is registered and current. */
	public function updatingBuild(node:RenderNode):Null<SelfUpdatingBuild> {
		var entry = selfUpdatingBuilds.get(node.id.value);
		return entry != null && entry.root == node ? entry : null;
	}

	/**
	 * Registers a cached widget again when its retained subtree returns. During a full build an unclaimed ID still
	 * belongs only to the previous frame, so a cached variant can replace that registration. An ID already claimed by
	 * this build, or an ID in an in-place patch, cannot be taken from a different live node.
	 *
	 * Validation can be requested without registering anything, so a cache with several updaters either rearms all of
	 * them or leaves the current registrations alone when any dependency no longer matches.
	 */
	public function rearm(id:WidgetId, entry:SelfUpdatingBuild):Bool {
		if (!canRearm(id, entry)) return false;
		rearmValidated(id, entry);
		return true;
	}

	@:allow(haxeon.ui.core.InteractionStateSnapshot)
	function canRearm(id:WidgetId, entry:SelfUpdatingBuild):Bool {
		if (!updateInPlace || entry.root == null || entry.epoch != updatingEpoch) return false;
		var current = selfUpdatingBuilds.get(id.value);
		if (current != null && current.root != entry.root && (patching || claimed.has(id.value))) return false;
		var dependencies = entry.dependencies;
		if (dependencies != null) {
			if (dependencies.observed != null && !dependencies.observed.current()) return false;
			if (dependencies.children != null && !dependencies.children.matches(this, false, true)) return false;
		}
		return true;
	}

	/** Commit a subtree after source versions and child registrations have been validated. */
	@:allow(haxeon.ui.core.InteractionStateSnapshot)
	function rearmValidated(id:WidgetId, entry:SelfUpdatingBuild):Void {
		var dependencies = entry.dependencies;
		if (dependencies != null && dependencies.children != null) dependencies.children.rearmValidated(this);
		if (selfUpdatingBuilds.get(id.value) != entry) registerSelfUpdatingBuild(id.value, entry);
		else updatingRegistrations++;
		retainUpdatingState(entry);
	}

	/**
	 * Called with the root of each rebuilt subtree once a patch has put it in the tree. A patch builds outside the view, so a view
	 * wrapper that moves nodes after building (TooltipOverlayHost lifts tooltips) uses this to do the same for what the patch made.
	 */
	public var onPatched:Null<RenderNode->Void> = null;

	/** Rebuilds the pending self-updating widgets and reconciles them with the retained tree; runs after beginFrame, before the root builds. */
	public function applyPatches(?topology:RenderTreeTopology):Void {
		if (pendingPatches.length == 0)
			return;
		var work = pendingPatches;
		pendingPatches = [];
		for (entry in work) {
			var old = entry.root;
			// Unmounted since it was asked, or built again by an ancestor's rebuild, which owns it now.
			if (old == null || selfUpdatingBuilds.get(old.id.value) != entry) {
				entry.pending = false;
				entry.reactivePending = false;
				entry.forcePending = false;
				continue;
			}
			if (entry.reactivePending && !entry.forcePending && !updatingStatesChanged(entry)) {
				entry.pending = false;
				entry.reactivePending = false;
				continue;
			}
			entry.pending = false;
			entry.reactivePending = false;
			entry.forcePending = false;
			var savedScope = scope, savedParent = styleParent, savedStack = textStyleStack;
			scope = entry.scope;
			styleParent = entry.styleParent;
			// withTextStyle balances every push, including when the builder throws.
			textStyleStack = entry.textStyleStack;
			patching = true;
			try {
				var fresh = buildUpdating(entry);
				// The frame comparison walks the tree it is given, which now holds the result, so hand it what was replaced:
				// the old nodes below the root, and for the root a stand-in of how it was (or the root itself, if replaced).
				var inPlace = old.canReconcile(fresh);
				// The root of the whole tree has nothing to be put into: the next full build makes a new one.
				if (!inPlace && old.parent == null) {
					patching = false;
					scope = savedScope;
					styleParent = savedParent;
					textStyleStack = savedStack;
					continue;
				}
				recordPriors(old, old, inPlace);
				if (inPlace) {
					var before = old.reconcile(fresh, entry.built, topology);
					if (!patchPriors.exists(old.id.value))
						patchPriors.set(old.id.value, before);
				} else {
					// Not possible to reconcile: the new node takes its place, without what callers added to the old one.
					old.replaceWith(fresh);
					entry.root = fresh;
					entry.built = fresh.snapshotBuilt();
				}
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
			var patched = onPatched;
			if (patched != null && entry.root != null) patched(entry.root);
		}
	}

	/** Each reconciled build owns its current dependencies and resources, even when its enclosing cache stays unchanged. */
	function buildUpdating(entry:SelfUpdatingBuild, ?prior:UpdatingDependencies):RenderNode {
		var previousObserved = activeObserved;
		var capture = previousObserved == observed ? localObserved : previousObserved;
		var previousUpdater = activeUpdatingBuild;
		activeObserved = capture;
		activeUpdatingBuild = entry;
		var stateMark = stateStore.beginUsage();
		var dependencyMark = capture.dependencyMarker();
		var registrationMark = updatingRegistrations;
		var previous = entry.dependencies == null ? prior : entry.dependencies;
		try {
			var root = trackReads(entry.build);
			entry.buildRevision++;
			var usedStates = stateUsageMarker() == stateMark ? null : stateIdsUsedSince(stateMark, previous == null ? null : previous.stateIds);
			var hasReads = capture.pendingCount() != dependencyMark;
			var children = updatingRegistrations == registrationMark ? null : new InteractionStateSnapshot(root, this, root);
			var reads = hasReads || previous != null && previous.observed != null
				? dependenciesSince(dependencyMark,
					previous == null ? null : previous.observed)
				: null;
			if (usedStates != null || reads != null || children != null || previous != null) {
				var dependencies = entry.dependencies == null ? new UpdatingDependencies() : entry.dependencies;
				var allStates = children == null ? usedStates : children.appendStateIds(usedStates, previous == null ? null : previous.allStateIds);
				if (!stateStore.frameActive && entry.root != null && !haxeon.Equality.equals(dependencies.allStateIds, allStates)) {
					requestBuildFeedback();
				}
				dependencies.stateIds = usedStates;
				dependencies.observed = reads;
				dependencies.children = children;
				dependencies.allStateIds = allStates;
				entry.dependencies = dependencies;
			}
			stateStore.finishUsage(stateMark);
			capture.truncate(dependencyMark);
			activeObserved = previousObserved;
			activeUpdatingBuild = previousUpdater;
			return root;
		} catch (error:Dynamic) {
			stateStore.finishUsage(stateMark);
			capture.truncate(dependencyMark);
			activeObserved = previousObserved;
			activeUpdatingBuild = previousUpdater;
			throw error;
		}
	}

	public function updatingStatesChanged(entry:SelfUpdatingBuild):Bool {
		var dependencies = entry.dependencies;
		if (dependencies == null) return false;
		if (dependencies.observed != null && dependencies.observed.trackedSourcesDirty()) return true;
		return dependencies.children != null && dependencies.children.statesChanged(this);
	}

	/** Hidden dock caches keep the latest patched resources alive without rearming unmounted widgets. */
	public function retainUpdatingState(entry:SelfUpdatingBuild):Void {
		var dependencies = entry.dependencies;
		if (dependencies == null) return;
		// A nested updater can change its own state IDs during an in-place patch. Refresh the flattened owner list from
		// the live child entries before retaining a cached subtree, so removed resource states are not kept by stale parents.
		dependencies.allStateIds = dependencies.children == null ? dependencies.stateIds :
			dependencies.children.appendStateIds(dependencies.stateIds, dependencies.allStateIds);
		if (dependencies.allStateIds != null)
			stateStore.retain(dependencies.allStateIds, false);
	}

	/** Keeps the nodes of `node`'s subtree as priors for the frame comparison, except `root` itself when `skipRoot`. */
	function recordPriors(node:RenderNode, root:RenderNode, skipRoot:Bool):Void {
		if ((node != root || !skipRoot) && !patchPriors.exists(node.id.value))
			patchPriors.set(node.id.value, node);
		for (child in node.children)
			recordPriors(child, root, skipRoot);
	}

	/** Nodes of the submitted tree changed directly since it was submitted, with how each looked before; see willEditRetained. */
	final retainedEdits:Array<RenderNode> = [];
	var retainedEditEpoch:Int = 0;
	final retainedEditCaches:Map<Int, RetainedEditCache> = new Map();
	final retainedEditCacheIds:Array<Int> = [];

	/** Start the lifetime of geometry feedback priors after event edits for this submission have been captured. */
	public function beginLayoutSubmission():Void
		retainedEditEpoch++;
	final retainedEditPriors:Array<RenderNode> = [];
	/** Bumped by each first edit of a node between frames; a different value from the submitted one means a frame is due. */
	public var retainedEditRevision(default, null):Int = 0;

	/**
	 * Call just before changing a node of the submitted tree in place, outside a build: its style, hit testing or paint. The next
	 * frame compares the node against how it was now and lays out and paints the change, without rebuilding the view. Repeated
	 * calls for the same node before that frame keep the first state.
	 */
	public function willEditRetained(node:RenderNode):Void {
		if (retainedEdits.indexOf(node) >= 0)
			return;
		retainedEdits.push(node);
		retainedEditPriors.push(captureEditPrior(node, retainedEditEpoch));
		retainedEditRevision++;
	}

	/** Input normalization runs after fingerprint checks, but its prior still belongs to the pre-feedback phase. */
	public function comparisonPrior(node:RenderNode):RenderNode
		return captureEditPrior(node, retainedEditEpoch - 1);

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
	public function editAnnounced(node:RenderNode):Bool
		return retainedEdits.indexOf(node) >= 0;

	public var hasRetainedEdits(get, never):Bool;
	inline function get_hasRetainedEdits():Bool
		return retainedEdits.length > 0;

	/** Hands the frame comparison the prior state of edited nodes still in the submitted tree, and forgets the rest. */
	public function takeRetainedEdits(mounted:Map<Int, RenderNode>):Void {
		for (index in 0...retainedEdits.length) {
			var node = retainedEdits[index];
			if (mounted.get(node.id.value) == node && !patchPriors.exists(node.id.value))
				patchPriors.set(node.id.value, retainedEditPriors[index]);
		}
		retainedEdits.resize(0);
		retainedEditPriors.resize(0);
	}

	/** The nodes patches replaced this frame, by ID, so the frame comparison can see what changed. */
	public function patchedPriors():Map<Int, RenderNode>
		return patchPriors;

	public function endPatchFrame():Void
		patchPriors.clear();

	function registerSelfUpdatingBuild(id:Int, entry:SelfUpdatingBuild):Void {
		if (!selfUpdatingBuilds.exists(id)) selfUpdatingIds.push(id);
		selfUpdatingBuilds.set(id, entry);
		updatingRegistrations++;
	}

	/** Retire builders whose widgets are absent from the committed render tree. */
	public function pruneSelfUpdatingBuilds(mounted:Map<Int, RenderNode>):Void {
		var cacheIndex = 0;
		while (cacheIndex < retainedEditCacheIds.length) {
			var id = retainedEditCacheIds[cacheIndex];
			if (mounted.exists(id)) { cacheIndex++; continue; }
			retainedEditCaches.remove(id);
			retainedEditCacheIds[cacheIndex] = retainedEditCacheIds[retainedEditCacheIds.length - 1];
			retainedEditCacheIds.pop();
		}
		var removed = false;
		var index = 0;
		while (index < selfUpdatingIds.length) {
			var id = selfUpdatingIds[index];
			if (mounted.exists(id)) {
				index++;
				continue;
			}
			var entry:SelfUpdatingBuild = cast selfUpdatingBuilds.get(id);
			entry.pending = false;
			// The node may still be held by a retained cache, which registers the build again on reuse (rearm).
			selfUpdatingBuilds.remove(id);
			selfUpdatingIds[index] = selfUpdatingIds[selfUpdatingIds.length - 1];
			selfUpdatingIds.pop();
			removed = true;
		}
		if (removed)
			pendingPatches = [for (entry in pendingPatches) if (entry.pending) entry];
	}

	/** Cache identities only for the committed tree and retained application state. */
	/**
	 * Drops the cached IDs and key paths of widgets that are no longer mounted. `mountedHash` summarizes which nodes are
	 * mounted (any hash of their IDs in tree order will do). A cache entry only becomes stale when the mounted nodes change,
	 * so with the same hash and the same cached IDs since the last walk there is nothing to find, and the walk, which hashes
	 * the path of every cached key, is skipped. Scopes that hold no widget are created and dropped again by a build, a few
	 * every frame, and are left until `SCOPE_GROWTH_PRUNE` of them have collected: they only cache path strings. A change that
	 * goes unnoticed (a hash collision, or state released for a widget that stays unmounted) only leaves an entry cached until
	 * the next change.
	 */
	public function pruneKeyCaches(mounted:Map<Int, RenderNode>, mountedHash:Int):Void {
		var scopeEntries = rootScope.cachedEntries();
		if (mountedHash == prunedMountedHash && cachedIdCount == prunedIdCount && scopeEntries >= prunedScopeEntries
			&& scopeEntries - prunedScopeEntries < SCOPE_GROWTH_PRUNE)
			return;
		keyCachePrunes++;
		var read = 0, write = 0;
		while (read < pathOrder.length) {
			var path = pathOrder[read++];
			var id = idsByPath.get(path);
			if (id == null)
				continue;
			if (!mounted.exists(id.value) && !stateStore.contains(id)) {
				idsByPath.remove(path);
				cachedIdCount--;
			} else
				pathOrder[write++] = path;
		}
		pathOrder.resize(write);
		rootScope.prune(function(path) return idsByPath.exists(path));
		prunedMountedHash = mountedHash;
		prunedIdCount = cachedIdCount;
		prunedScopeEntries = rootScope.cachedEntries();
	}

	/** Drops the self-updating builders, which hold the build closures of the retained tree; the next frame builds afresh. */
	public function releaseRetained():Void {
		clearCommandFlags();
		retainedEditCaches.clear();
		retainedEditCacheIds.resize(0);
		retainedEdits.resize(0);
		retainedEditPriors.resize(0);
		// Builds that retained caches still hold were made by the code being released; they must not come back.
		updatingEpoch++;
		for (entry in selfUpdatingBuilds) {
			if (entry.dependencies != null && entry.dependencies.observed != null)
				entry.dependencies.observed.dispose();
			entry.root = null;
			entry.pending = false;
		}
		selfUpdatingBuilds.clear();
		selfUpdatingIds.resize(0);
		pendingPatches = [];
		patchPriors.clear();
		rootDependencies.clearDependencies();
	}

	/** Releases builders and pending patches when the owning UI context is disposed. */
	public function dispose():Void {
		clearCommandFlags();
		retainedEditCaches.clear();
		retainedEditCacheIds.resize(0);
		for (entry in selfUpdatingBuilds)
			if (entry.dependencies != null && entry.dependencies.observed != null)
				entry.dependencies.observed.dispose();
		rootDependencies.dispose();
		selfUpdatingBuilds.clear();
		selfUpdatingIds.resize(0);
		pendingPatches = [];
		patchPriors.clear();
	}

	/** A retained subtree whose root was rebuilt in place since the cache saw it must return the replacement, not the old node. */
	public function currentRoot(root:RenderNode):RenderNode
		return RenderNode.latest(root);

	public function withScope<T>(key:Key, build:Void->T):T
		return withScopeUnder(scope, key, build);

	/** The scope widgets built now are keyed under; withScopeUnder keys a deeper subtree by it. */
	public function currentScope():KeyScope
		return scope;

	/**
		Builds under `base`'s child `key` rather than the current scope's, so a subtree placed anywhere below `base`
		keeps one identity, and its state, wherever it moves. Keys must be unique among the subtrees built under `base`.
	**/
	public function withScopeUnder<T>(base:KeyScope, key:Key, build:Void->T):T {
		if (base == null || key == null || build == null)
			throw "A scoped build requires a scope, a key and a callback";
		var previous = scope;
		scope = base.child(key);
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
		return stateStore.handle(id);
	}

	/** Like `state`, but calls `create` only when the state is first initialized, so later builds allocate no discarded value. */
	public function lazyState<T>(id:WidgetId, create:Void->T):State<T> {
		if (stateStore.contains(id))
			stateStore.touch(id);
		else
			stateStore.initialize(id, create());
		return stateStore.handle(id);
	}

	/** Captures state usage so a retained subtree can keep its resources mounted. */
	public function stateUsageMarker():Int
		return stateStore.usageMarker();

	/** Signal and observable-field reads captured by the current frame. */
	final observed:Dependencies = new Dependencies(true);
	/** A nested read log for self-updating builds; root caches must not subscribe to their local state. */
	final localObserved:Dependencies = new Dependencies(true);
	var activeObserved:Dependencies;
	var activeUpdatingBuild:Null<SelfUpdatingBuild>;
	/** Root subscription schedules a frame for any signal read in the mounted tree. */
	final rootDependencies:Dependencies = new Dependencies();

	/** Runs a build or getter as a read-only reactive tracking scope. */
	public function trackReads<T>(run:Void->T):T
		return ReactiveRuntime.withTracking(activeObserved, run);

	/** Marks the current dependency log for a retained subtree. */
	public function dependencyMarker():Int
		return activeObserved.dependencyMarker();

	/** Captures tracked reads since the marker into a reusable retained dependency record. */
	public function dependenciesSince(marker:Int, ?target:Dependencies):Dependencies {
		var result = target == null ? new Dependencies() : target;
		result.replaceSlice(activeObserved, marker);
		result.setInvalidationOwner(this, activeUpdatingBuild);
		return result;
	}

	/** Replaces the root subscriptions after a successful full build. */
	public function captureRootDependencies():Void {
		rootDependencies.replaceSlice(observed, 0);
		observed.markClean();
		reactiveBuildPending = false;
	}

	public function rootDependenciesDirty():Bool
		return reactiveBuildPending || rootDependencies.dirty;

	/** Records a reused subtree's reads again, so an enclosing cache depends on them too. */
	public function retainDependencies(dependencies:Dependencies):Void {
		dependencies.setInvalidationOwner(this, activeUpdatingBuild);
		activeObserved.addAll(dependencies);
	}

	/** Called as a frame starts: the log only links reads to the subtrees built in one frame. */
	public function resetObserved():Void {
		observed.clear();
		localObserved.clear();
	}


	/** Returns state IDs touched after a retained subtree build marker. */
	public function stateIdsUsedSince(marker:Int, ?previous:Array<Int>):Array<Int>
		return stateStore.usedIdsSince(marker, previous);

	/** Keeps state-backed resources alive for a retained subtree this frame. */
	public function retainStateIds(ids:Array<Int>, bubbleToEnclosingBuild:Bool = false):Void
		stateStore.retain(ids, bubbleToEnclosingBuild || activeUpdatingBuild == null);

	/** Claims IDs belonging to a retained render subtree without rebuilding it. */
	public function claimRetainedTree(root:RenderNode):Void {
		if (root == null)
			throw "A retained render subtree is required";
		// As for id(), a patch's IDs are claimed with its completed retained tree.
		if (patching) return;
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
		return stateStore.handle(id);
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
		var result:State<Dynamic> = stateStore.handle(id);
		return cast result;
	}

	static inline function finite(value:Float):Bool
		return value == value && value - value == 0.0;
}

/** How a self-updating widget rebuilds; retained caches hold the ones in their subtree (see InteractionStateSnapshot). */
class SelfUpdatingBuild {
	public final idValue:Int;
	public final build:Void->RenderNode;
	public final scope:KeyScope;
	public final styleParent:Null<ComputedStyle>;
	public final textStyleStack:Array<ResolvedTextStyle>;
	public var dependencies:Null<UpdatingDependencies>;
	public var root:Null<RenderNode> = null;
	public var pending:Bool = false;
	public var reactivePending:Bool = false;
	public var forcePending:Bool = false;
	public var buildsFromHover:Bool = true;
	public var epoch:Int = 0;
	/** Advances for every completed build, including quiet in-place patches. */
	public var buildRevision:Int = 0;
	/** What the builder last made on `root`, before callers decorated it: rebuilds replace just that (RenderNode.reconcile). */
	public var built:Null<BuiltNode> = null;

	public function new(id:WidgetId, build:Void->RenderNode, scope:KeyScope, styleParent:Null<ComputedStyle>, textStyleStack:Array<ResolvedTextStyle>) {
		this.idValue = id.value;
		this.build = build;
		this.scope = scope;
		this.styleParent = styleParent;
		this.textStyleStack = textStyleStack;
	}
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
			var previous = prior; prior = spare; spare = previous;
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

/** Dependencies of a composite or stateful updater; leaf controls need no additional capture record. */
class UpdatingDependencies {
	public var allStateIds:Null<Array<Int>>;
	public var stateIds:Null<Array<Int>>;
	public var observed:Null<Dependencies>;
	public var children:Null<InteractionStateSnapshot>;
	public function new() {}
}
