package haxeon.ui.core;

/** Position of the current delivery in a routed event. Direct notifications use Target. */
enum UiEventPhase {
  Capture;
  Target;
  Bubble;
}
