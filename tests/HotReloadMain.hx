import compiler.Diagnostic.CompileError;
import compiler.hl.HlWriter;
import compiler.ir.HlLower;
import compiler.ir.Ir.IrProgram;
import compiler.modules.Compiler;
import runtime.Runtime;
import runtime.PatchSet;

class HotReloadMain {
    static function moduleBytes(compiler:Compiler):haxe.io.Bytes {
        var valueFunction = compiler.modules.get("Value").irFunctions.get("Value.value");
        var readFunction = compiler.modules.get("Probe").irFunctions.get("Probe.read");
        var fibFunction = compiler.modules.get("Worker").irFunctions.get("Worker.fib");
        var workFunction = compiler.modules.get("Worker").irFunctions.get("Worker.run");
        var program = new IrProgram("Value.value");
        program.functions.push(valueFunction);
        program.functions.push(readFunction);
        program.functions.push(fibFunction);
        program.functions.push(workFunction);
        return HlWriter.encode(HlLower.lower(program));
    }

    static function main():Void {
        var compiler = new Compiler();
        compiler.update("Value.hx", "function value():Int { return 42; }");
        compiler.update("Probe.hx", "function read():Int { return Value.value(); }");
        compiler.update("Worker.hx", "function fib(n:Int):Int { if (n <= 1) return n; return fib(n - 1) + fib(n - 2); } function run():Int { return fib(38); }");
        compiler.update("Main.hx", "function main():Int { return Probe.read(); }");
        var initial = compiler.compile("Main");
        var liveRevision = initial.revision;

        var loaded = Runtime.load(moduleBytes(compiler));
        if (Runtime.callInt(loaded, 0) != 42) throw "initial generation did not return 42";
        if (Runtime.callInt(loaded, 1) != 42) throw "initial internal call did not return 42";

        compiler.update("Value.hx", "function value():Int { return 43; }");
        var changed = compiler.compile("Main");
        var compilerIndex = changed.functionIndices.get("Value.value");
        if (changed.changedFunctions.length != 1 || changed.changedFunctions[0] != compilerIndex)
            throw 'compiler reported unexpected changed functions: ${changed.changedFunctions}';
        Runtime.patchSet(loaded, new PatchSet(liveRevision, changed.revision, moduleBytes(compiler), [0], changed.requiresReload));
        liveRevision = changed.revision;
        if (Runtime.callInt(loaded, 0) != 43) throw "patched generation did not return 43";
        if (Runtime.callInt(loaded, 1) != 43) throw "existing caller did not dispatch through the patched slot";
        if (Runtime.retainedGenerationCount(loaded) != 2) throw "initial patch retained an unexpected number of generations";

        for (i in 0...100) {
            var expected = 44 + (i & 1);
            compiler.update("Value.hx", 'function value():Int { return $expected; }');
            var iteration = compiler.compile("Main");
            Runtime.patchSet(loaded, new PatchSet(liveRevision, iteration.revision, moduleBytes(compiler), [0], iteration.requiresReload));
            liveRevision = iteration.revision;
            if (Runtime.callInt(loaded, 1) != expected) throw 'stress patch $i returned the wrong value';
            if (Runtime.retainedGenerationCount(loaded) != 2) throw 'stress patch $i leaked a generation';
        }

        var started = new sys.thread.Lock(), finished = new sys.thread.Lock();
        var workerResult = 0;
        sys.thread.Thread.create(function() {
            started.release();
            workerResult = Runtime.callInt(loaded, 3);
            finished.release();
        });
        started.wait();
        Sys.sleep(0.01);
        compiler.update("Value.hx", "function value():Int { return 46; }");
        var concurrentPatch = compiler.compile("Main");
        Runtime.patchSet(loaded, new PatchSet(liveRevision, concurrentPatch.revision, moduleBytes(compiler), [0], concurrentPatch.requiresReload));
        liveRevision = concurrentPatch.revision;
        if (!finished.wait(5.0) || workerResult != 39088169) throw "concurrent call did not finish safely";
        if (Runtime.callInt(loaded, 1) != 46) throw "concurrent patch was not committed";

        compiler.update("Value.hx", 'function value():Bool { return true; }');
        try {
            compiler.compile("Main");
            throw "incompatible source unexpectedly compiled";
        } catch (error:CompileError) {}
        if (Runtime.callInt(loaded, 0) != 46) throw "compile failure damaged the live generation";

        try {
            Runtime.patchSet(loaded, new PatchSet(liveRevision, liveRevision + 1, haxe.io.Bytes.ofString("not HLB"), [0], false));
            throw "malformed patch unexpectedly succeeded";
        } catch (error:String) {
            if (error != "HashLink rejected the patch transaction") throw error;
        }
        if (Runtime.callInt(loaded, 0) != 46) throw "rejected patch damaged the live generation";

        try {
            Runtime.patchSet(loaded, new PatchSet(liveRevision - 1, liveRevision + 1, moduleBytes(compiler), [0], false));
            throw "stale patch unexpectedly succeeded";
        } catch (error:String) {
            if (error != "HashLink rejected the patch transaction") throw error;
        }
        if (Runtime.callInt(loaded, 0) != 46) throw "stale patch damaged the live generation";

        try {
            Runtime.patchSet(loaded, new PatchSet(liveRevision, liveRevision + 1, moduleBytes(compiler), [0], true));
            throw "structural patch unexpectedly succeeded";
        } catch (error:String) {
            if (error != "Patch changes module structure and requires a domain reload") throw error;
        }
        if (Runtime.callInt(loaded, 0) != 46) throw "structural rejection damaged the live generation";
        Runtime.dispose(loaded);
        Sys.println("PASS: in-process patches are transactional and retain bounded generations");
    }
}
