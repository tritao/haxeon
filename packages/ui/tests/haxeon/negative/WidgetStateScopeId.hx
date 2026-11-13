import haxeon.ui.core.StateStore;

class WidgetStateScopeId {
  static function main():Int {
    var store = new StateStore();
    store.contains(store.beginScope());
    return 42;
  }
}
