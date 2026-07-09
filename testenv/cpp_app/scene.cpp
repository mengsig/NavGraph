#include "scene.hpp"

namespace geo::scene {

Positioned::Positioned(int id, double x, double y)
    : Node(id), pos_(x, y) {}

Visible::Visible(int id, bool shown)
    : Node(id), shown_(shown) {}

// The most-derived class initializes the virtual base Node directly.
Sprite::Sprite(int id, double x, double y, bool shown)
    : Node(id), Positioned(id, x, y), Visible(id, shown) {}

double Sprite::move(double dx, double dy) noexcept {
    Vec2<double> delta(dx, dy);
    Vec2<double> next = position() + delta;
    return next.magnitude();
}

}  // namespace geo::scene
