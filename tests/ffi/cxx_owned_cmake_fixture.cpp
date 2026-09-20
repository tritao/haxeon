#include "cxx_owned_cmake_fixture.hpp"

namespace cxxcmakeown {

static int releaseCount = 0;

int ManagedWidget::value() const noexcept {
	return 7;
}

ManagedWidget *acquire_managed() noexcept {
	return new ManagedWidget();
}

void release_managed(ManagedWidget *value) noexcept {
	delete value;
	++releaseCount;
}

int released_managed() noexcept {
	return releaseCount;
}

}
