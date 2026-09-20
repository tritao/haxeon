#pragma once

namespace cxxown {

class Widget {
public:
	int value() const noexcept;
};

Widget *acquire() noexcept;
void release(Widget *value) noexcept;
int released() noexcept;

}
