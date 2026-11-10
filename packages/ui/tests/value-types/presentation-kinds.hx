import haxeon.ui.theme.TextRole;
import haxeon.ui.icons.IconName;
import haxeon.ui.docking.DockPanelHeaderMode;

struct PresentationChoices implements Hashable {
    public var role:TextRole;
    public var icon:IconName;
    public var header:DockPanelHeaderMode;
    public var marker:Int;
    public function new() {
        role = TextRole.Body;
        icon = IconName.Search;
        header = DockPanelHeaderMode.Dock;
        marker = 42;
    }
}

class OptionalIcon {
    public var icon:Null<IconName>;
    public function new() icon = null;
    public function index():Int return icon == null ? -1 : Type.enumIndex(icon);
}

function main():Int {
    if (sizeof<PresentationChoices>() != 16 || alignof<PresentationChoices>() != 4
        || offsetof<PresentationChoices>("marker") != 12) return 1;
    var initial = new PresentationChoices(), values = [initial], copy = values[0];
    if (initial != copy || haxeon.Hashing.hash(initial) != haxeon.Hashing.hash(copy)) return 2;
    values[0].role = TextRole.Button;
    values[0].icon = IconName.CollapseAll;
    values[0].header = DockPanelHeaderMode.Content;
    if (copy.role != TextRole.Body || copy.icon != IconName.Search
        || copy.header != DockPanelHeaderMode.Dock || values[0] == copy) return 3;
    if (Type.enumIndex(values[0].icon) != 45 || Type.enumIndex(values[0].header) != 1) return 4;
    var optional = new OptionalIcon();
    if (optional.index() != -1) return 5;
    optional.icon = IconName.NewFile;
    if (optional.index() != 10) return 6;
    var root:Dynamic = optional;
    Reflect.setField(root, "icon", IconName.Close);
    var actual:IconName = cast Reflect.field(root, "icon");
    if (actual != IconName.Close || optional.index() != 1) return 7;
    Reflect.setField(root, "icon", null);
    if (optional.index() != -1) return 8;
    var rejected = false;
    try Reflect.setField(root, "icon", TextRole.Body) catch (_:Dynamic) rejected = true;
    if (!rejected || optional.index() != -1) return 9;
    return 42;
}
