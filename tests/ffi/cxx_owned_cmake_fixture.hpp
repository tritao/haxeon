#pragma once

namespace cxxcmakeown {

class ManagedWidget {
public:
	int value() const noexcept;
};

ManagedWidget *acquire_managed() noexcept;
void release_managed(ManagedWidget *value) noexcept;
int released_managed() noexcept;

}
