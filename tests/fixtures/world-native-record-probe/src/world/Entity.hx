package world;

/** Flat process-local handle. Stable IDs are owned separately by World. */
struct Entity {
  public final slot:Int32;
  public final generation:Int32;

  public function new(slot:Int, generation:Int) {
    this.slot = cast slot;
    this.generation = cast generation;
  }

  public inline function same(other:Null<Entity>):Bool return other != null
    && slot == other.slot && generation == other.generation;
}
