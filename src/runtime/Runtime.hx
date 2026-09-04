package runtime;

import haxe.io.Bytes;

@:hlNative("realtime_runtime")
private class RuntimeNative {
    public static function load(bytes:hl.Bytes, length:Int):hl.Abstract<"realtime_module"> return null;
    public static function call_i32(module:hl.Abstract<"realtime_module">, index:Int):Int return 0;
    public static function patch(module:hl.Abstract<"realtime_module">, bytes:hl.Bytes, length:Int, indices:hl.NativeArray<Int>, baseRevision:Int, revision:Int):Bool return false;
    public static function generation_count(module:hl.Abstract<"realtime_module">):Int return 0;
    public static function dispose(module:hl.Abstract<"realtime_module">):Void {}
    public static function inspect_patch(bytes:hl.Bytes, length:Int):Int return -1;
}

class Runtime {
    public static function inspectPatch(bytes:Bytes):{baseRevision:Int, revision:Int, functionCount:Int} {
        var summary=RuntimeNative.inspect_patch(bytes.getData(),bytes.length);
        if(summary<0)throw "HashLink rejected the HLP bytes";
        return {baseRevision:summary>>>22,revision:(summary>>>12)&0x3FF,functionCount:summary&0xFFF};
    }
    public static function load(bytes:Bytes):LoadedModule {
        var module = RuntimeNative.load(bytes.getData(), bytes.length);
        if (module == null) throw "HashLink rejected the module bytes";
        return cast module;
    }

    public static function callInt(module:LoadedModule, stableIndex:Int):Int
        return RuntimeNative.call_i32(cast module, stableIndex);

    public static function retainedGenerationCount(module:LoadedModule):Int
        return RuntimeNative.generation_count(cast module);

    public static function dispose(module:LoadedModule):Void
        RuntimeNative.dispose(cast module);

    public static function patchSet(module:LoadedModule, patch:PatchSet):Void {
        if (patch.requiresReload) throw "Patch changes module structure and requires a domain reload";
        if (patch.changedFunctions.length == 0) return;
        var indices = new hl.NativeArray<Int>(patch.changedFunctions.length);
        for (i in 0...patch.changedFunctions.length) indices[i] = patch.changedFunctions[i];
        if (!RuntimeNative.patch(cast module, patch.bytes.getData(), patch.bytes.length, indices, patch.baseRevision, patch.revision))
            throw "HashLink rejected the patch transaction";
    }
}
