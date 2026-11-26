package haxeon.ui.core;

import haxeon.reactive.ReactiveDependencySet;
import haxeon.reactive.ReactiveRuntime;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.RenderNode;
import haxeon.ui.style.ComputedStyle;

/** Internal dependency owner for BoundText; mounted getters run after structural updates. */
internal class LiveTextBinding extends ReactiveDependencySet implements Disposable {
	final context:BuildContext;
	var read:Void->String;
	var node:Null<LiveTextNode>;
	var attached = false;
	var disposed = false;
	var pending = false;

	public var value(default, null):String = "";

	public function new(read:Void->String, context:BuildContext) {
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

	public function rebind(next:Void->String):Void {
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
			try evaluate() catch (_:Dynamic) {}
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

/** A text leaf owns its previous submitted value without a render-tree snapshot. */
@:access(haxeon.ui.core.RenderNode)
internal class LiveTextNode extends RenderNode {
	var submittedText:String;
	var announcedText:String;

	public function new(id:WidgetId, style:LayoutStyle, value:String) {
		super(id, LayoutVisualKind.Text, style);
		submittedText = value;
		announcedText = value;
	}

	public function setText(value:String):Void {
		announcedText = value;
		layout.text = value;
		if (semantics != null) semantics.label = value;
	}

	override public function submittedFingerprint():Int {
		if (layout.text != announcedText || semantics != null && semantics.label != announcedText) return fingerprint();
		return fingerprintText(submittedText, semantics == null ? null : submittedText);
	}

	override function syncRevisions(previous:Null<RenderNode>, diff:StyleDiff, accumulate:Bool = false):Void {
		var beforeText = previous == null ? layout.text : Std.isOfType(previous, LiveTextNode)
			? (cast previous:LiveTextNode).submittedText : previous.layout.text;
		var beforeContent = previous == null ? contentRevision : previous.contentRevision;
		var beforePaint = previous == null ? paintRevision : previous.paintRevision;
		var beforeGeometry = previous == null ? geometryRevision : previous.geometryRevision;
		super.syncRevisions(previous, diff, accumulate);
		if (beforeText != layout.text) {
			if (contentRevision == beforeContent) contentRevision++;
			if (paintRevision == beforePaint) paintRevision++;
			if (geometryRevision == beforeGeometry) geometryRevision++;
			paintKeyResolved = false;
			invalidationFlags |= UiDirtyFlag.NeedsTextLayout | UiDirtyFlag.NeedsLayout | UiDirtyFlag.NeedsPaint
				| UiDirtyFlag.NeedsSemantics;
		}
		submittedText = layout.text;
	}
}
