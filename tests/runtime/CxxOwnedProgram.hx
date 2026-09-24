import CxxOwnedFixture;
import CxxOwnedFixtureFunctions;

function main():Int {
	var owner = CxxOwnedFixtureFunctions.acquire(),
		widget = owner.borrow(),
		value = widget.value(),
		firstClose = owner.close(),
		secondClose = owner.close();
	return value == 42 && firstClose && !secondClose && owner.isClosed() && CxxOwnedFixture.__cxx_cxxown__released() == 1 ? 42 : 1;
}
