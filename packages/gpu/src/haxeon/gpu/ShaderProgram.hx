package haxeon.gpu;

import haxeon.gpu.Enums;
import nativekit.ffi.NativeKitGpu;

/** A native shading language and version a program carries sources for. */
enum ShaderTarget {
	/** Desktop OpenGL 4.1. */
	Glsl410;

	/** OpenGL ES 3.0 and WebGL 2. */
	Glsl300Es;

	/** Direct3D 11. */
	Hlsl5;

	/** Metal on macOS. */
	MetalMacos;

	/** Metal on iOS. */
	MetalIos;

	/** Desktop OpenGL 4.3, for compute. */
	Glsl430;

	/** OpenGL ES 3.1, for compute. */
	Glsl310Es;
}

/** A vertex input a program reads. */
typedef ShaderAttribute = {
	final slot:Int;
	final name:String;
	final semantic:String;
	final semanticIndex:Int;
}

/** A uniform block a program declares. */
typedef ShaderBlock = {
	final slot:Int;
	final stage:ShaderStage;
	final size:Int;
}

/** One member of a uniform block. */
typedef ShaderUniform = {
	final block:Int;
	final member:Int;
	final name:String;
	final type:UniformType;
	final count:Int;
}

/** A texture and sampler pair a program samples. */
typedef ShaderTexture = {
	final view:Int;
	final sampler:Int;
	final stage:ShaderStage;
	final type:ImageType;
	final name:String;
}

/** A storage buffer a program reads or writes. */
typedef ShaderStorageBuffer = {
	final view:Int;
	final stage:ShaderStage;
	final readonly:Bool;
	final name:String;
}

/** The compute threadgroup size Metal needs. */
typedef ShaderThreads = {
	final x:Int;
	final y:Int;
	final z:Int;
}

/** One target's program: vertex and fragment sources, or a compute source. */
typedef ShaderTargetProgram = {
	final target:ShaderTarget;
	final vertex:Null<String>;
	final fragment:Null<String>;
	final compute:Null<String>;
	final threads:Null<ShaderThreads>;
	final blocks:Array<ShaderBlock>;
	final uniforms:Array<ShaderUniform>;
	final textures:Array<ShaderTexture>;
	final storageBuffers:Array<ShaderStorageBuffer>;
}

/** Reflected shader sources and bindings, grouped by native target. */
class ShaderProgram {
	final attributes:Array<ShaderAttribute>;
	final targets:Array<ShaderTargetProgram>;

	/** A program with `attributes` and one entry per target. */
	public function new(attributes:Array<ShaderAttribute>, targets:Array<ShaderTargetProgram>) {
		this.attributes = attributes;
		this.targets = targets;
	}

	@:allow(haxeon.gpu.Shader)
	function table():Array<nkgpu_shader_table_entry> {
		var nativeAttributes = [for (attribute in attributes) {
			var row = new nkgpu_shader_table_attribute();
			row.slot = attribute.slot;
			row.glsl_name = attribute.name;
			row.hlsl_semantic = attribute.semantic;
			row.semantic_index = attribute.semanticIndex;
			row;
		}];
		return [for (target in targets) {
			var entry = new nkgpu_shader_table_entry();
			entry.target = switch target.target {
				case Glsl410: NativeShaderTarget.Glsl410;
				case Glsl300Es: NativeShaderTarget.Glsl300Es;
				case Hlsl5: NativeShaderTarget.Hlsl5;
				case MetalMacos: NativeShaderTarget.MetalMacos;
				case MetalIos: NativeShaderTarget.MetalIos;
				case Glsl430: NativeShaderTarget.Glsl430;
				case Glsl310Es: NativeShaderTarget.Glsl310Es;
			};
			entry.vertex = target.vertex;
			entry.fragment = target.fragment;
			entry.compute = target.compute;
			var threads = target.threads;
			if (threads != null) {
				entry.threads_x = threads.x;
				entry.threads_y = threads.y;
				entry.threads_z = threads.z;
			}
			entry.set_attributes(nativeAttributes);
			entry.set_blocks([for (block in target.blocks) {
				var row = new nkgpu_shader_table_block();
				row.slot = block.slot;
				row.stage = block.stage;
				row.size = block.size;
				row;
			}]);
			entry.set_uniforms([for (uniform in target.uniforms) {
				var row = new nkgpu_shader_table_uniform();
				row.block = uniform.block;
				row.member = uniform.member;
				row.name = uniform.name;
				row.type = uniform.type;
				row.count = uniform.count;
				row;
			}]);
			entry.set_textures([for (texture in target.textures) {
				var row = new nkgpu_shader_table_texture();
				row.view = texture.view;
				row.sampler = texture.sampler;
				row.stage = texture.stage;
				row.type = texture.type;
				row.name = texture.name;
				row;
			}]);
			entry.set_storage_buffers([for (buffer in target.storageBuffers) {
				var row = new nkgpu_shader_table_storage_buffer();
				row.view = buffer.view;
				row.stage = buffer.stage;
				row.readonly = buffer.readonly ? 1 : 0;
				row.name = buffer.name;
				row;
			}]);
			entry;
		}];
	}
}
