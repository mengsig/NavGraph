#include "tricky_cpp.hpp"

#include "geometry.hpp"
#include "scene.hpp"
#include "vec2.hpp"

#include <cmath>
#include <cstring>

namespace geo::tricky {

/// Anonymous-namespace helper sharing its name with shapes.cpp's own
/// `scaleArea`: two internal-linkage definitions, one name, two files.
namespace {
double scaleArea(double a, double factor) {
    return a * factor;
}
}  // namespace

/// Namespace alias plus a using-declaration.
namespace sc = ::geo::scene;
using ::geo::total_perimeter;

int Analyzer::instances = 0;

const char* label(Severity s) noexcept {
    return s == Severity::High ? "high" : "low";
}

Analyzer::Report::Report(int count, double score)
    : count_(count), score_(score) {}

Analyzer::Analyzer(Mode mode) : mode_(mode) {
    instances += 1;
}

Analyzer::Report Analyzer::measure(const Shape& shape) const {
    return Report(1, scaleArea(shape.area(), 1.0));
}

Analyzer::Report Analyzer::measure(const std::vector<Shape*>& shapes) const {
    AreaStats stats = summarize(shapes);
    return Report(static_cast<int>(shapes.size()), stats.total);
}

Analyzer::Report Analyzer::measure(double raw, Severity s) const {
    const double factor = (s == Severity::High) ? 2.0 : 1.0;
    return Report(1, scaleArea(raw, factor));
}

Analyzer Analyzer::thorough() {
    return Analyzer(Mode::Thorough);
}

Analyzer::Report Analyzer::combine(const Report& a, const Report& b) const {
    return Report(a.count() + b.count(), a.score() + b.score());
}

int StepCounter::step() {
    calls_ += 1;
    return calls_;
}

double Weights::operator()(std::size_t i) const {
    return w_[i];
}

template <typename T>
std::string Describe<T>::text() {
    return "generic";
}

std::string Describe<double>::text() {
    return "double";
}

/// Code-shaped text in a raw string literal and in comments: data, not code.
static const char* kBanner = R"cpp(
namespace phantom { class PhantomClass { public: void ghost(); }; }
double phantom_from_string() { return 0.0; }
)cpp";
// class PhantomFromComment { public: void ghost(); };

double tricky_run() {
    Circle unit(1.0);
    std::vector<Shape*> shapes{&unit};

    Analyzer fast;
    Analyzer deep = Analyzer::thorough();

    // Three call sites, three different overloads of `measure`.
    Analyzer::Report one = fast.measure(unit);
    Analyzer::Report many = deep.measure(shapes);
    Analyzer::Report raw = fast.measure(2.5, Severity::High);
    Analyzer::Report all = fast.combine(one, many);
    all.set_count(all.count() + raw.count());

    // A lambda bound to a variable, and one wrapped in std::function.
    auto twice = [](double v) { return v * 2.0; };
    std::function<double(double)> thrice = [](double v) { return v * 3.0; };
    double scaled = thrice(twice(all.score()));

    StepCounter counter;
    int steps = counter.bump();

    Weights weights({1.0, 2.0, 3.0});
    weights[0] = 0.5;
    double picked = weights(2);

    Car car(std::make_unique<Engine>(), std::make_shared<Engine>());
    int engineSteps = car.goUnique() + car.goShared();

    // Structured binding over a pair.
    std::pair<double, double> pair{picked, scaled};
    auto [lo, hi] = pair;

    sc::Sprite sprite(steps, lo, hi, true);
    double moved = sprite.move(lo, hi);
    double rim = total_perimeter(shapes);

    return moved + rim + std::strlen(kBanner) +
           std::strlen(label(Severity::Low)) + Describe<double>::text().size() +
           weights.size() + static_cast<double>(Analyzer::instances) + engineSteps;
}

}  // namespace geo::tricky
