package nativekit.ui.widgets.text;

import ResolvedLayoutItem;
import nativekit.ui.animation.Animation;
import nativekit.ui.animation.AnimationHandle;
import nativekit.ui.animation.AnimationScheduler;

/** Keeps selection scrolling while a captured pointer remains near a viewport edge. */
class SelectionDragController implements Animation {
	var scheduler:AnimationScheduler;
	var editor:TextEditorState;
	var geometry:Void->Null<ResolvedLayoutItem>;
	var selectAt:(Float, Float)->Void;
	var scroll:Float->Bool;
	var handle:Null<AnimationHandle>;
	var x:Float = 0.0;
	var y:Float = 0.0;

	public function new() {}

	public function configure(scheduler:AnimationScheduler, editor:TextEditorState,
			geometry:Void->Null<ResolvedLayoutItem>, selectAt:(Float, Float)->Void, scroll:Float->Bool):Void {
		this.scheduler = scheduler;
		this.editor = editor;
		this.geometry = geometry;
		this.selectAt = selectAt;
		this.scroll = scroll;
	}

	public function update(x:Float, y:Float):Void {
		this.x = x; this.y = y;
		if (velocity() == 0.0) stop();
		else if (handle == null || !handle.active) handle = scheduler.track(this);
	}

	function velocity():Float {
		var bounds = geometry();
		if (bounds == null || bounds.clipBounds.height <= 0.0) return 0.0;
		var clip = bounds.clipBounds;
		var margin = Math.min(16.0, clip.height / 4.0);
		var distance = y < clip.y + margin ? y - clip.y - margin :
			y > clip.y + clip.height - margin ? y - clip.y - clip.height + margin : 0.0;
		return Math.max(-600.0, Math.min(600.0, distance * 12.0));
	}

	public function advance(deltaSeconds:Float):Bool {
		if (editor.isDisposed() || !editor.draggingSelection) return false;
		var speed = velocity();
		if (speed == 0.0) return false;
		if (deltaSeconds <= 0.0) return true;
		if (!scroll(speed * Math.min(deltaSeconds, 0.1))) return false;
		selectAt(x, y);
		return true;
	}

	public function stop():Void {
		if (handle != null) handle.cancel();
		handle = null;
	}

	public function dispose():Void stop();
}
