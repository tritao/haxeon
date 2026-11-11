import haxeon.ui.widgets.controls.ButtonVariant;
import haxeon.ui.widgets.controls.SpinnerKind;
import haxeon.ui.widgets.controls.ProgressMode;
import haxeon.ui.widgets.ImageFit;
import haxeon.ui.widgets.layout.SplitSide;
import haxeon.ui.widgets.layout.SplitOrientation;

struct WidgetCases implements Hashable {
    public var button:ButtonVariant;
    public var spinner:SpinnerKind;
    public var progress:ProgressMode;
    public var image:ImageFit;
    public var side:SplitSide;
    public var orientation:SplitOrientation;
    public var marker:Int;
    public function new() {
        button = ButtonVariant.Secondary;
        spinner = SpinnerKind.Ring;
        progress = ProgressMode.Determinate;
        image = ImageFit.Contain;
        side = SplitSide.Leading;
        orientation = SplitOrientation.Horizontal;
        marker = 42;
    }
}

class WidgetField {
    public var button:ButtonVariant;
    public function new() button = ButtonVariant.Primary;
}

function spinnerPhase(kind:SpinnerKind):Int return switch kind {
    case Ring: 0;
    case Dots: 1;
    case Bars: 2;
    case Pulse: 3;
};

function main():Int {
    if (sizeof<WidgetCases>() != 28 || alignof<WidgetCases>() != 4
        || offsetof<WidgetCases>("marker") != 24) return 1;
    var initial = new WidgetCases(), values:Array<WidgetCases> = [initial];
    var copy = values[0];
    if (initial != copy || haxeon.Hashing.hash(initial) != haxeon.Hashing.hash(copy)) return 2;
    values[0].button = ButtonVariant.Navigation;
    values[0].spinner = SpinnerKind.Pulse;
    values[0].progress = ProgressMode.Indeterminate;
    values[0].image = ImageFit.Cover;
    values[0].side = SplitSide.Trailing;
    values[0].orientation = SplitOrientation.Vertical;
    if (copy.button != ButtonVariant.Secondary || copy.spinner != SpinnerKind.Ring
        || copy.progress != ProgressMode.Determinate || copy.image != ImageFit.Contain
        || copy.side != SplitSide.Leading || copy.orientation != SplitOrientation.Horizontal
        || values[0] == copy || spinnerPhase(values[0].spinner) != 3) return 3;
    var spins = [SpinnerKind.Ring, SpinnerKind.Dots, SpinnerKind.Bars, SpinnerKind.Pulse];
    for (index in 0...1024) if (spinnerPhase(spins[index & 3]) != (index & 3)) return 4;
    var field = new WidgetField(), dynamicField:Dynamic = field;
    Reflect.setField(dynamicField, "button", ButtonVariant.Navigation);
    var reflected:ButtonVariant = cast Reflect.field(dynamicField, "button");
    if (field.button != ButtonVariant.Navigation || reflected != field.button) return 5;
    var rejected = false;
    try Reflect.setField(dynamicField, "button", SpinnerKind.Ring) catch (_:Dynamic) rejected = true;
    if (!rejected || field.button != ButtonVariant.Navigation) return 6;
    return 42;
}
