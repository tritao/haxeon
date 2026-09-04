package runtime;

import haxe.io.Bytes;

@:hlNative("realtime_runtime")
private class RuntimeNative {
    public static function load(bytes:hl.Bytes, length:Int):hl.Abstract<"realtime_module"> return null;
    public static function call_i32(module:hl.Abstract<"realtime_module">, index:Int):Int return 0;
    public static function patch(module:hl.Abstract<"realtime_module">, bytes:hl.Bytes, length:Int, indices:hl.NativeArray<Int>):Bool return false;
    public static function generation_count(module:hl.Abstract<"realtime_module">):Int return 0;
    public static function dispose(module:hl.Abstract<"realtime_module">):Void {}
}

class Runtime {
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

    public static function patch(module:LoadedModule, bytes:Bytes, changedFunctions:Array<Int>, requiresReload:Bool):Void {
        if (requiresReload) throw "Patch changes module structure and requires a domain reload";
        if (changedFunctions.length == 0) return;
        var indices = new hl.NativeArray<Int>(changedFunctions.length);
        for (i in 0...changedFunctions.length) indices[i] = changedFunctions[i];
        if (!RuntimeNative.patch(cast module, bytes.getData(), bytes.length, indices))
            throw "HashLink rejected the patch transaction";
    }
}
