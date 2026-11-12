package haxeon.ui.core;

import haxeon.ui.LayoutStyle;
import haxeon.ui.semantics.Semantics;

/** The boundary between a component root and decorations added by its caller.
 * Stored by value on the native scope; it never reconciles or mutates the new body's contents. */
@:access(haxeon.ui.core.RenderNode)
struct ScopeRootBoundary {
  final style:LayoutStyle;
  final children:Array<RenderNode>;
  var semantics:Null<Semantics>;
  var styleOverrides:Int = 0;
  var semanticsOverride:Bool = false;
  var handlers:Int;
  var outside:Int;
  var resolved:Int;
  var paint:Int;
  var decorations:Int;

  public function new(root:RenderNode) {
    style = root.layout.style.copy();
    children = root.children.length == 0 ? [] : root.children.copy();
    semantics = root.semantics;
    handlers = root.handlers == null ? 0 : root.handlers.length;
    outside = root.outsidePointerDownHandlers == null ? 0 : root.outsidePointerDownHandlers.length;
    resolved = root.resolvedHandlers == null ? 0 : root.resolvedHandlers.length;
    paint = root.paintHandlers == null ? 0 : root.paintHandlers.length;
    decorations = root.decorations == null ? 0 : root.decorations.length;
  }

  /** Move only caller contributions, then remember the next body's boundary before those contributions. */
  public function transfer(previous:RenderNode, next:RenderNode):Void {
    if (previous == next) return;
    var nextHandlers = next.handlers == null ? 0 : next.handlers.length;
    var nextOutside = next.outsidePointerDownHandlers == null ? 0 : next.outsidePointerDownHandlers.length;
    var nextResolved = next.resolvedHandlers == null ? 0 : next.resolvedHandlers.length;
    var nextPaint = next.paintHandlers == null ? 0 : next.paintHandlers.length;
    var nextDecorations = next.decorations == null ? 0 : next.decorations.length;
    var nextSemantics = next.semantics;
    var nextChildren = next.children.length;
    transferStyle(previous.layout.style, next.layout.style);
    if (previous.semantics != semantics) semanticsOverride = true;
    if (semanticsOverride) next.semantics = previous.semantics;
    semantics = nextSemantics;
    next.handlers = appendTail(previous.handlers, handlers, next.handlers);
    next.outsidePointerDownHandlers = appendTail(previous.outsidePointerDownHandlers, outside, next.outsidePointerDownHandlers);
    next.resolvedHandlers = appendTail(previous.resolvedHandlers, resolved, next.resolvedHandlers);
    next.paintHandlers = appendTail(previous.paintHandlers, paint, next.paintHandlers);
    next.paintCacheKeys = appendTail(previous.paintCacheKeys, paint, next.paintCacheKeys);
    next.decorations = appendTail(previous.decorations, decorations, next.decorations);
    next.decorationCacheKeys = appendTail(previous.decorationCacheKeys, decorations, next.decorationCacheKeys);
    next.paintKeyResolved = false;
    var index = 0;
    while (index < previous.children.length) {
      var child = previous.children[index];
      if (owns(child)) { index++; continue; }
      child.detach();
      next.add(child);
    }
    children.resize(0);
    for (index in 0...nextChildren) children.push(next.children[index]);
    handlers = nextHandlers;
    outside = nextOutside;
    resolved = nextResolved;
    paint = nextPaint;
    decorations = nextDecorations;
  }

  public function owns(child:RenderNode):Bool {
    for (declared in children) {
      if (declared == child) return true;
      var owner = declared.scopeOwner();
      if (owner != null && owner.currentRoot(declared) == child) return true;
    }
    return false;
  }

  /** Forwarding scopes can share one physical root. Advance an ancestor's authored boundary
   * when an inner scope replaces that root, without claiming the ancestor's caller decorations. */
  public function rebase(inner:ScopeRootBoundary, next:RenderNode):Void {
    var after = next.layout.style;
    if (haxeon.Equality.equals(style.width, inner.style.width)) style.width = after.width;
    if (haxeon.Equality.equals(style.height, inner.style.height)) style.height = after.height;
    if (haxeon.Equality.equals(style.aspectRatio, inner.style.aspectRatio)) style.aspectRatio = after.aspectRatio;
    if (haxeon.Equality.equals(style.direction, inner.style.direction)) style.direction = after.direction;
    if (haxeon.Equality.equals(style.childAlignX, inner.style.childAlignX)) style.childAlignX = after.childAlignX;
    if (haxeon.Equality.equals(style.childAlignY, inner.style.childAlignY)) style.childAlignY = after.childAlignY;
    if (haxeon.Equality.equals(style.childDistribution, inner.style.childDistribution)) style.childDistribution = after.childDistribution;
    if (haxeon.Equality.equals(style.positioning, inner.style.positioning)) style.positioning = after.positioning;
    if (haxeon.Equality.equals(style.wrapMode, inner.style.wrapMode)) style.wrapMode = after.wrapMode;
    if (haxeon.Equality.equals(style.rowGap, inner.style.rowGap)) style.rowGap = after.rowGap;
    if (haxeon.Equality.equals(style.columnGap, inner.style.columnGap)) style.columnGap = after.columnGap;
    if (haxeon.Equality.equals(style.alignSelf, inner.style.alignSelf)) style.alignSelf = after.alignSelf;
    if (haxeon.Equality.equals(style.positionX, inner.style.positionX)) style.positionX = after.positionX;
    if (haxeon.Equality.equals(style.positionY, inner.style.positionY)) style.positionY = after.positionY;
    if (haxeon.Equality.equals(style.zIndex, inner.style.zIndex)) style.zIndex = after.zIndex;
    if (haxeon.Equality.equals(style.clipToParent, inner.style.clipToParent)) style.clipToParent = after.clipToParent;
    if (haxeon.Equality.equals(style.overlay, inner.style.overlay)) style.overlay = after.overlay;
    if (haxeon.Equality.equals(style.padding, inner.style.padding)) style.padding = after.padding;
    if (haxeon.Equality.equals(style.childGap, inner.style.childGap)) style.childGap = after.childGap;
    if (haxeon.Equality.equals(style.background, inner.style.background)) style.background = after.background;
    if (haxeon.Equality.equals(style.radiusTopLeft, inner.style.radiusTopLeft)) style.radiusTopLeft = after.radiusTopLeft;
    if (haxeon.Equality.equals(style.radiusTopRight, inner.style.radiusTopRight)) style.radiusTopRight = after.radiusTopRight;
    if (haxeon.Equality.equals(style.radiusBottomLeft, inner.style.radiusBottomLeft)) style.radiusBottomLeft = after.radiusBottomLeft;
    if (haxeon.Equality.equals(style.radiusBottomRight, inner.style.radiusBottomRight)) style.radiusBottomRight = after.radiusBottomRight;
    if (haxeon.Equality.equals(style.clipHorizontal, inner.style.clipHorizontal)) style.clipHorizontal = after.clipHorizontal;
    if (haxeon.Equality.equals(style.clipVertical, inner.style.clipVertical)) style.clipVertical = after.clipVertical;
    if (haxeon.Equality.equals(style.visible, inner.style.visible)) style.visible = after.visible;
    if (haxeon.Equality.equals(style.transform, inner.style.transform)) style.transform = after.transform;
    if (haxeon.Equality.equals(style.transformOriginX, inner.style.transformOriginX)) style.transformOriginX = after.transformOriginX;
    if (haxeon.Equality.equals(style.transformOriginY, inner.style.transformOriginY)) style.transformOriginY = after.transformOriginY;
    if (semantics == inner.semantics) semantics = next.semantics;
    handlers += (next.handlers == null ? 0 : next.handlers.length) - inner.handlers;
    outside += (next.outsidePointerDownHandlers == null ? 0 : next.outsidePointerDownHandlers.length) - inner.outside;
    resolved += (next.resolvedHandlers == null ? 0 : next.resolvedHandlers.length) - inner.resolved;
    paint += (next.paintHandlers == null ? 0 : next.paintHandlers.length) - inner.paint;
    decorations += (next.decorations == null ? 0 : next.decorations.length) - inner.decorations;
    for (child in inner.children) children.remove(child);
    for (index in 0...next.children.length) children.insert(index, next.children[index]);
  }

  /** Caller overrides belong to the scope until its caller builds it again.
   * Preserve their ownership when a later authored default happens to equal their value.
   * Per-field locals advance the baseline without an intermediate style allocation. */
  function transferStyle(previous:LayoutStyle, next:LayoutStyle):Void {
    styleOverrides |= haxeon.Diff.mask(style, previous);
    var authored_width = next.width;
    if ((styleOverrides & haxeon.Diff.bit(\LayoutStyle.width)) != 0) next.width = previous.width;
    style.width = authored_width;
    var authored_height = next.height;
    if ((styleOverrides & haxeon.Diff.bit(\LayoutStyle.height)) != 0) next.height = previous.height;
    style.height = authored_height;
    var authored_aspectRatio = next.aspectRatio;
    if ((styleOverrides & haxeon.Diff.bit(\LayoutStyle.aspectRatio)) != 0) next.aspectRatio = previous.aspectRatio;
    style.aspectRatio = authored_aspectRatio;
    var authored_direction = next.direction;
    if ((styleOverrides & haxeon.Diff.bit(\LayoutStyle.direction)) != 0) next.direction = previous.direction;
    style.direction = authored_direction;
    var authored_childAlignX = next.childAlignX;
    if ((styleOverrides & haxeon.Diff.bit(\LayoutStyle.childAlignX)) != 0) next.childAlignX = previous.childAlignX;
    style.childAlignX = authored_childAlignX;
    var authored_childAlignY = next.childAlignY;
    if ((styleOverrides & haxeon.Diff.bit(\LayoutStyle.childAlignY)) != 0) next.childAlignY = previous.childAlignY;
    style.childAlignY = authored_childAlignY;
    var authored_childDistribution = next.childDistribution;
    if ((styleOverrides & haxeon.Diff.bit(\LayoutStyle.childDistribution)) != 0) next.childDistribution = previous.childDistribution;
    style.childDistribution = authored_childDistribution;
    var authored_positioning = next.positioning;
    if ((styleOverrides & haxeon.Diff.bit(\LayoutStyle.positioning)) != 0) next.positioning = previous.positioning;
    style.positioning = authored_positioning;
    var authored_wrapMode = next.wrapMode;
    if ((styleOverrides & haxeon.Diff.bit(\LayoutStyle.wrapMode)) != 0) next.wrapMode = previous.wrapMode;
    style.wrapMode = authored_wrapMode;
    var authored_rowGap = next.rowGap;
    if ((styleOverrides & haxeon.Diff.bit(\LayoutStyle.rowGap)) != 0) next.rowGap = previous.rowGap;
    style.rowGap = authored_rowGap;
    var authored_columnGap = next.columnGap;
    if ((styleOverrides & haxeon.Diff.bit(\LayoutStyle.columnGap)) != 0) next.columnGap = previous.columnGap;
    style.columnGap = authored_columnGap;
    var authored_alignSelf = next.alignSelf;
    if ((styleOverrides & haxeon.Diff.bit(\LayoutStyle.alignSelf)) != 0) next.alignSelf = previous.alignSelf;
    style.alignSelf = authored_alignSelf;
    var authored_positionX = next.positionX;
    if ((styleOverrides & haxeon.Diff.bit(\LayoutStyle.positionX)) != 0) next.positionX = previous.positionX;
    style.positionX = authored_positionX;
    var authored_positionY = next.positionY;
    if ((styleOverrides & haxeon.Diff.bit(\LayoutStyle.positionY)) != 0) next.positionY = previous.positionY;
    style.positionY = authored_positionY;
    var authored_zIndex = next.zIndex;
    if ((styleOverrides & haxeon.Diff.bit(\LayoutStyle.zIndex)) != 0) next.zIndex = previous.zIndex;
    style.zIndex = authored_zIndex;
    var authored_clipToParent = next.clipToParent;
    if ((styleOverrides & haxeon.Diff.bit(\LayoutStyle.clipToParent)) != 0) next.clipToParent = previous.clipToParent;
    style.clipToParent = authored_clipToParent;
    var authored_overlay = next.overlay;
    if ((styleOverrides & haxeon.Diff.bit(\LayoutStyle.overlay)) != 0) next.overlay = previous.overlay;
    style.overlay = authored_overlay;
    var authored_padding = next.padding;
    if ((styleOverrides & haxeon.Diff.bit(\LayoutStyle.padding)) != 0) next.padding = previous.padding;
    style.padding = authored_padding;
    var authored_childGap = next.childGap;
    if ((styleOverrides & haxeon.Diff.bit(\LayoutStyle.childGap)) != 0) next.childGap = previous.childGap;
    style.childGap = authored_childGap;
    var authored_background = next.background;
    if ((styleOverrides & haxeon.Diff.bit(\LayoutStyle.background)) != 0) next.background = previous.background;
    style.background = authored_background;
    var authored_radiusTopLeft = next.radiusTopLeft;
    if ((styleOverrides & haxeon.Diff.bit(\LayoutStyle.radiusTopLeft)) != 0) next.radiusTopLeft = previous.radiusTopLeft;
    style.radiusTopLeft = authored_radiusTopLeft;
    var authored_radiusTopRight = next.radiusTopRight;
    if ((styleOverrides & haxeon.Diff.bit(\LayoutStyle.radiusTopRight)) != 0) next.radiusTopRight = previous.radiusTopRight;
    style.radiusTopRight = authored_radiusTopRight;
    var authored_radiusBottomLeft = next.radiusBottomLeft;
    if ((styleOverrides & haxeon.Diff.bit(\LayoutStyle.radiusBottomLeft)) != 0) next.radiusBottomLeft = previous.radiusBottomLeft;
    style.radiusBottomLeft = authored_radiusBottomLeft;
    var authored_radiusBottomRight = next.radiusBottomRight;
    if ((styleOverrides & haxeon.Diff.bit(\LayoutStyle.radiusBottomRight)) != 0) next.radiusBottomRight = previous.radiusBottomRight;
    style.radiusBottomRight = authored_radiusBottomRight;
    var authored_clipHorizontal = next.clipHorizontal;
    if ((styleOverrides & haxeon.Diff.bit(\LayoutStyle.clipHorizontal)) != 0) next.clipHorizontal = previous.clipHorizontal;
    style.clipHorizontal = authored_clipHorizontal;
    var authored_clipVertical = next.clipVertical;
    if ((styleOverrides & haxeon.Diff.bit(\LayoutStyle.clipVertical)) != 0) next.clipVertical = previous.clipVertical;
    style.clipVertical = authored_clipVertical;
    var authored_visible = next.visible;
    if ((styleOverrides & haxeon.Diff.bit(\LayoutStyle.visible)) != 0) next.visible = previous.visible;
    style.visible = authored_visible;
    var authored_transform = next.transform;
    if ((styleOverrides & haxeon.Diff.bit(\LayoutStyle.transform)) != 0) next.transform = previous.transform;
    style.transform = authored_transform;
    var authored_transformOriginX = next.transformOriginX;
    if ((styleOverrides & haxeon.Diff.bit(\LayoutStyle.transformOriginX)) != 0) next.transformOriginX = previous.transformOriginX;
    style.transformOriginX = authored_transformOriginX;
    var authored_transformOriginY = next.transformOriginY;
    if ((styleOverrides & haxeon.Diff.bit(\LayoutStyle.transformOriginY)) != 0) next.transformOriginY = previous.transformOriginY;
    style.transformOriginY = authored_transformOriginY;
  }

  static function appendTail<T>(previous:Null<Array<T>>, count:Int, next:Null<Array<T>>):Null<Array<T>> {
    if (previous == null || previous.length <= count) return next;
    if (next == null) next = [];
    for (index in count...previous.length) next.push(previous[index]);
    return next;
  }
}
