import compiler.Diagnostic.CompileError;
import compiler.hl.HlWriter;
import compiler.hl.HlPatchReader;
import compiler.modules.Compiler;
import runtime.Runtime;
import runtime.RuntimeError;
import runtime.RuntimeStatus;
import runtime.PatchSet;

class HotReloadMain {
    static function main():Void {
        var compiler = new Compiler();
        compiler.update("Value.hx", "function value():Int { return 42; }");
        compiler.update("Probe.hx", "function read():Int { return Value.value(); }");
        compiler.update("Worker.hx", "function fib(n:Int):Int { if (n <= 1) return n; return fib(n - 1) + fib(n - 2); } function run():Int { return fib(38); }");
        compiler.update("Main.hx", "function main():Int { return Probe.read(); }");
        var initial = compiler.compile("Main");
        var liveRevision = initial.revision;

        var valueIndex=initial.functionIds.get("Value.value"),readIndex=initial.functionIds.get("Probe.read"),workIndex=initial.functionIds.get("Worker.run");
        var loaded = Runtime.load(HlWriter.encode(initial.module),initial.runtimeIdentity);
        if (Runtime.callInt(loaded, valueIndex) != 42) throw "initial generation did not return 42";
        if (Runtime.callInt(loaded, readIndex) != 42) throw "initial internal call did not return 42";

        compiler.update("Value.hx", "function value():Int { return 43; }");
        var changed = compiler.compile("Main");
        var decoded=HlPatchReader.decode(changed.patchBytes);
        if(decoded.moduleId.compare(initial.runtimeIdentity.sub(4,16))!=0)throw "HLP module identity does not match its load manifest";
        if(decoded.baseInts!=initial.module.ints.length||decoded.ints.length!=1||decoded.ints[0]!=43)
            throw "HLP did not encode the integer symbol delta";
        var nativeDecoded=Runtime.inspectPatch(changed.patchBytes);
        if(nativeDecoded.baseRevision!=decoded.baseRevision||nativeDecoded.revision!=decoded.revision||nativeDecoded.functionCount!=decoded.functions.length)
            throw "native and Haxe HLP decoders disagree";
        try {Runtime.inspectPatch(changed.patchBytes.sub(0,changed.patchBytes.length-1));throw "native decoder accepted truncated HLP";}catch(error:String){if(error!="HashLink rejected the HLP bytes")throw error;}
        var compilerIndex = changed.functionIds.get("Value.value");
        if (changed.changedFunctions.length != 1 || changed.changedFunctions[0] != compilerIndex)
            throw 'compiler reported unexpected changed functions: ${changed.changedFunctions}';
        var corruptHash=changed.patchBytes.sub(0,changed.patchBytes.length),hashPosition=skipIndex(corruptHash,24);
        corruptHash.set(hashPosition,corruptHash.get(hashPosition)^1);
        try {
            Runtime.patchSet(loaded,new PatchSet(liveRevision,changed.revision,corruptHash,changed.changedFunctions,false));
            throw "mismatched symbol prefix unexpectedly succeeded";
        } catch(error:RuntimeError) {if(error.status!=RuntimeStatus.Incompatible)throw error;}
        Runtime.patchSet(loaded, new PatchSet(liveRevision, changed.revision, changed.patchBytes, changed.changedFunctions, changed.requiresReload));
        liveRevision = changed.revision;
        if(Runtime.patchJitCount(loaded)!=1)throw "one-function patch did not JIT exactly one function";
        if (Runtime.callInt(loaded, valueIndex) != 43) throw "patched generation did not return 43";
        if (Runtime.callInt(loaded, readIndex) != 43) throw "existing caller did not dispatch through the patched slot";
        if (Runtime.retainedCodeAllocationCount(loaded) != 2) throw "initial patch retained an unexpected number of code allocations";

        for (i in 0...100) {
            var expected = 44 + (i & 1);
            compiler.update("Value.hx", 'function value():Int { return $expected; }');
            var iteration = compiler.compile("Main");
            Runtime.patchSet(loaded, new PatchSet(liveRevision, iteration.revision, iteration.patchBytes, iteration.changedFunctions, iteration.requiresReload));
            liveRevision = iteration.revision;
            if (Runtime.callInt(loaded, readIndex) != expected) throw 'stress patch $i returned the wrong value';
            if (Runtime.retainedCodeAllocationCount(loaded) != 2) throw 'stress patch $i leaked a code allocation';
        }

        var beforePair=Runtime.patchJitCount(loaded);
        compiler.update("Value.hx", "function value():Int { return 46; }");
        compiler.update("Probe.hx", "function read():Int { var result = Value.value(); return result; }");
        var pair=compiler.compile("Main");
        if(pair.changedFunctions.length!=2)throw "two-function edit did not produce an atomic pair";
        var pairDecoded=HlPatchReader.decode(pair.patchBytes),hasRelocation=false;
        for(patchedFunction in pairDecoded.functions)if(patchedFunction.relocations.length>0)hasRelocation=true;
        if(!hasRelocation)throw "patched calls were not encoded as stable-ID relocations";
        Runtime.patchSet(loaded,new PatchSet(liveRevision,pair.revision,pair.patchBytes,pair.changedFunctions,pair.requiresReload));
        liveRevision=pair.revision;
        if(Runtime.patchJitCount(loaded)-beforePair!=2)throw "two-function patch did not JIT exactly two functions";
        if(Runtime.callInt(loaded,readIndex)!=46)throw "two-function patch was not committed together";

        var started = new sys.thread.Lock(), finished = new sys.thread.Lock();
        var workerResult = 0;
        sys.thread.Thread.create(function() {
            started.release();
            workerResult = Runtime.callInt(loaded, workIndex);
            finished.release();
        });
        started.wait();
        Sys.sleep(0.01);
        compiler.update("Value.hx", "function value():Int { return 47; }");
        var concurrentPatch = compiler.compile("Main");
        Runtime.patchSet(loaded, new PatchSet(liveRevision, concurrentPatch.revision, concurrentPatch.patchBytes, concurrentPatch.changedFunctions, concurrentPatch.requiresReload));
        liveRevision = concurrentPatch.revision;
        if (!finished.wait(5.0) || workerResult != 39088169) throw "concurrent call did not finish safely";
        if (Runtime.callInt(loaded, readIndex) != 47) throw "concurrent patch was not committed";

        compiler.update("Value.hx", 'function value():Bool { return true; }');
        try {
            compiler.compile("Main");
            throw "incompatible source unexpectedly compiled";
        } catch (error:CompileError) {}
        if (Runtime.callInt(loaded, valueIndex) != 47) throw "compile failure damaged the live generation";

        try {
            Runtime.patchSet(loaded, new PatchSet(liveRevision, liveRevision + 1, haxe.io.Bytes.ofString("not HLP"), [valueIndex], false));
            throw "malformed patch unexpectedly succeeded";
        } catch (error:RuntimeError) {
            if (error.status != RuntimeStatus.BadFormat) throw error;
        }
        if (Runtime.callInt(loaded, valueIndex) != 47) throw "rejected patch damaged the live generation";

        try {
            Runtime.patchSet(loaded, new PatchSet(liveRevision - 1, concurrentPatch.revision, concurrentPatch.patchBytes, concurrentPatch.changedFunctions, false));
            throw "stale patch unexpectedly succeeded";
        } catch (error:RuntimeError) {
            if (error.status != RuntimeStatus.StalePatch) throw error;
        }
        if (Runtime.callInt(loaded, valueIndex) != 47) throw "stale patch damaged the live generation";

        try {
            Runtime.patchSet(loaded, new PatchSet(liveRevision, liveRevision + 1, concurrentPatch.patchBytes, [valueIndex], true));
            throw "structural patch unexpectedly succeeded";
        } catch (error:RuntimeError) {
            if (error.status != RuntimeStatus.Incompatible) throw error;
        }
        if (Runtime.callInt(loaded, valueIndex) != 47) throw "structural rejection damaged the live generation";

        var foreign=new Compiler();
        foreign.update("Value.hx", "function value():Int { return 47; }");
        foreign.update("Probe.hx", "function read():Int { return Value.value(); }");
        foreign.update("Main.hx", "function main():Int { return Probe.read(); }");
        foreign.compile("Main");
        foreign.update("Value.hx", "function value():Int { return 99; }");
        var foreignPatch=foreign.compile("Main");
        try {
            Runtime.patchSet(loaded,new PatchSet(liveRevision,liveRevision+1,foreignPatch.patchBytes,foreignPatch.changedFunctions,false));
            throw "foreign-module patch unexpectedly succeeded";
        } catch(error:RuntimeError) {
            if(error.status!=RuntimeStatus.Incompatible)throw error;
        }
        if(Runtime.callInt(loaded,valueIndex)!=47)throw "foreign patch damaged the live generation";
        Runtime.dispose(loaded);
        Sys.println("PASS: selective HLP patches are atomic and retain bounded JIT code");
    }

    static function skipIndex(bytes:haxe.io.Bytes,position:Int):Int {
        var first=bytes.get(position++);
        if((first&0x80)==0)return position;
        return position+((first&0x40)==0?1:3);
    }
}
