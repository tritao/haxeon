package haxeon.ui.core;

/** Caller-chosen stable key; the validated string is the complete identity value. */
abstract Key(String) {
  public inline function new(value:String) {
    if (value == null || value.length == 0) throw "Widget keys must not be empty";
    this = value;
  }

  public inline function rawValue():String return this;
}
