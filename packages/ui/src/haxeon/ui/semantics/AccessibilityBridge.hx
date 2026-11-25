package haxeon.ui.semantics;

import haxeon.platform.Surface;
import haxeon.ui.Rect;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.WidgetId;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.semantics.Semantics.AccessibilityAction;
import haxeon.ui.semantics.Semantics.AccessibilityOrientation;
import haxeon.ui.semantics.Semantics.AccessibilityRole;
import haxeon.ui.semantics.Semantics.AccessibilityState;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitConstants;
import nativekit.ffi.NativeKitTypes;

/** Projects Haxe semantics and resolved geometry into NativeKit's virtual tree. */
class AccessibilityBridge implements Disposable {
	public var coordinateScale:Float = 1.0;
	final surface:Surface;
	var previousParents:Map<Int, Int>;
	var disposed:Bool;

	public function new(surface:Surface) {
		if (surface == null || surface.isDisposed())
			throw "Accessibility projection requires a live NativeKit surface";
		this.surface = surface;
		NativeKit.nk_surface_accessibility_clear_checked(surface.nativeHandle());
		previousParents = new Map();
		disposed = false;
	}

	/** Builds a stable, parent-first snapshot for the current resolved tree. */
	public static function project(root:Null<RenderNode>, focused:Null<WidgetId>):Array<AccessibilitySnapshotNode> {
		var result:Array<AccessibilitySnapshotNode> = [];
		var childCounts:Map<Int, Int> = new Map();
		if (root == null)
			return result;
		var semanticRoot = findFocusTrap(root);
		if (semanticRoot == null)
			semanticRoot = root;
		projectNode(semanticRoot, NativeKitConstants.NK_ACCESSIBILITY_ROOT,
			true, focused, result, childCounts);
		return result;
	}

	/** Sends one atomic snapshot replacement, removals, and focus update. */
	public function update(root:Null<RenderNode>, focused:Null<WidgetId>):Void {
		ensureLive();
		var snapshot = project(root, focused);
		var currentParents:Map<Int, Int> = new Map();
		for (item in snapshot)
			currentParents.set(item.id, item.parentId);
		var requestedFocus = focused == null ? NativeKitConstants.NK_ACCESSIBILITY_ROOT : focused.value;
		var batch = buildUpdate(snapshot, previousParents, requestedFocus, coordinateScale);
		NativeKit.nk_surface_accessibility_update_with_removed_ids_checked(surface.nativeHandle(),
			batch.nativeUpdate, batch.removedNodeIds);
		previousParents = currentParents;
	}

	/** Builds a platform-neutral atomic NativeKit update from a complete semantic snapshot. */
	public static function buildUpdate(snapshot:Array<AccessibilitySnapshotNode>,
			previousParents:Map<Int, Int>, focus:Int, coordinateScale:Float = 1.0):AccessibilityUpdateBatch {
		var currentIds:Map<Int, Bool> = new Map();
		for (item in snapshot)
			currentIds.set(item.id, true);
		var nodes = buildNodes(snapshot, coordinateScale);
		var removed:Array<Int> = [];
		for (id in previousParents.keys()) {
			if (!currentIds.exists(id)) {
				var parentId = previousParents.get(id);
				if (parentId == NativeKitConstants.NK_ACCESSIBILITY_ROOT || currentIds.exists(parentId))
					removed.push(id);
			}
		}

		var update = new AccessibilityUpdate();
		update.struct_size = AccessibilityUpdate.byteSize();
		update.flags = AccessibilityUpdateFlags.Focus;
		update.set_nodes(nodes);
		update.node_count = nodes.length;
		var removedBytes = haxe.io.Bytes.alloc(removed.length * 4);
		for (index in 0...removed.length) {
			var offset = index * 4;
			var id = removed[index];
			removedBytes.set(offset, id & 0xff);
			removedBytes.set(offset + 1, (id >>> 8) & 0xff);
			removedBytes.set(offset + 2, (id >>> 16) & 0xff);
			removedBytes.set(offset + 3, (id >>> 24) & 0xff);
		}
		update.removed_node_count = 0;
		var focusTarget = NativeKitConstants.NK_ACCESSIBILITY_ROOT;
		for (item in snapshot)
			if (item.id == focus && !item.states.contains(AccessibilityState.Disabled)) {
				focusTarget = item.id;
				break;
			}
		update.focus = focusTarget;
		update.reserved = 0;
		return new AccessibilityUpdateBatch(update, removedBytes, removed.length);
	}

	/** Serializes every record in a semantic snapshot into native ABI structures. */
	public static function buildNodes(snapshot:Array<AccessibilitySnapshotNode>,
			coordinateScale:Float = 1.0):Array<AccessibilityNode> {
		var result:Array<AccessibilityNode> = [];
		for (item in snapshot)
			result.push(toNativeNode(item, coordinateScale));
		return result;
	}

	/** Removes the projected tree if the host surface still exists. */
	public function dispose():Void {
		if (disposed)
			return;
		if (!surface.isDisposed())
			NativeKit.nk_surface_accessibility_clear_checked(surface.nativeHandle());
		disposed = true;
		previousParents = new Map();
	}

	static function toNativeNode(item:AccessibilitySnapshotNode, coordinateScale:Float = 1.0):AccessibilityNode {
		var value = item.semantics;
		var node = new AccessibilityNode();
		node.struct_size = AccessibilityNode.byteSize();
		node.id = item.id;
		node.parent_id = item.parentId;
		node.child_index = item.childIndex;
		node.role = item.role;
		node.states = item.states;
		node.actions = item.actions;
		node.reserved0 = 0;
		node.x = item.bounds.x * coordinateScale;
		node.y = item.bounds.y * coordinateScale;
		node.width = item.bounds.width * coordinateScale;
		node.height = item.bounds.height * coordinateScale;
		node.label = value.label;
		node.value = value.value;
		node.numeric_value = value.numericValue;
		node.numeric_minimum = value.numericMinimum;
		node.numeric_maximum = value.numericMaximum;
		node.text_start = value.textStart;
		node.document_length = value.documentLength;
		node.selection_start = value.selectionStart;
		node.selection_end = value.selectionEnd;
		node.set_size = item.setSize;
		node.position_in_set = item.positionInSet;
		node.row_count = item.rowCount;
		node.column_count = item.columnCount;
		node.row_index = item.rowIndex;
		node.column_index = item.columnIndex;
		node.row_span = item.rowSpan;
		node.column_span = item.columnSpan;
		node.hierarchy_level = item.hierarchyLevel;
		node.orientation = item.orientation;
		return node;
	}

	function ensureLive():Void {
		if (disposed)
			throw "Accessibility bridge has been disposed";
		if (surface.isDisposed())
			throw "Accessibility host surface has been disposed";
	}

	static function projectNode(node:RenderNode, semanticParent:Int, ancestorsEnabled:Bool,
			focused:Null<WidgetId>, output:Array<AccessibilitySnapshotNode>, childCounts:Map<Int, Int>):Void {
		if (node.resolved == null || !node.resolved.visible)
			return;
		var explicitlyDisabled = false;
		if (node.semantics != null) {
			var declared:Semantics = cast node.semantics;
			explicitlyDisabled = declared.states.contains(AccessibilityState.Disabled);
		}
		var enabled = ancestorsEnabled && node.enabled && !explicitlyDisabled;
		var nextParent = semanticParent;
		if (node.semantics != null) {
			var semantics:Semantics = cast node.semantics;
			var childIndex = childCounts.exists(semanticParent) ? childCounts.get(semanticParent) : 0;
			childCounts.set(semanticParent, childIndex + 1);
			var states = semantics.states;
			if (node.focusable && enabled)
				states |= AccessibilityState.Focusable;
			if (!enabled) {
				states |= AccessibilityState.Disabled;
				states = states.remove(AccessibilityState.Focusable | AccessibilityState.Focused);
			}
			if (enabled && focused != null && node.id.equals(focused))
				states |= AccessibilityState.Focused;
			var actions = semantics.actions;
			if (node.focusable && enabled)
				actions |= AccessibilityAction.Focus;
			if (!enabled)
				actions = AccessibilityAction.empty();
			output.push(new AccessibilitySnapshotNode(node.id.value, semanticParent,
				childIndex, semantics.role, states, actions,
				node.resolved.clippedViewportBounds(), semantics));
			nextParent = node.id.value;
		}
		for (child in node.children)
			projectNode(child, nextParent, enabled, focused, output, childCounts);
	}

	static function findFocusTrap(node:Null<RenderNode>):Null<RenderNode> {
		if (node == null || node.resolved == null || !node.resolved.visible)
			return null;
		var result:Null<RenderNode> = node.focusTrap ? node : null;
		for (child in node.children) {
			var nested = findFocusTrap(child);
			if (nested != null)
				result = nested;
		}
		return result;
	}



}

/** Surface-local semantic record ready for projection into NativeKit. */
class AccessibilitySnapshotNode {
	public final id:Int;
	public final parentId:Int;
	public final childIndex:Int;
	public final role:AccessibilityRole;
	public final states:AccessibilityState;
	public final actions:AccessibilityAction;
	public final bounds:Rect;
	public final semantics:Semantics;
	public final setSize:Int;
	public final positionInSet:Int;
	public final rowCount:Int;
	public final columnCount:Int;
	public final rowIndex:Int;
	public final columnIndex:Int;
	public final rowSpan:Int;
	public final columnSpan:Int;
	public final hierarchyLevel:Int;
	public final orientation:AccessibilityOrientation;

	public function new(id:Int, parentId:Int, childIndex:Int, role:AccessibilityRole,
			states:AccessibilityState, actions:AccessibilityAction, bounds:Rect, semantics:Semantics) {
		this.id = id;
		this.parentId = parentId;
		this.childIndex = childIndex;
		this.role = role;
		this.states = states;
		this.actions = actions;
		this.bounds = bounds;
		this.semantics = semantics;
		setSize = semantics.setSize;
		positionInSet = semantics.positionInSet;
		rowCount = semantics.rowCount;
		columnCount = semantics.columnCount;
		rowIndex = semantics.rowIndex;
		columnIndex = semantics.columnIndex;
		rowSpan = semantics.rowSpan;
		columnSpan = semantics.columnSpan;
		hierarchyLevel = semantics.hierarchyLevel;
		orientation = semantics.orientation;
	}
}

/** Complete Haxe-owned input for one native accessibility update call. */
class AccessibilityUpdateBatch {
	public final nativeUpdate:AccessibilityUpdate;
	/** Packed little-endian 32-bit node IDs consumed by the core binding helper. */
	public final removedNodeIds:haxe.io.Bytes;
	public final removedNodeCount:Int;

	public function new(nativeUpdate:AccessibilityUpdate,
			removedNodeIds:haxe.io.Bytes, removedNodeCount:Int) {
		this.nativeUpdate = nativeUpdate;
		this.removedNodeIds = removedNodeIds;
		this.removedNodeCount = removedNodeCount;
	}
}
