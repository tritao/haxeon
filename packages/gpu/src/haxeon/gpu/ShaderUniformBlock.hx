package haxeon.gpu;

import haxeon.gpu.Enums.ShaderStage;

/** Slot and size of a uniform block with a generated native record layout. */
class ShaderUniformBlock<T> {
	/** The block's binding slot. */
	public final slot:Int;

	/** The stage that reads it. */
	public final stage:ShaderStage;

	/** Its size, in bytes. */
	public final size:Int;

	/** Block `slot` of `size` bytes for `stage`. */
	public function new(slot:Int, stage:ShaderStage, size:Int) {
		this.slot = slot;
		this.stage = stage;
		this.size = size;
	}
}
