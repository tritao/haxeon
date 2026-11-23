#pragma once

namespace shapes {

class Circle {
public:
	explicit Circle(double radius) noexcept;
	~Circle() noexcept;

	double area() const noexcept;
	void scale(double factor) noexcept;

private:
	double radius_;
};

} // namespace shapes
