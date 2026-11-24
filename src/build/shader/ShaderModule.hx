package build.shader;

import haxe.Json;
import build.shader.ShaderSchema.Attribute;
import build.shader.ShaderSchema.Member;
import build.shader.ShaderSchema.Program;
import build.shader.ShaderSchema.ShaderImage;
import compiler.core.UsageError;

class ShaderModule {
	static final targets = [
		"glsl410" => "Glsl410",
		"glsl300es" => "Glsl300Es",
		"hlsl5" => "Hlsl5",
		"metal_macos" => "MetalMacos",
		"metal_ios" => "MetalIos"
	];
	static final types = [
		"float" => "Float",
		"vec2" => "Float2",
		"vec3" => "Float3",
		"vec4" => "Float4",
		"int" => "Int",
		"ivec2" => "Int2",
		"ivec3" => "Int3",
		"ivec4" => "Int4",
		"mat4" => "Mat4"
	];
	static final images = ["2d" => "TwoD", "array" => "Array", "cube" => "Cube", "cube_array" => "CubeArray"];

	public static function generate(module:String, target:String, entries:Array<Program>):String {
		var parts = module.split("."), name = parts.pop(), first:Array<Attribute> = null;
		var definitions = [], declarations = [], programs:Map<String, Array<{variant:String, program:Program}>> = [];
		var blocks:Map<String, String> = [];
		for (program in entries) {
			var attrs = program.attributes;
			attrs.sort((a, b) -> a.slot - b.slot);
			if (first == null)
				first = attrs;
			else if (Json.stringify(first) != Json.stringify(attrs))
				throw new UsageError("Programs in a module require one vertex interface");
			for (block in program.blocks) {
				var fields = block.members;
				var record = name + pascal(block.name);
				var definition = uniformRecord(record, block.size, fields);
				if (blocks.exists(record)) {
					if (blocks.get(record) != definition)
						throw new UsageError('Conflicting layouts for ${block.name}');
				} else {
					blocks.set(record, definition);
					definitions.push(definition);
					declarations.push('public static final ${camel(block.name)} = new ShaderUniformBlock<$record>(${block.slot}, ShaderStage.${pascal(block.stage)}, sizeof<$record>());');
				}
			}
			var items = programs.get(program.name);
			if (items == null) {
				items = [];
				programs.set(program.name, items);
			}
			items.push({variant: program.variant, program: program});
		}
		if (first == null)
			throw new UsageError("Shader has no programs");
		if (first.length > 0) {
			var offset = 0, fields = [], attributes = [];
			for (attr in first) {
				var field = camel(attr.name);
				fields.push('${field}Offset: $offset');
				attributes.push('{slot: ${attr.slot}, bufferIndex: 0, offset: $offset, format: VertexFormat.${types.get(attr.type)}}');
				offset += 4 * components(attr.type);
			}
			declarations.push('public static final Vertex = {stride: $offset, ${fields.join(", ")}, layout: new VertexLayout($offset, [${attributes.join(", ")}])};');
		}
		var names = [for (key in programs.keys()) key];
		names.sort(Reflect.compare);
		for (key in names) {
			var field = camel(key), entries = programs.get(key), variantType = name + pascal(key) + "Variant";
			if (entries.length == 1) {
				declarations.push('public static final $field = ${descriptor(entries[0].program, target)};');
				if (names.length == 1)
					declarations.push('public static function create(renderer:Renderer):Shader return Shader.create(renderer, $field);');
				continue;
			}
			var labels = [for (entry in entries) pascal(entry.variant)];
			definitions.push('enum $variantType { ${labels.join("; ")}; }');
			for (index => entry in entries)
				declarations.push('private static final $field${labels[index]} = ${descriptor(entry.program, target)};');
			var cases = [for (label in labels) 'case $label: $field$label;'];
			declarations.push('public static function $field(variant:$variantType):ShaderProgram return switch variant { ${cases.join(" ")} };');
			if (names.length == 1)
				declarations.push('public static function create(renderer:Renderer, variant:$variantType):Shader return Shader.create(renderer, $field(variant));');
		}
		return 'package ${parts.join(".")};\n\nimport haxeon.gpu.Enums;\nimport haxeon.gpu.Renderer;\nimport haxeon.gpu.Shader;\nimport haxeon.gpu.ShaderProgram;\nimport haxeon.gpu.ShaderUniformBlock;\nimport haxeon.gpu.VertexLayout;\n\n${definitions.join("\n")}\nclass $name {\n\t${declarations.join("\n\t")}\n}\n';
	}

	static function descriptor(program:Program, target:String):String {
		var attrs = [for (attr in program.attributes)
			'{slot: ${attr.slot}, name: ${Json.stringify(attr.name)}, semantic: ${Json.stringify(attr.semantic)}, semanticIndex: ${attr.semanticIndex}}'];
		var blocks:Array<String> = [], uniforms:Array<String> = [], textures:Array<String> = [];
		for (block in program.blocks) {
			blocks.push('{slot: ${block.slot}, stage: ShaderStage.${pascal(block.stage)}, size: ${block.size}}');
			for (index => member in block.uniforms)
				uniforms.push('{block: ${block.slot}, member: $index, name: ${Json.stringify(member.name)}, type: UniformType.${types.get(member.type)}, count: ${member.arrayCount}}');
		}
		var views:Map<Int, ShaderImage> = [];
		for (image in program.images)
			views.set(image.slot, image);
		for (pair in program.pairs) {
			var image = views.get(pair.image);
			if (image == null || image.sampleType != "float" || image.multisampled || !images.exists(image.type))
				throw new UsageError("Unsupported shader texture type");
			textures.push('{view: ${image.slot}, sampler: ${pair.sampler}, stage: ShaderStage.${pascal(image.stage)}, type: ImageType.${images.get(image.type)}, name: ${Json.stringify(pair.name)}}');
		}
		var vertex = Json.stringify(program.vertex), fragment = Json.stringify(program.fragment);
		return 'new ShaderProgram([${attrs.join(", ")}], [{\n\t\ttarget: ShaderTarget.${targets.get(target)},\n\t\tvertex: $vertex,\n\t\tfragment: $fragment,\n\t\tblocks: [${blocks.join(", ")}],\n\t\tuniforms: [${uniforms.join(", ")}],\n\t\ttextures: [${textures.join(", ")}]\n\t}])';
	}

	static function uniformRecord(name:String, size:Int, fields:Array<Member>):String {
		var declarations = [], assertions = [Std.string(size)], cursor = 0;
		for (field in fields) {
			var member = camel(field.name), width = components(field.type);
			var scalar = StringTools.startsWith(field.type, "i") ? "Int" : "Float32";
			var stride:Int = field.arrayStride ?? width * 4;
			for (index in 0...field.arrayCount) {
				var offset:Int = field.offset + index * stride;
				if (offset < cursor || (offset - cursor) % 4 != 0)
					throw new UsageError("Invalid offset in " + name);
				while (cursor < offset) {
					declarations.push('private var pad$cursor:Int;');
					cursor += 4;
				}
				var label = index == 0 ? member : member + "_" + index;
				assertions.push(Json.stringify(label));
				assertions.push(Std.string(offset));
				for (component in 0...width)
					declarations.push('public var ${component == 0 ? label : label + "_c" + component}:$scalar;');
				cursor += width * 4;
			}
		}
		if (cursor > size || (size - cursor) % 4 != 0)
			throw new UsageError("Invalid size in " + name);
		while (cursor < size) {
			declarations.push('private var pad$cursor:Int;');
			cursor += 4;
		}
		return '@:value @:repr("C") @:assertLayout(${assertions.join(", ")})\nclass $name {\n\t${declarations.join("\n\t")}\n}';
	}

	static function components(kind:String):Int
		return switch kind {
			case "float" | "int": 1;
			case "vec2" | "ivec2": 2;
			case "vec3" | "ivec3": 3;
			case "vec4" | "ivec4": 4;
			case "mat4": 16;
			case _: throw new UsageError("Unsupported shader type " + kind);
		};

	static function pascal(name:String):String {
		if (name == null || !~/^[A-Za-z][A-Za-z0-9_]*$/.match(name))
			throw new UsageError('Invalid shader identifier "$name"');
		return [for (part in name.split("_")) if (part != "") part.charAt(0).toUpperCase() + part.substr(1)].join("");
	}

	static function camel(name:String):String {
		var title = pascal(name);
		return title.charAt(0).toLowerCase() + title.substr(1);
	}
}
