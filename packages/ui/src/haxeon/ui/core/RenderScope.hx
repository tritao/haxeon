package haxeon.ui.core;

import haxeon.reactive.ReactiveDependencySet;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.style.ComputedStyle;

import haxeon.ui.core.Key;
import haxeon.ui.core.LiveTextBinding;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.WidgetId;
/** A structural computation whose identity is its actual body root. */
internal class RenderScope extends ReactiveDependencySet implements Disposable {
	public var root(default, null):RenderNode;

	var boundary:ScopeRootBoundary;
	@:allow(haxeon.ui.core.BuildContext) var parentScope:Null<RenderScope>;

	/** The instance whose body is mounted: its reads are this scope's subscriptions. */
	public final component:ScopeView;

	/** The newest equal description of it, whose callbacks a kept body calls. */
	public var latest(default, null):ScopeView;

	public var capturedScope(default, null):KeyScope;
	public var capturedParent(default, null):Null<ComputedStyle>;
	public var capturedText(default, null):Array<ResolvedTextStyle>;

	/** The style revision and viewport the body last ran with: a parent's equal description reuses it only under these. */
	@:allow(haxeon.ui.core.BuildContext) var builtStyleRevision:Int = 0;

	@:allow(haxeon.ui.core.BuildContext) var builtWidth:Float = 0.0;
	@:allow(haxeon.ui.core.BuildContext) var builtHeight:Float = 0.0;

	final context:BuildContext;

	public final resourceId:ScopeResourceId;
	public final identityId:Int;

	@:allow(haxeon.ui.core.BuildContext) var mounted:Bool = true;

	public var disposed(default, null):Bool = false;
	public var pending(default, null):Bool = false;

	@:allow(haxeon.ui.core.UiContext) var builtEpoch:Int = 0;

	/** What the caller adds to the root, applied after each body run; `applied` takes it off again. */
	var modifier:Null<RootModifier> = null;

	var applied:Null<AppliedModifier> = null;

	public function new(resourceId:ScopeResourceId,
			identityId:Int,
			context:BuildContext,
			component:ScopeView,
			scope:KeyScope,
			parent:Null<ComputedStyle>,
			text:Array<ResolvedTextStyle>) {
		super();
		if (resourceId.rawValue <= 0 || identityId <= 0 || context == null
			|| component == null) throw "A render scope requires an identity, lifetime, context and component";
		this.resourceId = resourceId;
		this.identityId = identityId;
		this.context = context;
		this.component = component;
		latest = component;
		capturedScope = scope;
		capturedParent = parent;
		capturedText = text;
	}

	/** Caller-added overlays belong to the caller, rather than this body's interaction reads. */
	public function owns(node:RenderNode):Bool return root != null && boundary.owns(node);

	/** Logical identity belongs to the store and scoped ID, without a separate identity-holder object. */
	public function sameSlot(other:RenderScope):Bool return context.stateStore == other.context.stateStore
		&& identityId == other.identityId;

	/** Old body references resolve through their logical native owners, never a global numeric-ID redirect. */
	public function currentRoot(previous:RenderNode):RenderNode {
		if (context.isBuildingRoot(previous)) return previous;
		var owner:Null<RenderScope> = this;
		while (owner != null) {
			if (owner.root == null) break;
			var current = owner.context.stateStore.scopeOwner(owner.resourceId);
			if (current != null && current == owner && current.root != null
				&& current.root != previous) return current.root;
			if (owner.root != null && owner.root != previous) return owner.root;
			owner = owner.parentScope;
			// Only forwarding scopes share this identity. An unchanged child must not resolve
			// to a physically different ancestor's root.
			if (owner != null && (owner.root == null || !owner.root.id.equals(previous.id))) break;
		}
		return previous;
	}

	/** Checks derived inputs before running; unchanged inputs leave the tree untouched. */
	public function mount(rootId:WidgetId):Void {
		if (root != null || rootId == null) throw "A native scope mounts one initial body";
		refreshBody(rootId);
	}

	public function refresh():Void {
		if (root == null) throw "A native scope must be mounted before refresh";
		refreshBody(root.id);
	}

	function refreshBody(rootId:WidgetId):Void {
		pending = false;
		if (disposed) return;
		pending = true;
		try {
			if (!dirty) {
				pending = false;
				return;
			}
		} catch (error:Dynamic) {
			pending = false;
			throw error;
		}
		pending = false;
		var previous = root;
		var parent = previous == null ? null : previous.parent;
		var slot = parent == null ? -1 : parent.children.indexOf(previous);
		// The body builds a fresh root: take the caller's modifiers off the old one, outermost first, so what moves to
		// the new root is only what earlier callers added by hand.
		if (previous != null) removeSharedModifiers(this, previous);
		beginDependencies();
		var next:Null<RenderNode> = null;
		try {
			if (previous != null) context.beforeRenderScopeChange(previous);
			next = context.buildRenderScope(this, rootId);
			if (next == null || !next.id.equals(rootId) || next.parent != null && !(next == previous
				&& next.parent == parent)) throw "A render scope body must produce its reserved, unparented root";
			var existing = next.scopeOwner();
			if (existing == null || existing.disposed || existing.sameSlot(this)) next.setScopeOwner(this);
			if (previous == null) boundary = new ScopeRootBoundary(next);
			else if (next != previous) {
				// Several scopes can forward the same physical body root: each records the new body as its own.
				var ancestor = parentScope;
				while (ancestor != null && ancestor.root == previous) {
					ancestor.boundary.reset(next);
					ancestor.root = next;
					ancestor = ancestor.parentScope;
				}
				boundary.reset(next);
				if (previous.parent != null) previous.parent.replaceChild(previous, next);
				else if (parent != null) parent.insertChild(slot, next);
			} else {
				boundary.reset(next);
				if (parent != null && next.parent == null) parent.insertChild(slot, next);
			}
			root = next;
			if (previous != null) applySharedModifiers(next);
			finishDependencies();
			builtEpoch = context.retainedEditEpoch;
		} catch (error:Dynamic) {
			if (previous != null && parent != null && previous.parent != parent) {
				previous.detach();
				parent.insertChild(slot, previous);
			}
			if (previous != null && root == previous) applySharedModifiers(previous);
			failDependencies();
			throw error;
		}
		// A rerun builds outside the enclosing view, like a patch: a view wrapper that moves nodes after building
		// (TooltipOverlayHost lifts tooltips) must see what the body made, or the new nodes and the ones it moved
		// before would carry one ID. The initial mount runs inside that view's build, which sees it.
		if (previous != null) context.renderScopeRebuilt(next);
	}

	/** What a caller changed on this root by hand, beside its modifier; null when nothing. */
	@:allow(haxeon.ui.core.BuildContext) function callerChanges():Null<String> {
		if (root == null || boundary == null) return null;
		if (applied != null) applied.remove();
		var change = boundary.callerChanges(root);
		applied = modifier == null ? null : modifier.apply(root);
		return change;
	}

	@:allow(haxeon.ui.core.BuildContext) function hasModifier():Bool return modifier != null;

	/** Replaces the caller's modifier, keeping the body. */
	@:allow(haxeon.ui.core.BuildContext) function setModifier(next:Null<RootModifier>):Void {
		if (applied != null) applied.remove();
		applied = null;
		modifier = next;
		if (next != null && root != null) applied = next.apply(root);
	}

	static function removeSharedModifiers(scope:RenderScope, shared:RenderNode):Void {
		var outer = scope.parentScope;
		if (outer != null && outer.root == shared) removeSharedModifiers(outer, shared);
		if (scope.applied != null) scope.applied.remove();
		scope.applied = null;
	}

	/** This scope's modifier, then each forwarding ancestor's, as their builds applied them. */
	function applySharedModifiers(node:RenderNode):Void {
		var scope:Null<RenderScope> = this;
		while (scope != null && scope.root == node) {
			if (scope.modifier != null) scope.applied = scope.modifier.apply(node);
			scope = scope.parentScope;
		}
	}

	override public function onMaybeStale():Void {
		requestRun();
	}

	override public function onInvalidated():Void {
		requestRun();
	}

	function requestRun():Void {
		if (disposed || pending) return;
		pending = true;
		context.requestBindingFrame();
	}

	/** Keeps the body for a parent run that described this component with equal inputs, under its context. */
	@:allow(haxeon.ui.core.BuildContext) function keep(description:ScopeView, scope:KeyScope,
			parent:Null<ComputedStyle>, text:Array<ResolvedTextStyle>):Void {
		latest = description;
		capturedScope = scope;
		capturedParent = parent;
		capturedText = text;
	}

	public function dispose():Void {
		if (disposed) return;
		disposed = true;
		pending = false;
		context.forgetScope(this);
		context.stateStore.releaseScope(this);
		clearDependencies();
	}

	/** Cached alternatives remain resources of their parent while temporarily absent from its visible root. */
	public function retainedByParent():Bool {
		var ancestor = parentScope;
		while (ancestor != null) {
			if (!ancestor.disposed && context.stateStore.ownsResource(ResourceId.scope(ancestor.resourceId),
				ResourceId.scope(resourceId))) return true;
			ancestor = ancestor.parentScope;
		}
		return false;
	}

	/** A parent rerun may remove this body before its pending work is visited. */
	public function attached(submittedRoot:Null<RenderNode>):Bool {
		return !disposed && context.attachedToRoot(root, submittedRoot);
	}
}

/** A component is its structural description; its native owner runs this body directly. */
interface ScopeView extends View {
	/** Identifies this component among its siblings: its state lives as long as each build gives it the same key. */
	function scopeKey():String;

	/** Whether `previous`, the description this one replaces, has the same inputs, so its body would build the same. */
	function inputsEqual(previous:ScopeView):Bool;

	/** Builds the component's content inside its own scope, which `BuildContext.mountComponent` opens for it. */
	function buildBody(context:BuildContext):RenderNode;
}

/** A component's actual body root carries its native owner; ordinary descendants carry no owner field. */
internal class ScopeRootNode extends RenderNode {
	var owner:RenderScope;

	public function new(id:WidgetId, kind:LayoutVisualKind, style:Null<LayoutStyle>, owner:RenderScope) {
		super(id, kind, style);
		this.owner = owner;
	}

	override public function scopeOwner():Null<RenderScope> return owner;
	override public function setScopeOwner(owner:RenderScope):Void this.owner = owner;
}

/** Live text keeps its submitted-value bookkeeping when it is also a component's body root. */
internal class ScopeTextRootNode extends LiveTextNode {
	var owner:RenderScope;

	public function new(id:WidgetId, style:LayoutStyle, value:String, owner:RenderScope) {
		super(id, style, value);
		this.owner = owner;
	}

	override public function scopeOwner():Null<RenderScope> return owner;
	override public function setScopeOwner(owner:RenderScope):Void this.owner = owner;
}

/** A component instance lifetime, independent of its widget identity. */
internal abstract ScopeResourceId(Int) {
	@:allow(haxeon.ui.core.StateStore) @:allow(haxeon.ui.core.ResourceId) inline function new(value:Int) this = value;

	public var rawValue(get, never):Int;

	inline function get_rawValue():Int
		return this;
}
