package haxeon.gpu;

import haxeon.gpu.Enums.ShaderStage;

/** Slot and size of a uniform block with a generated native record layout. */
class ShaderUniformBlock<T> {
	public final slot:Int;
	public final stage:ShaderStage;
	public final size:Int;

	public function new(slot:Int, stage:ShaderStage, size:Int) {
		this.slot = slot;
		this.stage = stage;
		this.size = size;
	}
}
