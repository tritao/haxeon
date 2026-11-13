package haxeon.ui.core;

import haxeon.reactive.ReactiveDependencySet;
import haxeon.ui.component.ScopeView;
import haxeon.ui.style.ComputedStyle;

/** A structural computation whose identity is its actual body root. */
class RenderScope extends ReactiveDependencySet {
  public var root(default, null):RenderNode;

  var boundary:ScopeRootBoundary;
  @:allow(haxeon.ui.core.BuildContext) var parentScope:Null<RenderScope>;

  public final component:ScopeView;
  public final capturedScope:KeyScope;
  public final capturedParent:Null<ComputedStyle>;
  public final capturedText:Array<ResolvedTextStyle>;

  final context:BuildContext;

  public final resourceId:Int;
  public final identityId:Int;

  @:allow(haxeon.ui.core.BuildContext) var mounted:Bool = true;

  public var disposed(default, null):Bool = false;
  public var pending(default, null):Bool = false;

  @:allow(haxeon.ui.core.UiContext) var builtEpoch:Int = 0;

  public function new(
    resourceId:Int,
    identityId:Int,
    context:BuildContext,
    component:ScopeView,
    scope:KeyScope,
    parent:Null<ComputedStyle>,
    text:Array<ResolvedTextStyle>
  ) {
    super();
    if (resourceId >= 0 || identityId <= 0 || context == null
      || component == null) throw "A render scope requires an identity, lifetime, context and component";
    this.resourceId = resourceId;
    this.identityId = identityId;
    this.context = context;
    this.component = component;
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
      if (current != null && current == owner && current.root != null && current.root != previous) return current.root;
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
    beginDependencies();
    try {
      if (previous != null) context.beforeRenderScopeChange(previous);
      var next = context.buildRenderScope(this, rootId);
      if (next == null || !next.id.equals(rootId) || next.parent != null && !(next == previous
        && next.parent == parent)) throw "A render scope body must produce its reserved, unparented root";
      var existing = next.scopeOwner();
      if (existing == null || existing.disposed || existing.sameSlot(this)) next.setScopeOwner(this);
      if (previous == null) boundary = new ScopeRootBoundary(next);
      else if (next != previous) {
        // Several scopes can forward the same physical body root. Advance each ancestor's
        // declared boundary before moving decorations, so none adopts caller-owned overlays.
        var ancestor = parentScope;
        while (ancestor != null && ancestor.root == previous) {
          ancestor.boundary.rebase(boundary, next);
          ancestor.root = next;
          ancestor = ancestor.parentScope;
        }
        boundary.transfer(previous, next);
        if (previous.parent != null) previous.parent.replaceChild(previous, next);
        else if (parent != null) parent.insertChild(slot, next);
      } else if (parent != null && next.parent == null) parent.insertChild(slot, next);
      root = next;
      finishDependencies();
      builtEpoch = context.retainedEditEpoch;
    } catch (error:Dynamic) {
      if (previous != null && parent != null && previous.parent != parent) {
        previous.detach();
        parent.insertChild(slot, previous);
      }
      failDependencies();
      throw error;
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

  public function dispose():Void {
    if (disposed) return;
    disposed = true;
    pending = false;
    context.stateStore.releaseScope(this);
    clearDependencies();
  }

  /** Cached alternatives remain resources of their parent while temporarily absent from its visible root. */
  public function retainedByParent():Bool {
    var ancestor = parentScope;
    while (ancestor != null) {
      if (!ancestor.disposed && context.stateStore.ownsResource(ancestor.resourceId, resourceId)) return true;
      ancestor = ancestor.parentScope;
    }
    return false;
  }

  /** A parent rerun may remove this body before its pending work is visited. */
  public function attached(submittedRoot:Null<RenderNode>):Bool {
    return !disposed && context.attachedToRoot(root, submittedRoot);
  }
}
