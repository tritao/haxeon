package compiler.ffi;

import compiler.ffi.CxxModel.CxxFunction;
import compiler.ffi.CxxModel.CxxMethod;
import compiler.ffi.CxxModel.CxxModel;
import compiler.ffi.CxxModel.CxxRecord;
import compiler.ffi.CxxModel.CxxType;
import haxe.crypto.Sha256;

/** Emits C-ABI entry points which contain C++ exceptions before they reach Haxeon. */
class CxxThunkGenerator {
	public static function prepare(model:CxxModel):Void {
		for (functionModel in model.functions)
			if (!functionModel.isNoexcept)
				functionModel.thunkSymbol = thunkSymbol("function", functionModel.qualifiedName, functionModel.symbol);
		for (record in model.records)
			for (method in record.methods)
				if (!method.isNoexcept && !method.isConstructor && !method.isDestructor)
					method.thunkSymbol = thunkSymbol("method", method.qualifiedName, method.symbol);
	}

	public static function source(model:CxxModel):String {
		var output = new StringBuf();
		output.add("// Generated C++ exception thunks for Haxeon. Do not edit.\n");
		output.add('#include "${escape(model.header)}"\n');
		output.add("#include <cstddef>\n");
		output.add("#include <cstdint>\n");
		output.add("#include <cstring>\n");
		output.add("#include <exception>\n\n");
		output.add("namespace {\n");
		output.add("thread_local char haxeon_cxx_thunk_error[512] = {};\n");
		output.add("void haxeon_cxx_thunk_clear() noexcept { haxeon_cxx_thunk_error[0] = 0; }\n");
		output.add("void haxeon_cxx_thunk_fail(const char *message) noexcept {\n");
		output.add("\tif (message == nullptr) message = \"Unknown C++ exception\";\n");
		output.add("\tstd::strncpy(haxeon_cxx_thunk_error, message, sizeof(haxeon_cxx_thunk_error) - 1);\n");
		output.add("\thaxeon_cxx_thunk_error[sizeof(haxeon_cxx_thunk_error) - 1] = 0;\n");
		output.add("}\n");
		output.add("}\n\n");
		output.add("extern \"C\" const char *haxeon_cxx_thunk_last_error() noexcept {\n");
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
		var arguments = [
			for (index in 0...functionModel.parameters.length)
				'${cppType(functionModel.parameters[index].type)} arg$index'
		];
		output.add('extern "C" ${cppType(functionModel.result)} ${functionModel.thunkSymbol}(${arguments.join(", ")}) noexcept {\n');
		emitTry(output, '${functionModel.qualifiedName}(${callArguments(functionModel.parameters.length)})', functionModel.result);
		output.add("}\n\n");
	}

	static function emitMethod(output:StringBuf, record:CxxRecord, method:CxxMethod):Void {
		var arguments:Array<String> = [];
		if (!method.isStatic)
			arguments.push('${method.isConst ? "const " : ""}${record.qualifiedName} *__this');
		for (index in 0...method.parameters.length)
			arguments.push('${cppType(method.parameters[index].type)} arg$index');
		var receiver = method.isStatic ? '${record.qualifiedName}::${method.name}' : '__this->${method.name}';
		output.add('extern "C" ${cppType(method.result)} ${method.thunkSymbol}(${arguments.join(", ")}) noexcept {\n');
		emitTry(output, '$receiver(${callArguments(method.parameters.length)})', method.result);
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

	static function callArguments(count:Int):String
		return [for (index in 0...count) 'arg$index'].join(", ");

	static function cppType(type:CxxType):String {
		return switch type {
			case CxxVoid: "void";
			case CxxPrimitive(name): primitiveType(name);
			case CxxNamed(name): name;
			case CxxConst(element): "const " + cppType(element);
			case CxxPointer(element): cppType(element) + " *";
			case CxxReference(element): cppType(element) + " &";
			case CxxRValueReference(_): throw "CXX016 cannot generate a thunk for an rvalue reference";
			case CxxUnsupported(raw, reason): throw 'CXX016 cannot generate a thunk for "$raw": $reason';
		};
	}

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
