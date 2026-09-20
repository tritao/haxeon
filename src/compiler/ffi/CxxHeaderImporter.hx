package compiler.ffi;

import compiler.Source.SourceFile;
import compiler.Source.SourceSpan;
import compiler.ffi.ClangAstTools;
import compiler.ffi.ClangRecordLayouts.RecordLayout;
import compiler.ffi.ClangVtableLayouts.VtableLayout;
import compiler.ffi.CxxModel.CxxAlias;
import compiler.ffi.CxxModel.CxxBase;
import compiler.ffi.CxxModel.CxxEnum;
import compiler.ffi.CxxModel.CxxEnumValue;
import compiler.ffi.CxxModel.CxxField;
import compiler.ffi.CxxModel.CxxFunction;
import compiler.ffi.CxxModel.CxxMethod;
import compiler.ffi.CxxModel.CxxModel;
import compiler.ffi.CxxModel.CxxParameter;
import compiler.ffi.CxxModel.CxxRecord;
import compiler.ffi.CxxModel.CxxSpanElement;
import compiler.ffi.CxxModel.CxxType;
import compiler.ffi.HxiAbi.HxiAbi;
import compiler.ffi.HxiNativeSignature.HxiFunctionAbi;
import haxe.Int64;
import haxe.io.Path;
import sys.FileSystem;

typedef CxxImportResult = {
	final model:CxxModel;
	final hxi:HxiModel.HxiInterface;
	final plans:Array<HxiFunctionAbi>;
}

private typedef CxxSelectionClosure = {
	final declarations:Map<String, Bool>;
	final types:Map<String, Bool>;
	final byValue:Map<String, Bool>;
}

/** Imports the supported C++ source semantics and immediately lowers them to HXI. */
class CxxHeaderImporter {
	public static function importHeader(header:String, target:String, includes:Array<String>, clang:String = "clang++", ?library:String,
			?interfaceName:String, ?dependencies:Array<String>, ?excludedHeaders:Array<String>, standard:String = "c++20", ?defines:Array<String>,
			?compileCommands:String, trivialValues:Bool = false, lifetimes:Bool = false, virtualDispatch:Bool = false, cxxThunks:Bool = false,
			?selectedDeclarations:Array<String>, ?cxxOwnership:Map<String, String>):CxxImportResult {
		var frontend = ClangFrontend.run({
			header: header,
			target: target,
			language: "c++",
			standard: standard,
			includes: includes,
			defines: defines == null ? [] : defines,
			clang: clang,
			compileCommands: compileCommands
		});
		var sourcePath = FileSystem.fullPath(header),
			roots = [FileSystem.fullPath(Path.directory(sourcePath))];
		for (include in includes)
			roots.push(FileSystem.fullPath(include));
		var excluded:Array<String> = [];
		if (excludedHeaders != null)
			for (excludedHeader in excludedHeaders)
				excluded.push(ClangAstTools.pathKey(FileSystem.fullPath(excludedHeader)));
		var builder = new CxxAstBuilder(sourcePath, roots, excluded, frontend.layouts, frontend.vtableLayouts, selectedDeclarations, cxxOwnership);
		builder.visit(frontend.ast, [], null, sourcePath);
		var model = builder.finish(target);
		CxxSubsetValidator.throwIfInvalid(model, trivialValues, lifetimes, virtualDispatch, cxxThunks, cxxOwnership);
		var hxi = CxxAbiLowerer.lower(model, target, library, interfaceName, dependencies, trivialValues, lifetimes, virtualDispatch, cxxThunks, cxxOwnership);
		return {
			model: model,
			hxi: hxi,
			plans: HxiNativeSignature.lower(hxi, HxiAbi.forInterface(hxi), null, CxxAbiLowerer.dispatches(model))
		};
	}
}

private class CxxAstBuilder {
	final sourcePath:String;
	final roots:Array<String>;
	final excluded:Array<String>;
	final layouts:Map<String, RecordLayout>;
	final vtableLayouts:Map<String, VtableLayout>;
	final records:Array<CxxRecord> = [];
	final enums:Array<CxxEnum> = [];
	final aliases:Array<CxxAlias> = [];
	final functions:Array<CxxFunction> = [];
	final recordNames:Map<String, Bool> = [];
	final enumNames:Map<String, Bool> = [];
	final aliasNames:Map<String, Bool> = [];
	final functionSymbols:Map<String, Bool> = [];
	final selectedDeclarations:Null<Array<String>>;
	final cxxOwnership:Null<Map<String, String>>;

	public function new(sourcePath:String, roots:Array<String>, excluded:Array<String>, layouts:Map<String, RecordLayout>,
			vtableLayouts:Map<String, VtableLayout>, selectedDeclarations:Null<Array<String>>, ?cxxOwnership:Map<String, String>) {
		this.sourcePath = sourcePath;
		this.roots = roots;
		this.excluded = excluded;
		this.layouts = layouts;
		this.vtableLayouts = vtableLayouts;
		this.selectedDeclarations = selectedDeclarations;
		this.cxxOwnership = cxxOwnership;
	}

	public function visit(node:Dynamic, namespaces:Array<String>, owner:Null<String>, currentFile:String):Void {
		if (node == null)
			return;
		currentFile = ClangAstTools.updateFile(node, currentFile);
		var kind:String = ClangAstTools.field(node, "kind"),
			name:String = ClangAstTools.field(node, "name"),
			user = ClangAstTools.isUserDeclaration(node, roots, currentFile) && excluded.indexOf(ClangAstTools.pathKey(currentFile)) < 0;
		switch kind {
			case "TranslationUnitDecl" | "LinkageSpecDecl" | "ExternCContextDecl":
				for (child in ClangAstTools.children(node))
					visit(child, namespaces, owner, currentFile);
			case "NamespaceDecl":
				var nested = namespaces.copy();
				if (name != null && name.length != 0)
					nested.push(name);
				for (child in ClangAstTools.children(node))
					visit(child, nested, owner, currentFile);
			case "CXXRecordDecl":
				if (name != null
					&& name.length != 0
					&& ClangAstTools.field(node, "isImplicit") != true
					&& (user || selectedRecord(qualify(name, namespaces)))) {
					var qualified = qualify(name, namespaces),
						record = makeRecord(node, qualified, namespaces);
					if (!recordNames.exists(qualified)) {
						recordNames.set(qualified, true);
						records.push(record);
					}
				}
				// Nested records and declarations are still traversed, but methods and
				// fields of this record are handled together to preserve access sections.
				for (child in ClangAstTools.children(node))
					if (ClangAstTools.field(child, "kind") == "CXXRecordDecl")
						visit(child, namespaces, name == null ? owner : qualify(name, namespaces), currentFile);
			case "EnumDecl":
				if (name != null
					&& name.length != 0
					&& ClangAstTools.field(node, "isImplicit") != true
					&& (user || explicitlySelected(qualify(name, namespaces)))) {
					var enumModel = makeEnum(node, qualify(name, namespaces));
					if (!enumNames.exists(enumModel.qualifiedName)) {
						enumNames.set(enumModel.qualifiedName, true);
						enums.push(enumModel);
					}
				}
			case "TypedefDecl" | "TypeAliasDecl":
				if (name != null
					&& name.length != 0
					&& ClangAstTools.field(node, "isImplicit") != true
					&& (user || explicitlySelected(qualify(name, namespaces)))) {
					var alias = makeAlias(node, qualify(name, namespaces), namespaces, owner);
					if (!aliasNames.exists(alias.qualifiedName)) {
						aliasNames.set(alias.qualifiedName, true);
						aliases.push(alias);
					}
				}
			case "FunctionDecl":
				if (owner == null
					&& name != null
					&& ClangAstTools.field(node, "isImplicit") != true
					&& (user || explicitlySelected(qualify(name, namespaces)))) {
					var functionModel = makeFunction(node, qualify(name, namespaces));
					if (!functionSymbols.exists(functionModel.symbol)) {
						functionSymbols.set(functionModel.symbol, true);
						functions.push(functionModel);
					}
				}
			case _:
		}
		// A record's child declarations are not visited through the generic path;
		// all supported member declarations are parsed by makeRecord above.
	}

	public function finish(target:String):CxxModel {
		var selectedRecords = records.copy(),
			selectedEnums = enums.copy(),
			selectedAliases = aliases.copy(),
			selectedFunctions = functions.copy();
		if (selectedDeclarations != null) {
			var closure = selectionClosure(), missing:Array<String> = [];
			for (name in closure.types.keys())
				if (!recordNames.exists(name) && !enumNames.exists(name) && !aliasNames.exists(name))
					missing.push(name);
			if (missing.length > 0) {
				missing.sort(Reflect.compare);
				throw "CXX019 " + sourcePath + ": selected C++ declarations require unavailable type dependencies: " + missing.join(", ");
			}
			selectedRecords = [];
			for (record in records)
				if (closure.declarations.exists(record.qualifiedName)) {
					if (!selectedRecordExactly(record.qualifiedName)) {
						var index = record.methods.length - 1;
						while (index >= 0) {
							if (!selectedMethodExactly(record.methods[index].qualifiedName))
								record.methods.splice(index, 1);
							index--;
						}
					}
					selectedRecords.push(record);
				}
			selectedEnums = [
				for (enumModel in enums)
					if (closure.declarations.exists(enumModel.qualifiedName)) enumModel
			];
			selectedAliases = [
				for (alias in aliases)
					if (closure.declarations.exists(alias.qualifiedName)) alias
			];
			selectedFunctions = [
				for (functionModel in functions)
					if (closure.declarations.exists(functionModel.qualifiedName)) functionModel
			];
		}
		selectedRecords.sort(function(left, right) return Reflect.compare(left.qualifiedName, right.qualifiedName));
		selectedEnums.sort(function(left, right) return Reflect.compare(left.qualifiedName, right.qualifiedName));
		selectedAliases.sort(function(left, right) return Reflect.compare(left.qualifiedName, right.qualifiedName));
		selectedFunctions.sort(function(left, right) return Reflect.compare(left.symbol, right.symbol));
		var source = new SourceFile(sourcePath, FileSystem.exists(sourcePath) ? sys.io.File.getContent(sourcePath) : "");
		return new CxxModel(target, sourcePath, source.span(0, source.bytes.length), selectedRecords, selectedEnums, selectedAliases, selectedFunctions);
	}

	function explicitlySelected(name:String):Bool {
		if (selectedDeclarations != null && selectedDeclarations.indexOf(name) >= 0)
			return true;
		if (cxxOwnership != null) {
			if (cxxOwnership.exists(name))
				return true;
			for (ownerName in cxxOwnership.keys())
				if (cxxOwnership.get(ownerName) == name)
					return true;
		}
		return false;
	}

	function selectedRecord(name:String):Bool {
		if (selectedDeclarations == null)
			return false;
		for (selection in selectedDeclarations)
			if (selection == name || StringTools.startsWith(selection, name + "::"))
				return true;
		return false;
	}

	function selectedRecordExactly(name:String):Bool
		return selectedDeclarations != null && selectedDeclarations.indexOf(name) >= 0;

	function selectedMethodExactly(name:String):Bool
		return selectedDeclarations != null && selectedDeclarations.indexOf(name) >= 0;

	function selectionClosure():CxxSelectionClosure {
		var declarations:Map<String, Bool> = [],
			types:Map<String, Bool> = [],
			byValue:Map<String, Bool> = [];
		for (selection in selectedDeclarations) {
			declarations.set(selection, true);
			for (record in records)
				if (selection == record.qualifiedName || StringTools.startsWith(selection, record.qualifiedName + "::"))
					declarations.set(record.qualifiedName, true);
		}
		if (cxxOwnership != null)
			for (ownerName => releaseName in cxxOwnership) {
				declarations.set(ownerName, true);
				declarations.set(releaseName, true);
			}
		var changed = true;
		while (changed) {
			changed = false;
			for (alias in aliases)
				if (declarations.exists(alias.qualifiedName))
					changed = markType(alias.target, byValue.exists(alias.qualifiedName), declarations, types, byValue) || changed;
			for (enumModel in enums)
				if (declarations.exists(enumModel.qualifiedName))
					changed = markType(enumModel.underlying, true, declarations, types, byValue) || changed;
			for (record in records)
				if (declarations.exists(record.qualifiedName)) {
					if (byValue.exists(record.qualifiedName)) {
						for (base in record.bases)
							changed = markName(base.name, true, declarations, types, byValue) || changed;
						for (field in record.fields)
							changed = markType(field.type, true, declarations, types, byValue) || changed;
					}
					var allMethods = selectedRecordExactly(record.qualifiedName);
					for (method in record.methods)
						if (allMethods || selectedMethodExactly(method.qualifiedName)) {
							changed = markType(method.result, true, declarations, types, byValue) || changed;
							for (parameter in method.parameters)
								changed = markType(parameter.type, true, declarations, types, byValue) || changed;
						}
				}
			for (functionModel in functions)
				if (declarations.exists(functionModel.qualifiedName)) {
					changed = markType(functionModel.result, true, declarations, types, byValue) || changed;
					for (parameter in functionModel.parameters)
						changed = markType(parameter.type, true, declarations, types, byValue) || changed;
				}
		}
		return {declarations: declarations, types: types, byValue: byValue};
	}

	function markName(name:String, byValueRequired:Bool, declarations:Map<String, Bool>, types:Map<String, Bool>, byValue:Map<String, Bool>):Bool {
		var changed = false;
		if (!declarations.exists(name)) {
			declarations.set(name, true);
			changed = true;
		}
		if (!types.exists(name)) {
			types.set(name, true);
			changed = true;
		}
		if (byValueRequired && !byValue.exists(name)) {
			byValue.set(name, true);
			changed = true;
		}
		return changed;
	}

	function markType(type:CxxType, byValueRequired:Bool, declarations:Map<String, Bool>, types:Map<String, Bool>, byValue:Map<String, Bool>):Bool {
		return switch type {
			case CxxType.CxxConst(element): markType(element, byValueRequired, declarations, types, byValue);
			case CxxType.CxxPointer(element) | CxxType.CxxReference(element) | CxxType.CxxRValueReference(element):
				markType(element, false, declarations, types, byValue);
			case CxxType.CxxNamed(name): markName(name, byValueRequired, declarations, types, byValue);
			case _: false;
		};
	}

	function makeRecord(node:Dynamic, qualified:String, namespaces:Array<String>):CxxRecord {
		var name:String = ClangAstTools.field(node, "name"),
			tagUsed:String = ClangAstTools.field(node, "tagUsed"),
			definitionData:Dynamic = ClangAstTools.field(node, "definitionData"),
			layout = layouts.get(qualified);
		if (layout == null)
			layout = layouts.get(name);
		var fields:Array<CxxField> = [],
			methods:Array<CxxMethod> = [],
			bases:Array<CxxBase> = [],
			access = tagUsed == "struct" ? "public" : "private",
			hasVirtual = ClangAstTools.field(definitionData, "isPolymorphic") == true;
		var rawBases:Array<Dynamic> = ClangAstTools.field(node, "bases");
		if (rawBases != null)
			for (base in rawBases)
				bases.push({
					name: qualifyType(ClangAstTools.field(ClangAstTools.field(base, "type"), "qualType"), namespaces, qualified),
					access: stringOr(ClangAstTools.field(base, "access"), "private"),
					isVirtual: ClangAstTools.field(base, "isVirtual") == true,
					span: ClangAstTools.sourceSpan(node, sourcePath)
				});
		for (child in ClangAstTools.children(node)) {
			var childKind:String = ClangAstTools.field(child, "kind");
			if (childKind == "AccessSpecDecl") {
				access = stringOr(ClangAstTools.field(child, "access"), access);
				continue;
			}
			if (childKind == "FieldDecl") {
				var fieldName:String = ClangAstTools.field(child, "name");
				if (fieldName != null)
					fields.push({
						name: fieldName,
						type: parseType(typeName(child), namespaces, qualified),
						offset: layout == null ? null : layout.offsets.get(fieldName),
						bitfield: ClangAstTools.field(child, "isBitfield") == true,
						span: ClangAstTools.sourceSpan(child, sourcePath)
					});
				continue;
			}
			if (childKind == "CXXMethodDecl" || childKind == "CXXConstructorDecl" || childKind == "CXXDestructorDecl") {
				if (ClangAstTools.field(child, "isImplicit") == true)
					continue;
				var method = makeMethod(child, qualified, access, namespaces);
				methods.push(method);
				hasVirtual = hasVirtual || method.isVirtual;
			}
		}
		var vtable = vtableLayouts.get(qualified);
		if (vtable != null)
			for (method in methods)
				if (method.isVirtual)
					for (entry in vtable.entries)
						if (entry.owner == method.owner && entry.method == method.name) {
							method.virtualAbi = {vtableIndex: entry.index, thisAdjustment: entry.thisAdjustment};
							break;
						}
		return new CxxRecord(name, qualified, tagUsed == null ? "class" : tagUsed, ClangAstTools.field(node, "completeDefinition") == true,
			ClangAstTools.field(definitionData, "isAbstract") == true, layout == null ? 0 : layout.size, layout == null ? 0 : layout.align,
			ClangAstTools.field(definitionData, "isStandardLayout") == true, ClangAstTools.field(definitionData, "isTriviallyCopyable") == true, hasVirtual,
			bases, fields, methods, ClangAstTools.sourceSpan(node, sourcePath));
	}

	function makeMethod(node:Dynamic, owner:String, access:String, namespaces:Array<String>):CxxMethod {
		var kind:String = ClangAstTools.field(node, "kind"),
			name:String = ClangAstTools.field(node, "name"),
			type:Dynamic = ClangAstTools.field(node, "type"),
			qualifiedType:String = stringOr(ClangAstTools.field(type, "qualType"), "void ()"),
			symbol:String = stringOr(ClangAstTools.field(node, "mangledName"), ""),
			constructor = kind == "CXXConstructorDecl",
			destructor = kind == "CXXDestructorDecl";
		return new CxxMethod(owner, name == null ? "" : name, owner + "::" + (name == null ? "" : name), symbol, access,
			ClangAstTools.field(node, "storageClass") == "static", isConstMethod(qualifiedType), qualifiedType.indexOf("noexcept") >= 0,
			ClangAstTools.field(node, "virtual") == true,
			parameters(node, namespaces, owner), constructor || destructor ? CxxType.CxxVoid : parseType(resultType(qualifiedType), namespaces, owner),
			ClangAstTools.sourceSpan(node, sourcePath),
			constructor, destructor);
	}

	function makeFunction(node:Dynamic, qualified:String):CxxFunction {
		var qualifiedType:String = stringOr(ClangAstTools.field(ClangAstTools.field(node, "type"), "qualType"), "void ()");
		return new CxxFunction(ClangAstTools.field(node, "name"), qualified, stringOr(ClangAstTools.field(node, "mangledName"), ""),
			parameters(node, namespaceOf(qualified), null), parseType(resultType(qualifiedType), namespaceOf(qualified), null),
			qualifiedType.indexOf("noexcept") >= 0, ClangAstTools.sourceSpan(node, sourcePath));
	}

	function makeEnum(node:Dynamic, qualified:String):CxxEnum {
		var fixed:Dynamic = ClangAstTools.field(node, "fixedUnderlyingType"),
			underlying = fixed == null ? CxxType.CxxPrimitive("c_int") : parseType(ClangAstTools.field(fixed, "qualType"), namespaceOf(qualified), null),
			values:Array<CxxEnumValue> = [];
		for (child in ClangAstTools.children(node))
			if (ClangAstTools.field(child, "kind") == "EnumConstantDecl")
				values.push({
					name: ClangAstTools.field(child, "name"),
					value: stringOr(constantValue(child), "0"),
					span: ClangAstTools.sourceSpan(child, sourcePath)
				});
		return new CxxEnum(ClangAstTools.field(node, "name"), qualified, ClangAstTools.field(node, "scopedEnumTag") != null, underlying, values,
			ClangAstTools.sourceSpan(node, sourcePath));
	}

	function makeAlias(node:Dynamic, qualified:String, namespaces:Array<String>, owner:Null<String>):CxxAlias
		return new CxxAlias(ClangAstTools.field(node, "name"), qualified,
			parseType(stringOr(ClangAstTools.field(ClangAstTools.field(node, "type"), "qualType"), "void"), namespaces, owner),
			ClangAstTools.sourceSpan(node, sourcePath));

	function parameters(node:Dynamic, namespaces:Array<String>, owner:Null<String>):Array<CxxParameter> {
		var result:Array<CxxParameter> = [], index = 0;
		for (child in ClangAstTools.children(node))
			if (ClangAstTools.field(child, "kind") == "ParmVarDecl") {
				var name:String = ClangAstTools.field(child, "name");
				result.push({
					name: name == null ? 'arg$index' : name,
					type: parseType(typeName(child), namespaces, owner),
					span: ClangAstTools.sourceSpan(child, sourcePath)
				});
				index++;
			}
		return result;
	}

	function parseType(raw:String, namespaces:Array<String>, owner:Null<String>):CxxType {
		var value = StringTools.trim(raw);
		if (value.length == 0)
			return CxxType.CxxUnsupported(raw, "empty type");
		if (value.indexOf("volatile") >= 0)
			return CxxType.CxxUnsupported(value, "volatile-qualified types are not supported");
		if (StringTools.endsWith(value, "&&"))
			return CxxType.CxxRValueReference(parseType(StringTools.trim(value.substring(0, value.length - 2)), namespaces, owner));
		if (StringTools.endsWith(value, "&"))
			return CxxType.CxxReference(parseType(StringTools.trim(value.substring(0, value.length - 1)), namespaces, owner));
		if (StringTools.endsWith(value, "]"))
			return CxxType.CxxUnsupported(value, "array types are not supported");
		if (StringTools.endsWith(value, "* const"))
			value = StringTools.trim(value.substring(0, value.length - 6));
		if (StringTools.endsWith(value, "*"))
			return CxxType.CxxPointer(parseType(StringTools.trim(value.substring(0, value.length - 1)), namespaces, owner));
		if (StringTools.startsWith(value, "const "))
			return CxxType.CxxConst(parseType(StringTools.trim(value.substring(6)), namespaces, owner));
		if (StringTools.startsWith(value, "class ") || StringTools.startsWith(value, "struct ") || StringTools.startsWith(value, "enum "))
			value = StringTools.trim(value.substring(value.indexOf(" ") + 1));
		if (isStringViewName(value))
			return CxxType.CxxStringView;
		var spanElement = byteSpanElement(value);
		if (spanElement != null)
			return CxxType.CxxByteSpan(spanElement);
		if (StringTools.startsWith(compactType(value), "std::span<"))
			return CxxType.CxxUnsupported(value, "only dynamic read-only byte spans are supported");
		if (value.indexOf("<") >= 0 || value.indexOf(">") >= 0)
			return CxxType.CxxUnsupported(value, "dependent or template types are not supported");
		var primitive = primitiveType(value);
		return primitive == null ? CxxType.CxxNamed(qualifyType(value, namespaces, owner)) : CxxType.CxxPrimitive(primitive);
	}

	static function primitiveType(value:String):Null<String> {
		return switch StringTools.replace(StringTools.trim(value), "  ", " ") {
			case "void": "void";
			case "bool": "c_bool";
			case "char": "c_char";
			case "signed char": "c_schar";
			case "unsigned char": "c_uchar";
			case "short" | "short int": "c_short";
			case "unsigned short" | "unsigned short int": "c_ushort";
			case "int": "c_int";
			case "unsigned" | "unsigned int": "c_uint";
			case "long" | "long int": "c_long";
			case "unsigned long" | "unsigned long int": "c_ulong";
			case "long long" | "long long int": "c_long_long";
			case "unsigned long long" | "unsigned long long int": "c_ulong_long";
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
			case "uintptr_t" | "size_t" | "std::size_t": "usize";
			case "wchar_t": "c_wchar";
			case _: null;
		};
	}

	static function isStringViewName(value:String):Bool {
		value = compactType(value);
		return value == "std::string_view"
			|| value == "std::basic_string_view<char>"
			|| value == "std::basic_string_view<char,std::char_traits<char>>";
	}

	static function byteSpanElement(value:String):Null<CxxSpanElement> {
		value = compactType(value);
		var prefix = "std::span<const";
		if (!StringTools.startsWith(value, prefix) || !StringTools.endsWith(value, ">"))
			return null;
		var contents = value.substring(prefix.length, value.length - 1),
			comma = contents.indexOf(","),
			element = comma < 0 ? contents : contents.substring(0, comma),
			extent = comma < 0 ? "" : contents.substring(comma + 1);
		if (extent.length != 0 && extent != "std::dynamic_extent" && extent != "18446744073709551615" && extent != "18446744073709551615UL")
			return null;
		return switch element {
			case "std::byte": CxxSpanElement.CxxStdByte;
			case "uint8_t" | "std::uint8_t" | "unsignedchar": CxxSpanElement.CxxUInt8;
			case _: null;
		};
	}

	static function compactType(value:String):String
		return StringTools.replace(StringTools.trim(value), " ", "");

	static function typeName(node:Dynamic):String
		return stringOr(ClangAstTools.field(ClangAstTools.field(node, "type"), "desugaredQualType"),
			stringOr(ClangAstTools.field(ClangAstTools.field(node, "type"), "qualType"), ""));

	static function resultType(signature:String):String {
		var open = signature.indexOf("(");
		return open < 0 ? signature : StringTools.trim(signature.substring(0, open));
	}

	static function isConstMethod(signature:String):Bool {
		var close = signature.lastIndexOf(")");
		return close >= 0 && signature.substring(close + 1).indexOf("const") >= 0;
	}

	static function qualify(name:String, namespaces:Array<String>):String
		return name.indexOf("::") >= 0
			|| namespaces.length == 0 ? StringTools.startsWith(name, "::") ? name.substring(2) : name : namespaces.join("::") + "::" + name;

	static function qualifyType(name:String, namespaces:Array<String>, owner:Null<String>):String {
		name = StringTools.trim(name);
		if (name.indexOf("::") >= 0 || StringTools.startsWith(name, "::"))
			return StringTools.startsWith(name, "::") ? name.substring(2) : name;
		if (owner != null && owner.indexOf("::") >= 0)
			return owner.substring(0, owner.lastIndexOf("::")) + "::" + name;
		return qualify(name, namespaces);
	}

	static function namespaceOf(qualified:String):Array<String> {
		var split = qualified.lastIndexOf("::");
		return split < 0 ? [] : qualified.substring(0, split).split("::");
	}

	static function constantValue(node:Dynamic):Null<String> {
		var value:String = ClangAstTools.field(node, "value");
		if (value != null)
			return value;
		for (child in ClangAstTools.children(node)) {
			value = constantValue(child);
			if (value != null)
				return value;
		}
		return null;
	}

	static function stringOr(value:Null<String>, fallback:String):String
		return value == null ? fallback : value;
}
