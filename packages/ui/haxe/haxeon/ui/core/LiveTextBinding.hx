package haxeon.ui.core;

import haxeon.reactive.ReactiveDependencySet;
import haxeon.reactive.ReactiveRuntime;

/** Internal dependency owner for BoundText; mounted getters run after structural updates. */
class LiveTextBinding extends ReactiveDependencySet {
  final context:BuildContext;
  var read:Void -> String;
  var node:Null<LiveTextNode>;
  var attached = false;
  var disposed = false;
  var pending = false;

  public var value(default, null):String = "";

  public function new(read:Void -> String, context:BuildContext) {
    super();
    this.read = read;
    this.context = context;
    try evaluate() catch (error:Dynamic) {
      disposed = true;
      clearDependencies();
      throw error;
    }
    context.registerTextBinding(this);
  }

  function readTracked():String {
    var frame = ReactiveRuntime.enterTracking(this);
    try {
      var result = read();
      ReactiveRuntime.leaveTracking(frame);
      return result;
    } catch (error:Dynamic) {
      ReactiveRuntime.leaveTracking(frame);
      throw error;
    }
  }

  function evaluate():Void {
    beginDependencies();
    try {
      var next = readTracked();
      finishDependencies();
      if (next == null) next = "";
      if (value != next) {
        value = next;
        if (node != null) node.setText(next);
      }
      pending = false;
    } catch (error:Dynamic) {
      failDependencies();
      throw error;
    }
  }

  public function rebind(next:Void -> String):Void {
    if (!attached) {
      read = next;
      return;
    }
    var previousNode = node, previousRead = read;
    node = null;
    read = next;
    try evaluate() catch (error:Dynamic) {
      node = previousNode;
      read = previousRead;
      try evaluate() catch (_:Dynamic) {
      }
      throw error;
    }
  }

  public function attach(next:LiveTextNode):Void {
    node = next;
    attached = true;
  }

  public function flush(root:RenderNode):Void {
    if (disposed || node == null || !context.attachedToRoot(node, root)) return;
    try {
      if (dirty) evaluate();
      pending = false;
    } catch (error:Dynamic) {
      markFailed();
      throw error;
    }
  }

  override public function onMaybeStale():Void {
    if (!disposed) {
      pending = true;
      context.requestBindingFrame();
    }
  }

  public function retryAfterFailedFrame():Void {
    // The parent can throw before this phase runs. Keep later source writes able to wake the host.
    if (pending && !disposed) markFailed();
  }

  public function dispose():Void {
    if (disposed) return;
    disposed = true;
    node = null;
    clearDependencies();
    context.unregisterTextBinding(this);
  }
}
