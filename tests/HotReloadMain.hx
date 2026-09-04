import compiler.Diagnostic.CompileError;
import compiler.hl.HlWriter;
import compiler.ir.HlLower;
import compiler.ir.Ir.IrProgram;
import compiler.modules.Compiler;
import runtime.Runtime;

class HotReloadMain {
    static function moduleBytes(compiler:Compiler):haxe.io.Bytes {
        var valueFunction = compiler.modules.get("Value").irFunctions.get("Value.value");
        var readFunction = compiler.modules.get("Probe").irFunctions.get("Probe.read");
        var program = new IrProgram("Value.value");
        program.functions.push(valueFunction);
        program.functions.push(readFunction);
        return HlWriter.encode(HlLower.lower(program));
    }

    static function main():Void {
        var compiler = new Compiler();
        compiler.update("Value.hx", "function value():Int { return 42; }");
        compiler.update("Probe.hx", "function read():Int { return Value.value(); }");
        compiler.update("Main.hx", "function main():Int { return Probe.read(); }");
        compiler.compile("Main");

        var loaded = Runtime.load(moduleBytes(compiler));
        if (Runtime.callInt(loaded, 0) != 42) throw "initial generation did not return 42";
        if (Runtime.callInt(loaded, 1) != 42) throw "initial internal call did not return 42";

        compiler.update("Value.hx", "function value():Int { return 43; }");
        var changed = compiler.compile("Main");
        var compilerIndex = changed.functionIndices.get("Value.value");
        if (changed.changedFunctions.length != 1 || changed.changedFunctions[0] != compilerIndex)
            throw 'compiler reported unexpected changed functions: ${changed.changedFunctions}';
        Runtime.patch(loaded, moduleBytes(compiler), [0], changed.requiresReload);
        if (Runtime.callInt(loaded, 0) != 43) throw "patched generation did not return 43";
        if (Runtime.callInt(loaded, 1) != 43) throw "existing caller did not dispatch through the patched slot";

        compiler.update("Value.hx", 'function value():Bool { return true; }');
        try {
            compiler.compile("Main");
            throw "incompatible source unexpectedly compiled";
        } catch (error:CompileError) {}
        if (Runtime.callInt(loaded, 0) != 43) throw "compile failure damaged the live generation";

        try {
            Runtime.patch(loaded, haxe.io.Bytes.ofString("not HLB"), [0], false);
            throw "malformed patch unexpectedly succeeded";
        } catch (error:String) {
            if (error != "HashLink rejected the patch transaction") throw error;
        }
        if (Runtime.callInt(loaded, 0) != 43) throw "rejected patch damaged the live generation";

        try {
            Runtime.patch(loaded, moduleBytes(compiler), [0], true);
            throw "structural patch unexpectedly succeeded";
        } catch (error:String) {
            if (error != "Patch changes module structure and requires a domain reload") throw error;
        }
        if (Runtime.callInt(loaded, 0) != 43) throw "structural rejection damaged the live generation";
        Sys.println("PASS: in-process stable-slot patch changed 42 to 43 transactionally");
    }
}
