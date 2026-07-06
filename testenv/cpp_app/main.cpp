#include "shapes.hpp"

#include <cstdio>
#include <vector>

// Build a few circles and print their measured areas.
int main() {
    geo::Circle unit(1.0);
    geo::Circle big(10.0);

    std::vector<geo::Shape*> shapes;
    shapes.push_back(&unit);
    shapes.push_back(&big);

    double single = unit.area();
    double combined = total_area(shapes);
    int wider = max_of<int>(3, 7);

    std::printf("unit=%f total=%f wider=%d\n", single, combined, wider);
    return 0;
}
