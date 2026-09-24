#pragma once

namespace cxxlife {

class Widget {
public:
	 explicit Widget(int value) noexcept;
	~Widget() noexcept;

	int value() const noexcept;
	static int destroyed() noexcept;

private:
	int value_;
};

}
