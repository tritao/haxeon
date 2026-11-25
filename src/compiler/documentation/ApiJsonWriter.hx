package compiler.documentation;

import compiler.core.InternalError;
import compiler.documentation.ApiModel.ApiArgument;
import compiler.documentation.ApiModel.ApiDeclaration;
import compiler.documentation.ApiModel.ApiMember;
import compiler.documentation.ApiModel.ApiModule;
import compiler.documentation.ApiModel.ApiSource;
import compiler.documentation.ApiModel.ApiType;
import compiler.documentation.ApiModel.ApiTypeParameter;
import haxe.Json;

/**
 * Writes the model as docs/design/API_MODEL.md specifies it: each record's fields in the order the schema lists them, and
 * a member's or a type's fields only as its kind has them. Written field by field, so the output is the schema whatever the
 * records hold, and the same model always gives the same bytes.
 */
class ApiJsonWriter {
	public static function emit(model:ApiModel):String {
		var output = new JsonOutput();
		output.open();
		output.number("version", model.version);
		output.list("described", model.described, text);
		output.list("modules", model.modules, module, true);
		output.list("types", model.types, declaration, true);
		output.close();
		return output.text() + "\n";
	}

	static function module(output:JsonOutput, value:ApiModule):Void {
		output.open();
		output.string("path", value.path);
		output.string("file", value.file);
		output.list("members", value.members, member);
		output.close();
	}

	static function declaration(output:JsonOutput, value:ApiDeclaration):Void {
		output.open();
		output.string("path", value.path);
		output.string("module", value.module);
		output.string("kind", value.kind);
		output.boolean("isExtern", value.isExtern);
		output.field("source", () -> source(output, value.source));
		output.list("typeParameters", value.typeParameters, typeParameter);
		output.list("supertypes", value.supertypes, type);
		output.list("interfaces", value.interfaces, type);
		output.field("underlying", () -> value.underlying == null ? output.nothing() : type(output, value.underlying));
		output.list("from", value.from, type);
		output.list("to", value.to, type);
		output.list("members", value.members, member);
		output.close();
	}

	static function source(output:JsonOutput, value:ApiSource):Void {
		output.open();
		output.string("visibility", value.visibility);
		output.field("position", () -> {
			output.open();
			output.string("file", value.position.file);
			output.number("line", value.position.line);
			output.close();
		});
		output.list("metadata", value.metadata, (output, entry) -> {
			output.open();
			output.string("name", entry.name);
			output.list("arguments", entry.arguments, (output, text) -> output.scalar(text));
			output.close();
		});
		output.field("documentation", () -> {
			var documentation = value.documentation;
			if (documentation == null) {
				output.nothing();
				return;
			}
			output.open();
			output.string("markdown", documentation.markdown);
			output.list("tags", documentation.tags, (output, tag) -> {
				output.open();
				output.string("name", tag.name);
				output.field("parameter",
					() -> tag.parameter == null ? output.nothing() : output.scalar(tag.parameter));
				output.string("text", tag.text);
				output.close();
			});
			output.close();
		});
		output.close();
	}

	static function member(output:JsonOutput, value:ApiMember):Void {
		output.open();
		output.string("name", value.name);
		output.string("kind", value.kind);
		output.boolean("isStatic", value.isStatic);
		output.field("source", () -> source(output, value.source));
		switch value.kind {
			case "field" | "enumValue":
				output.field("type", () -> type(output, required(value.type, value.kind, "type")));
			case "property":
				output.field("type", () -> type(output, required(value.type, value.kind, "type")));
				output.string("get", required(value.get, value.kind, "get"));
				output.string("set", required(value.set, value.kind, "set"));
			case _:
				output.list("typeParameters", required(value.typeParameters, value.kind, "typeParameters"),
					typeParameter);
				output.list("arguments", required(value.arguments, value.kind, "arguments"), argument);
				output.field("result", () -> type(output, required(value.result, value.kind, "result")));
				if (value.kind == "operator")
					output.string("operatorText", required(value.operatorText, value.kind, "operatorText"));
				if (value.kind == "conversion")
					output.string("conversion", required(value.conversion, value.kind, "conversion"));
		}
		output.close();
	}

	static function argument(output:JsonOutput, value:ApiArgument):Void {
		output.open();
		output.field("name", () -> value.name == null ? output.nothing() : output.scalar(value.name));
		output.field("type", () -> type(output, value.type));
		output.boolean("optional", value.optional);
		output.field("defaultValue",
			() -> value.defaultValue == null ? output.nothing() : output.scalar(value.defaultValue));
		output.close();
	}

	static function typeParameter(output:JsonOutput, value:ApiTypeParameter):Void {
		output.open();
		output.string("name", value.name);
		output.list("constraints", value.constraints, type);
		output.close();
	}

	static function type(output:JsonOutput, value:ApiType):Void {
		output.open();
		output.string("kind", value.kind);
		switch value.kind {
			case "named" | "builtin":
				output.string("path", required(value.path, value.kind, "path"));
				output.list("arguments", required(value.arguments, value.kind, "arguments"), type);
			case "parameter":
				output.string("owner", required(value.owner, value.kind, "owner"));
				output.string("name", required(value.name, value.kind, "name"));
			case "function":
				output.list("arguments", required(value.arguments, value.kind, "arguments"), type);
				output.list("optional", required(value.optional, value.kind, "optional"), flag);
				output.field("result", () -> type(output, required(value.result, value.kind, "result")));
			case "anonymous":
				output.number("id", required(value.id, value.kind, "id"));
				output.list("fields", required(value.fields, value.kind, "fields"), anonymousField);
			case "anonymousRef":
				output.number("id", required(value.id, value.kind, "id"));
			case _:
				output.string("name", required(value.name, value.kind, "name"));
		}
		output.close();
	}

	static function anonymousField(output:JsonOutput, field:AnonymousField):Void {
		output.open();
		output.string("name", field.name);
		output.field("type", () -> type(output, field.type));
		output.boolean("optional", field.optional);
		output.boolean("isFinal", field.isFinal);
		output.close();
	}

	static function flag(output:JsonOutput, value:Bool):Void
		output.scalar(value);

	static function text(output:JsonOutput, value:String):Void
		output.scalar(value);

	/** A field the schema gives every record of `kind`: the builder always sets it, so its absence is a builder bug. */
	static function required<T>(value:Null<T>, kind:String, field:String):T {
		if (value == null)
			throw new InternalError('API model: a $kind has no $field');
		return value;
	}
}

private typedef AnonymousField = {name:String, type:ApiType, optional:Bool, isFinal:Bool};

/** Builds JSON text from objects opened and closed in order, with the separators between their fields and items. */
private class JsonOutput {
	final buffer = new StringBuf();

	/** Whether the next field or item of each open object or list is its first. */
	final first:Array<Bool> = [];

	public function new() {}

	public function text():String
		return buffer.toString();

	public function open():Void {
		separate();
		buffer.add("{");
		first.push(true);
	}

	public function close():Void {
		first.pop();
		buffer.add("}");
	}

	public function field(name:String, write:() -> Void):Void {
		separate();
		buffer.add(Json.stringify(name));
		buffer.add(":");
		// The value follows its name: it is not an item of the object.
		first.push(true);
		write();
		first.pop();
	}

	public function string(name:String, value:String):Void
		field(name, () -> scalar(value));

	public function number(name:String, value:Int):Void
		field(name, () -> scalar(value));

	public function boolean(name:String, value:Bool):Void
		field(name, () -> scalar(value));

	/** With `lines`, each item on a line of its own, as the top-level lists are written so that a change diffs by entry. */
	public function list<T>(name:String, items:Array<T>, write:(JsonOutput, T) -> Void, lines:Bool = false):Void
		field(name, () -> {
			buffer.add("[");
			first.push(true);
			for (item in items) {
				if (lines) {
					separate();
					buffer.add("\n");
					first[first.length - 1] = true;
				}
				write(this, item);
			}
			first.pop();
			if (lines && items.length > 0)
				buffer.add("\n");
			buffer.add("]");
		});

	public function scalar(value:Dynamic):Void {
		separate();
		buffer.add(Json.stringify(value));
	}

	public function nothing():Void {
		separate();
		buffer.add("null");
	}

	/** A comma before every field or item of an object or list but its first. */
	function separate():Void {
		var last = first.length - 1;
		if (last < 0)
			return;
		if (!first[last])
			buffer.add(",");
		first[last] = false;
	}
}
