import haxeon.ui.PaintRecord;
import haxeon.ui.PaintStore;

function main():Int {
	if (sizeof<PaintRecord>() != 104 || alignof<PaintRecord>() != 8 ||
		offsetof<PaintRecord>("textRed") != 64 || offsetof<PaintRecord>("generation") != 96 ||
		offsetof<PaintRecord>("flags") != 100) return 1;
	var store = new PaintStore(), first = store.acquire(), generation = store.generation(first);
	store.acknowledge(first, generation);
	if (store.isDirty(first, generation)) return 6;
	store.setBackground(first, generation, 0.1, 0.0, 0.0, 0.0);
	store.setRadii(first, generation, 0.0, 0.0, 0.0, 3.25);
	if (!store.isDirty(first, generation)) return 7;
	for (_ in 0...32) store.acquire();
	if (store.at(first, generation).ref.backgroundRed != 0.1 ||
		store.at(first, generation).ref.radiusBottomRight != 3.25) return 2;
	var view = store.span();
	store.release(first, generation);
	var stale = false;
	try store.at(first, generation) catch (_:Dynamic) stale = true;
	if (!stale) return 3;
	var replacement = store.acquire();
	if (replacement != first || store.generation(replacement) == generation ||
		store.at(replacement, store.generation(replacement)).ref.backgroundRed != 0.0) return 4;
	store.dispose();
	store.dispose();
	var closed = false;
	try view.at(0) catch (_:Dynamic) closed = true;
	return closed ? 42 : 5;
}
