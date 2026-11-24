#include "shapes.hpp"

namespace shapes {

Circle::Circle(double radius) noexcept : radius_(radius) {}

Circle::~Circle() noexcept = default;

double Circle::area() const noexcept {
	return 3.141592653589793 * radius_ * radius_;
}

void Circle::scale(double factor) noexcept {
	radius_ *= factor;
}

} // namespace shapes
