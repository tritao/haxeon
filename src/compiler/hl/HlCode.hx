package compiler.hl;

class HlCode {
    public static inline final VERSION = 6;

    public var ints:Array<Int> = [];
    public var floats:Array<Float> = [];
    public var strings:Array<String> = [];
    public var types:Array<HlTypeDef> = [];
    public var natives:Array<HlNative> = [];
    public var functions:Array<HlFunction> = [];
    public var entryPoint:Int = 0;

    public function new() {}
}

enum HlTypeDef {
    Simple(kind:HlType);
    Function(arguments:Array<Int>, result:Int);
}

typedef HlNative = {
    final library:Int;
    final name:Int;
    final type:Int;
    final functionIndex:Int;
}
