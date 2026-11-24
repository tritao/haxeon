package compiler.ffi;

import haxe.Int64;
import compiler.formatter.FormatConfig;
import compiler.formatter.FormatConfig.FormatConfigTools;
import compiler.formatter.ProjectFormat;
import compiler.ffi.HxiModel.HxiDeclaration;
import compiler.ffi.HxiModel.HxiDocumentation;
import compiler.ffi.HxiModel.HxiField;
import compiler.ffi.HxiModel.HxiInterface;
import compiler.ffi.HxiModel.HxiParameter;
import compiler.ffi.HxiModel.HxiResultPolicy;
import compiler.ffi.HxiModel.HxiType;
import compiler.ffi.HxiModel.HxiOwnership;
import compiler.ffi.HxiModel.HxiHandleDisposition;

/** Serializes typed HXI models in a stable declaration and annotation order. */
class HxiWriter {
	final config:FormatConfig;
	final output = new StringBuf();
	var line = new HxiLine();

	function new(width:Null<Int>) {
		config = ProjectFormat.standard();
		if (width != null)
			config.lineWidth = width;
	}

	public static function write(value:HxiInterface, ?headerComment:String, ?targetOverride:String, ?width:Int):String
		return new HxiWriter(width).writeInterface(value, headerComment, targetOverride);

	function writeInterface(value:HxiInterface, headerComment:Null<String>, targetOverride:Null<String>):String {
		var target = targetOverride == null ? value.target : targetOverride;
		if (headerComment != null)
			output.add(StringTools.endsWith(headerComment, "\n") ? headerComment : headerComment + "\n");
		line.add('interface ${value.name}');
		var targetAnnotation = new HxiLine("@target");
		targetAnnotation.arguments(['"$target"']);
		var annotations = [targetAnnotation];
		if (value.library != null) {
			var library = new HxiLine("@library");
			library.arguments(['"${value.library}"']);
			annotations.push(library);
		}
		if (value.dependencies.length > 0) {
			var depends = new HxiLine("@depends");
			depends.arguments([for (dependency in value.dependencies) '"$dependency"']);
			annotations.push(depends);
		}
		var indent = 0;
		for (i in 0...annotations.length) {
			var annotation = annotations[i];
			if (indent * config.indentWidth + line.width + 1 + annotation.width + (i == annotations.length - 1 ? 2 : 0)
				> config.lineWidth) {
				endLine(indent);
				indent = 1;
			} else
				line.add(" ");
			line.append(annotation);
		}
		line.add(" {");
		endLine(indent);
		var declarations = value.declarations.copy();
		declarations.sort((left, right) -> Reflect.compare(declarationKey(left), declarationKey(right)));
		for (declaration in declarations)
			writeDeclaration(value, declaration);
		output.add("}\n");
		return output.toString();
	}

	function endLine(indent:Int):Void {
		output.add(FormatConfigTools.indentation(indent, config));
		line.render(output, config, indent, indent * config.indentWidth);
		output.add("\n");
		line = new HxiLine();
	}

	static function declarationKey(value:HxiDeclaration):String
		return switch value {
			case Opaque(name, _): 'Opaque:$name';
			case Alias(name, _, _) | Handle(name, _, _, _) | Callback(name, _, _, _, _): 'TypedefDecl:$name';
			case Constant(name, _, _): 'EnumConstantDecl:$name';
			case Structure(name, _, _, _, _): 'RecordDecl:$name';
			case Enumeration(name, _, _, _, _): 'EnumDecl:$name';
			case Function(name, _, _, _, _, _, _, _): 'FunctionDecl:$name';
		};

	function writeDeclaration(value:HxiInterface, declaration:HxiDeclaration):Void
		switch declaration {
			case Opaque(name, _):
				writeDocumentation(value.documentation.get(name));
				line.add('opaque $name;');
				endLine(1);
			case Alias(name, type, _):
				writeDocumentation(value.documentation.get(name));
				line.add('type $name = ');
				writeType(line, type);
				line.add(";");
				endLine(1);
			case Handle(name, representation, destroySymbol, _):
				writeDocumentation(value.documentation.get(name));
				line.add('handle $name : ');
				writeType(line, representation);
				if (destroySymbol != null)
					line.annotation("@destroy", '"$destroySymbol"');
				line.add(";");
				endLine(1);
			case Constant(name, constant, _):
				writeDocumentation(value.documentation.get(name));
				line.add('const $name = $constant;');
				endLine(1);
			case Structure(name, size, align, fields, _):
				writeDocumentation(value.documentation.get(name));
				line.add('struct $name @layout');
				line.arguments(['$size', '$align']);
				line.add(" {");
				endLine(1);
				for (field in fields)
					writeField(value.documentation, name, field);
				line.add("}");
				endLine(1);
			case Enumeration(name, representation, flags, entries, _):
				writeDocumentation(value.documentation.get(name));
				line.add('${flags ? "flags" : "enum"} $name : ');
				writeType(line, representation);
				line.add(" {");
				endLine(1);
				for (entry in entries) {
					writeDocumentation(value.documentation.get('$name.${entry.name}'), 2);
					line.add('${entry.name} = ${Int64.toStr(entry.value)};');
					endLine(2);
				}
				line.add("}");
				endLine(1);
			case Callback(name, parameters, result, callConvention, _):
				writeDocumentation(value.documentation.get(name));
				line.add('callback $name = fn');
				line.list("(", [for (parameter in parameters) writeParameter(parameter)], ")");
				line.add(" -> ");
				writeType(line, result);
				if (callConvention != "cdecl")
					line.annotation("@callconv", '"$callConvention"');
				line.add(";");
				endLine(1);
			case Function(name, parameters, result, symbol, leaf, callConvention, resultPolicy, _):
				writeDocumentation(value.documentation.get(name));
				line.add('extern fn $name');
				line.list("(", [for (parameter in parameters) writeParameter(parameter)], ")");
				line.add(" -> ");
				writeType(line, result);
				if (symbol != null)
					line.annotation("@symbol", '"$symbol"');
				if (leaf)
					line.add(" @leaf");
				if (resultPolicy.metadata == null)
					writeFunctionMetadataFallback(line, callConvention, resultPolicy);
				else
					writeMetadata(line, resultPolicy.metadata, ["callconv", "borrowed", "owned", "length", "span"]);
				line.add(";");
				endLine(1);
		}

	function writeField(documentation:Map<String, HxiDocumentation>, typeName:String,
			field:HxiField):Void {
		writeDocumentation(documentation.get('$typeName.${field.name}'), 2);
		line.add('${field.name}: ');
		writeType(line, field.type);
		if (field.metadata == null) {
			if (field.offset != null)
				line.annotation("@offset", '${field.offset}');
			writeOwnership(line, field.ownership);
			writeHandleDisposition(line, field.handleDisposition);
			if (field.lengthField != null)
				line.annotation("@length_field", '"${field.lengthField}"');
			if (field.structSize)
				line.add(" @struct_size");
		} else
			writeMetadata(line, field.metadata, ["offset", "borrowed", "owned", "length_field", "struct_size"]);
		line.add(";");
		endLine(2);
	}

	static function writeParameter(parameter:HxiParameter):HxiLine {
		var line = new HxiLine('${parameter.name}: ');
		writeType(line, parameter.type);
		if (parameter.metadata == null) {
			switch parameter.direction {
				case Out:
					line.add(" @out");
				case InOut:
					line.add(" @inout");
				case OutBuffer(size):
					line.annotation("@out_buffer", '"$size"');
				case InArray(count):
					line.annotation("@in_array", '"$count"');
				case OutArray(count):
					line.annotation("@out_array", '"$count"');
				case In:
			}
			writeOwnership(line, parameter.ownership);
			writeHandleDisposition(line, parameter.handleDisposition);
			if (parameter.retained)
				line.add(" @retained");
		} else
			writeMetadata(line, parameter.metadata, [
				"out",
				"inout",
				"out_buffer",
				"in_array",
				"out_array",
				"initial_capacity",
				"borrowed",
				"owned",
				"retained"
			]);
		return line;
	}

	static function writeFunctionMetadataFallback(line:HxiLine, callConvention:String,
			policy:HxiResultPolicy):Void {
		if (callConvention != "cdecl")
			line.annotation("@callconv", '"$callConvention"');
		writeOwnership(line, policy.ownership);
		writeHandleDisposition(line, policy.handleDisposition);
		if (policy.length != null)
			line.annotation("@length", '"${policy.length}"');
		if (policy.span != null)
			line.annotation("@span", '"${policy.span}"');
	}

	static function writeMetadata(line:HxiLine, metadata:Map<String, Array<String>>, names:Array<String>):Void {
		for (name in names) {
			var values = metadata.get(name);
			if (values == null)
				continue;
			line.add(' @$name');
			if (values.length > 0)
				line.arguments(values);
		}
	}

	static function writeOwnership(line:HxiLine, ownership:HxiOwnership):Void
		switch ownership {
			case Borrowed:
				line.add(" @borrowed");
			case Owned(release):
				line.annotation("@owned", '"$release"');
			case Unspecified:
		}

	static function writeHandleDisposition(line:HxiLine, disposition:HxiHandleDisposition):Void
		switch disposition {
			case Owned:
				line.add(" @owned");
			case Unspecified:
		}

	static function writeType(line:HxiLine, value:HxiType):Void
		switch value {
			case Primitive(name) | Named(name):
				line.add(name);
			case Pointer(element) | Nullable(element) | Const(element):
				line.add(switch value {
					case Pointer(_): "ptr<";
					case Nullable(_): "nullable<";
					case _: "const<";
				});
				writeType(line, element);
				line.add(">");
			case Array(element, length):
				var item = new HxiLine();
				writeType(item, element);
				line.list("array<", [item, new HxiLine('$length')], ">");
		}

	function writeDocumentation(value:Null<HxiDocumentation>, level:Int = 1):Void {
		if (value == null || value.lines.length == 0)
			return;
		var indent = FormatConfigTools.indentation(level, config);
		output.add(indent + "/**\n");
		for (line in value.lines)
			output.add(indent + " *" + (line.length == 0 ? "" : " " + line) + "\n");
		output.add(indent + " */\n");
	}
}

private enum HxiLinePart {
	Text(value:String);
	List(open:String, items:Array<HxiLine>, close:String, width:Int);
}

private class HxiLine {
	final parts:Array<HxiLinePart> = [];
	public var width(default, null) = 0;

	public function new(?text:String) {
		if (text != null)
			add(text);
	}

	public function add(text:String):Void {
		parts.push(Text(text));
		width += text.length;
	}

	public function append(other:HxiLine):Void {
		for (part in other.parts)
			parts.push(part);
		width += other.width;
	}

	public function annotation(name:String, argument:String):Void {
		add(" " + name);
		arguments([argument]);
	}

	public function arguments(values:Array<String>):Void
		list("(", [for (value in values) new HxiLine(value)], ")");

	public function list(open:String, items:Array<HxiLine>, close:String):Void {
		var listWidth = open.length + close.length;
		for (item in items)
			listWidth += item.width;
		if (items.length > 1)
			listWidth += (items.length - 1) * 2;
		parts.push(List(open, items, close, listWidth));
		width += listWidth;
	}

	public function render(output:StringBuf, config:FormatConfig, indent:Int, column:Int, suffixWidth:Int = 0):Int {
		var remaining = width + suffixWidth;
		for (part in parts)
			switch part {
				case Text(text):
					output.add(text);
					column += text.length;
					remaining -= text.length;
				case List(open, items, close, listWidth):
					// Include the suffix so the closing delimiter and signature are measured together.
					var split = items.length > 0 && column + remaining > config.lineWidth;
					remaining -= listWidth;
					output.add(open);
					column += open.length;
					for (i in 0...items.length) {
						var comma = i < items.length - 1;
						if (split) {
							output.add("\n" + FormatConfigTools.indentation(indent + 1, config));
							items[i].render(output, config, indent + 1, (indent + 1) * config.indentWidth,
								comma ? 1 : 0);
							if (comma)
								output.add(",");
						} else {
							column = items[i].render(output, config, indent, column);
							if (comma) {
								output.add(", ");
								column += 2;
							}
						}
					}
					if (split) {
						output.add("\n" + FormatConfigTools.indentation(indent, config));
						column = indent * config.indentWidth;
					}
					output.add(close);
					column += close.length;
			}
		return column;
	}
}
