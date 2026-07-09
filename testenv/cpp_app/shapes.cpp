#include "shapes.hpp"

#include <vector>

namespace geo {

namespace {
/// Shared circle constant, kept internal to this translation unit.
constexpr double kPi = 3.14159265358979;

// intentionally dead (fixture): unused private helper.
double scaleArea(double a, double factor) {
    return a * factor;
}
}  // namespace

double Shape::area() const {
    return 0.0;
}

double Shape::perimeter() const {
    return 0.0;
}

std::string Shape::name() const {
    return "shape";
}

ShapeKind Shape::kind() const {
    return ShapeKind::Unknown;
}

Circle::Circle(double radius) : radius_(radius) {}

double Circle::area() const {
    return kPi * radius_ * radius_;
}

double Circle::perimeter() const {
    return 2.0 * kPi * radius_;
}

std::string Circle::name() const {
    return "circle";
}

ShapeKind Circle::kind() const {
    return ShapeKind::Circle;
}

Rectangle::Rectangle(double width, double height)
    : width_(width), height_(height) {}

double Rectangle::area() const {
    return width_ * height_;
}

double Rectangle::perimeter() const {
    return 2.0 * (width_ + height_);
}

std::string Rectangle::name() const {
    return "rectangle";
}

ShapeKind Rectangle::kind() const {
    return ShapeKind::Rectangle;
}

Square::Square(double side) : Rectangle(side, side) {}

std::string Square::name() const {
    return "square";
}

ShapeKind Square::kind() const {
    return ShapeKind::Square;
}

LabeledCircle::LabeledCircle(double radius, std::string label)
    : Circle(radius), label_(std::move(label)) {}

std::string LabeledCircle::describe() const {
    return label_ + ": circle r=" + std::to_string(radius_);
}

ShapeKind LabeledCircle::kind() const {
    return ShapeKind::Labeled;
}

}  // namespace geo

// Sum the areas of every shape in the collection.
double total_area(const std::vector<geo::Shape*>& shapes) {
    double sum = 0.0;
    for (const geo::Shape* s : shapes) {
        sum += s->area();
    }
    return sum;
}
