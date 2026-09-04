import compiler.hl.HlWriter;
import compiler.ir.HlLower;
import compiler.modules.Compiler;
import compiler.Diagnostic.CompileError;
import sys.io.File;

class ModuleMain {
    static function main():Void {
        var output=Sys.args()[0], compiler=new Compiler();
        compiler.update("Math.hx", "function add(a:Int, b:Int):Int { return a + b; }");
        compiler.update("Main.hx", "function main():Int { return Math.add(20, 22); }");
        compiler.update("Unused.hx", "function identity(x:Int):Int { return x; }");
        var first=compiler.compile("Main");
        var firstBytes=HlWriter.encode(HlLower.lower(first.ir));
        compiler.update("Math.hx", "function add(a:Int, b:Int):Int { var sum = a + b; return sum; }");
        var result=compiler.compile("Main");
        if (result.retyped.join(",") != "Main,Math") throw 'Unexpected invalidation: ${result.retyped}';
        if (compiler.modules.get("Main").parseVersion != 1) throw "Dependent module was reparsed";
        if (compiler.modules.get("Main").typeVersion != 2) throw "Dependent module was not retyped";
        if (compiler.modules.get("Unused").parseVersion != 1 || compiler.modules.get("Unused").typeVersion != 1)
            throw "Unrelated module was not reused";
        var secondBytes=HlWriter.encode(HlLower.lower(result.ir));
        if (firstBytes.compare(secondBytes) != 0) throw "Equivalent incremental builds were not deterministic";
        File.saveBytes(output,secondBytes);

        var missing=new Compiler();
        missing.update("Main.hx", "function main():Int { return Missing.value(); }");
        try {
            missing.compile("Main");
            throw "missing module was accepted";
        } catch (error:CompileError) {
            if (error.diagnostic.code != "E2001") throw error;
            if (missing.modules.get("Main").diagnostics.length != 1) throw "module did not retain its diagnostic";
        }
        Sys.println("PASS: update invalidated dependents and reused unrelated module state");
    }
}
