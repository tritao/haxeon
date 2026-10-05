package nativekit.ui.semantics;
import nativekit.ffi.NativeKitTypes;

import nativekit.ffi.NativeKit;

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
