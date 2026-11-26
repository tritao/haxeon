package haxeon.ui.docking;

import Observable;
import haxeon.ui.icons.IconName;

/** Persistent, view-independent description of one editor workspace region. */
enum DockNode {
	/** No panels. */
	Empty;
	/** One panel on its own. */
	Panel(panelId:String);
	/** Panels sharing a tab strip, with one active. */
	Tabs(panelIds:Array<String>, activePanelId:String);
	/** Two regions side by side or stacked; `ratio` is the first one's share. */
	Split(axis:DockSplitAxis, ratio:Float, first:DockNode, second:DockNode);

	/** A deep copy of this layout. */
	public function clone():DockNode {
		return switch (this) {
			case Empty: Empty;
			case Panel(id): Panel(id);
			case Tabs(ids, active): Tabs(ids == null ? [] : ids.copy(), active);
			case Split(axis, ratio, first, second):
				Split(axis, ratio, first.clone(), second.clone());
		};
	}

	/** Copies a layout while omitting selected panels, normalizing each node in the same traversal. */
	public function copyExcluding(excluded:Array<String>):DockNode {
		return switch this {
			case Empty: Empty;
			case Panel(id): id == null || id.length == 0 || containsId(excluded, id) ? Empty : Panel(id);
			case Tabs(ids, active):
				var filtered:Array<String> = [];
				if (ids != null)
					for (id in ids)
						if (id != null && id.length > 0 && !containsId(excluded, id) && !containsId(filtered, id))
							filtered.push(id);
				if (filtered.length == 0)
					Empty;
				else if (filtered.length == 1)
					Panel(filtered[0]);
				else
					Tabs(filtered, containsId(filtered, active) ? active : filtered[0]);
			case Split(axis, ratio, first, second):
				var copiedFirst = first.copyExcluding(excluded), copiedSecond = second.copyExcluding(excluded);
				switch [copiedFirst, copiedSecond] {
					case [Empty, Empty]: Empty;
					case [Empty, other]: other;
					case [other, Empty]: other;
					default: Split(axis, clampRatio(ratio), copiedFirst, copiedSecond);
				}
		};
	}

	/** Removes redundant empty/single-child containers and clamps ratios. */
	public function normalize():DockNode {
		return switch (this) {
			case Empty: Empty;
			case Panel(id): id == null || id.length == 0 ? Empty : Panel(id);
			case Tabs(ids, active):
				var filtered:Array<String> = [];
				if (ids != null)
					for (id in ids)
						if (id != null && id.length > 0 && !containsId(filtered, id))
							filtered.push(id);
				if (filtered.length == 0)
					Empty;
				else if (filtered.length == 1)
					Panel(filtered[0]);
				else {
					var selected = containsId(filtered, active) ? active : filtered[0];
					Tabs(filtered, selected);
				}
			case Split(axis, ratio, first, second):
				var normalizedFirst = first.normalize();
				var normalizedSecond = second.normalize();
				switch ([normalizedFirst, normalizedSecond]) {
					case [Empty, Empty]: Empty;
					case [Empty, other]: other;
					case [other, Empty]: other;
					default: Split(axis, clampRatio(ratio), normalizedFirst, normalizedSecond);
				}
		};
	}

	/**
	 * Removes panels that are no longer registered by an application and then
	 * normalizes the remaining tree. This is intended for persisted layouts;
	 * strict programmatic layouts should continue to use validate().
	 */
	public function keepKnown(known:Map<String, Bool>):DockNode {
		var kept:DockNode = switch (this) {
			case Empty: Empty;
			case Panel(id): known != null && known.exists(id) ? Panel(id) : Empty;
			case Tabs(ids, active):
				var kept:Array<String> = [];
				if (ids != null)
					for (id in ids)
						if (known != null && known.exists(id) && !containsId(kept, id))
							kept.push(id);
				Tabs(kept, containsId(kept, active) ? active : (kept.length == 0 ? null : kept[0]));
			case Split(axis, ratio, first, second):
				Split(axis, ratio, first.keepKnown(known), second.keepKnown(known));
		};
		return kept.normalize();
	}

	/** Whether this layout holds panel `panelId`. */
	public function contains(panelId:String):Bool {
		if (panelId == null)
			return false;
		return switch (this) {
			case Empty: false;
			case Panel(id): id == panelId;
			case Tabs(ids, _): containsId(ids, panelId);
			case Split(_, _, first, second): first.contains(panelId) || second.contains(panelId);
		};
	}

	/** The first panel in reading order, or null for an empty layout. */
	public function firstPanel():Null<String> {
		return switch (this) {
			case Empty: null;
			case Panel(id): id;
			case Tabs(ids, _): ids == null || ids.length == 0 ? null : ids[0];
			case Split(_, _, first, second):
				var leading = first.firstPanel();
				leading == null ? second.firstPanel() : leading;
		};
	}

	/** Every panel it holds, in reading order. */
	public function panelIds():Array<String> {
		var result:Array<String> = [];
		appendPanelIds(this, result);
		return result;
	}

	/** Whether `other` is the same layout, with the same ratios and active tabs. */
	public function same(other:DockNode):Bool {
		if (other == null)
			return false;
		return switch ([this, other]) {
			case [Empty, Empty]: true;
			case [Panel(firstId), Panel(secondId)]: firstId == secondId;
			case [Tabs(firstIds, firstActive), Tabs(secondIds, secondActive)]:
				firstActive == secondActive && sameIds(firstIds, secondIds);
			case [
				Split(firstAxis, firstRatio, firstLeft, firstRight),
				Split(secondAxis, secondRatio, secondLeft, secondRight)
			]:
				firstAxis == secondAxis && firstRatio == secondRatio && firstLeft.same(secondLeft)
					&& firstRight.same(secondRight);
			default: false;
		};
	}

	/** This layout with panel `panelId` as the active tab of its group. */
	public function activate(panelId:String):DockNode {
		if (panelId == null)
			return DockNode.Empty;
		return isActive(this, panelId) ? this : activatePath(this, panelId);
	}

	static function activatePath(node:DockNode, panelId:String):DockNode {
		return switch (node) {
			case Empty | Panel(_): node;
			case Tabs(ids, _): containsId(ids, panelId) ? Tabs(ids.copy(), panelId) : node;
			case Split(axis, ratio, first, second):
				if (first.contains(panelId)) Split(axis, ratio, activatePath(first, panelId), second);
				else if (second.contains(panelId)) Split(axis, ratio, first, activatePath(second, panelId));
				else node;
		};
	}

	static function isActive(node:DockNode, panelId:String):Bool {
		return switch (node) {
			case Empty: false;
			case Panel(id): id == panelId;
			case Tabs(ids, active): active == panelId && containsId(ids, panelId);
			case Split(_, _, first, second): isActive(first, panelId) || isActive(second, panelId);
		};
	}

	/** This layout without panel `panelId`, normalized. */
	public function remove(panelId:String):DockNode {
		if (panelId == null)
			return DockNode.Empty;
		var removed:DockNode = switch (this) {
			case Empty: Empty;
			case Panel(id): id == panelId ? Empty : Panel(id);
			case Tabs(ids, active):
				var remaining:Array<String> = [];
				if (ids != null)
					for (id in ids)
						if (id != panelId)
							remaining.push(id);
				Tabs(remaining, active == panelId && remaining.length > 0 ? remaining[0] : active);
			case Split(axis, ratio, first, second):
				Split(axis, ratio, first.remove(panelId), second.remove(panelId));
		};
		return removed.normalize();
	}

	/** Moves or inserts a panel relative to the target panel. */
	public function dock(panelId:String, targetPanelId:String, zone:DockDropZone):DockNode {
		if (panelId == null || targetPanelId == null || panelId == targetPanelId || !contains(targetPanelId))
			return normalize();
		var without = contains(panelId) ? remove(panelId) : clone();
		return insert(without, panelId, targetPanelId, zone).normalize();
	}

	/** Updates a split addressed by a child-index path from the root. */
	public function setSplitRatio(path:Array<Int>, ratio:Float, depth:Int = 0):DockNode {
		if (path == null || depth < 0)
			return normalize();
		if (depth == path.length)
			return switch (this) {
				case Split(axis, _, first, second): Split(axis, clampRatio(ratio), first, second);
				default: this;
			};
		return switch (this) {
			case Split(axis, current, first, second):
				var branch = path[depth];
				branch == 0 ? Split(axis, current, first.setSplitRatio(path, ratio, depth + 1), second) : branch == 1
					? Split(axis, current, first, second.setSplitRatio(path, ratio, depth + 1)) : this;
			default: this;
		};
	}

	/** Validates IDs, uniqueness, active tabs, and split ratios. */
	public function validate(known:Map<String, Bool>):Null<String> {
		var seen:Map<String, Bool> = new Map();
		return validateNode(this, known, seen);
	}

	static function validateNode(node:DockNode, known:Map<String, Bool>,
			seen:Map<String, Bool>):Null<String> {
		if (node == null)
			return "Dock layout contains a null node";
		return switch (node) {
			case Empty: null;
			case Panel(id): validatePanel(id, known, seen);
			case Tabs(ids, active):
				if (ids == null || ids.length == 0)
					"Dock tab groups cannot be empty";
				else if (!containsId(ids, active))
					"Dock tab groups require an active panel";
				else {
					var error:Null<String> = null;
					for (id in ids)
						if (error == null)
							error = validatePanel(id, known, seen);
					error;
				}
			case Split(_, ratio, first, second):
				if (!finite(ratio) || ratio <= 0.0 || ratio >= 1.0)
					"Dock split ratios must be between zero and one";
				else {
					var firstError = validateNode(first, known, seen);
					firstError == null ? validateNode(second, known, seen) : firstError;
				}
		};
	}

	static function validatePanel(id:String, known:Map<String, Bool>,
			seen:Map<String, Bool>):Null<String> {
		if (id == null || id.length == 0)
			return "Dock panels require stable IDs";
		if (known != null && !known.exists(id))
			return "Dock layout references an unregistered panel: " + id;
		if (seen.exists(id))
			return "Dock layout references a panel more than once: " + id;
		seen.set(id, true);
		return null;
	}

	static function insert(node:DockNode, panelId:String, targetPanelId:String,
			zone:DockDropZone):DockNode {
		return switch (node) {
			case Empty: Empty;
			case Panel(id):
				if (id != targetPanelId)
					Panel(id);
				else
					switch (zone) {
						case Center: Tabs([id, panelId], panelId);
						case TabBefore: Tabs([panelId, id], panelId);
						case TabAfter: Tabs([id, panelId], panelId);
						case Left: Split(DockSplitAxis.Horizontal, 0.3, Panel(panelId), Panel(id));
						case Right: Split(DockSplitAxis.Horizontal, 0.7, Panel(id), Panel(panelId));
						case Top: Split(DockSplitAxis.Vertical, 0.3, Panel(panelId), Panel(id));
						case Bottom: Split(DockSplitAxis.Vertical, 0.7, Panel(id), Panel(panelId));
					};
			case Tabs(ids, active):
				if (!containsId(ids, targetPanelId))
					Tabs(ids == null ? [] : ids.copy(), active);
				else
					switch (zone) {
						case Center:
							var next:Array<String> = ids == null ? [] : ids.copy();
							if (!containsId(next, panelId))
								next.push(panelId);
							Tabs(next, panelId);
						case TabBefore | TabAfter:
							insertTab(ids, panelId, targetPanelId, zone);
						case Left | Right | Top | Bottom:
							var group = Tabs(ids == null ? [] : ids.copy(), active);
							splitAround(group, panelId, zone);
					};
			case Split(axis, ratio, first, second):
				if (first.contains(targetPanelId))
					Split(axis, ratio, insert(first, panelId, targetPanelId, zone), second);
				else if (second.contains(targetPanelId))
					Split(axis, ratio, first, insert(second, panelId, targetPanelId, zone));
				else
					Split(axis, ratio, first, second);
		};
	}

	static function splitAround(target:DockNode, panelId:String, zone:DockDropZone):DockNode {
		return switch (zone) {
			case Left: Split(DockSplitAxis.Horizontal, 0.3, Panel(panelId), target);
			case Right: Split(DockSplitAxis.Horizontal, 0.7, target, Panel(panelId));
			case Top: Split(DockSplitAxis.Vertical, 0.3, Panel(panelId), target);
			case Bottom: Split(DockSplitAxis.Vertical, 0.7, target, Panel(panelId));
			case Center | TabBefore | TabAfter: target;
		};
	}

	static function insertTab(ids:Array<String>, panelId:String, targetPanelId:String,
			zone:DockDropZone):DockNode {
		var next:Array<String> = [];
		var inserted = false;
		if (ids != null)
			for (id in ids) {
				if (id == panelId)
					continue;
				if (!inserted && id == targetPanelId && zone == DockDropZone.TabBefore) {
					next.push(panelId);
					inserted = true;
				}
				next.push(id);
				if (!inserted && id == targetPanelId && zone == DockDropZone.TabAfter) {
					next.push(panelId);
					inserted = true;
				}
			}
		if (!inserted)
			next.push(panelId);
		return Tabs(next, panelId);
	}

	static function appendPanelIds(node:DockNode, result:Array<String>):Void {
		switch (node) {
			case Empty:
			case Panel(id):
				if (id != null && !containsId(result, id))
					result.push(id);
			case Tabs(ids, _):
				if (ids != null)
					for (id in ids)
						if (!containsId(result, id))
							result.push(id);
			case Split(_, _, first, second):
				appendPanelIds(first, result);
				appendPanelIds(second, result);
		}
	}

	static function containsId(ids:Array<String>, id:String):Bool {
		if (ids == null || id == null)
			return false;
		for (item in ids)
			if (item == id)
				return true;
		return false;
	}

	static function sameIds(first:Array<String>, second:Array<String>):Bool {
		if (first == null || second == null)
			return first == second;
		if (first.length != second.length)
			return false;
		for (index in 0...first.length)
			if (first[index] != second[index])
				return false;
		return true;
	}

	static inline function clampRatio(value:Float):Float {
		if (!finite(value))
			return 0.5;
		return value < 0.05 ? 0.05 : value > 0.95 ? 0.95 : value;
	}

	static inline function finite(value:Float):Bool
		return value == value && value - value == 0.0;
}

/** Target region used when docking one panel relative to another. */
enum DockDropZone {
	/** Into the target's tab group. */
	Center;
	/** Inserts the dragged panel before the target tab in the same group. */
	TabBefore;
	/** Inserts the dragged panel after the target tab in the same group. */
	TabAfter;

	/** Beside the target, on its left. */
	Left;

	/** Beside the target, on its right. */
	Right;

	/** Above the target. */
	Top;

	/** Below the target. */
	Bottom;
}

/** Axis used by a dock split. */
enum DockSplitAxis {
	/** Regions side by side. */
	Horizontal;

	/** Regions stacked. */
	Vertical;
}

/** Panels share dock tabs only within the same group; standalone panels split. */
class DockPanelGrouping {
	/** The group's name. */
	public final group:String;

	/** Whether the group's panels may share a tab strip. */
	public final shareTabs:Bool;

	/** Membership of `group`. */
	public function new(group:String, shareTabs:Bool = true) {
		if (group == null || group.length == 0) throw "Dock grouping requires a name";
		this.group = group;
		this.shareTabs = shareTabs;
	}
}

/** Header ownership for a panel occupying a dock group by itself. */
enum DockPanelHeaderMode implements Hashable {
	/** The dock draws the panel's tab header. */
	Dock;
	/** Panel content provides its own header; multi-panel groups retain dock tabs. */
	Content;
}

/** View-independent metadata for one registered dock panel. */
class DockPanelDescriptor implements Observable {
	/** A stable identifier, used in layouts. */
	public final id:String;

	/** Its tab title. */
	public final title:String;

	/** The count shown on its tab; zero shows none. */
	public var badgeCount(default, null):Int = 0;
	@:allow(haxeon.ui.docking.DockWorkspaceModel)
	function setBadgeCount(value:Int):Void badgeCount = value;

	/** Whether the user can close it. */
	public final closable:Bool;

	/** Whether it can be activated. */
	public final enabled:Bool;

	/** Its tab icon, or null. */
	public final icon:Null<IconName>;

	/** Who draws its header when it is alone in its group. */
	public final headerMode:DockPanelHeaderMode;

	/** Which panels it may share tabs with; null shares with other ungrouped panels. */
	public final grouping:Null<DockPanelGrouping>;

	/** A panel `id` titled `title`. Throws when either is empty. */
	public function new(id:String, title:String, closable:Bool = true, enabled:Bool = true,
			?icon:IconName, headerMode:DockPanelHeaderMode = DockPanelHeaderMode.Dock,
			?grouping:DockPanelGrouping) {
		if (id == null || id.length == 0 || title == null || title.length == 0)
			throw "Dock panels require a stable ID and title";
		this.id = id;
		this.title = title;
		this.closable = closable;
		this.enabled = enabled;
		this.icon = icon;
		this.headerMode = headerMode;
		this.grouping = grouping;
	}
}
