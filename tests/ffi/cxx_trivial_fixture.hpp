#pragma once

struct Point {
    int x;
    float y;
};

Point make_point() noexcept;
void use_point(Point value) noexcept;
