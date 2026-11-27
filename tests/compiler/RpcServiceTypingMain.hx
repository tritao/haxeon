import compiler.Compiler;
import compiler.core.Diagnostic.CompileError;
import compiler.runtime.CompilerIntrinsics;
import sys.FileSystem;
import sys.io.File;
import tools.LintCommand;

class RpcServiceTypingMain {
	static function main():Void {
		expectError("function run():Int;", "must take one required request and return one response");
		expectError("function run(request:Int):Void;", "must take one required request and return one response");
		expectError("@:id(1) function run(request:Int):Int; function stop(request:Int):Int;",
			"mixes named and numbered methods");
		expectError("@:id(1) function run(request:Int):Int; @:id(1) function stop(request:Int):Int;",
			"uses duplicate @:id(1)");
		expectError("function run(request:Dynamic):Int;", "does not support type");
		expectCallError("connection.of();",
			"RpcConnection.of takes the service interface as a type argument: of<Service>(...)");
		expectCallError("connection.serve<Service>();", "RpcConnection.serve expects the service's implementation");
		checkPinning();
		Sys.println("PASS: RPC service declarations reject invalid signatures and IDs, calls name the service as a type argument, and methods pin in declaration order");
	}

	static function checkPinning():Void {
		var path = haxe.io.Path.join([Sys.getEnv("TMPDIR") ?? ".",
			"rpc-service-pin-" + Std.random(1000000000) + ".hx"]);
		var arguments = ["--fix", "--pin-wire", "Service", path];
		var source = "interface Service { function zebra(request:Int):Int; function alpha(request:Int):Int; }";
		File.saveContent(path, source);
		try {
			LintCommand.run(arguments);
			var pinned = File.getContent(path);
			if (pinned.indexOf("@:id(1) function zebra") < 0 || pinned.indexOf("@:id(2) function alpha") < 0)
				throw "RPC method IDs must follow declaration order";
			LintCommand.run(arguments);
			if (File.getContent(path) != pinned)
				throw "Pinning changed an already pinned service";
		} catch (error:Dynamic) {
			FileSystem.deleteFile(path);
			throw error;
		}
		FileSystem.deleteFile(path);
	}

	/** `call`, on `connection`, fails with `message`. */
	static function expectCallError(call:String, message:String):Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.update("Main.hx",
			'import haxeon.rpc.RpcConnection; interface Service { function run(request:Int):Int; }
			function build(connection:RpcConnection):Void { $call }
			function main():Int { build(null); return 42; }');
		try {
			compiler.compile("Main");
		} catch (error:CompileError) {
			if (error.diagnostic.message != message)
				throw error;
			return;
		}
		throw 'Expected RPC call diagnostic "$message"';
	}

	static function expectError(methods:String, message:String):Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.update("Main.hx",
			'import haxeon.rpc.RpcConnection; interface Service { $methods }
			function build(connection:RpcConnection):Void { connection.of<Service>(); }
			function main():Int { build(null); return 42; }');
		try {
			compiler.compile("Main");
		} catch (error:CompileError) {
			if (error.diagnostic.code != "E1024" || error.diagnostic.message.indexOf(message) < 0)
				throw error;
			return;
		}
		throw 'Expected RPC service diagnostic "$message"';
	}
}
