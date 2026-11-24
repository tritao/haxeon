package build.shader;

import compiler.core.UsageError;
import haxe.Json;
import sys.io.File;

typedef Attribute = {
	final slot:Int;
	final name:String;
	final type:String;
	final semantic:String;
	final semanticIndex:Int;
}

typedef Member = {
	final name:String;
	final type:String;
	final arrayCount:Int;
	final offset:Int;
	final arrayStride:Null<Int>;
}

typedef Block = {
	final slot:Int;
	final size:Int;
	final stage:String;
	final name:String;
	final members:Array<Member>;
	final uniforms:Array<Member>;
}

typedef ShaderImage = {
	final slot:Int;
	final stage:String;
	final type:String;
	final sampleType:String;
	final multisampled:Bool;
}

typedef ImageSampler = {
	final image:Int;
	final sampler:Int;
	final name:String;
}

typedef Program = {
	final name:String;
	final variant:String;
	final attributes:Array<Attribute>;
	final blocks:Array<Block>;
	final images:Array<ShaderImage>;
	final pairs:Array<ImageSampler>;
	final vertex:String;
	final fragment:String;
}

/** The boundary between the NativeKit reflection document and typed shader generation. */
class ShaderSchema {
	public static function read(path:String, target:String):Array<Program> {
		var root:Dynamic = Json.parse(File.getContent(path));
		if (string(root, "schema") != "nkgpu-shader-reflection/1")
			throw new UsageError("Unsupported NativeKit shader reflection schema");
		var programs = object(root, "programs"), sources = object(root, "sources"), result = [];
		var names = Reflect.fields(programs);
		names.sort(Reflect.compare);
		for (name in names) {
			var named = object(programs, name), variants = Reflect.fields(named);
			variants.sort(Reflect.compare);
			for (variant in variants)
				result.push(program(name, variant, target, object(object(object(named, variant), "targets"), target),
					sources));
		}
		return result;
	}

	static function program(name:String, variant:String, target:String, data:Dynamic, sources:Dynamic):Program {
		if (array(data, "storage_buffers").length > 0)
			throw new UsageError("Unsupported shader table resource in " + name);
		var stages = object(data, "stages"), entry = StringTools.startsWith(target, "metal_") ? "main0" : "main";
		function source(stage:String):String {
			var value = object(stages, stage);
			if (string(value, "entry_point") != entry)
				throw new UsageError('Expected entry point $entry for $stage in $name');
			return string(sources, string(value, "source"));
		}
		for (sampler in array(data, "samplers")) {
			integer(sampler, "slot");
			string(sampler, "stage");
			string(sampler, "name");
			string(sampler, "type");
		}
		return {name: name,
			variant: variant,
			attributes: array(data, "attributes").map(attribute),
			blocks: array(data, "uniform_blocks").map(block),
			images: [for (image in array(data, "images")) {
				slot:integer(image, "slot"),
					stage:string(image, "stage"),
					type:string(image, "type"),
					sampleType:string(image, "sample_type"),
					multisampled:boolean(image, "multisampled")
			}],
				pairs: [for (pair in array(data, "image_sampler_pairs")) {
			image:integer(pair, "image_slot"),
				sampler:integer(pair, "sampler_slot"),
				name:string(pair, "name")
		}],
			vertex: source("vertex"),
			fragment: source("fragment")};
	}

	static function attribute(data:Dynamic):Attribute {
		var semantic = object(data, "semantic"), format = string(data, "format");
		var type = switch format {
			case "float": "float";
			case "float2": "vec2";
			case "float3": "vec3";
			case "float4": "vec4";
			case _: throw new UsageError("Unsupported shader vertex format " + format);
		};
		return {
			slot: integer(data, "slot"),
			name: string(data, "name"),
			type: type,
			semantic: string(semantic, "name"),
			semanticIndex: integer(semantic, "index")
		};
	}

	static function block(data:Dynamic):Block {
		return {
			slot: integer(data, "slot"),
			size: integer(data, "size"),
			stage: string(data, "stage"),
			name: string(data, "name"),
			members: [for (item in array(data, "members")) member(item, true)],
			uniforms: [for (item in array(data, "gl_uniforms")) member(item, false)]
		};
	}

	static function member(data:Dynamic, layout:Bool):Member {
		return {
			name: string(data, "name"),
			type: string(data, "type"),
			arrayCount: integer(data, "array_count"),
			offset: layout ? integer(data, "offset") : 0,
			arrayStride: Reflect.hasField(data, "array_stride") ? integer(data, "array_stride") : null
		};
	}

	static function object(data:Dynamic, field:String):Dynamic {
		var value:Dynamic = Reflect.field(data, field);
		if (!Reflect.isObject(value) || Std.isOfType(value, Array) || Std.isOfType(value, String))
			throw invalid(field, "object");
		return value;
	}

	static function array(data:Dynamic, field:String):Array<Dynamic> {
		var value:Dynamic = Reflect.field(data, field);
		if (!Std.isOfType(value, Array))
			throw invalid(field, "array");
		return cast value;
	}

	static function integer(data:Dynamic, field:String):Int {
		var value:Dynamic = Reflect.field(data, field);
		if (!Std.isOfType(value, Int) || value < 0)
			throw invalid(field, "non-negative integer");
		return value;
	}

	static function string(data:Dynamic, field:String):String {
		var value:Dynamic = Reflect.field(data, field);
		if (!Std.isOfType(value, String))
			throw invalid(field, "string");
		return value;
	}

	static function boolean(data:Dynamic, field:String):Bool {
		var value:Dynamic = Reflect.field(data, field);
		if (!Std.isOfType(value, Bool))
			throw invalid(field, "boolean");
		return value;
	}

	static function invalid(field:String, type:String):UsageError
		return new UsageError('Invalid NativeKit shader reflection. Expected a $type in "$field".');
}
