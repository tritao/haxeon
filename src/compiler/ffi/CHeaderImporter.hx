package compiler.ffi;

import haxe.Json;
import haxe.Int64;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import compiler.Source.SourceFile;
import compiler.Source.SourceSpan;
import compiler.ffi.HxiModel.HxiDeclaration;
import compiler.ffi.HxiModel.HxiDocumentation;
import compiler.ffi.HxiModel.HxiField;
import compiler.ffi.HxiModel.HxiInterface;
import compiler.ffi.HxiModel.HxiOwnership;
import compiler.ffi.HxiModel.HxiHandleDisposition;
import compiler.ffi.HxiModel.HxiParameter;
import compiler.ffi.HxiModel.HxiParameterDirection;
import compiler.ffi.HxiModel.HxiResultPolicy;
import compiler.ffi.HxiModel.HxiType;
import compiler.documentation.Documentation.DocumentationTools;

typedef CLayout = {
	var size:Int;
	var align:Int;
	var offsets:Map<String, Int>;
}

/** Imports the ABI-visible subset of a C header into a raw typed HXI model. */
class CHeaderImporter {
	static final sourceCache:Map<String, String> = [];
	static final sourceFiles:Map<String, SourceFile> = [];
	@:noCompletion
	static var lastLayoutText:Null<String>;

	public static function importHeader(header:String, target:String, includes:Array<String>, clang:String = "clang", ?library:String, ?interfaceName:String,
			?dependencies:Array<String>, ?excludedHeaders:Array<String>):HxiInterface {
		return importHeaderModel(header, target, includes, clang, library, interfaceName, dependencies, excludedHeaders);
	}

	static function importHeaderModel(header:String, target:String, includes:Array<String>, clang:String, ?library:String, ?interfaceName:String,
			?dependencies:Array<String>, ?excludedHeaders:Array<String>):HxiInterface {
		if (interfaceName != null && !~/^[A-Za-z_][A-Za-z0-9_]*$/.match(interfaceName))
			throw 'Invalid HXI interface name "$interfaceName"';
		if (dependencies != null)
			for (dependency in dependencies)
				if (!~/^[A-Za-z_][A-Za-z0-9_]*$/.match(dependency))
					throw 'Invalid HXI dependency name "$dependency"';
		// Keep failures bounded for Haxe's eval Process implementation; warnings are not part of the importer result.
		var base = [
			"-x",
			"c",
			"-std=c11",
			"-ffreestanding",
			"-target",
			target,
			"-w",
			"-ferror-limit=1",
			"-fno-caret-diagnostics"
		];
		for (include in includes)
			base.push('-I$include');
		var astProcess = ProcessOutputCapture.capture(clang, base.concat(["-Xclang", "-ast-dump=json", "-fsyntax-only", header]),
			ProcessOutputCapture.defaultDiagnosticLimit);
		if (astProcess.exitCode != 0)
			throw 'Clang could not import $header:\n${diagnostics(astProcess.stderr, astProcess.stderrTruncated)}';
		// Record layouts are semantic ABI data, not diagnostics. Keep the complete dump so
		// large platform headers cannot truncate the records needed by the importer.
		var layoutProcess = ProcessOutputCapture.capture(clang, base.concat(["-Xclang", "-fdump-record-layouts-complete", "-fsyntax-only", header]), null);
		if (layoutProcess.exitCode != 0)
			throw 'Clang could not calculate layouts for $header:\n${diagnostics(layoutProcess.stderr, layoutProcess.stderrTruncated)}';
		var astText = astProcess.stdout,
			layoutText = layoutProcess.stdout + layoutProcess.stderr;
		lastLayoutText = layoutText;
		var layouts = parseLayouts(layoutText),
			declarations:Array<Dynamic> = [],
			roots = [FileSystem.fullPath(Path.directory(header))];
		var excluded = [];
		if (excludedHeaders != null)
			for (excludedHeader in excludedHeaders)
				excluded.push(FileSystem.fullPath(excludedHeader));
		for (include in includes)
			roots.push(FileSystem.fullPath(include));
		collect(Json.parse(astText), declarations, roots, FileSystem.fullPath(header), excluded);
		for (declaration in declarations) {
			if (field(declaration, "kind") != "EnumDecl")
				continue;
			var enumName:String = field(declaration, "_hxiEnumName"),
				isFlags:Bool = field(declaration, "_hxiFlags") == true;
			if (enumName == null)
				continue;
			var alias:Dynamic = enumAlias(enumName, declarations),
				representation = alias == null ? null : mapType(field(field(alias, "type"), "qualType"));
			if (alias == null)
				throw '${declarationLocation(declaration)}: annotated enum "$enumName" has no matching typedef';
			if (isFlags) {
				if (representation != "u8" && representation != "u16" && representation != "u32" && representation != "u64")
					throw '${declarationLocation(declaration)}: annotated flags "$enumName" must use an unsigned 8-, 16-, 32-, or 64-bit fixed-width integer typedef';
			} else if (representation != "i8" && representation != "u8" && representation != "i16" && representation != "u16" && representation != "i32"
				&& representation != "u32")
				throw '${declarationLocation(declaration)}: annotated enum "$enumName" must use an 8-, 16-, or 32-bit fixed-width integer typedef';
			Reflect.setField(declaration, "_hxiEnumRepresentation", representation);
			Reflect.setField(declaration, "_hxiDocumentationNode", alias);
			Reflect.setField(alias, "_hxiEnumAlias", true);
		}
		declarations.sort(function(left, right) return Reflect.compare(key(left), key(right)));
		var handleNames:Map<String, Bool> = [],
			handleRecords:Map<String, Dynamic> = [],
			handleDestroySymbols:Map<String, String> = [];
		for (declaration in declarations) {
			var kind:String = field(declaration, "kind"),
				name:String = field(declaration, "name");
			if ((kind == "TypedefDecl" || kind == "RecordDecl") && hasAnnotation(declaration, "hxi:handle")) {
				handleNames.set(name, true);
				if (hasAnnotation(declaration, "hxi:handle_destroy")) {
					var destroySymbol = annotationMacroArgument(declaration, "hxi:handle_destroy");
					if (destroySymbol == null)
						throw '${declarationLocation(declaration)}: could not resolve the HXI handle destroy symbol';
					handleDestroySymbols.set(name, destroySymbol);
				}
			}
			if (kind == "RecordDecl")
				handleRecords.set(name, declaration);
		}
		var hxiDeclarations:Array<HxiDeclaration> = [],
			documentation:Map<String, HxiDocumentation> = [];
		for (declaration in declarations) {
			var imported = importDeclaration(declaration, layouts, handleNames, handleRecords, handleDestroySymbols, documentation);
			if (imported != null)
				hxiDeclarations.push(imported);
		}
		var source = sourceFile(FileSystem.fullPath(header));
		return new HxiInterface(interfaceName == null ? moduleName(header) : interfaceName, target, library, dependencies == null ? [] : dependencies.copy(),
			hxiDeclarations, source.span(0, source.bytes.length), documentation);
	}

	static function diagnostics(text:String, truncated:Bool):String
		return truncated ? '$text\n[Clang diagnostics truncated after ${ProcessOutputCapture.defaultDiagnosticLimit} bytes]' : text;

	static function collect(node:Dynamic, output:Array<Dynamic>, roots:Array<String>, currentFile:String, excluded:Array<String>):String {
		if (node == null)
			return currentFile;
		var locationFile:String = locationPath(node);
		if (locationFile != null)
			currentFile = FileSystem.fullPath(locationFile);
		Reflect.setField(node, "_hxiFile", currentFile);
		var kind:String = field(node, "kind"),
			name:String = field(node, "name"),
			annotatedEnumName:String = kind == "EnumDecl" ? enumAnnotation(node) : null,
			annotatedFlagsName:String = kind == "EnumDecl" ? flagsAnnotation(node) : null;
		if (annotatedEnumName != null)
			Reflect.setField(node, "_hxiEnumName", annotatedEnumName);
		if (annotatedFlagsName != null) {
			Reflect.setField(node, "_hxiEnumName", annotatedFlagsName);
			Reflect.setField(node, "_hxiFlags", true);
		}
		var userDeclaration = annotatedEnumName != null
			|| annotatedFlagsName != null
			|| (name != null
				&& !StringTools.startsWith(name, "__")
				&& (kind == "TypedefDecl" || kind == "RecordDecl" || kind == "FunctionDecl" || kind == "EnumDecl" || kind == "EnumConstantDecl"));
		if (userDeclaration && isUserDeclaration(node, roots, currentFile) && excluded.indexOf(currentFile) < 0)
			output.push(node);
		var inner:Array<Dynamic> = field(node, "inner");
		if (inner != null && !(kind == "EnumDecl" && (name != null || annotatedEnumName != null || annotatedFlagsName != null)))
			for (child in inner)
				currentFile = collect(child, output, roots, currentFile, excluded);
		return currentFile;
	}

	static function importDeclaration(node:Dynamic, layouts:Map<String, CLayout>, handleNames:Map<String, Bool>, handleRecords:Map<String, Dynamic>,
			handleDestroySymbols:Map<String, String>, documentation:Map<String, HxiDocumentation>):Null<HxiDeclaration> {
		var kind:String = field(node, "kind"),
			name:String = field(node, "name"),
			type:Dynamic = field(node, "type");
		switch kind {
			case "EnumDecl":
				var enumName:String = field(node, "_hxiEnumName"), annotatedRepresentation:String = field(node, "_hxiEnumRepresentation"),
					fixed:Dynamic = field(node, "fixedUnderlyingType"),
					representation = annotatedRepresentation == null ? (fixed == null ? "c_int" : mapType(field(fixed, "qualType"))) : annotatedRepresentation,
					values = [
						for (child in children(node))
							if (field(child, "kind") == "EnumConstantDecl") child
					];
				if (enumName == null)
					enumName = name;
				var documentationNode:Dynamic = field(node, "_hxiDocumentationNode");
				addDocumentation(documentation, enumName, documentationNode == null ? node : documentationNode);
				var entries:Array<compiler.ffi.HxiModel.HxiEnumValue> = [],
					nextValue = Int64.parseString("0");
				for (entry in values) {
					var entryName:String = field(entry, "name"),
						rawValue = constantValue(entry);
					if (rawValue == null)
						rawValue = Int64.toStr(nextValue);
					var projectedValue = projectedIntegerValue(entry, rawValue, field(node, "_hxiFlags") == true);
					if (field(entry, "_hxiFile") == null)
						Reflect.setField(entry, "_hxiFile", field(node, "_hxiFile"));
					addDocumentation(documentation, '$enumName.$entryName', entry);
					entries.push({name: entryName, value: Int64.parseString(projectedValue), span: sourceSpan(entry)});
					nextValue = Int64.add(Int64.parseString(projectedValue), Int64.parseString("1"));
				}
				return Enumeration(enumName, typeFromProjection(representation), field(node, "_hxiFlags") == true, entries, sourceSpan(node));
			case "EnumConstantDecl":
				var value = projectedConstantValue(node);
				if (value == null)
					return null;
				addDocumentation(documentation, name, node);
				return Constant(name, value, sourceSpan(node));
			case "TypedefDecl":
				var qualified:String = field(type, "qualType"),
					callback = functionPointer(qualified);
				if (hasAnnotation(node, "hxi:bool32")) {
					if (mapType(qualified) != "u32")
						throw '${declarationLocation(node)}: ABI bool typedef "$name" must use uint32_t storage';
					addDocumentation(documentation, name, node);
					return Alias(name, Primitive("bool32"), sourceSpan(node));
				}
				if (handleNames.exists(name)) {
					validateHandle(name, qualified, layouts, handleRecords);
					addDocumentation(documentation, name, node);
					return Handle(name, Primitive("u32"), handleDestroySymbols.get(name), sourceSpan(node));
				}
				if (callback != null) {
					addDocumentation(documentation, name, node);
					var parameters:Array<HxiParameter> = [];
					for (index in 0...callback.arguments.length)
						parameters.push({
							name: 'arg$index',
							type: typeFromProjection(mapType(callback.arguments[index])),
							direction: In,
							ownership: Unspecified,
							handleDisposition: Unspecified,
							retained: false,
							metadata: [],
							span: sourceSpan(node)
						});
					return Callback(name, parameters, typeFromProjection(mapType(callback.result)), callback.callConvention, sourceSpan(node));
				}
				if (field(node, "_hxiEnumAlias") == true)
					return null;
				if (!StringTools.startsWith(qualified, "struct ") && !StringTools.startsWith(qualified, "enum ")) {
					addDocumentation(documentation, name, node);
					return Alias(name, typeFromProjection(mapType(qualified)), sourceSpan(node));
				}
				return null;
			case "RecordDecl":
				if (handleNames.exists(name))
					return null;
				var fields:Array<Dynamic> = [for (child in children(node)) if (field(child, "kind") == "FieldDecl") child];
				if (fields.length == 0)
					return null;
				var layout = layouts.get(name),
					modelFields:Array<HxiField> = [];
				addDocumentation(documentation, name, node);
				for (entry in fields) {
					var fieldName:String = field(entry, "name"),
						fieldType:Dynamic = field(entry, "type"),
						qualifiedType:String = field(fieldType, "qualType"),
						offset = layout == null ? null : layout.offsets.get(fieldName);
					if (StringTools.endsWith(qualifiedType, "[]"))
						throw '${declarationLocation(entry)}: unsupported flexible array field "$fieldName"';
					addDocumentation(documentation, '$name.$fieldName', entry);
					var typeName = fieldTypeProjection(entry, qualifiedType),
						borrowed = hasAnnotation(entry, "hxi:borrowed"),
						lengthField = fieldLengthField(entry),
						structSize = hasAnnotation(entry, "hxi:struct_size"),
						metadata:Map<String, Array<String>> = [];
					if (offset != null)
						metadata.set("offset", [Std.string(offset)]);
					if (borrowed)
						metadata.set("borrowed", []);
					if (lengthField != null)
						metadata.set("length_field", ['"$lengthField"']);
					if (structSize)
						metadata.set("struct_size", []);
					modelFields.push({
						name: fieldName,
						type: typeFromProjection(typeName),
						offset: offset,
						ownership: borrowed ? Borrowed : Unspecified,
						handleDisposition: Unspecified,
						lengthField: lengthField,
						structSize: structSize,
						metadata: metadata,
						span: sourceSpan(entry)
					});
				}
				return Structure(name, layout == null ? 0 : layout.size, layout == null ? 0 : layout.align, modelFields, sourceSpan(node));
			case "FunctionDecl":
				if (field(node, "variadic") == true)
					throw '${declarationLocation(node)}: unsupported variadic function "$name"';
				var parameters = [for (child in children(node)) if (field(child, "kind") == "ParmVarDecl") child],
					rawSignature:String = field(type, "qualType"),
					callConvention = callingConvention(rawSignature),
					signature = stripCallingConvention(rawSignature),
					result = StringTools.trim(signature.substring(0, signature.indexOf("("))),
					borrowedUtf8 = hasAnnotation(node, "hxi:returns_borrowed_utf8"),
					owned = hasAnnotation(node, "hxi:owned");
				addDocumentation(documentation, name, node);
				var modelParameters:Array<HxiParameter> = [for (parameter in parameters) parameterModel(parameter)],
					resultMetadata:Map<String, Array<String>> = [],
					ownership:HxiOwnership = Unspecified,
					handleDisposition:HxiHandleDisposition = Unspecified;
				if (callConvention != "cdecl")
					resultMetadata.set("callconv", ['"$callConvention"']);
				if (borrowedUtf8) {
					ownership = Borrowed;
					resultMetadata.set("borrowed", []);
				}
				if (owned) {
					handleDisposition = Owned;
					resultMetadata.set("owned", []);
				}
				var policy:HxiResultPolicy = {
					ownership: ownership,
					handleDisposition: handleDisposition,
					length: null,
					metadata: resultMetadata
				};
				return Function(name, modelParameters, typeFromProjection(borrowedUtf8 ? "utf8" : mapType(result)), null, false, callConvention, policy,
					sourceSpan(node));
			case _:
				return null;
		}
	}

	static function parameterModel(parameter:Dynamic):HxiParameter {
		var direction = parameterDirection(parameter),
			type:Dynamic = field(parameter, "type"),
			qualified:String = field(type, "qualType"),
			retained = hasAnnotation(parameter, "hxi:retained"),
			owned = hasAnnotation(parameter, "hxi:owned"),
			metadata = direction.metadata;
		if (owned)
			metadata.set("owned", []);
		if (retained)
			metadata.set("retained", []);
		var projected:String;
		if (hasAnnotation(parameter, "hxi:utf8_array"))
			projected = switch direction.direction {
				case OutArray(_): "nullable<ptr<utf8>>";
				case _: "ptr<utf8>";
			};
		else if (hasAnnotation(parameter, "hxi:nullable_utf8"))
			projected = "nullable<utf8>";
		else if (hasAnnotation(parameter, "hxi:utf8"))
			projected = "utf8";
		else {
			if (switch direction.direction {
					case OutBuffer(_): true;
					case _: false;
				}) {
				var desugared:String = field(type, "desugaredQualType");
				if (desugared != null)
					qualified = desugared;
				}
			projected = mapType(qualified);
			if ((switch direction.direction {
				case OutBuffer(_): true;
				case _: false;
			}) && !StringTools.startsWith(projected, "nullable<"))
				projected = 'nullable<$projected>';
		}
		return {
			name: field(parameter, "name"),
			type: typeFromProjection(projected),
			direction: direction.direction,
			ownership: Unspecified,
			handleDisposition: owned ? Owned : Unspecified,
			retained: retained,
			metadata: metadata,
			span: sourceSpan(parameter)
		};
	}

	static function parameterDirection(parameter:Dynamic):{direction:HxiParameterDirection, metadata:Map<String, Array<String>>} {
		var file:String = field(parameter, "_hxiFile"),
			metadata:Map<String, Array<String>> = [];
		if (file == null || !FileSystem.exists(file))
			return {direction: In, metadata: metadata};
		for (child in children(parameter)) {
			if (field(child, "kind") != "AnnotateAttr")
				continue;
			var range:Dynamic = field(child, "range"),
				begin:Dynamic = field(range, "begin"),
				end:Dynamic = field(range, "end"),
				spellingBegin:Dynamic = field(begin, "spellingLoc"),
				spellingEnd:Dynamic = field(end, "spellingLoc");
			if (spellingBegin == null)
				spellingBegin = begin;
			if (spellingEnd == null)
				spellingEnd = end;
			var annotation = sourceRange(file, spellingBegin, spellingEnd),
				argument:Null<String> = null;
			if (annotation.indexOf("hxi:out_array") >= 0) {
				argument = expansionArgument(parameter, child);
				if (argument == null)
					throw '${declarationLocation(parameter)}: could not resolve output-array count parameter';
				metadata.set("out_array", ['"$argument"']);
				return {direction: OutArray(argument), metadata: metadata};
			}
			if (annotation.indexOf("hxi:in_array") >= 0) {
				argument = expansionArgument(parameter, child);
				if (argument == null)
					throw '${declarationLocation(parameter)}: could not resolve input-array count parameter';
				metadata.set("in_array", ['"$argument"']);
				return {direction: InArray(argument), metadata: metadata};
			}
			if (annotation.indexOf("hxi:out_buffer") >= 0) {
				var direct = ~/hxi:out_buffer=([A-Za-z_][A-Za-z0-9_]*)/;
				if (direct.match(annotation))
					argument = direct.matched(1);
				else {
					var expansion:Dynamic = field(begin, "expansionLoc"),
						offset:Dynamic = field(expansion, "offset"),
						expansionFile:String = field(expansion, "file");
					if (offset != null) {
						var expansionSource = File.getContent(expansionFile == null ? file : expansionFile),
							invocation = expansionSource.substring(offset, Std.int(Math.min(expansionSource.length, offset + 256))),
							pattern = ~/^[A-Za-z_][A-Za-z0-9_]*\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)/;
						if (pattern.match(invocation))
							argument = pattern.matched(1);
					}
				}
				if (argument == null)
					throw '${declarationLocation(parameter)}: could not resolve output-buffer size parameter';
				metadata.set("out_buffer", ['"$argument"']);
				return {direction: OutBuffer(argument), metadata: metadata};
			}
			if (annotation.indexOf("hxi:inout") >= 0) {
				metadata.set("inout", []);
				return {direction: InOut, metadata: metadata};
			}
			if (annotation.indexOf("hxi:out") >= 0) {
				metadata.set("out", []);
				return {direction: Out, metadata: metadata};
			}
		}
		return {direction: In, metadata: metadata};
	}

	static function fieldLengthField(entry:Dynamic):Null<String> {
		for (child in children(entry)) {
			if (field(child, "kind") != "AnnotateAttr")
				continue;
			var annotation = annotationSource(entry, child);
			if (annotation.indexOf("hxi:length_field") < 0)
				continue;
			var direct = ~/hxi:length_field=([A-Za-z_][A-Za-z0-9_]*)/;
			if (direct.match(annotation))
				return direct.matched(1);
			var argument = expansionArgument(entry, child);
			if (argument == null)
				throw '${declarationLocation(entry)}: could not resolve borrowed-buffer length field';
			return argument;
		}
		return null;
	}

	static function typeFromProjection(value:String):HxiType {
		value = StringTools.trim(value);
		for (wrapper in ["ptr", "const", "nullable"])
			if (StringTools.startsWith(value, wrapper + "<") && StringTools.endsWith(value, ">")) {
				var element = typeFromProjection(value.substring(wrapper.length + 1, value.length - 1));
				return switch wrapper {
					case "ptr": Pointer(element);
					case "const": Const(element);
					default: Nullable(element);
				};
			}
		if (StringTools.startsWith(value, "array<") && StringTools.endsWith(value, ">")) {
			var inner = value.substring(6, value.length - 1), depth = 0, separator = -1;
			for (index in 0...inner.length) {
				var code = inner.charAt(index);
				if (code == "<")
					depth++;
				else if (code == ">")
					depth--;
				else if (code == "," && depth == 0) {
					separator = index;
					break;
				}
			}
			if (separator < 0)
				throw 'Invalid imported HXI array type "$value"';
			var element = typeFromProjection(inner.substring(0, separator)),
				length = Std.parseInt(StringTools.trim(inner.substring(separator + 1)));
			if (length == null)
				throw 'Invalid imported HXI array length in "$value"';
			return Array(element, length);
		}
		return switch value {
			case "void" | "i8" | "u8" | "i16" | "u16" | "i32" | "u32" | "i64" | "u64" | "bool32" | "isize" | "usize" | "f32" | "f64" | "utf8" | "c_char" |
				"c_schar" | "c_uchar" | "c_bool" | "c_short" | "c_ushort" | "c_int" | "c_uint" | "c_long" | "c_ulong" | "c_long_long" | "c_ulong_long" |
				"c_wchar" | "c_size": Primitive(value);
			case _: Named(value);
		};
	}

	static function addDocumentation(documentation:Map<String, HxiDocumentation>, name:String, node:Dynamic):Void {
		var raw = documentationText(node);
		if (raw == null)
			return;
		var normalized = DocumentationTools.normalize(raw);
		if (normalized.lines.length == 0)
			return;
		documentation.set(name, {
			raw: normalized.raw,
			lines: normalized.lines,
			source: projectionDocumentation(normalized.lines),
			indentedSource: projectionDocumentation(normalized.lines, "\t")
		});
	}

	static function sourceSpan(node:Dynamic):SourceSpan {
		var path:String = field(node, "_hxiFile");
		if (path == null)
			path = "<header>";
		var source = sourceFile(path),
			range:Dynamic = field(node, "range"),
			begin:Dynamic = field(range, "begin"),
			end:Dynamic = field(range, "end"),
			location:Dynamic = field(node, "loc"),
			start:Dynamic = field(begin, "offset");
		if (start == null)
			start = field(location, "offset");
		var finish:Dynamic = field(end, "offset"),
			tokenLength:Dynamic = field(end, "tokLen");
		if (start == null)
			start = 0;
		if (finish == null)
			finish = start;
		else
			finish += tokenLength == null ? 1 : tokenLength;
		var first = Std.int(Math.max(0, Math.min(source.bytes.length, start))),
			last = Std.int(Math.max(first, Math.min(source.bytes.length, finish)));
		return source.span(first, last);
	}

	static function sourceFile(path:String):SourceFile {
		var cached = sourceFiles.get(path);
		if (cached != null)
			return cached;
		var text = FileSystem.exists(path) ? File.getContent(path) : "",
			source = new SourceFile(path, text);
		sourceFiles.set(path, source);
		return source;
	}

	static function projectionDocumentation(lines:Array<String>, indent:String = ""):String {
		var output = new StringBuf();
		output.add(indent + "/**\n");
		for (line in lines)
			output.add(indent + " *" + (line.length == 0 ? "" : " " + line) + "\n");
		output.add(indent + " */\n");
		return output.toString();
	}

	static function validateHandle(name:String, qualified:String, layouts:Map<String, CLayout>, records:Map<String, Dynamic>):Void {
		if (!StringTools.startsWith(qualified, "struct ")) {
			if (mapType(qualified) != "u32")
				throw 'Handle "$name" must use uint32_t storage';
			return;
		}
		var recordName = qualified.substring(7),
			layout = layouts.get(recordName),
			record = records.get(recordName);
		if (layout == null || layout.size != 4 || layout.align != 4 || record == null)
			throw 'Handle "$name" must have a 4-byte, 4-byte-aligned record representation';
		var fields:Array<Dynamic> = [for (child in children(record)) if (field(child, "kind") == "FieldDecl") child];
		if (fields.length != 1 || field(fields[0], "name") != "id" || mapType(field(field(fields[0], "type"), "qualType")) != "u32")
			throw 'Handle "$name" must contain one uint32_t field named id';
	}

	static function documentationText(node:Dynamic):Null<String> {
		var comment:Dynamic = null;
		for (child in children(node))
			if (field(child, "kind") == "FullComment") {
				comment = child;
				break;
			}
		if (comment == null)
			return null;
		var file:String = field(node, "_hxiFile"),
			range:Dynamic = field(comment, "range"),
			begin:Dynamic = field(range, "begin"),
			offset:Dynamic = field(begin, "offset");
		if (file == null || offset == null || !FileSystem.exists(file))
			return null;
		var source = sourceCache.get(file);
		if (source == null) {
			source = File.getContent(file);
			sourceCache.set(file, source);
		}
		var start = source.lastIndexOf("/**", Std.int(offset));
		if (start < 0)
			return null;
		var close = source.indexOf("*/", start + 3);
		return close < 0 ? null : source.substring(start + 3, close);
	}

	static function fieldTypeProjection(entry:Dynamic, qualifiedType:String):String {
		for (child in children(entry)) {
			if (field(child, "kind") != "AnnotateAttr")
				continue;
			var annotation = annotationSource(entry, child);
			if (annotation.indexOf("hxi:nullable_utf8") >= 0)
				return "nullable<utf8>";
			if (annotation.indexOf("hxi:utf8") >= 0)
				return "utf8";
		}
		return mapType(qualifiedType);
	}

	static function hasAnnotation(node:Dynamic, expected:String):Bool {
		var file:String = field(node, "_hxiFile");
		if (file == null || !FileSystem.exists(file))
			return false;
		for (child in children(node)) {
			if (field(child, "kind") != "AnnotateAttr")
				continue;
			var range:Dynamic = field(child, "range"),
				begin:Dynamic = field(range, "begin"),
				end:Dynamic = field(range, "end"),
				spellingBegin:Dynamic = field(begin, "spellingLoc"),
				spellingEnd:Dynamic = field(end, "spellingLoc");
			if (spellingBegin == null)
				spellingBegin = begin;
			if (spellingEnd == null)
				spellingEnd = end;
			if (sourceRange(file, spellingBegin, spellingEnd).indexOf(expected) >= 0)
				return true;
		}
		return false;
	}

	static function annotationMacroArgument(node:Dynamic, expected:String):Null<String> {
		for (child in children(node)) {
			if (field(child, "kind") != "AnnotateAttr" || annotationSource(node, child).indexOf(expected) < 0)
				continue;
			return expansionArgument(node, child);
		}
		return null;
	}

	static function annotationSource(node:Dynamic, annotation:Dynamic):String {
		var range:Dynamic = field(annotation, "range"),
			begin:Dynamic = field(range, "begin"),
			end:Dynamic = field(range, "end"),
			spellingBegin:Dynamic = field(begin, "spellingLoc"),
			spellingEnd:Dynamic = field(end, "spellingLoc"),
			file:String = field(node, "_hxiFile");
		return sourceRange(file, spellingBegin == null ? begin : spellingBegin, spellingEnd == null ? end : spellingEnd);
	}

	static function expansionArgument(node:Dynamic, annotation:Dynamic):Null<String> {
		var range:Dynamic = field(annotation, "range"),
			begin:Dynamic = field(range, "begin"),
			expansion:Dynamic = field(begin, "expansionLoc"),
			offset:Dynamic = field(expansion, "offset"),
			file:String = field(expansion, "file");
		if (offset == null)
			return null;
		if (file == null)
			file = field(node, "_hxiFile");
		var source = File.getContent(file),
			invocation = source.substring(offset, Std.int(Math.min(source.length, offset + 256))),
			argument = ~/^[A-Za-z_][A-Za-z0-9_]*\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)/;
		return argument.match(invocation) ? argument.matched(1) : null;
	}

	static function sourceRange(defaultFile:String, begin:Dynamic, end:Dynamic):String {
		var start:Dynamic = field(begin, "offset"),
			finish:Dynamic = field(end, "offset"),
			tokenLength:Dynamic = field(end, "tokLen");
		if (start == null || finish == null)
			return "";
		var sourceFile:String = field(begin, "file"),
			source = File.getContent(sourceFile == null ? defaultFile : sourceFile);
		return source.substring(start, finish + (tokenLength == null ? 1 : tokenLength));
	}

	static function locationPath(node:Dynamic):Null<String> {
		var location:Dynamic = field(node, "loc"),
			range:Dynamic = field(node, "range"),
			begin:Dynamic = field(range, "begin"),
			expansion:Dynamic = field(begin, "expansionLoc"),
			path:String = field(expansion, "file");
		if (path != null)
			return path;
		path = field(location, "file");
		if (path != null)
			return path;
		var spelling:Dynamic = field(begin, "spellingLoc");
		path = field(spelling, "file");
		if (path != null)
			return path;
		return field(begin, "file");
	}

	static function functionPointer(type:String):Null<{arguments:Array<String>, result:String, callConvention:String}> {
		var callConvention = callingConvention(type);
		type = stripCallingConvention(type);
		var pattern = ~/^(.+)\(\s*\*\s*\)\s*\((.*)\)$/;
		if (!pattern.match(StringTools.trim(type)))
			return null;
		var arguments = StringTools.trim(pattern.matched(2));
		return {
			result: StringTools.trim(pattern.matched(1)),
			arguments: arguments == "" || arguments == "void" ? [] : [for (argument in arguments.split(",")) StringTools.trim(argument)],
			callConvention: callConvention
		};
	}

	static function callingConvention(type:String):String
		return type.indexOf("__attribute__((stdcall))") >= 0 || type.indexOf("__stdcall") >= 0 ? "stdcall" : "cdecl";

	static function stripCallingConvention(type:String):String {
		type = StringTools.replace(type, " __attribute__((stdcall))", "");
		type = StringTools.replace(type, " __attribute__((cdecl))", "");
		type = StringTools.replace(type, " __stdcall", "");
		type = StringTools.replace(type, " __cdecl", "");
		return StringTools.trim(type);
	}

	static function mapType(value:String):String {
		value = StringTools.trim(value);
		if (StringTools.endsWith(value, " _Nullable"))
			return 'nullable<${mapType(value.substring(0, value.length - 10))}>';
		if (StringTools.endsWith(value, " _Nonnull"))
			return mapType(value.substring(0, value.length - 9));
		if (StringTools.endsWith(value, "]")) {
			var split = value.lastIndexOf("[");
			if (split == value.length - 2)
				throw 'Unsupported flexible array type "$value"';
			return 'array<${mapType(value.substring(0, split))}, ${value.substring(split + 1, value.length - 1)}>';
		}
		if (StringTools.endsWith(value, "*")) {
			var pointee = StringTools.trim(value.substring(0, value.length - 1)),
				qualifiedPointer = ~/^(.*)\*\s*const$/;
			if (qualifiedPointer.match(pointee))
				return 'ptr<const<ptr<${mapType(qualifiedPointer.matched(1))}>>>';
			return 'ptr<${mapType(pointee)}>';
		}
		if (StringTools.startsWith(value, "const "))
			return 'const<${mapType(value.substring(6))}>';
		return switch value {
			case "hxi_utf8": "utf8";
			case "hxi_nullable_utf8": "nullable<utf8>";
			case "void": "void";
			case "char": "c_char";
			case "signed char": "c_schar";
			case "unsigned char": "c_uchar";
			case "short": "c_short";
			case "unsigned short": "c_ushort";
			case "int": "c_int";
			case "unsigned int": "c_uint";
			case "long": "c_long";
			case "unsigned long": "c_ulong";
			case "long long": "c_long_long";
			case "unsigned long long": "c_ulong_long";
			case "_Bool": "c_bool";
			case "float": "f32";
			case "double": "f64";
			case "int8_t": "i8";
			case "uint8_t": "u8";
			case "int16_t": "i16";
			case "uint16_t": "u16";
			case "int32_t": "i32";
			case "uint32_t": "u32";
			case "int64_t": "i64";
			case "uint64_t": "u64";
			case "intptr_t": "isize";
			case "uintptr_t": "usize";
			case "size_t": "usize";
			default: StringTools.startsWith(value, "struct ") ? value.substring(7) : StringTools.startsWith(value, "enum ") ? value.substring(5) : value;
		}
	}

	static function parseLayouts(text:String):Map<String, CLayout> {
		var result:Map<String, CLayout> = [],
			current:String = null,
			offsets:Map<String, Int> = [],
			size:Null<Int> = null,
			align:Null<Int> = null;
		for (rawLine in text.split("\n")) {
			// Clang emits CRLF on Windows.  Keep the layout grammar independent
			// of the host line ending so the record marker and size trailer are
			// still parsed before they reach the HXI model.
			var line = StringTools.endsWith(rawLine, "\r") ? rawLine.substring(0, rawLine.length - 1) : rawLine;
			var record = ~/^\s*[0-9]+\s*\|\s*(?:struct|class|union)\s+([A-Za-z_][A-Za-z0-9_]*)/;
			if (record.match(line)) {
				current = record.matched(1);
				offsets = [];
				size = null;
				align = null;
				continue;
			}
			if (current == null)
				continue;
			var fieldLine = ~/^\s*([0-9]+) \|\s+.+ ([A-Za-z_][A-Za-z0-9_]*)$/;
			if (fieldLine.match(line))
				offsets.set(fieldLine.matched(2), Std.parseInt(fieldLine.matched(1)));
			var sizeValue = ~/sizeof=([0-9]+)/;
			if (sizeValue.match(line))
				size = Std.parseInt(sizeValue.matched(1));
			var alignValue = ~/align=([0-9]+)/;
			if (alignValue.match(line))
				align = Std.parseInt(alignValue.matched(1));
			var sizeLabel = ~/\bSize:\s*([0-9]+)/;
			if (sizeLabel.match(line))
				size = Std.parseInt(sizeLabel.matched(1));
			var alignLabel = ~/\bAlignment:\s*([0-9]+)/;
			if (alignLabel.match(line))
				align = Std.parseInt(alignLabel.matched(1));
			if (size != null && align != null) {
				result.set(current, {size: size, align: align, offsets: offsets});
				current = null;
			}
		}
		return result;
	}

	static function children(node:Dynamic):Array<Dynamic> {
		var value:Array<Dynamic> = field(node, "inner");
		return value == null ? [] : value;
	}

	static function constantValue(node:Dynamic):Null<String> {
		var value:String = field(node, "value");
		if (value != null)
			return value;
		for (child in children(node)) {
			value = constantValue(child);
			if (value != null)
				return value;
		}
		return null;
	}

	static function projectedConstantValue(node:Dynamic):Null<String> {
		var value = constantValue(node);
		if (value == null || !~/^-?[0-9]+$/.match(value))
			return value;
		return projectedIntegerValue(node, value);
	}

	static function projectedIntegerValue(node:Dynamic, value:String, allowUnsigned64:Bool = false):String {
		if (allowUnsigned64 && StringTools.startsWith(value, "-")) {
			var parsedNegative = Int64.parseString(value);
			if (Int64.compare(parsedNegative, Int64.parseString("-9223372036854775808")) < 0)
				throw '${declarationLocation(node)}: flag constant "$value" does not fit a 64-bit Haxe Int64';
			return Int64.toStr(parsedNegative);
		}
		if (allowUnsigned64 && compareDecimal(value, "9223372036854775807") > 0) {
			if (compareDecimal(value, "18446744073709551615") > 0)
				throw '${declarationLocation(node)}: flag constant "$value" does not fit a 64-bit unsigned integer';
			value = "-" + subtractDecimal("18446744073709551616", value);
			return Int64.toStr(Int64.parseString(value));
		}
		var parsed = Int64.parseString(value),
			minimum = Int64.parseString("-2147483648"),
			maximum = Int64.parseString(allowUnsigned64 ? "9223372036854775807" : "4294967295");
		if (Int64.compare(parsed, minimum) < 0 || Int64.compare(parsed, maximum) > 0)
			throw '${declarationLocation(node)}: untyped constant "$value" does not fit a ${allowUnsigned64 ? "64-bit" : "32-bit"} Haxe Int';
		if (!allowUnsigned64 && Int64.compare(parsed, Int64.parseString("2147483647")) > 0)
			parsed = Int64.sub(parsed, Int64.parseString("4294967296"));
		return Int64.toStr(parsed);
	}

	static function compareDecimal(left:String, right:String):Int {
		left = stripDecimalZeros(left);
		right = stripDecimalZeros(right);
		if (left.length != right.length)
			return left.length < right.length ? -1 : 1;
		return left < right ? -1 : left > right ? 1 : 0;
	}

	static function subtractDecimal(left:String, right:String):String {
		var result = new StringBuf(), borrow = 0, rightIndex = right.length - 1;
		for (index in 0...left.length) {
			var leftDigit = left.charCodeAt(left.length - index - 1) - "0".code,
				rightDigit = rightIndex >= 0 ? right.charCodeAt(rightIndex--) - "0".code : 0,
				digit = leftDigit - rightDigit - borrow;
			borrow = digit < 0 ? 1 : 0;
			if (digit < 0)
				digit += 10;
			result.addChar("0".code + digit);
		}
		var digits = result.toString(), reversed = new StringBuf();
		for (index in 0...digits.length)
			reversed.addChar(digits.charCodeAt(digits.length - index - 1));
		return stripDecimalZeros(reversed.toString());
	}

	static function stripDecimalZeros(value:String):String {
		var index = 0;
		while (index + 1 < value.length && value.charCodeAt(index) == "0".code)
			index++;
		return value.substr(index);
	}

	/** Returns the fixed-width enum type named by an hxi:enum annotation. */
	static function enumAnnotation(node:Dynamic):Null<String>
		return integerAnnotation(node, "hxi:enum:", "enum");

	static function flagsAnnotation(node:Dynamic):Null<String>
		return integerAnnotation(node, "hxi:flags:", "flags");

	static function integerAnnotation(node:Dynamic, marker:String, kind:String):Null<String> {
		for (child in children(node)) {
			if (field(child, "kind") != "AnnotateAttr")
				continue;
			var source = annotationSource(node, child);
			if (source.indexOf(marker) < 0)
				continue;
			var direct = new EReg(marker + "([A-Za-z_][A-Za-z0-9_]*)", "");
			if (direct.match(source))
				return direct.matched(1);
			var argument = expansionArgument(node, child);
			if (argument != null)
				return argument;
			throw '${declarationLocation(node)}: could not resolve annotated $kind type';
		}
		return null;
	}

	static function enumAlias(name:String, declarations:Array<Dynamic>):Dynamic {
		for (declaration in declarations)
			if (field(declaration, "kind") == "TypedefDecl" && field(declaration, "name") == name)
				return declaration;
		return null;
	}

	static function field(value:Dynamic, name:String):Dynamic
		return value == null ? null : Reflect.field(value, name);

	static function key(value:Dynamic):String
		return Std.string(field(value, "kind")) + ":" + Std.string(field(value, "name") == null ? field(value, "_hxiEnumName") : field(value, "name"));

	static function moduleName(path:String):String {
		var name = path.split("/").pop();
		return StringTools.replace(name, ".", "_");
	}

	static function isUserDeclaration(node:Dynamic, roots:Array<String>, currentFile:String):Bool {
		var location:Dynamic = field(node, "loc");
		if (location == null)
			return false;
		for (root in roots)
			if (currentFile == root || StringTools.startsWith(currentFile, root + "/"))
				return true;
		return false;
	}

	static function declarationLocation(node:Dynamic):String {
		var location:Dynamic = field(node, "loc"),
			file:String = field(node, "_hxiFile"),
			line:Dynamic = field(location, "line"),
			column:Dynamic = field(location, "col");
		if (file == null)
			file = "<header>";
		return '$file:${line == null ? "?" : line}:${column == null ? "?" : column}';
	}
}
