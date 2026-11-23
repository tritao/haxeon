import compiler.Compiler;
import compiler.core.Diagnostic.CompileError;
import compiler.core.UnresolvedNameKind;
import compiler.runtime.CompilerIntrinsics;

class MissingImportMain {
	static function main():Void {
		for (fixture in [
			{
				body: "var value:Widget;",
				code: "E1020",
				kind: UnresolvedNameKind.WantedType,
				name: "Widget",
				message: 'Unknown type "Widget"',
				imports: ["first.Controls.Widget", "second.Widget"]
			},
			{
				body: "var value = new Widget();",
				code: "E2001",
				kind: UnresolvedNameKind.WantedModule,
				name: "Widget",
				message: 'Missing module "Widget"',
				imports: ["first.Controls.Widget", "second.Widget"]
			},
			{
				body: "var value = Bytes;",
				code: "E1005",
				kind: UnresolvedNameKind.WantedVariable,
				name: "Bytes",
				message: 'Unknown variable "Bytes"',
				imports: ["haxe.io.Bytes", "hl.Bytes"]
			},
			{
				body: "var value:NoSuchType;",
				code: "E1020",
				kind: UnresolvedNameKind.WantedType,
				name: "NoSuchType",
				message: 'Unknown type "NoSuchType"',
				imports: []
			}
		]) {
			var compiler = new Compiler();
			CompilerIntrinsics.register(compiler);
			compiler.addStandardLibrarySourceRoot("stdlib");
			compiler.update("first/Controls.hx", "package first; class Controls {} class Widget {}");
			compiler.update("second/Widget.hx", "package second; class Widget {}");
			compiler.update("hidden/Widget.hx", "package hidden; private class Widget {}");
			compiler.update("Main.hx", 'function main():Int { ${fixture.body} return 0; }');
			var failure:Null<CompileError> = null;
			try compiler.compile("Main") catch (error:CompileError) failure = error;
			if (failure == null || failure.diagnostic.code != fixture.code
				|| failure.diagnostic.message != fixture.message)
				throw 'Unexpected diagnostic for ${fixture.body}: $failure';
			var unresolved = failure.diagnostic.unresolvedName;
			if (unresolved == null || unresolved.kind != fixture.kind || unresolved.name != fixture.name)
				throw 'Unexpected unresolved name for ${fixture.body}: $unresolved';
			if (compiler.modules.exists("haxe.io.Bytes") || compiler.modules.exists("hl.Bytes"))
				throw "The import search retained a standard-library candidate";
			var lines = failure.formatAll().split("\n");
			if (lines[0] != failure.diagnostic.format() || lines.slice(1).join("\n")
				!= [for (path in fixture.imports) '  help: import $path;'].join("\n"))
				throw 'Unexpected import suggestions for ${fixture.body}: ${failure.formatAll()}';
		}
	}
}
