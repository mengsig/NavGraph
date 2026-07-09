#ifndef GEO_SHAPES_HPP
#define GEO_SHAPES_HPP

#include <string>
#include <vector>

#include "vec2.hpp"

namespace geo {

/// Classification tag for shapes; used by the analytics layer.
enum class ShapeKind {
    Circle,
    Rectangle,
    Square,
    Labeled,
    Unknown,
};

/// Interface for anything that can render a one-line description.
///
/// Pure-virtual mixin used to demonstrate multiple inheritance.
class Printable {
public:
    virtual ~Printable() = default;
    /// One-line human description.
    virtual std::string describe() const = 0;
};

/// Abstract base for any 2D shape.
class Shape {
public:
    virtual ~Shape() = default;
    /// Surface area of the shape.
    virtual double area() const;
    /// Boundary length of the shape.
    virtual double perimeter() const;
    /// Human-readable label.
    virtual std::string name() const;
    /// Classification tag for the shape.
    virtual ShapeKind kind() const;
};

/// A circle described by a single radius.
class Circle : public Shape {
public:
    explicit Circle(double radius);
    double area() const override;
    double perimeter() const override;
    std::string name() const override;
    ShapeKind kind() const override;

    /// Radius accessor (inline).
    double radius() const noexcept { return radius_; }

protected:
    double radius_;
};

/// An axis-aligned rectangle described by width and height.
class Rectangle : public Shape {
public:
    Rectangle(double width, double height);
    double area() const override;
    double perimeter() const override;
    std::string name() const override;
    ShapeKind kind() const override;

    /// Width accessor (inline).
    double width() const noexcept { return width_; }
    /// Height accessor (inline).
    double height() const noexcept { return height_; }

protected:
    double width_;
    double height_;
};

/// A rectangle constrained to equal sides.
class Square : public Rectangle {
public:
    explicit Square(double side);
    std::string name() const override;
    ShapeKind kind() const override;
};

/// A circle that also carries a label and can describe itself.
///
/// Demonstrates multiple inheritance (Circle + Printable).
class LabeledCircle : public Circle, public Printable {
public:
    LabeledCircle(double radius, std::string label);
    std::string describe() const override;
    ShapeKind kind() const override;

    /// Label accessor (inline).
    const std::string& label() const noexcept { return label_; }

private:
    std::string label_;
};

// intentionally dead (fixture): a type nothing references.
struct Bounds {
    Vec2<double> lo;
    Vec2<double> hi;
};

}  // namespace geo

// Sum the areas of every shape in the collection.
double total_area(const std::vector<geo::Shape*>& shapes);

// Return the larger of two comparable values.
template <typename T>
T max_of(T a, T b) {
    return a > b ? a : b;
}

#endif  // GEO_SHAPES_HPP
