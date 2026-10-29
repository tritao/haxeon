package haxeon.gpu;

import haxeon.platform.BindingError;

import haxeon.gpu.Renderer;

import haxeon.gpu.GpuResult;
import nativekit.ffi.NativeKitGpu;

/** One consumed uniform block staged for the current renderer frame. */
class Uniforms {
	final renderer:Renderer;
	final registration:haxeon.platform.DisposalRegistration;
	final value:nkgpu_uniform_builder;
	var consumed:Bool = false;

	@:allow(Renderer)
	private function new(renderer:Renderer, value:nkgpu_uniform_builder) {
		this.renderer = renderer;
		this.value = value;
		registration = renderer.registerResource(rendererClosed);
	}

	public function writeFloat(offset:Int, number:Float):Uniforms {
		ensureLive();
		if (offset < 0)
			throw BindingError.invalidArgument("Uniforms.writeFloat", "GPU uniform offset must be non-negative");
		GpuResult.check(NativeKitGpu.nkgpu_uniforms_write_f32(value, offset, number), "uniforms.writeFloat");
		return this;
	}

	public function apply(slot:Int):Void {
		ensureLive();
		if (slot < 0)
			throw BindingError.invalidArgument("Uniforms.apply", "GPU uniform slot must be non-negative");
		GpuResult.check(NativeKitGpu.nkgpu_apply_uniforms(renderer.nativeHandle(), slot, value), "uniforms.apply");
		consumed = true;
		registration.detach();
	}

	@:allow(Renderer)
	function rendererClosed():Void {
		consumed = true;
		registration.detach();
	}

	function ensureLive():Void {
		if (consumed)
			throw BindingError.invalidState("Uniforms.ensureLive", "GPU uniform builder has been consumed");
		renderer.ensureFrame();
	}
}
