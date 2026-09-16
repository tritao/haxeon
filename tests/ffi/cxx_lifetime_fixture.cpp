#include "cxx_lifetime_fixture.hpp"

namespace cxxlife {

static int destructionCount = 0;

Widget::Widget(int value) noexcept : value_(value) {}

Widget::~Widget() noexcept {
	++destructionCount;
}

int Widget::value() const noexcept {
	return value_;
}

int Widget::destroyed() noexcept {
	return destructionCount;
}

}
