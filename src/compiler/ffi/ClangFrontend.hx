package compiler.ffi;

import haxe.Json;
import haxe.io.Path;
import compiler.ffi.ClangInvocation.ClangInvocationOptions;
import compiler.ffi.ClangRecordLayouts.RecordLayout;
import compiler.ffi.ProcessOutputCapture.ProcessCaptureResult;
import sys.FileSystem;
import sys.io.File;

typedef ClangFrontendResult = {
	final ast:Dynamic;
	final layouts:Map<String, RecordLayout>;
}

/** Runs Clang once for AST semantics and once for target record layouts. */
class ClangFrontend {
	public static function run(options:ClangInvocationOptions):ClangFrontendResult {
		var invocation = new ClangInvocation(options),
			base = invocation.arguments(),
			astProcess = ProcessOutputCapture.capture(options.clang, base.concat(["-Xclang", "-ast-dump=json", "-fsyntax-only", options.header]),
				ProcessOutputCapture.defaultDiagnosticLimit);
		if (astProcess.exitCode != 0)
			throw 'Clang could not import ${options.header}:\n${diagnostics(astProcess.stderr, astProcess.stderrTruncated)}';
		var ast = Json.parse(astProcess.stdout),
			layoutInput = options.language == "c++" ? cxxLayoutProbe(options.header, ast, options.includes) : options.header,
			layoutProcess:ProcessCaptureResult;
		try {
			layoutProcess = ProcessOutputCapture.capture(options.clang, base.concat([
				"-Xclang",
				options.language == "c++" ? "-fdump-record-layouts" : "-fdump-record-layouts-complete",
				"-fsyntax-only",
				layoutInput
			]), null);
		} catch (error:Dynamic) {
			if (options.language == "c++" && layoutInput != options.header)
				FileSystem.deleteFile(layoutInput);
			throw error;
		}
		if (options.language == "c++" && layoutInput != options.header)
			FileSystem.deleteFile(layoutInput);
		if (layoutProcess.exitCode != 0)
			throw 'Clang could not calculate layouts for ${options.header}:\n${diagnostics(layoutProcess.stderr, layoutProcess.stderrTruncated)}';
		return {
			ast: ast,
			layouts: ClangRecordLayouts.parse(layoutProcess.stdout + layoutProcess.stderr)
		};
	}

	static function cxxLayoutProbe(header:String, ast:Dynamic, includes:Array<String>):String {
		var sourcePath = FileSystem.fullPath(header),
			roots = [FileSystem.fullPath(Path.directory(sourcePath))],
			names:Array<String> = [],
			seen:Map<String, Bool> = [];
		for (include in includes)
			roots.push(FileSystem.fullPath(include));
		collectCxxRecords(ast, [], null, sourcePath, roots, names, seen);
		var tempRoot:Null<String> = Sys.getEnv("TMPDIR");
		if (tempRoot == null || tempRoot.length == 0)
			tempRoot = Sys.getEnv("TEMP");
		if (tempRoot == null || tempRoot.length == 0)
			tempRoot = Sys.getEnv("TMP");
		if (tempRoot == null || tempRoot.length == 0)
			tempRoot = "/tmp";
		var suffix = StringTools.replace(Std.string(Sys.time()), ".", "_") + "-" + StringTools.hex(Std.random(0x7fffffff), 8),
			probePath = Path.join([tempRoot, 'haxeon-cxx-layout-$suffix.cpp']),
			includePath = StringTools.replace(StringTools.replace(sourcePath, "\\", "/"), '"', '\\"'),
			content = new StringBuf();
		content.add('#include "$includePath"\n');
		for (name in names)
			content.add('static_assert(sizeof($name) > 0, "Haxeon C++ layout probe");\n');
		File.saveContent(probePath, content.toString());
		return probePath;
	}

	static function collectCxxRecords(node:Dynamic, namespaces:Array<String>, owner:Null<String>, currentFile:String, roots:Array<String>,
			names:Array<String>, seen:Map<String, Bool>):Void {
		if (node == null)
			return;
		currentFile = ClangAstTools.updateFile(node, currentFile);
		var kind:String = ClangAstTools.field(node, "kind"),
			name:String = ClangAstTools.field(node, "name"),
			qualifiedOwner = owner;
		if (kind == "NamespaceDecl") {
			var nested = namespaces.copy();
			if (name != null && name.length != 0)
				nested.push(name);
			for (child in ClangAstTools.children(node))
				collectCxxRecords(child, nested, owner, currentFile, roots, names, seen);
			return;
		}
		if (kind == "CXXRecordDecl") {
			var location:Dynamic = ClangAstTools.field(node, "loc"),
				includedFrom:Dynamic = ClangAstTools.field(location, "includedFrom"),
				user = includedFrom == null && ClangAstTools.isUserDeclaration(node, roots, currentFile);
			if (name != null
				&& name.length != 0
				&& ClangAstTools.field(node, "isImplicit") != true
				&& ClangAstTools.field(node, "completeDefinition") == true
				&& user) {
				var qualified = qualify(name, namespaces, owner);
				if (validQualifiedName(qualified) && !seen.exists(qualified)) {
					seen.set(qualified, true);
					names.push(qualified);
				}
				qualifiedOwner = qualified;
			}
			for (child in ClangAstTools.children(node))
				if (ClangAstTools.field(child, "kind") == "CXXRecordDecl")
					collectCxxRecords(child, namespaces, qualifiedOwner, currentFile, roots, names, seen);
			return;
		}
		for (child in ClangAstTools.children(node))
			collectCxxRecords(child, namespaces, owner, currentFile, roots, names, seen);
	}

	static function qualify(name:String, namespaces:Array<String>, owner:Null<String>):String {
		if (name.indexOf("::") >= 0 || StringTools.startsWith(name, "::"))
			return StringTools.startsWith(name, "::") ? name.substring(2) : name;
		if (owner != null)
			return owner + "::" + name;
		return namespaces.length == 0 ? name : namespaces.join("::") + "::" + name;
	}

	static function validQualifiedName(name:String):Bool {
		for (part in name.split("::")) {
			if (part.length == 0 || !~/^[A-Za-z_][A-Za-z0-9_]*$/.match(part))
				return false;
		}
		return true;
	}

	static function diagnostics(text:String, truncated:Bool):String
		return truncated ? '$text\n[Clang diagnostics truncated after ${ProcessOutputCapture.defaultDiagnosticLimit} bytes]' : text;
}
