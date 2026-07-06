#include "shapes.hpp"

#include <vector>

namespace geo {

double Shape::area() const {
    return 0.0;
}

std::string Shape::name() const {
    return "shape";
}

Circle::Circle(double radius) : radius_(radius) {}

double Circle::area() const {
    const double pi = 3.14159265358979;
    return pi * radius_ * radius_;
}

std::string Circle::name() const {
    return "circle";
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
