#ifndef GEO_SCENE_HPP
#define GEO_SCENE_HPP

#include "vec2.hpp"

// Nested namespace: scene-graph entities live under geo::scene.
namespace geo::scene {

/// Common base for every scene-graph entity.
class Node {
public:
    explicit Node(int id) : id_(id) {}
    virtual ~Node() = default;

    /// Stable identifier for this node (inline).
    int id() const noexcept { return id_; }

private:
    int id_;
};

/// Mixin adding a 2D position.
///
/// Uses virtual inheritance so a diamond resolves to a single Node.
class Positioned : public virtual Node {
public:
    Positioned(int id, double x, double y);

    /// Current position as a vector (inline, out-of-namespace type).
    Vec2<double> position() const noexcept { return pos_; }

private:
    Vec2<double> pos_;
};

/// Mixin adding a visibility flag; also a virtual base over Node.
class Visible : public virtual Node {
public:
    Visible(int id, bool shown);

    /// Whether the node is currently drawn (inline).
    bool shown() const noexcept { return shown_; }

private:
    bool shown_;
};

/// A sprite that is both positioned and visible.
///
/// The diamond (Positioned + Visible, both virtual over Node) collapses to a
/// single shared Node subobject.
class Sprite : public Positioned, public Visible {
public:
    Sprite(int id, double x, double y, bool shown);

    /// Translate by a delta and return the magnitude of the new position.
    double move(double dx, double dy) noexcept;
};

}  // namespace geo::scene

#endif  // GEO_SCENE_HPP
