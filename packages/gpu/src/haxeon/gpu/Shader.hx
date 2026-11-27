package haxeon.gpu;

import haxeon.platform.BindingError;

import haxeon.gpu.Enums;
import haxeon.gpu.Pipeline;

import haxeon.gpu.Renderer;

import haxeon.gpu.GpuResult;
import nativekit.ffi.NativeKitGpu;

import haxeon.gpu.Enums.ImageFormat;
import haxeon.gpu.Enums.ImageType;
import haxeon.gpu.Enums.ShaderLanguage;
import haxeon.gpu.Enums.ShaderStage;
import haxeon.gpu.Enums.UniformType;

/** Renderer-owned shader resource. */
class Shader implements Disposable {
	final renderer:Renderer;
	final registration:haxeon.platform.DisposalRegistration;
	final value:nkgpu_shader;
	var disposed:Bool = false;

	@:allow(haxeon.gpu.ShaderBuilder)
	private function new(renderer:Renderer, value:nkgpu_shader) {
		this.renderer = renderer;
		this.value = value;
		registration = renderer.registerResource(rendererClosed);
	}

	/**
	 * A shader from `program`, the sources and bindings the shader build generated for every backend, or why the device
	 * cannot make it (`Unsupported` where `program` has no source for the renderer's backend).
	 */
	public static function create(renderer:Renderer, program:ShaderProgram):Result<Shader, GpuError> {
		renderer.ensureResourceOperation();
		var made = NativeKitGpu.nkgpu_shader_create_from_table(renderer.nativeHandle(), program.table());
		return GpuResult.made(made.status, "shader.create", () -> new Shader(renderer, made.out_shader));
	}

	/**
	 * Starts a shader from hand-written vertex and fragment sources in `language`, whose bindings the builder
	 * declares. Generated programs and `create` are the usual route.
	 */
	public static function begin(renderer:Renderer, language:ShaderLanguage,
			vertexSource:String, fragmentSource:String):ShaderBuilder {
		renderer.ensureResourceOperation();
		var made = NativeKitGpu.nkgpu_shader_begin(renderer.nativeHandle(), language,
			vertexSource, fragmentSource);
		GpuResult.check(made.status, "shader.begin");
		return new ShaderBuilder(renderer, made.out_builder);
	}

	/** Begins a compute-only shader builder. */
	public static function beginCompute(renderer:Renderer, language:ShaderLanguage,
			computeSource:String):ShaderBuilder {
		renderer.ensureResourceOperation();
		var made = NativeKitGpu.nkgpu_shader_begin_compute(renderer.nativeHandle(), language, computeSource);
		GpuResult.check(made.status, "shader.beginCompute");
		return new ShaderBuilder(renderer, made.out_builder);
	}

	internal function nativeHandle():nkgpu_shader {
		ensureLive();
		return value;
	}

	@:allow(haxeon.gpu.Pipeline)
	function rendererOwner():Renderer
		return renderer;

	public function dispose():Void {
		if (disposed)
			return;
		renderer.ensureResourceOperation();
		GpuResult.check(NativeKitGpu.nkgpu_shader_destroy(renderer.nativeHandle(), value), "shader.dispose");
		disposed = true;
		registration.detach();
	}

	/** Whether it has been disposed. */
	public function isDisposed():Bool
		return disposed;

	@:allow(haxeon.gpu.Renderer)
	function rendererClosed():Void {
		disposed = true;
		registration.detach();
	}

	function ensureLive():Void {
		if (disposed)
			throw BindingError.disposed("Shader.ensureLive", "GPU shader has been disposed");
		renderer.ensureLive();
	}
}

/** Configures shader bindings before creating the immutable shader resource. */
class ShaderBuilder {
	final renderer:Renderer;
	final registration:haxeon.platform.DisposalRegistration;
	final value:nkgpu_shader_builder;
	var consumed:Bool = false;

	@:allow(haxeon.gpu.Shader)
	private function new(renderer:Renderer, value:nkgpu_shader_builder) {
		this.renderer = renderer;
		this.value = value;
		registration = renderer.registerResource(rendererClosed);
	}

	/** Declares uniform block `slot` of `size` bytes for `stage`. Returns this builder. */
	public function uniformBlock(slot:Int, stage:ShaderStage, size:Int):ShaderBuilder {
		ensureLive();
		if (slot < 0 || size <= 0)
			throw BindingError.invalidArgument("ShaderBuilder.uniformBlock",
				"GPU uniform block slot and size are invalid");
		GpuResult.check(NativeKitGpu.nkgpu_shader_uniform_block(value, slot, stage, size), "shader.uniformBlock");
		return this;
	}

	/** Declares vertex attribute `location`, by its GLSL name and HLSL semantic. Returns this builder. */
	public function attribute(location:Int, glslName:String, hlslSemantic:String,
			semanticIndex:Int = 0):ShaderBuilder {
		ensureLive();
		if (location < 0 || semanticIndex < 0)
			throw BindingError.invalidArgument("ShaderBuilder.attribute", "GPU shader vertex attribute is invalid");
		GpuResult.check(NativeKitGpu.nkgpu_shader_attribute(value, location, glslName,
			hlslSemantic, semanticIndex), "shader.attribute");
		return this;
	}

	/** Declares member `memberIndex` of uniform block `slot`. Returns this builder. */
	public function uniform(slot:Int, memberIndex:Int, name:String, type:UniformType,
			arrayCount:Int = 1):ShaderBuilder {
		ensureLive();
		if (slot < 0 || memberIndex < 0 || arrayCount < 0)
			throw BindingError.invalidArgument("ShaderBuilder.uniform", "GPU uniform description is invalid");
		GpuResult.check(NativeKitGpu.nkgpu_shader_uniform(value, slot, memberIndex, name, type, arrayCount),
			"shader.uniform");
		return this;
	}

	/** Declares a texture and its sampler for `stage`. Returns this builder. */
	public function texture(viewSlot:Int, samplerSlot:Int, stage:ShaderStage, name:String):ShaderBuilder {
		ensureLive();
		if (viewSlot < 0 || samplerSlot < 0)
			throw BindingError.invalidArgument("ShaderBuilder.texture", "GPU texture slots must be non-negative");
		GpuResult.check(NativeKitGpu.nkgpu_shader_texture(value, viewSlot, samplerSlot, stage, name), "shader.texture");
		return this;
	}

	/** Describes a filtering texture binding with an explicit image shape. */
	public function textureType(viewSlot:Int, samplerSlot:Int, stage:ShaderStage,
			imageType:ImageType, name:String):ShaderBuilder {
		ensureLive();
		if (viewSlot < 0 || samplerSlot < 0)
			throw BindingError.invalidArgument("ShaderBuilder.textureType", "GPU texture slots must be non-negative");
		GpuResult.check(NativeKitGpu.nkgpu_shader_texture_type(value, viewSlot, samplerSlot, stage,
			imageType, name), "shader.textureType");
		return this;
	}

	/** Describes a storage-buffer resource for a compute or graphics stage. */
	public function storageBuffer(viewSlot:Int, stage:ShaderStage = ShaderStage.Compute,
			readonly:Bool = false):ShaderBuilder {
		ensureLive();
		if (viewSlot < 0)
			throw BindingError.invalidArgument("ShaderBuilder.storageBuffer",
				"GPU storage-buffer slot must be non-negative");
		GpuResult.check(NativeKitGpu.nkgpu_shader_storage_buffer(value, viewSlot, stage,
			readonly ? 1 : 0), "shader.storageBuffer");
		return this;
	}

	/** Describes a compute storage-image resource and its access format. */
	public function storageImage(viewSlot:Int, format:ImageFormat,
			writeonly:Bool = false):ShaderBuilder {
		ensureLive();
		if (viewSlot < 0)
			throw BindingError.invalidArgument("ShaderBuilder.storageImage",
				"GPU storage-image slot must be non-negative");
		GpuResult.check(NativeKitGpu.nkgpu_shader_storage_image(value, viewSlot, format,
			writeonly ? 1 : 0), "shader.storageImage");
		return this;
	}

	/** Creates the shader, or answers why the device cannot. The builder is used up either way. */
	public function build():Result<Shader, GpuError> {
		ensureLive();
		var made = NativeKitGpu.nkgpu_shader_end(value);
		consumed = true;
		registration.detach();
		return GpuResult.made(made.status, "shader.end", () -> new Shader(renderer, made.out_shader));
	}

	@:allow(haxeon.gpu.Renderer)
	function rendererClosed():Void {
		consumed = true;
		registration.detach();
	}

	function ensureLive():Void {
		if (consumed)
			throw BindingError.invalidState("ShaderBuilder.ensureLive", "GPU shader builder has been consumed");
		renderer.ensureResourceOperation();
	}
}
