import haxeon.ui.Color;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutTransaction;
import haxeon.ui.PaintStore;

function main():Int {
	scoped var paint = new PaintStore();
	var transaction = new LayoutTransaction(paint), first = LayoutNode.box(1);
	first.style.background = Color.rgba(0.1, 0.2, 0.3, 1);
	transaction.encodeInto(first);
	transaction.commit();
	first.style.background = Color.rgba(0.2, 0.3, 0.4, 1);
	if (first.style.background.red != 0.2) return 1;
	var replacement = LayoutNode.box(1);
	replacement.style.background = Color.rgba(0.7, 0.8, 0.9, 1);
	transaction.encodeInto(replacement);
	transaction.rollback();
	if (first.style.background.red != 0.2 || replacement.style.background.red != 0.7) return 2;
	first.style.background = Color.rgba(0.3, 0.4, 0.5, 1);
	transaction.encodeInto(replacement);
	transaction.commit();
	if (first.style.background.red != 0.3 || replacement.style.background.red != 0.7) return 3;
	transaction.dispose();
	return replacement.style.background.red == 0.7 ? 42 : 4;
}
