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
        if (result.retyped.join(",") != "Math.add") throw 'Body edit invalidated callers: ${result.retyped}';
        if (compiler.modules.get("Main").parseVersion != 1) throw "Dependent module was reparsed";
        if (compiler.modules.get("Main").typeVersion != 1) throw "Body edit retyped dependent module";
        if (compiler.modules.get("Math").irVersions.get("Math.add") != 2) throw "Edited function IR was not regenerated";
        if (compiler.modules.get("Unused").parseVersion != 1 || compiler.modules.get("Unused").typeVersion != 1)
            throw "Unrelated module was not reused";
        var secondBytes=HlWriter.encode(HlLower.lower(result.ir));
        if (firstBytes.compare(secondBytes) != 0) throw "Equivalent incremental builds were not deterministic";
        compiler.update("Math.hx", "function add(a:Int, b:Int):Bool { return a < b; }");
        try {
            compiler.compile("Main");
            throw "incompatible signature edit was accepted";
        } catch (error:CompileError) {
            if (error.diagnostic.code != "E1003") throw error;
        }
        compiler.update("Math.hx", "function add(a:Int, b:Int):Int { return a + b; }");
        compiler.compile("Main");
        var mainIr=compiler.modules.get("Main").irFunctions.get("main");
        var mathIr=compiler.modules.get("Math").irFunctions.get("Math.add");
        compiler.update("Unused.hx", "function identity(x:Int):Int { var copy = x; return copy; }");
        var unrelated=compiler.compile("Main");
        if(unrelated.regenerated.join(",")!="Unused.identity")throw 'Unrelated edit regenerated ${unrelated.regenerated}';
        if(compiler.modules.get("Main").irFunctions.get("main")!=mainIr || compiler.modules.get("Math").irFunctions.get("Math.add")!=mathIr)
            throw "Unrelated edit replaced cached IR objects";
        File.saveBytes(output,HlWriter.encode(HlLower.lower(unrelated.ir)));

        var missing=new Compiler();
        missing.update("Main.hx", "function main():Int { return Missing.value(); }");
        try {
            missing.compile("Main");
            throw "missing module was accepted";
        } catch (error:CompileError) {
            if (error.diagnostic.code != "E2001") throw error;
            if (missing.modules.get("Main").diagnostics.length != 1) throw "module did not retain its diagnostic";
        }
        Sys.println("PASS: function fingerprints selectively retyped and regenerated cached artifacts");
    }
}
