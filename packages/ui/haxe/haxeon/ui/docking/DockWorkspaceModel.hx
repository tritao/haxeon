package haxeon.ui.docking;

/**
 * Mutable dock layout and panel metadata. Mutations increment revision and
 * notify listeners so mounted workspaces can invalidate a frame.
 */
class DockWorkspaceModel {
	public final panels:Map<String, DockPanelDescriptor>;
	public var root(default, null):DockNode;
	public var defaultRoot(default, null):DockNode;
	public var activePanelId(default, null):Null<String>;
	public var revision(default, null):Int;
	final listeners:Array<Void->Void>;
	public var listenerCount(get, never):Int;
	inline function get_listenerCount():Int return listeners.length;

	public function new(?defaultRoot:DockNode) {
		panels = new Map();
		root = DockNodeTools.normalize(defaultRoot == null ? DockNode.Empty : defaultRoot);
		this.defaultRoot = DockNodeTools.clone(root);
		activePanelId = DockNodeTools.firstPanel(root);
		revision = 0;
		listeners = [];
	}

	/** Registers a change listener and returns a cleanup callback. */
	public function listen(callback:Void->Void):Void->Void {
		if (callback == null || listeners.contains(callback))
			return function() {};
		listeners.push(callback);
		return function() { listeners.remove(callback); };
	}

	public function register(panel:DockPanelDescriptor):Void {
		if (panel == null)
			throw "Dock workspace cannot register a null panel";
		if (panels.exists(panel.id))
			throw 'Dock panel ${panel.id} is already registered';
		panels.set(panel.id, panel);
		if (DockNodeTools.contains(root, panel.id) && activePanelId == null)
			activePanelId = panel.id;
	}

	public function setPanelBadge(panelId:String, count:Int):Bool {
		var panel = get(panelId);
		if (panel == null || count < 0 || panel.badgeCount == count) return false;
		panel.setBadgeCount(count); revision++; return true;
	}

	public function get(panelId:String):Null<DockPanelDescriptor>
		return panelId == null ? null : panels.get(panelId);

	public function isOpen(panelId:String):Bool
		return DockNodeTools.contains(root, panelId);

	public function panelIds():Array<String>
		return DockNodeTools.panelIds(root);

	/** Installs a validated default layout and makes it the active layout. */
	public function setDefaultLayout(layout:DockNode):Void {
		validateLayout(layout);
		defaultRoot = normalizeGroups(layout);
		setRoot(layout);
	}

	public function setRoot(layout:DockNode):Void {
		validateLayout(layout);
		root = normalizeGroups(layout);
		activePanelId = chooseActive(activePanelId);
		touch();
	}

	public function reset():Void
		setRoot(defaultRoot);

	public function activate(panelId:String):Bool {
		if (!isOpen(panelId))
			return false;
		var changed = activePanelId != panelId;
		root = DockNodeTools.normalize(DockNodeTools.activate(root, panelId));
		activePanelId = panelId;
		if (changed)
			touch();
		return true;
	}

	public function close(panelId:String):Bool {
		var panel = get(panelId);
		if (panel == null || !panel.closable || !isOpen(panelId))
			return false;
		root = DockNodeTools.remove(root, panelId);
		if (activePanelId == panelId)
			activePanelId = DockNodeTools.firstPanel(root);
		touch();
		return true;
	}

	/** Reopens a closed panel into a target tab group or the first panel. */
	public function open(panelId:String, ?targetPanelId:String):Bool {
		if (get(panelId) == null)
			return false;
		if (isOpen(panelId))
			return activate(panelId);
		var target = targetPanelId != null && isOpen(targetPanelId) ? targetPanelId :
			DockNodeTools.firstPanel(root);
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

	public function canShareTabs(firstId:String, secondId:String):Bool {
		var first = get(firstId), second = get(secondId);
		if (first == null || second == null) return false;
		var a = first.grouping, b = second.grouping;
		if (a == null || b == null) return a == null && b == null;
		return a.shareTabs && b.shareTabs && a.group == b.group;
	}

	public function canDock(panelId:String, targetPanelId:String, zone:DockDropZone):Bool {
		if (get(panelId) == null || get(targetPanelId) == null || zone == null ||
			panelId == targetPanelId || !isOpen(targetPanelId)) return false;
		return switch zone {
			case Center | TabBefore | TabAfter: canShareTabs(panelId, targetPanelId);
			case Left | Right | Top | Bottom: true;
		};
	}

	/** Repairs older layouts against current grouping rules without losing panels. */
	function normalizeGroups(node:DockNode):DockNode {
		return groupedLayout(DockNodeTools.normalize(node));
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
					var leaf = group.length == 1 ? DockNode.Panel(group[0]) :
						DockNode.Tabs(group, group.indexOf(active) >= 0 ? active : group[0]);
					result = index == 0 ? leaf : DockNode.Split(DockSplitAxis.Vertical, 0.72, leaf, result);
				}
				result;
		};
	}

	public function dock(panelId:String, targetPanelId:String, zone:DockDropZone):Bool {
		if (!canDock(panelId, targetPanelId, zone))
			return false;
		var next = DockNodeTools.dock(root, panelId, targetPanelId, zone);
		if (DockNodeTools.validate(next, panelMap()) != null)
			return false;
		root = next;
		activePanelId = panelId;
		touch();
		return true;
	}

	public function setSplitRatio(path:Array<Int>, ratio:Float):Bool {
		var next = DockNodeTools.setSplitRatio(root, path, ratio);
		if (DockNodeTools.same(root, next))
			return false;
		root = next;
		touch();
		return true;
	}

	/** Resize the nearest horizontal split; supply the mounted layout's divider and minimum extents. */
	public function setPanelWidth(panelId:String, width:Float, workspaceWidth:Float, dividerExtent:Float = 0.0, minimumExtent:Float = 0.0):Bool {
		if (width <= 0 || workspaceWidth <= 0 || width - width != 0 || workspaceWidth - workspaceWidth != 0 ||
			dividerExtent < 0 || minimumExtent < 0 || dividerExtent - dividerExtent != 0 || minimumExtent - minimumExtent != 0)
			return false;
		return resizePanelWidth(root, panelId, width, workspaceWidth, dividerExtent, minimumExtent, []);
	}
	function resizePanelWidth(node:DockNode, id:String, width:Float, extent:Float, divider:Float, minimum:Float, path:Array<Int>):Bool {
		return switch node {
			case Split(axis, ratio, first, second):
				var inFirst = DockNodeTools.contains(first, id), inSecond = DockNodeTools.contains(second, id);
				if (!inFirst && !inSecond) false;
				else {
					var branch = inFirst ? 0 : 1;
					path.push(branch);
					var firstExtent = Math.max(minimum, Math.min(ratio * extent, Math.max(minimum, extent - minimum - divider)));
					var childExtent = axis == DockSplitAxis.Horizontal ? (inFirst ? firstExtent : Math.max(0.0, extent - firstExtent - divider)) : extent;
					var found = resizePanelWidth(inFirst ? first : second, id, width, childExtent, divider, minimum, path);
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

	public function restore(snapshot:DockWorkspaceSnapshot):Bool {
		if (snapshot == null || snapshot.version != DockWorkspaceSnapshot.CurrentVersion)
			return false;
		if (DockNodeTools.validate(snapshot.root, panelMap()) != null)
			return false;
		root = normalizeGroups(snapshot.root);
		activePanelId = snapshot.activePanelId != null && isOpen(snapshot.activePanelId) ?
			snapshot.activePanelId : DockNodeTools.firstPanel(root);
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
		var persistedIds = DockNodeTools.panelIds(snapshot.root);
		var compatible = DockNodeTools.keepKnown(snapshot.root, panelMap());
		if (persistedIds.length > 0 && DockNodeTools.firstPanel(compatible) == null)
			return false;
		if (DockNodeTools.validate(compatible, panelMap()) != null)
			return false;
		root = normalizeGroups(compatible);
		activePanelId = snapshot.activePanelId != null && isOpen(snapshot.activePanelId) ?
			snapshot.activePanelId : DockNodeTools.firstPanel(root);
		touch();
		return true;
	}

	public function unregister(panelId:String):Bool {
		if (!panels.exists(panelId))
			return false;
		panels.remove(panelId);
		root = DockNodeTools.remove(root, panelId);
		defaultRoot = DockNodeTools.remove(defaultRoot, panelId);
		if (activePanelId == panelId)
			activePanelId = DockNodeTools.firstPanel(root);
		touch();
		return true;
	}

	function validateLayout(layout:DockNode):Void {
		var error = DockNodeTools.validate(layout, panelMap());
		if (error != null)
			throw error;
	}

	function chooseActive(preferred:Null<String>):Null<String>
		return preferred != null && isOpen(preferred) ? preferred : DockNodeTools.firstPanel(root);

	function panelMap():Map<String, Bool> {
		var result:Map<String, Bool> = new Map();
		for (id in panels.keys())
			result.set(id, true);
		return result;
	}

	function touch():Void {
		revision++;
		var callbacks = listeners.copy();
		for (callback in callbacks)
			callback();
	}
}
