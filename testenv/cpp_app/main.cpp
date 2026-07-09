#include "geometry.hpp"
#include "scene.hpp"
#include "shapes.hpp"
#include "vec2.hpp"

#include <cstdio>
#include <vector>

// Build a mix of shapes and print measured areas, perimeters, and stats.
int main() {
    geo::Circle unit(1.0);
    geo::Circle big(10.0);
    geo::Rectangle rect(3.0, 4.0);
    geo::Square sq(5.0);
    geo::LabeledCircle tagged(2.0, "hero");

    std::vector<geo::Shape*> shapes;
    shapes.push_back(&unit);
    shapes.push_back(&big);
    shapes.push_back(&rect);
    shapes.push_back(&sq);
    shapes.push_back(&tagged);

    double single = unit.area();
    double combined = total_area(shapes);
    double rim = geo::total_perimeter(shapes);
    geo::AreaStats stats = geo::summarize(shapes);
    int wider = max_of<int>(3, 7);

    // Vector math via the Vec2 template and its operator overloads.
    geo::Vec2<double> a(1.0, 2.0);
    geo::Vec2<double> b(3.0, 4.0);
    geo::Vec2<double> sum = a + b;
    double d = geo::dot(a, b);
    double len = sum.magnitude();

    // Template container.
    geo::Registry<double> reg;
    reg.add(single);
    reg.add(combined);

    // Scene-graph diamond.
    geo::scene::Sprite sprite(1, 0.0, 0.0, true);
    double moved = sprite.move(len, d);

    std::printf("%s area=%f total=%f rim=%f wider=%d dot=%f moved=%f n=%zu\n",
                stats.largest_name.c_str(), single, combined, rim, wider, d,
                moved, reg.size());
    return 0;
}
