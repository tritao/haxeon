import native_enums.*;

function main():Int {
    var calls = 0;
    var callback = new EchoCallback(function(mode:Mode):Mode { calls++; return mode; });
    defer callback.close();
    if (callback.call(Mode.On) != Mode.On || calls != 1) return 1;
    var invalid:Mode = cast 2;
    var rejected = false;
    try {
        callback.call(invalid);
        rejected = callback.errorKind().rawValue() != 0;
    } catch (_:Dynamic) rejected = true;
    if (!rejected || calls != 1) return 2;
    var invalidResult = new EchoCallback(function(mode:Mode):Mode return cast 2);
    defer invalidResult.close();
    rejected = false;
    try invalidResult.call(Mode.On) catch (_:Dynamic) rejected = true;
    if (!rejected) return 3;
    return 42;
}
