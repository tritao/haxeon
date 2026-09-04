import compiler.hl.HlWriter;
import compiler.hl.HlPatchReader;
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
        var mathIndex=first.functionIndices.get("Math.add"),mathId=first.functionIds.get("Math.add");
        var twentyIndex=first.module.ints.indexOf(20);
        compiler.update("Aardvark.hx", "function helper(x:Int):Int { return x + 7; }");
        var added=compiler.compile("Main");
        if(added.functionIndices.get("Math.add")!=mathIndex)throw "Adding an earlier module renumbered Math.add";
        if(added.functionIds.get("Math.add")!=mathId)throw "Adding a function changed the stable Math.add identity";
        if(added.module.ints.indexOf(20)!=twentyIndex)throw "Adding a constant renumbered an existing constant";
        var firstBytes=HlWriter.encode(added.module);
        compiler.update("Math.hx", "function add(a:Int, b:Int):Int { var sum = a + b; return sum; }");
        var result=compiler.compile("Main");
        if (result.retyped.join(",") != "Math.add") throw 'Body edit invalidated callers: ${result.retyped}';
        if (compiler.modules.get("Main").parseVersion != 1) throw "Dependent module was reparsed";
        if (compiler.modules.get("Main").typeVersion != 1) throw "Body edit retyped dependent module";
        if (compiler.modules.get("Math").irVersions.get("Math.add") != 2) throw "Edited function IR was not regenerated";
        if(result.changedFunctions.length!=1 || result.changedFunctions[0]!=result.functionIds.get("Math.add"))throw 'Wrong changed stable functions: ${result.changedFunctions}';
        if(result.patchBytes==null)throw "Compatible body edit did not emit HLP bytes";
        var decodedPatch=HlPatchReader.decode(result.patchBytes);
        if(decodedPatch.functions.length!=1||decodedPatch.functions[0].functionIndex!=mathId)
            throw "Compiler HLP did not contain exactly the changed function";
        if(result.requiresReload)throw "Body edit unexpectedly requires reload";
        if (compiler.modules.get("Unused").parseVersion != 1 || compiler.modules.get("Unused").typeVersion != 1)
            throw "Unrelated module was not reused";
        var secondBytes=HlWriter.encode(result.module);
        if (firstBytes.compare(secondBytes) != 0) throw "Equivalent incremental builds were not deterministic";
        compiler.update("Math.hx", "function add(a:Int, b:Int):Bool { return a < b; }");
        try {
            compiler.compile("Main");
            throw "incompatible signature edit was accepted";
        } catch (error:CompileError) {
            if (error.diagnostic.code != "E1003") throw error;
        }
        compiler.update("Math.hx", "function add(a:Int, b:Int):Int { return a + b; }");
        var restored=compiler.compile("Main");
        if(!restored.requiresReload)throw "Signature restoration did not require reload";
        var mainIr=compiler.modules.get("Main").irFunctions.get("main");
        var mathIr=compiler.modules.get("Math").irFunctions.get("Math.add");
        compiler.update("Unused.hx", "function identity(x:Int):Int { var copy = x; return copy; }");
        var unrelated=compiler.compile("Main");
        if(unrelated.regenerated.join(",")!="Unused.identity")throw 'Unrelated edit regenerated ${unrelated.regenerated}';
        if(compiler.modules.get("Main").irFunctions.get("main")!=mainIr || compiler.modules.get("Math").irFunctions.get("Math.add")!=mathIr)
            throw "Unrelated edit replaced cached IR objects";
        compiler.update("Temp.hx", "function oldValue():Int { return 3; }");
        var withOld=compiler.compile("Main"), oldIndex=withOld.functionIndices.get("Temp.oldValue"),oldId=withOld.functionIds.get("Temp.oldValue");
        compiler.update("Temp.hx", "function freshValue():Int { return 4; }");
        var removed=compiler.compile("Main");
        if(removed.functionIndices.get("Temp.oldValue")!=oldIndex || removed.functionIndices.get("Temp.freshValue")<=oldIndex)
            throw "Removed function slot was not retained as a tombstone";
        if(removed.functionIds.get("Temp.oldValue")!=oldId||removed.functionIds.get("Temp.freshValue")==oldId)
            throw "Function removal reused or changed a stable identity";
        if(!removed.requiresReload)throw "Removing a function did not require reload";
        var unchanged=compiler.compile("Main");
        if(unchanged.changedFunctions.length!=0 || unchanged.requiresReload)throw "Unchanged build reported changes";
        var compacted=compiler.compact("Main");
        if(compacted.functionIndices.exists("Temp.oldValue"))throw "Compact build retained tombstone";
        if(compacted.functionIds.get("Math.add")!=mathId)throw "Compaction changed a live function identity";
        var resumed=new Compiler(compiler.exportIdentityState());
        resumed.update("Math.hx", "function add(a:Int, b:Int):Int { return a + b; }");
        resumed.update("Main.hx", "function main():Int { return Math.add(20, 22); }");
        var resumedBuild=resumed.compile("Main");
        if(resumedBuild.functionIds.get("Math.add")!=mathId||resumedBuild.runtimeIdentity.sub(4,16).compare(compacted.runtimeIdentity.sub(4,16))!=0)
            throw "Serialized compiler identity did not survive restart";
        File.saveBytes(output,HlWriter.encode(compacted.module));

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
