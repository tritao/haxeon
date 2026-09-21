package compiler.ffi;

import compiler.ffi.CxxModel.CxxFunction;
import compiler.ffi.CxxModel.CxxMethod;
import compiler.ffi.CxxModel.CxxModel;
import compiler.ffi.CxxModel.CxxRecord;
import compiler.ffi.CxxModel.CxxSpanElement;
import compiler.ffi.CxxModel.CxxType;
import haxe.crypto.Sha256;

/** Emits C-ABI entry points which adapt supported C++ calls before they reach Haxeon. */
class CxxThunkGenerator {
	public static function prepare(model:CxxModel, ?cxxOwnership:Map<String, String>, forceAll:Bool = false):Void {
		for (functionModel in model.functions)
			if (forceAll
				|| !functionModel.isNoexcept
				|| needsAdapter(functionModel.parameters)
				|| ownedFunction(functionModel.qualifiedName, cxxOwnership))
				functionModel.thunkSymbol = thunkSymbol("function", functionModel.qualifiedName, functionModel.symbol);
		for (record in model.records)
			for (method in record.methods)
				if ((forceAll || !method.isNoexcept || needsAdapter(method.parameters)) && !method.isConstructor && !method.isDestructor)
					method.thunkSymbol = thunkSymbol("method", method.qualifiedName, method.symbol);
	}

	static function ownedFunction(name:String, ownership:Null<Map<String, String>>):Bool {
		if (ownership == null)
			return false;
		if (ownership.exists(name))
			return true;
		for (release in ownership)
			if (release == name)
				return true;
		return false;
	}

	static function needsAdapter(parameters:Array<CxxModel.CxxParameter>):Bool {
		for (parameter in parameters)
			if (CxxTypeTools.isStringView(parameter.type) || CxxTypeTools.isByteSpan(parameter.type))
				return true;
		return false;
	}

	public static function source(model:CxxModel):String {
		var output = new StringBuf();
		output.add("// Generated C++ adapter thunks for Haxeon. Do not edit.\n");
		output.add('#include "${escape(model.header)}"\n');
		output.add("#include <cstddef>\n");
		output.add("#include <cstdint>\n");
		output.add("#include <cstring>\n");
		output.add("#include <exception>\n\n");
		output.add("#include <span>\n");
		output.add("#include <string_view>\n\n");
		output.add("#if defined(_WIN32)\n");
		output.add("#define HAXEON_CXX_THUNK_EXPORT __declspec(dllexport)\n");
		output.add("#else\n");
		output.add("#define HAXEON_CXX_THUNK_EXPORT\n");
		output.add("#endif\n\n");
		output.add("namespace {\n");
		output.add("thread_local char haxeon_cxx_thunk_error[512] = {};\n");
		output.add("void haxeon_cxx_thunk_clear() noexcept { haxeon_cxx_thunk_error[0] = 0; }\n");
		output.add("void haxeon_cxx_thunk_fail(const char *message) noexcept {\n");
		output.add("\tif (message == nullptr) message = \"Unknown C++ exception\";\n");
		output.add("\tstd::strncpy(haxeon_cxx_thunk_error, message, sizeof(haxeon_cxx_thunk_error) - 1);\n");
		output.add("\thaxeon_cxx_thunk_error[sizeof(haxeon_cxx_thunk_error) - 1] = 0;\n");
		output.add("}\n");
		output.add("}\n\n");
		output.add("extern \"C\" HAXEON_CXX_THUNK_EXPORT const char *haxeon_cxx_thunk_last_error() noexcept {\n");
		output.add("\treturn haxeon_cxx_thunk_error[0] == 0 ? nullptr : haxeon_cxx_thunk_error;\n");
		output.add("}\n\n");

		var functions = model.functions.copy();
		functions.sort((left, right) -> Reflect.compare(left.symbol, right.symbol));
		for (functionModel in functions)
			if (functionModel.thunkSymbol != null)
				emitFunction(output, functionModel);
		var records = model.records.copy();
		records.sort((left, right) -> Reflect.compare(left.qualifiedName, right.qualifiedName));
		for (record in records) {
			var methods = record.methods.copy();
			methods.sort((left, right) -> Reflect.compare(left.symbol, right.symbol));
			for (method in methods)
				if (method.thunkSymbol != null)
					emitMethod(output, record, method);
		}
		return output.toString();
	}

	static function emitFunction(output:StringBuf, functionModel:CxxFunction):Void {
		var arguments = thunkParameterDeclarations(functionModel.parameters);
		output.add('extern "C" HAXEON_CXX_THUNK_EXPORT ${cppType(functionModel.result)} ${functionModel.thunkSymbol}(${arguments.join(", ")}) noexcept {\n');
		emitTry(output, '${functionModel.qualifiedName}(${callArguments(functionModel.parameters)})', functionModel.result);
		output.add("}\n\n");
	}

	static function emitMethod(output:StringBuf, record:CxxRecord, method:CxxMethod):Void {
		var arguments:Array<String> = [];
		if (!method.isStatic)
			arguments.push('${method.isConst ? "const " : ""}${record.qualifiedName} *__this');
		arguments = arguments.concat(thunkParameterDeclarations(method.parameters));
		var receiver = method.isStatic ? '${record.qualifiedName}::${method.name}' : '__this->${method.name}';
		output.add('extern "C" HAXEON_CXX_THUNK_EXPORT ${cppType(method.result)} ${method.thunkSymbol}(${arguments.join(", ")}) noexcept {\n');
		emitTry(output, '$receiver(${callArguments(method.parameters)})', method.result);
		output.add("}\n\n");
	}

	static function emitTry(output:StringBuf, expression:String, result:CxxType):Void {
		output.add("\thaxeon_cxx_thunk_clear();\n");
		output.add("\ttry {\n");
		if (isVoid(result))
			output.add('\t\t$expression;\n');
		else
			output.add('\t\treturn $expression;\n');
		output.add("\t} catch (const std::exception &error) {\n");
		output.add("\t\thaxeon_cxx_thunk_fail(error.what());\n");
		if (!isVoid(result))
			output.add('\t\treturn ${fallback(result)};\n');
		output.add("\t} catch (...) {\n");
		output.add("\t\thaxeon_cxx_thunk_fail(\"Unknown C++ exception\");\n");
		if (!isVoid(result))
			output.add('\t\treturn ${fallback(result)};\n');
		output.add("\t}\n");
	}

	static function thunkParameterDeclarations(parameters:Array<CxxModel.CxxParameter>):Array<String> {
		var result:Array<String> = [];
		for (index in 0...parameters.length) {
			var parameter = parameters[index];
			if (CxxTypeTools.isStringView(parameter.type)) {
				result.push('const char *arg$index');
				result.push('std::size_t arg${index}__length');
			} else if (CxxTypeTools.isByteSpan(parameter.type)) {
				result.push('const ${spanElementType(parameter.type)} *arg$index');
				result.push('std::size_t arg${index}__length');
			} else if (isFunctionPointer(parameter.type))
				result.push(functionPointerParameter(parameter.type, 'arg$index'));
			else
				result.push('${cppType(parameter.type)} arg$index');
		}
		return result;
	}

	static function callArguments(parameters:Array<CxxModel.CxxParameter>):String {
		var result:Array<String> = [];
		for (index in 0...parameters.length) {
			var type = parameters[index].type;
			result.push(CxxTypeTools.isStringView(type) ? 'std::string_view(arg$index, arg${index}__length)' : CxxTypeTools.isByteSpan(type) ? 'std::span<const ${spanElementType(type)}>(arg$index, arg${index}__length)' : 'arg$index');
		}
		return result.join(", ");
	}

	static function spanElementType(type:CxxType):String
		return switch type {
			case CxxConst(element): spanElementType(element);
			case CxxByteSpan(element): switch element {
					case CxxStdByte: "std::byte";
					case CxxUInt8: "std::uint8_t";
				};
			case _: throw "CXX016 expected a byte std::span";
		};

	static function cppType(type:CxxType):String {
		return switch type {
			case CxxVoid: "void";
			case CxxPrimitive(name): primitiveType(name);
			case CxxNamed(name): name;
			case CxxConst(element): "const " + cppType(element);
			case CxxPointer(element): cppType(element) + " *";
			case CxxReference(element): cppType(element) + " &";
			case CxxRValueReference(_): throw "CXX016 cannot generate a thunk for an rvalue reference";
			case CxxFunctionPointer(parameters, result, isNoexcept):
				cppType(result) + " (*) (" + [for (parameter in parameters) cppType(parameter)].join(", ") + ")" + (isNoexcept ? " noexcept" : "");
			case CxxStringView: throw "CXX016 std::string_view is emitted through the adapter parameter expansion";
			case CxxByteSpan(_): throw "CXX016 byte std::span is emitted through the adapter parameter expansion";
			case CxxUnsupported(raw, reason): throw 'CXX016 cannot generate a thunk for "$raw": $reason';
		};
	}

	static function functionPointerParameter(type:CxxType, name:String):String
		return switch type {
			case CxxFunctionPointer(parameters, result, isNoexcept):
				'${cppType(result)} (*$name)(${[for (parameter in parameters) cppType(parameter)].join(", ")})${isNoexcept ? " noexcept" : ""}';
			case CxxConst(element): functionPointerParameter(element, name);
			case _: throw "CXX016 expected a C++ function pointer parameter";
		};

	static function isFunctionPointer(type:CxxType):Bool
		return switch type {
			case CxxFunctionPointer(_, _, _): true;
			case CxxConst(element): isFunctionPointer(element);
			case _: false;
		};

	static function primitiveType(name:String):String {
		return switch name {
			case "void": "void";
			case "c_bool": "bool";
			case "c_char": "char";
			case "c_schar": "signed char";
			case "c_uchar": "unsigned char";
			case "c_short": "short";
			case "c_ushort": "unsigned short";
			case "c_int": "int";
			case "c_uint": "unsigned int";
			case "c_long": "long";
			case "c_ulong": "unsigned long";
			case "c_long_long": "long long";
			case "c_ulong_long": "unsigned long long";
			case "f32": "float";
			case "f64": "double";
			case "i8": "int8_t";
			case "u8": "uint8_t";
			case "i16": "int16_t";
			case "u16": "uint16_t";
			case "i32": "int32_t";
			case "u32": "uint32_t";
			case "i64": "int64_t";
			case "u64": "uint64_t";
			case "isize": "intptr_t";
			case "usize": "std::size_t";
			case "c_wchar": "wchar_t";
			case _: throw 'CXX016 cannot spell primitive type "$name" in a generated thunk';
		};
	}

	static function isVoid(type:CxxType):Bool
		return switch type {
			case CxxVoid | CxxPrimitive("void"): true;
			case CxxConst(element): isVoid(element);
			case _: false;
		};

	static function fallback(type:CxxType):String {
		return switch type {
			case CxxReference(_): throw "CXX016 throwing C++ calls cannot return references through a generated thunk";
			case CxxConst(element): fallback(element);
			case CxxPointer(_): "nullptr";
			case _: '${cppType(type)}{}';
		};
	}

	static function thunkSymbol(kind:String, qualifiedName:String, symbol:String):String
		return "haxeon_cxx_thunk_" + Sha256.encode('$kind\n$qualifiedName\n$symbol').substr(0, 20);

	static function escape(value:String):String
		return StringTools.replace(StringTools.replace(value, "\\", "\\\\"), '"', '\\"');
}
