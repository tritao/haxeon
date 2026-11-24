package build.shader;

import haxe.Json;
import sys.io.File;
import build.shader.ShaderReflection.rows;

typedef ShaderVariant = {
	final name:String;
	final programs:Array<Dynamic>;
	final members:Map<String, Array<Dynamic>>;
}

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

	public static function generate(module:String, target:String, variants:Array<ShaderVariant>):String {
		var parts = module.split("."), name = parts.pop(), first:Array<Dynamic> = null;
		var definitions = [], declarations = [], programs:Map<String, Array<{variant:String, program:Dynamic}>> = [];
		var blocks:Map<String, String> = [];
		for (variant in variants)
			for (program in variant.programs) {
				var attrs = rows(program, "attrs");
				attrs.sort((a, b) -> a.slot - b.slot);
				if (first == null)
					first = attrs;
				else if (Json.stringify(first) != Json.stringify(attrs))
					throw "Programs in a module require one vertex interface";
				for (block in rows(program, "uniform_blocks")) {
					var fields = variant.members.get(block.struct_name);
					if (fields == null)
						throw 'Missing shader layout for ${block.struct_name}';
					var record = name + pascal(block.struct_name);
					var definition = uniformRecord(record, block.size, fields);
					if (blocks.exists(record)) {
						if (blocks.get(record) != definition)
							throw 'Conflicting layouts for ${block.struct_name}';
					} else {
						blocks.set(record, definition);
						definitions.push(definition);
						declarations.push('public static final ${camel(block.struct_name)} = new ShaderUniformBlock<$record>(${block.slot}, ShaderStage.${pascal(block.stage)}, sizeof<$record>());');
					}
				}
				var items = programs.get(program.name);
				if (items == null) {
					items = [];
					programs.set(program.name, items);
				}
				items.push({variant: variant.name, program: program});
			}
		if (first == null)
			throw "Shader has no programs";
		if (first.length > 0) {
			var offset = 0, fields = [], attributes = [];
			for (attr in first) {
				var field = camel(attr.glsl_name);
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

	static function descriptor(program:Dynamic, target:String):String {
		var attrs = [for (attr in rows(program, "attrs"))
			'{slot: ${attr.slot}, name: ${Json.stringify(attr.glsl_name)}, semantic: ${Json.stringify(attr.hlsl_sem_name ?? "")}, semanticIndex: ${attr.hlsl_sem_index ?? 0}}'];
		var blocks:Array<String> = [], uniforms:Array<String> = [], textures:Array<String> = [];
		for (block in rows(program, "uniform_blocks")) {
			blocks.push('{slot: ${block.slot}, stage: ShaderStage.${pascal(block.stage)}, size: ${block.size}}');
			for (index => member in rows(block, "glsl_uniforms"))
				uniforms.push('{block: ${block.slot}, member: $index, name: ${Json.stringify(member.glsl_name)}, type: UniformType.${types.get(member.type)}, count: ${member.array_count}}');
		}
		var views:Map<Int, Dynamic> = [];
		for (view in rows(program, "views")) {
			if (view.texture == null)
				throw "Unsupported shader table resource";
			views.set(view.texture.slot, view.texture);
		}
		for (pair in rows(program, "texture_sampler_pairs")) {
			var image:Dynamic = views.get(pair.view_slot);
			if (image == null || image.sample_type != "float" || image.multisampled == true
				|| !images.exists(image.type))
				throw "Unsupported shader texture type";
			textures.push('{view: ${image.slot}, sampler: ${pair.sampler_slot}, stage: ShaderStage.${pascal(image.stage)}, type: ImageType.${images.get(image.type)}, name: ${Json.stringify(pair.glsl_name ?? pair.name)}}');
		}
		var vertex = shaderSource(program.vertex_func, target), fragment = shaderSource(program.fragment_func, target);
		return 'new ShaderProgram([${attrs.join(", ")}], [{\n\t\ttarget: ShaderTarget.${targets.get(target)},\n\t\tvertex: $vertex,\n\t\tfragment: $fragment,\n\t\tblocks: [${blocks.join(", ")}],\n\t\tuniforms: [${uniforms.join(", ")}],\n\t\ttextures: [${textures.join(", ")}]\n\t}])';
	}

	static function shaderSource(stage:Dynamic, target:String):String {
		var entry = StringTools.startsWith(target, "metal_") ? "main0" : "main";
		if (stage == null || stage.is_binary == true || stage.entry_point != entry)
			throw "Expected a shader stage with entry point " + entry;
		return Json.stringify(File.getContent(stage.path));
	}

	static function uniformRecord(name:String, size:Int, fields:Array<Dynamic>):String {
		var declarations = [], assertions = [Std.string(size)], cursor = 0;
		for (field in fields) {
			var member = camel(field.name), width = components(field.type);
			var scalar = StringTools.startsWith(field.type, "i") ? "Int" : "Float32";
			var stride:Int = field.arrayStride ?? width * 4;
			for (index in 0...cast(field.arrayCount, Int)) {
				var offset:Int = field.offset + index * stride;
				if (offset < cursor || (offset - cursor) % 4 != 0)
					throw "Invalid offset in " + name;
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
			throw "Invalid size in " + name;
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
			case _: throw "Unsupported shader type " + kind;
		};

	static function pascal(name:String):String {
		if (name == null || !~/^[A-Za-z][A-Za-z0-9_]*$/.match(name))
			throw 'Invalid shader identifier "$name"';
		return [for (part in name.split("_")) if (part != "") part.charAt(0).toUpperCase() + part.substr(1)].join("");
	}

	static function camel(name:String):String {
		var title = pascal(name);
		return title.charAt(0).toLowerCase() + title.substr(1);
	}
}
