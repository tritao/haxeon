package haxeon.ui.core;

import haxeon.ui.IntIndex;

/** Exact topology of a published frame. Rebuilding reparents retained nodes, so their old parent/children cannot be read live. */
class RenderTreeTopology {
	final indices:IntIndex = new IntIndex();
	final parents:Array<Int> = [];
	final offsets:Array<Int> = [];
	final counts:Array<Int> = [];
	final children:Array<Int> = [];

	public function new() {}

	public function clear():Void {
		indices.clear(); parents.resize(0); offsets.resize(0); counts.resize(0); children.resize(0);
	}

	public function append(node:RenderNode):Void {
		indices.set(node.id.value, parents.length);
		parents.push(node.parent == null ? 0 : node.parent.id.value);
		offsets.push(children.length);
		counts.push(node.children.length);
		for (child in node.children) children.push(child.id.value);
	}

	public function parent(id:Int):Int {
		var index = indices.get(id);
		return index < 0 ? 0 : parents[index];
	}

	/** Original child slot when a retained builder has already reparented the live child into its new root. */
	public function childPosition(parent:Int, child:Int):Int {
		var index = indices.get(parent);
		if (index < 0) return -1;
		var offset = offsets[index];
		for (slot in 0...counts[index]) if (children[offset + slot] == child) return slot;
		return -1;
	}

	public function sameChildren(node:RenderNode):Bool {
		var index = indices.get(node.id.value);
		if (index < 0 || counts[index] != node.children.length) return false;
		var offset = offsets[index];
		for (child in 0...node.children.length)
			if (children[offset + child] != node.children[child].id.value) return false;
		return true;
	}
}
