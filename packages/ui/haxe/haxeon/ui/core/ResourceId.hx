package haxeon.ui.core;

/** A scalar ownership-list entry. The low bit is the domain; the sign is payload. */
abstract ResourceId(Int) {
  @:allow(haxeon.ui.core.StateStore) inline function new(value:Int) this = value;

  public static inline function widget(id:WidgetId):ResourceId return new ResourceId(id.value << 1);
  public static inline function scope(id:ScopeResourceId):ResourceId return new ResourceId((id.rawValue() << 1) | 1);

  public inline function rawValue():Int return this;
  public inline function isScope():Bool return (this & 1) != 0;

  @:allow(haxeon.ui.core.StateStore) inline function payload():Int return this >>> 1;
  @:allow(haxeon.ui.core.StateStore) inline function scopeId():ScopeResourceId return new ScopeResourceId(this >>> 1);
}
