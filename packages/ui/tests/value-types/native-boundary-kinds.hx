import haxeon.ui.CompositeMode;
import haxeon.ui.LineCap;
import haxeon.ui.LineJoin;
import haxeon.ui.ImageFormat;
import haxeon.ui.ImageFilter;
import haxeon.ui.style.MaskKind;
import haxeon.ui.core.CachePolicy;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.semantics.AccessibilityOrientation;
import haxeon.ui.NativeEnums;

struct NativeBoundaryChoices implements Hashable {
    public var choice0:CompositeMode;
    public var choice1:LineCap;
    public var choice2:LineJoin;
    public var choice3:ImageFormat;
    public var choice4:ImageFilter;
    public var choice5:MaskKind;
    public var choice6:CachePolicy;
    public var choice7:AccessibilityRole;
    public var choice8:AccessibilityOrientation;
    public var marker:Int;
    public function new() {
        choice0=CompositeMode.SourceOver;
        choice1=LineCap.Butt;
        choice2=LineJoin.Round;
        choice3=ImageFormat.R8;
        choice4=ImageFilter.Linear;
        choice5=MaskKind.Rectangle;
        choice6=CachePolicy.None;
        choice7=AccessibilityRole.Group;
        choice8=AccessibilityOrientation.Unspecified;
        marker=42;
    }
}

function main():Int {
    if (sizeof<NativeBoundaryChoices>() != 40 || offsetof<NativeBoundaryChoices>("marker") != 36) return 1;
    var value=new NativeBoundaryChoices(), values=[value], copy=values[0];
    values[0].choice1=LineCap.Round;
    if (copy.choice1 != LineCap.Butt || value != copy || values[0] == copy) return 2;
    if (NativeEnums.compositeMode(CompositeMode.SourceOver).rawValue() != 1) return 3;
    if (NativeEnums.lineCap(LineCap.Square).rawValue() != 2) return 4;
    if (NativeEnums.lineJoin(LineJoin.Miter).rawValue() != 4) return 5;
    if (NativeEnums.imageFormat(ImageFormat.RGBA8).rawValue() != 2) return 6;
    if (NativeEnums.imageFilter(ImageFilter.Nearest).rawValue() != 2) return 7;
    if (Type.enumIndex(AccessibilityRole.Alert) != 35 || Type.enumIndex(MaskKind.Image) != 4) return 8;
    var nativeEvent = new nativekit.ffi.NativeKitTypes.Event();
    nativeEvent.set_result(nativekit.ffi.NativeKitTypes.Result.TransportWouldBlock);
    if (nativeEvent.get_result() != nativekit.ffi.NativeKitTypes.Result.TransportWouldBlock) return 9;
    nativeEvent.set_result(nativekit.ffi.NativeKitTypes.Result.HttpDns);
    if (nativeEvent.get_result() != nativekit.ffi.NativeKitTypes.Result.HttpDns) return 10;
    var invalidResult:nativekit.ffi.NativeKitTypes.Result = cast 0x7ffffffe;
    nativeEvent.set_result(invalidResult);
    var rejected = false;
    try { nativeEvent.get_result(); } catch (_:Dynamic) { rejected = true; }
    if (!rejected) return 11;
    return 42;
}
