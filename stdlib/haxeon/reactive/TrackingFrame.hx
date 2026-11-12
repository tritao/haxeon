package haxeon.reactive;

/** Value snapshot of nested tracking bookkeeping; enter/leave do not allocate a callback or stack record. */
struct TrackingFrame {
  public final previous:Null<ReactiveCollector>;
  public final previousStart:Int;
  public final previousCount:Int;
  public function new(previous:Null<ReactiveCollector>, previousStart:Int, previousCount:Int) {
    this.previous = previous;
    this.previousStart = previousStart;
    this.previousCount = previousCount;
  }
}
