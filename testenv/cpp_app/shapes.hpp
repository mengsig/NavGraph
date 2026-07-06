#ifndef GEO_SHAPES_HPP
#define GEO_SHAPES_HPP

#include <string>
#include <vector>

namespace geo {

// Abstract base for any 2D shape.
class Shape {
public:
    virtual ~Shape() = default;
    // Surface area of the shape.
    virtual double area() const;
    // Human-readable label.
    virtual std::string name() const;
};

// A circle described by a single radius.
class Circle : public Shape {
public:
    explicit Circle(double radius);
    double area() const override;
    std::string name() const override;

private:
    double radius_;
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
