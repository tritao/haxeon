package haxeon.ui.core;

/** A component instance lifetime, independent of its widget identity. */
abstract ScopeResourceId(Int) {
  @:allow(haxeon.ui.core.StateStore) @:allow(haxeon.ui.core.ResourceId) inline function new(value:Int) this = value;

  public inline function rawValue():Int return this;
}
