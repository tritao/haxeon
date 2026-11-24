package haxeon.gpu;

import haxeon.gpu.Enums;
import nativekit.ffi.NativeKitGpu;

typedef ShaderTarget = NativeShaderTarget;

typedef ShaderAttribute = {
	final slot:Int;
	final name:String;
	final semantic:String;
	final semanticIndex:Int;
}

typedef ShaderBlock = {
	final slot:Int;
	final stage:ShaderStage;
	final size:Int;
}

typedef ShaderUniform = {
	final block:Int;
	final member:Int;
	final name:String;
	final type:UniformType;
	final count:Int;
}

typedef ShaderTexture = {
	final view:Int;
	final sampler:Int;
	final stage:ShaderStage;
	final type:ImageType;
	final name:String;
}

typedef ShaderTargetProgram = {
	final target:ShaderTarget;
	final vertex:String;
	final fragment:String;
	final blocks:Array<ShaderBlock>;
	final uniforms:Array<ShaderUniform>;
	final textures:Array<ShaderTexture>;
}

/** Reflected shader sources and bindings, grouped by native target. */
class ShaderProgram {
	final attributes:Array<ShaderAttribute>;
	final targets:Array<ShaderTargetProgram>;

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
			entry.target = target.target;
			entry.vertex = target.vertex;
			entry.fragment = target.fragment;
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
			entry;
		}];
	}
}
