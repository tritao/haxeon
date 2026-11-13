import haxeon.ui.core.StateStore;
import haxeon.ui.core.WidgetId;

class ScopeOwnerWidgetId {
  static function main():Int {
    var store = new StateStore();
    store.scopeOwner(new WidgetId(1));
    return 42;
  }
}
