#include "cxx_owned_fixture.hpp"

namespace cxxown {

static int releaseCount = 0;

int Widget::value() const noexcept {
	return 42;
}

Widget *acquire() noexcept {
	Widget *value = new Widget();
	return value;
}

void release(Widget *value) noexcept {
	delete value;
	++releaseCount;
}

int released() noexcept {
	return releaseCount;
}

}
