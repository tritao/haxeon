import native_enums.*;

class CaseProbe {
    static var record:Null<Record>;
    @:expose public static function prepare():Void { record = new Record(); record.set_mode(Mode.Off); record.set_modes(0, Mode.On); }
    @:expose public static function clearRoots():Void record = null;
    @:expose public static function churn(count:Int):Void { for (i in 0...count) record = new Record(); record = null; }
    @:expose public static function perform(count:Int):Int {
        var value = record;
        if (value == null) return -1;
        var total = 0;
        for (i in 0...count) {
            var code = (i & 1) == 0 ? 0 : 3;
            var mode = native_enums.Native_enumsEnumDecoders.decodeMode(code);
            value.set_mode(mode);
            value.set_modes(0, mode);
            if (value.get_mode() != mode || value.get_modes(0) != mode || mode.rawValue() != code) return -1;
            total += 42;
        }
        return total;
    }
}

function main():Int {
    // Consecutive ranges, gaps, and signed endpoints must keep exactly the declared domain.
    for (code in [-2147483648, -2, -1, 0, 2, 2147483647])
        if (native_enums.Native_enumsEnumDecoders.decodePacked(code).rawValue() != code) return 5;
    for (code in [-2147483647, -3, 1, 3, 2147483646]) {
        var invalid = false;
        try native_enums.Native_enumsEnumDecoders.decodePacked(code) catch (_:Dynamic) invalid = true;
        if (!invalid) return 6;
    }
    var rejected = false;
    try native_enums.Native_enumsEnumDecoders.decodeMode(2) catch (_:Dynamic) rejected = true;
    if (!rejected) return 1;
    var value = new Record();
    native_enums.__hxi_struct_setI32(cast value, 0, 2);
    rejected = false;
    try value.get_mode() catch (_:Dynamic) rejected = true;
    if (!rejected) return 2;
    native_enums.__hxi_struct_setI32(cast value, 4, 2);
    rejected = false;
    try value.get_modes(0) catch (_:Dynamic) rejected = true;
    if (!rejected) return 3;
    CaseProbe.prepare();
    return CaseProbe.perform(2) == 84 ? 42 : 4;
}
