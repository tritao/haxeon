package haxe.ds;

/** A read-only view of an Array. Copy the source first when a snapshot is needed. */
@:forward(length, iterator, join, contains, indexOf, lastIndexOf, copy, slice, map, filter, concat, toString)
@:arrayAccess
abstract ReadOnlyArray<T>(Array<T>) from Array<T> {}
