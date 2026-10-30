package haxeon.ui.animation;

/**
 * An animation that only changes nodes already on screen, announcing each change with BuildContext.willEditRetained. Its frames
 * lay out and paint those nodes without rebuilding the view, so it does not count as pending build work.
 */
interface RetainedAnimation extends Animation {}
