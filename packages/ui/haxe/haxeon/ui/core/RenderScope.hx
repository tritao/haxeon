package haxeon.ui.core;

import haxeon.reactive.ReactiveDependencySet;
import haxeon.reactive.ReactiveRuntime;

/** A structural computation owned by a stable wrapper in the render tree. */
class RenderScope extends ReactiveDependencySet {
	public final root:RenderNode;
	@:allow(haxeon.ui.core.BuildContext)
	var stateIds:Null<Array<Int>>;
	@:allow(haxeon.ui.core.BuildContext)
	var parentScope:Null<RenderScope>;
	@:allow(haxeon.ui.core.BuildContext)
	var resourceId:WidgetId;
	@:allow(haxeon.ui.core.BuildContext)
	var mounted:Bool = true;
	@:allow(haxeon.ui.core.BuildContext)
	var build:Void->RenderNode;
	final schedule:Void->Void;
	final beforeChange:RenderNode->Void;
	var child:Null<RenderNode>;
	public var disposed(default, null):Bool = false;
	public var pending(default, null):Bool = false;
	var validating:Bool = false;

	public function new(root:RenderNode, build:Void->RenderNode, schedule:Void->Void,
			beforeChange:RenderNode->Void) {
		super();
		if (root == null || build == null || schedule == null || beforeChange == null)
			throw "A render scope requires a root, body, scheduler and change observer";
		this.root = root;
		this.build = build;
		this.schedule = schedule;
		this.beforeChange = beforeChange;
	}

	/** Checks derived inputs before running; unchanged inputs leave the tree untouched. */
	public function refresh():Void {
		pending = false;
		if (disposed) return;
		validating = true;
		try {
			if (!dirty) { validating = false; return; }
		} catch (error:Dynamic) {
			validating = false;
			throw error;
		}
		validating = false;
		var slot = child == null ? root.children.length : root.children.indexOf(child);
		if (slot < 0) throw "A render scope lost its body child";
		beginDependencies();
		try {
			if (child != null) beforeChange(root);
			var next = ReactiveRuntime.withTracking(this, build);
			if (next == null || next.parent != null && !(next == child && next.parent == root))
				throw "A render scope body must produce an unparented node";
			if (child == null) root.add(next);
			else if (child.parent != root) root.insertChild(slot, next);
			else if (next != child) {
				root.replaceChild(child, next);
			}
			child = next;
			finishDependencies();
		} catch (error:Dynamic) {
			if (child != null && child.parent != root) {
				child.detach();
				root.insertChild(slot, child);
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
		if (disposed || pending || validating) return;
		pending = true;
		schedule();
	}

	public function dispose():Void {
		if (disposed) return;
		disposed = true;
		pending = false;
		clearDependencies();
	}

	/** A parent rerun may remove this body before its pending work is visited. */
	public function attached():Bool {
		if (disposed) return false;
		var owner = parentScope;
		if (owner == null) return true;
		if (!owner.attached()) return false;
		var ancestor = root.parent;
		while (ancestor != null) {
			if (ancestor == owner.root) return true;
			ancestor = ancestor.parent;
		}
		return false;
	}
}

/** A state-store resource anchors a scope across temporary panel detachment. */
class RenderScopeLifetime {
	var owner:Null<RenderScope>;
	public function new() {}
	public function replace(next:RenderScope):Void {
		if (owner != null && owner != next) owner.dispose();
		owner = next;
	}
	public function dispose():Void {
		if (owner != null) owner.dispose();
		owner = null;
	}
}
