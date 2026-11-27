package haxeon.gpu;

import haxeon.platform.BindingError;

import haxeon.gpu.CommandBuffer;
import haxeon.gpu.Enums;
import haxeon.gpu.Shader;

import haxeon.gpu.Renderer;

import haxeon.gpu.GpuResult;
import nativekit.ffi.NativeKitGpu;

import haxeon.gpu.Enums.IndexType;
import haxeon.gpu.Enums.VertexFormat;

/** Renderer-owned pipeline resource. */
class Pipeline implements Disposable {
	final renderer:Renderer;
	final registration:haxeon.platform.DisposalRegistration;
	final value:nkgpu_pipeline;
	var disposed:Bool = false;

	@:allow(haxeon.gpu.PipelineBuilder)
	private function new(renderer:Renderer, value:nkgpu_pipeline) {
		this.renderer = renderer;
		this.value = value;
		registration = renderer.registerResource(rendererClosed);
	}

	static function beginWithStride(renderer:Renderer, shader:Shader, stride:Int):PipelineBuilder {
		renderer.ensureResourceOperation();
		if (shader.rendererOwner() != renderer)
			throw BindingError.invalidArgument("Pipeline.begin", "GPU pipeline shader belongs to a different renderer");
		if (stride < 0)
			throw BindingError.invalidArgument("Pipeline.begin", "GPU pipeline vertex stride must not be negative");
		var made = NativeKitGpu.nkgpu_pipeline_begin(renderer.nativeHandle(), shader.nativeHandle(), stride);
		GpuResult.check(made.status, "pipeline.begin");
		return new PipelineBuilder(renderer, made.out_builder);
	}

	/** Starts building a render pipeline for `shader` whose vertices follow `layout`. */
	public static function begin(renderer:Renderer, shader:Shader, layout:VertexLayout):PipelineBuilder
		return layout.apply(beginWithStride(renderer, shader, layout.stride));

	/** Begins a compute-only pipeline builder. */
	public static function beginCompute(renderer:Renderer, shader:Shader):PipelineBuilder {
		renderer.ensureResourceOperation();
		if (shader.rendererOwner() != renderer)
			throw BindingError.invalidArgument("Pipeline.beginCompute",
				"GPU compute pipeline shader belongs to a different renderer");
		var made = NativeKitGpu.nkgpu_pipeline_begin_compute(renderer.nativeHandle(), shader.nativeHandle());
		GpuResult.check(made.status, "pipeline.beginCompute");
		return new PipelineBuilder(renderer, made.out_builder);
	}

	internal function nativeHandle():nkgpu_pipeline {
		ensureLive();
		return value;
	}

	/** Binds it for the next draws. */
	public function apply():Void {
		ensureLive();
		renderer.ensureFrame();
		GpuResult.check(NativeKitGpu.nkgpu_apply_pipeline(renderer.nativeHandle(), value), "pipeline.apply");
	}

	public function dispose():Void {
		if (disposed)
			return;
		renderer.ensureResourceOperation();
		GpuResult.check(NativeKitGpu.nkgpu_pipeline_destroy(renderer.nativeHandle(), value), "pipeline.dispose");
		disposed = true;
		registration.detach();
	}

	/** Whether it has been disposed. */
	public function isDisposed():Bool
		return disposed;

	@:allow(haxeon.gpu.CommandBuffer)
	function rendererOwner():Renderer
		return renderer;

	@:allow(haxeon.gpu.Renderer)
	function rendererClosed():Void {
		disposed = true;
		registration.detach();
	}

	function ensureLive():Void {
		if (disposed)
			throw BindingError.disposed("Pipeline.ensureLive", "GPU pipeline has been disposed");
		renderer.ensureLive();
	}
}

/** Configures one vertex/index layout before creating an immutable pipeline. */
class PipelineBuilder {
	final renderer:Renderer;
	final registration:haxeon.platform.DisposalRegistration;
	final value:nkgpu_pipeline_builder;
	var consumed:Bool = false;

	@:allow(haxeon.gpu.Pipeline)
	private function new(renderer:Renderer, value:nkgpu_pipeline_builder) {
		this.renderer = renderer;
		this.value = value;
		registration = renderer.registerResource(rendererClosed);
	}

	/**
	 * Reads vertex attribute `location` from buffer `bufferIndex` at byte `offset`, in `format`. Returns this builder.
	 */
	public function attribute(location:Int, bufferIndex:Int, offset:Int, format:VertexFormat):PipelineBuilder {
		ensureLive();
		if (location < 0 || bufferIndex < 0 || offset < 0)
			throw BindingError.invalidArgument("PipelineBuilder.attribute",
				"GPU vertex attribute indices and offset must be non-negative");
		GpuResult.check(NativeKitGpu.nkgpu_pipeline_attribute(value, location, bufferIndex, offset, format),
			"pipeline.attribute");
		return this;
	}

	/** Turns depth testing and writing on or off. Returns this builder. */
	public function depthStencil(enabled:Bool):PipelineBuilder {
		ensureLive();
		GpuResult.check(NativeKitGpu.nkgpu_pipeline_depth_stencil(value, enabled ? 1 : 0), "pipeline.depthStencil");
		return this;
	}

	/** Marks this pipeline builder as compute-only. */
	public function compute():PipelineBuilder {
		ensureLive();
		GpuResult.check(NativeKitGpu.nkgpu_pipeline_compute(value), "pipeline.compute");
		return this;
	}

	/** Sets how indexed draws read indices. Returns this builder. */
	public function indexType(type:IndexType):PipelineBuilder {
		ensureLive();
		GpuResult.check(NativeKitGpu.nkgpu_pipeline_index_type(value, type), "pipeline.indexType");
		return this;
	}

	/** Creates the pipeline, or answers why the device cannot. The builder is used up either way. */
	public function build():Result<Pipeline, GpuError> {
		ensureLive();
		var made = NativeKitGpu.nkgpu_pipeline_end(value);
		consumed = true;
		registration.detach();
		return GpuResult.made(made.status, "pipeline.end", () -> new Pipeline(renderer, made.out_pipeline));
	}

	@:allow(haxeon.gpu.Renderer)
	function rendererClosed():Void {
		consumed = true;
		registration.detach();
	}

	function ensureLive():Void {
		if (consumed)
			throw BindingError.invalidState("PipelineBuilder.ensureLive", "GPU pipeline builder has been consumed");
		renderer.ensureResourceOperation();
	}
}
