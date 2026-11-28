package haxeon.ui.docking;

import Observable;
import haxeon.ui.core.Command;
import haxeon.ui.core.CommandRegistry;
import haxeon.ui.docking.DockNode;

import haxeon.ui.docking.DockWorkspaceSnapshot;
/**
 * Mutable dock layout and panel metadata. Observable fields invalidate views;
 * listeners remain for persistence and other non-view side effects.
 */
class DockWorkspaceModel implements Observable {
	/** The registered panels, by id. */
	public var panels(default, null):Map<String, DockPanelDescriptor>;

	/** The current layout. */
	public var root(default, null):DockNode;

	/** The layout `reset` returns to. */
	public var defaultRoot(default, null):DockNode;

	/** The focused panel, or null. */
	public var activePanelId(default, null):Null<String>;
	final listeners:Array<Void->Void>;

	/** How many change listeners are registered. */
	public var listenerCount(get, never):Int;
	inline function get_listenerCount():Int return listeners.length;

	/** A workspace whose default and current layout is `defaultRoot`, or empty. */
	public function new(?defaultRoot:DockNode) {
		panels = new Map();
		root = (defaultRoot == null ? DockNode.Empty : defaultRoot).normalize();
		this.defaultRoot = root.clone();
		activePanelId = root.firstPanel();
		listeners = [];
	}

	/** Registers a change listener and returns a cleanup callback. */
	public function listen(callback:Void->Void):Void->Void {
		if (callback == null || listeners.contains(callback))
			return () -> {};
		listeners.push(callback);
		return () -> {
			listeners.remove(callback);
		};
	}

	/** Registers `panel`. Throws when its id is taken. */
	public function register(panel:DockPanelDescriptor):Void {
		if (panel == null)
			throw "Dock workspace cannot register a null panel";
		if (panels.exists(panel.id))
			throw 'Dock panel ${panel.id} is already registered';
		var next = copyPanels(panels);
		next.set(panel.id, panel);
		panels = next;
		if (root.contains(panel.id) && activePanelId == null)
			activePanelId = panel.id;
	}

	/** Sets the count shown on a panel's tab. Returns false for an unknown panel, a negative count or no change. */
	public function setPanelBadge(panelId:String, count:Int):Bool {
		var panel = get(panelId);
		if (panel == null || count < 0 || panel.badgeCount == count) return false;
		panel.setBadgeCount(count);
		return true;
	}

	/** Panel `panelId`, or null. */
	public function get(panelId:String):Null<DockPanelDescriptor>
		return panelId == null ? null : panels.get(panelId);

	/** Whether panel `panelId` is in the layout. */
	public function isOpen(panelId:String):Bool
		return root.contains(panelId);

	/** The open panels, in reading order. */
	public function panelIds():Array<String>
		return root.panelIds();

	/** Installs a validated default layout and makes it the active layout. */
	public function setDefaultLayout(layout:DockNode):Void {
		validateLayout(layout);
		defaultRoot = normalizeGroups(layout);
		setRoot(layout);
	}

	/** Installs `layout`. Throws when it is invalid. */
	public function setRoot(layout:DockNode):Void {
		validateLayout(layout);
		root = normalizeGroups(layout);
		activePanelId = chooseActive(activePanelId);
		touch();
	}

	/** Returns to the default layout. */
	public function reset():Void
		setRoot(defaultRoot);

	/** Focuses an open panel, selecting its tab. Returns false when it is not open. */
	public function activate(panelId:String):Bool {
		if (!isOpen(panelId))
			return false;
		var changed = activePanelId != panelId;
		// Model roots are normalized when installed. Activation changes one tab header and preserves every other branch.
		root = root.activate(panelId);
		activePanelId = panelId;
		if (changed)
			touch();
		return true;
	}

	/** Closes a closable open panel. Returns false otherwise. */
	public function close(panelId:String):Bool {
		var panel = get(panelId);
		if (panel == null || !panel.closable || !isOpen(panelId))
			return false;
		root = root.remove(panelId);
		if (activePanelId == panelId)
			activePanelId = root.firstPanel();
		touch();
		return true;
	}

	/** Reopens a closed panel into a target tab group or the first panel. */
	public function open(panelId:String, ?targetPanelId:String):Bool {
		if (get(panelId) == null)
			return false;
		if (isOpen(panelId))
			return activate(panelId);
		var target = targetPanelId != null && isOpen(targetPanelId) ? targetPanelId : root.firstPanel();
		if (target == null) {
			root = DockNode.Panel(panelId);
			activePanelId = panelId;
			touch();
			return true;
		}
		if (!canShareTabs(panelId, target)) {
			for (candidate in panelIds())
				if (canShareTabs(panelId, candidate)) return dock(panelId, candidate, DockDropZone.Center);
			return dock(panelId, target, DockDropZone.Bottom);
		}
		return dock(panelId, target, DockDropZone.Center);
	}

	/** Whether the two panels' groupings let them share a tab strip. */
	public function canShareTabs(firstId:String, secondId:String):Bool {
		var first = get(firstId), second = get(secondId);
		if (first == null || second == null) return false;
		var a = first.grouping, b = second.grouping;
		if (a == null || b == null) return a == null && b == null;
		return a.shareTabs && b.shareTabs && a.group == b.group;
	}

	/** Whether panel `panelId` may go at `zone` of open panel `targetPanelId`. */
	public function canDock(panelId:String, targetPanelId:String, zone:DockDropZone):Bool {
		if (get(panelId) == null || get(targetPanelId) == null || zone == null || panelId == targetPanelId
			|| !isOpen(targetPanelId)) return false;
		return switch zone {
			case Center | TabBefore | TabAfter: canShareTabs(panelId, targetPanelId);
			case Left | Right | Top | Bottom: true;
		};
	}

	/** Repairs older layouts against current grouping rules without losing panels. */
	function normalizeGroups(node:DockNode):DockNode {
		return groupedLayout(node.normalize());
	}

	function groupedLayout(node:DockNode):DockNode {
		return switch node {
			case Empty: DockNode.Empty;
			case Panel(id): DockNode.Panel(id);
			case Split(axis, ratio, first, second):
				DockNode.Split(axis, ratio, groupedLayout(first), groupedLayout(second));
			case Tabs(ids, active):
				var groups:Array<Array<String>> = [];
				for (id in ids) {
					var found = false;
					for (group in groups) if (canShareTabs(id, group[0])) {
						group.push(id);
						found = true;
						break;
					}
					if (!found) groups.push([id]);
				}
				var result = DockNode.Empty;
				for (index in 0...groups.length) {
					var group = groups[groups.length - index - 1];
					var leaf = group.length == 1 ? DockNode.Panel(group[0]) : DockNode.Tabs(group,
						group.indexOf(active) >= 0 ? active : group[0]);
					result = index == 0 ? leaf : DockNode.Split(DockSplitAxis.Vertical, 0.72, leaf, result);
				}
				result;
		};
	}

	/** Moves panel `panelId` to `zone` of `targetPanelId` and focuses it. Returns false when that is not allowed. */
	public function dock(panelId:String, targetPanelId:String, zone:DockDropZone):Bool {
		if (!canDock(panelId, targetPanelId, zone))
			return false;
		var next = root.dock(panelId, targetPanelId, zone);
		if (next.validate(panelMap()) != null)
			return false;
		root = next;
		activePanelId = panelId;
		touch();
		return true;
	}

	/** Sets the ratio of the split at `path`, child indices from the root. Returns false when nothing changed. */
	public function setSplitRatio(path:Array<Int>, ratio:Float):Bool {
		var next = root.setSplitRatio(path, ratio);
		if (root.same(next))
			return false;
		root = next;
		touch();
		return true;
	}

	/** Resize the nearest horizontal split; supply the mounted layout's divider and minimum extents. */
	public function setPanelWidth(panelId:String, width:Float, workspaceWidth:Float, dividerExtent:Float = 0.0,
			minimumExtent:Float = 0.0):Bool {
		if (width <= 0 || workspaceWidth <= 0 || width - width != 0 || workspaceWidth - workspaceWidth != 0
			|| dividerExtent < 0 || minimumExtent < 0 || dividerExtent - dividerExtent != 0
			|| minimumExtent - minimumExtent != 0)
			return false;
		return resizePanelWidth(root, panelId, width, workspaceWidth, dividerExtent, minimumExtent, []);
	}
	function resizePanelWidth(node:DockNode, id:String, width:Float, extent:Float, divider:Float, minimum:Float,
			path:Array<Int>):Bool {
		return switch node {
			case Split(axis, ratio, first, second):
				var inFirst = first.contains(id), inSecond = second.contains(id);
				if (!inFirst && !inSecond) false;
				else {
					var branch = inFirst ? 0 : 1;
					path.push(branch);
					var firstExtent = Math.max(minimum,
						Math.min(ratio * extent, Math.max(minimum, extent - minimum - divider)));
					var childExtent = axis == DockSplitAxis.Horizontal
						? (inFirst ? firstExtent : Math.max(0.0, extent - firstExtent - divider)) : extent;
					var found = resizePanelWidth(inFirst ? first : second, id, width, childExtent, divider, minimum,
						path);
					path.pop();
					if (found) true;
					else if (axis == DockSplitAxis.Horizontal) {
						setSplitRatio(path, inFirst ? width / extent : (extent - width - divider) / extent);
						true;
					} else false;
				}
			case _: false;
		};
	}

	/** The layout and focused panel, for saving. */
	public function snapshot():DockWorkspaceSnapshot
		return new DockWorkspaceSnapshot(root, activePanelId);

	/** Serializes the current layout through the shared versioned codec. */
	public function snapshotJson():String
		return DockWorkspaceSnapshotCodec.encode(snapshot());

	/** Restores a serialized layout without coupling the UI module to storage. */
	public function restoreJson(source:String):Bool {
		var snapshot = DockWorkspaceSnapshotCodec.decode(source);
		return snapshot != null && restorePersisted(snapshot);
	}

	/** Installs a saved layout exactly. Returns false when it does not fit the registered panels. */
	public function restore(snapshot:DockWorkspaceSnapshot):Bool {
		if (snapshot == null || snapshot.version != DockWorkspaceSnapshot.CurrentVersion)
			return false;
		if (snapshot.root.validate(panelMap()) != null)
			return false;
		root = normalizeGroups(snapshot.root);
		activePanelId = snapshot.activePanelId != null
			&& isOpen(snapshot.activePanelId) ? snapshot.activePanelId : root.firstPanel();
		touch();
		return true;
	}

	/**
	 * Restores persisted state across application revisions. Removed panels are
	 * pruned, empty containers collapse, and the active panel is repaired. If
	 * every persisted panel disappeared, the snapshot is rejected so callers
	 * can use their default layout.
	 */
	public function restorePersisted(snapshot:DockWorkspaceSnapshot):Bool {
		if (snapshot == null || snapshot.version != DockWorkspaceSnapshot.CurrentVersion)
			return false;
		var persistedIds = snapshot.root.panelIds();
		var compatible = snapshot.root.keepKnown(panelMap());
		if (persistedIds.length > 0 && compatible.firstPanel() == null)
			return false;
		if (compatible.validate(panelMap()) != null)
			return false;
		root = normalizeGroups(compatible);
		activePanelId = snapshot.activePanelId != null
			&& isOpen(snapshot.activePanelId) ? snapshot.activePanelId : root.firstPanel();
		touch();
		return true;
	}

	/** Removes panel `panelId` from the workspace and its layouts. Returns false for an unknown panel. */
	public function unregister(panelId:String):Bool {
		if (!panels.exists(panelId))
			return false;
		var next = copyPanels(panels);
		next.remove(panelId);
		panels = next;
		root = root.remove(panelId);
		defaultRoot = defaultRoot.remove(panelId);
		if (activePanelId == panelId)
			activePanelId = root.firstPanel();
		touch();
		return true;
	}

	function validateLayout(layout:DockNode):Void {
		var error = layout.validate(panelMap());
		if (error != null)
			throw error;
	}

	function chooseActive(preferred:Null<String>):Null<String>
		return preferred != null && isOpen(preferred) ? preferred : root.firstPanel();

	function panelMap():Map<String, Bool> {
		var result:Map<String, Bool> = new Map();
		for (id in panels.keys())
			result.set(id, true);
		return result;
	}

	function touch():Void {
		var callbacks = listeners.copy();
		for (callback in callbacks)
			callback();
	}

	static function copyPanels(source:Map<String, DockPanelDescriptor>):Map<String, DockPanelDescriptor> {
		var result:Map<String, DockPanelDescriptor> = new Map();
		for (key in source.keys()) result.set(key, source.get(key));
		return result;
	}
}

/** Registers command adapters for a workspace model. */
class DockWorkspaceCommands {
	/**
	 * Registers the workspace's commands, such as closing the active panel and resetting the layout, under `prefix`.
	 */
	public static function install(model:DockWorkspaceModel, registry:CommandRegistry,
			prefix:String = "dock", scope:String = CommandRegistry.GlobalScope):Void {
		if (model == null || registry == null || prefix == null || prefix.length == 0)
			throw "Dock commands require a workspace, registry, and stable prefix";
		registry.register(Command.contextual(prefix + ".close", "Close panel", context -> {
			var panelId = context.parameters.getString("panel");
			if (panelId == null)
				panelId = model.activePanelId;
			return panelId != null && model.close(panelId)
				? CommandResult.executed() : CommandResult.rejected("The active panel cannot be closed");
		}, null, context -> {
			var panelId = context.parameters.getString("panel");
			if (panelId == null)
				panelId = model.activePanelId;
			var panel = panelId == null ? null : model.get(panelId);
			return panel != null && panel.closable && model.isOpen(panelId);
		}), scope);
		registry.register(Command.contextual(prefix + ".reset", "Reset workspace", _ -> {
			model.reset();
			return CommandResult.executed();
		}), scope);
	}
}
