#include "geometry.hpp"

namespace geo {

namespace detail {

double clamp(double v, double lo, double hi) noexcept {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

double deadScale(double v) noexcept {  // intentionally dead (fixture)
    return v * 2.0;
}

}  // namespace detail

AreaStats summarize(const std::vector<Shape*>& shapes) {
    AreaStats stats{0.0, 0.0, "none"};
    // Cross-file call: total_area is defined in shapes.cpp.
    stats.total = total_area(shapes);
    for (const Shape* s : shapes) {
        double capped = detail::clamp(s->area(), 0.0, 1e9);
        if (capped > stats.largest) {
            stats.largest = capped;
            stats.largest_name = s->name();
        }
    }
    return stats;
}

double total_perimeter(const std::vector<Shape*>& shapes) {
    double sum = 0.0;
    for (const Shape* s : shapes) {
        sum += s->perimeter();
    }
    return sum;
}

}  // namespace geo
