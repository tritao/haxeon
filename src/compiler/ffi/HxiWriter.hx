package compiler.ffi;

import haxe.Int64;
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
	public static function write(value:HxiInterface, ?headerComment:String, ?targetOverride:String):String {
		var output = new StringBuf(),
			target = targetOverride == null ? value.target : targetOverride;
		if (headerComment != null)
			output.add(StringTools.endsWith(headerComment, "\n") ? headerComment : headerComment + "\n");
		output.add('interface ${value.name} @target("$target")');
		if (value.library != null)
			output.add(' @library("${value.library}")');
		if (value.dependencies.length > 0)
			output.add(' @depends(' + [for (dependency in value.dependencies) '"$dependency"'].join(", ") + ")");
		output.add(" {\n");
		var declarations = value.declarations.copy();
		declarations.sort((left, right) -> Reflect.compare(declarationKey(left), declarationKey(right)));
		for (declaration in declarations)
			writeDeclaration(output, value, declaration);
		output.add("}\n");
		return output.toString();
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

	static function writeDeclaration(output:StringBuf, value:HxiInterface, declaration:HxiDeclaration):Void
		switch declaration {
			case Opaque(name, _):
				writeDocumentation(output, value.documentation.get(name));
				output.add('\topaque $name;\n');
			case Alias(name, type, _):
				writeDocumentation(output, value.documentation.get(name));
				output.add('\ttype $name = ${writeType(type)};\n');
			case Handle(name, representation, destroySymbol, _):
				writeDocumentation(output, value.documentation.get(name));
				output.add('\thandle $name : ${writeType(representation)}');
				if (destroySymbol != null)
					output.add(' @destroy("$destroySymbol")');
				output.add(";\n");
			case Constant(name, constant, _):
				writeDocumentation(output, value.documentation.get(name));
				output.add('\tconst $name = $constant;\n');
			case Structure(name, size, align, fields, _):
				writeDocumentation(output, value.documentation.get(name));
				output.add('\tstruct $name @layout($size, $align) {\n');
				for (field in fields)
					writeField(output, value.documentation, name, field);
				output.add("\t}\n");
			case Enumeration(name, representation, flags, entries, _):
				writeDocumentation(output, value.documentation.get(name));
				output.add('\t${flags ? "flags" : "enum"} $name : ${writeType(representation)} {\n');
				for (entry in entries) {
					writeDocumentation(output, value.documentation.get('$name.${entry.name}'), "\t\t");
					output.add('\t\t${entry.name} = ${Int64.toStr(entry.value)};\n');
				}
				output.add("\t}\n");
			case Callback(name, parameters, result, callConvention, _):
				writeDocumentation(output, value.documentation.get(name));
				output.add('\tcallback $name = fn(${[for (parameter in parameters) writeParameter(parameter)].join(", ")}) -> ${writeType(result)}');
				if (callConvention != "cdecl")
					output.add(' @callconv("$callConvention")');
				output.add(";\n");
			case Function(name, parameters, result, symbol, leaf, callConvention, resultPolicy, _):
				writeDocumentation(output, value.documentation.get(name));
				output.add('\textern fn $name(${[for (parameter in parameters) writeParameter(parameter)].join(", ")}) -> ${writeType(result)}');
				if (symbol != null)
					output.add(' @symbol("$symbol")');
				if (leaf)
					output.add(" @leaf");
				if (resultPolicy.metadata == null)
					writeFunctionMetadataFallback(output, callConvention, resultPolicy);
				else
					writeMetadata(output, resultPolicy.metadata, ["callconv", "borrowed", "owned", "length"]);
				output.add(";\n");
		}

	static function writeField(output:StringBuf, documentation:Map<String, HxiDocumentation>, typeName:String, field:HxiField):Void {
		writeDocumentation(output, documentation.get('$typeName.${field.name}'), "\t\t");
		output.add('\t\t${field.name}: ${writeType(field.type)}');
		if (field.metadata == null) {
			if (field.offset != null)
				output.add(' @offset(${field.offset})');
			writeOwnership(output, field.ownership);
			writeHandleDisposition(output, field.handleDisposition);
			if (field.lengthField != null)
				output.add(' @length_field("${field.lengthField}")');
			if (field.structSize)
				output.add(" @struct_size");
		} else
			writeMetadata(output, field.metadata, ["offset", "borrowed", "owned", "length_field", "struct_size"]);
		output.add(";\n");
	}

	static function writeParameter(parameter:HxiParameter):String {
		var output = new StringBuf();
		output.add('${parameter.name}: ${writeType(parameter.type)}');
		if (parameter.metadata == null) {
			switch parameter.direction {
				case Out:
					output.add(" @out");
				case InOut:
					output.add(" @inout");
				case OutBuffer(size):
					output.add(' @out_buffer("$size")');
				case InArray(count):
					output.add(' @in_array("$count")');
				case OutArray(count):
					output.add(' @out_array("$count")');
				case In:
			}
			writeOwnership(output, parameter.ownership);
			writeHandleDisposition(output, parameter.handleDisposition);
			if (parameter.retained)
				output.add(" @retained");
		} else
			writeMetadata(output, parameter.metadata, [
				"out",
				"inout",
				"out_buffer",
				"in_array",
				"out_array",
				"borrowed",
				"owned",
				"retained"
			]);
		return output.toString();
	}

	static function writeFunctionMetadataFallback(output:StringBuf, callConvention:String, policy:HxiResultPolicy):Void {
		if (callConvention != "cdecl")
			output.add(' @callconv("$callConvention")');
		writeOwnership(output, policy.ownership);
		writeHandleDisposition(output, policy.handleDisposition);
		if (policy.length != null)
			output.add(' @length("${policy.length}")');
	}

	static function writeMetadata(output:StringBuf, metadata:Map<String, Array<String>>, names:Array<String>):Void {
		for (name in names) {
			var values = metadata.get(name);
			if (values == null)
				continue;
			output.add(' @$name');
			if (values.length > 0)
				output.add("(" + values.join(", ") + ")");
		}
	}

	static function writeOwnership(output:StringBuf, ownership:HxiOwnership):Void
		switch ownership {
			case Borrowed:
				output.add(" @borrowed");
			case Owned(release):
				output.add(' @owned("$release")');
			case Unspecified:
		}

	static function writeHandleDisposition(output:StringBuf, disposition:HxiHandleDisposition):Void
		switch disposition {
			case Owned:
				output.add(" @owned");
			case Unspecified:
		}

	static function writeType(value:HxiType):String
		return switch value {
			case Primitive(name) | Named(name): name;
			case Pointer(element): 'ptr<${writeType(element)}>';
			case Nullable(element): 'nullable<${writeType(element)}>';
			case Const(element): 'const<${writeType(element)}>';
			case Array(element, length): 'array<${writeType(element)}, $length>';
		};

	static function writeDocumentation(output:StringBuf, value:Null<HxiDocumentation>, indent:String = "\t"):Void {
		if (value == null || value.lines.length == 0)
			return;
		output.add(indent + "/**\n");
		for (line in value.lines)
			output.add(indent + " *" + (line.length == 0 ? "" : " " + line) + "\n");
		output.add(indent + " */\n");
	}
}
