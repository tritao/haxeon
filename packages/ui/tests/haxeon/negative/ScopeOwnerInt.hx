import haxeon.ui.core.StateStore;

class ScopeOwnerInt {
  static function main():Int {
    new StateStore().touchScope(1);
    return 42;
  }
}
