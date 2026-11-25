package haxeon.ui.widgets.navigation;

import haxeon.ui.animation.AnimationController;
import haxeon.ui.core.View;

/**
 * The screens of a NavigationStack: the last entry is shown. Changes bump `revision`; the stack rebuilds when the
 * application's next frame builds it, and plays a 220 ms slide for pushes and pops.
 *
 * Back: the kit's build context cannot reach `UiHostContext`, so the application forwards a Back request with
 * `hostContext.onBack = controller.handleBack` (or calls it from its own handler after closing sheets and menus).
 */
class NavigationController {
	public var entries(default, null):Array<NavigationEntry>;
	public var revision(default, null):Int;

	/** Transition in flight: 1 push, -1 pop, 0 none. Read by NavigationStack. */
	public var transitionKind(default, null):Int;
	/** The screen that was on top before the change; it slides out on a pop and stays beneath on a push. */
	public var transitionFrom(default, null):Null<NavigationEntry>;
	/** Eased 0..1 progress of the transition in flight. */
	public var transitionProgress:Float;
	/** The revision whose transition the stack has already started. */
	public var startedRevision:Int;
	/** Running slide, kept so a new change can stop it. */
	public var motion:Null<AnimationController>;

	public function new(root:NavigationEntry) {
		if (root == null) throw "A navigation controller requires a root entry";
		check(root);
		entries = [root];
		revision = 0;
		transitionKind = 0;
		transitionFrom = null;
		transitionProgress = 1.0;
		startedRevision = 0;
		motion = null;
	}

	public var depth(get, never):Int;

	function get_depth():Int return entries.length;

	public var top(get, never):NavigationEntry;

	function get_top():NavigationEntry return entries[entries.length - 1];

	/** Shows `entry` on top, sliding in from the right. */
	public function push(entry:NavigationEntry):Void {
		check(entry);
		beginTransition(1, top);
		entries.push(entry);
	}

	/** Removes the top screen; false at the root. */
	public function pop():Bool {
		if (entries.length <= 1) return false;
		beginTransition(-1, top);
		entries.pop();
		return true;
	}

	/** Back request: pops when there is more than one screen and reports whether it consumed the request. */
	public function handleBack():Bool return pop();

	/** Replaces every screen by `entry`, without a slide. */
	public function replaceRoot(entry:NavigationEntry):Void {
		check(entry);
		endTransition();
		entries = [entry];
		revision++;
		startedRevision = revision;
	}

	/** Called by the stack when a slide ends. */
	public function endTransition():Void {
		if (motion != null) motion.stop();
		motion = null;
		transitionKind = 0;
		transitionFrom = null;
		transitionProgress = 1.0;
	}

	function beginTransition(kind:Int, from:NavigationEntry):Void {
		endTransition();
		transitionKind = kind;
		transitionFrom = from;
		transitionProgress = 0.0;
		revision++;
	}

	static function check(entry:NavigationEntry):Void {
		if (entry == null || entry.id == null || entry.id.length == 0 || entry.build == null)
			throw "Navigation entries require an id and a builder";
	}
}

/** One screen in a NavigationStack: a stable id and a builder for its content. */
typedef NavigationEntry = {
	id:String,
	build:Void->View
};
