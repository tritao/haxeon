package compiler.types;

import compiler.types.Type.CompilerType;

class Scope {
    final parent:Null<Scope>;
    final values:Map<String, CompilerType> = [];

    public function new(?parent:Scope) this.parent = parent;

    public function define(name:String, type:CompilerType):Void {
        if (values.exists(name)) throw 'Duplicate local "$name"';
        values.set(name, type);
    }

    public function resolve(name:String):Null<CompilerType> {
        var value = values.get(name);
        return value != null ? value : parent == null ? null : parent.resolve(name);
    }
}
