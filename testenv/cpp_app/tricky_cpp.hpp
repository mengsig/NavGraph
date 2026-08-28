#ifndef GEO_TRICKY_CPP_HPP
#define GEO_TRICKY_CPP_HPP

#include <functional>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "shapes.hpp"

namespace geo::tricky {

/// Enum class carrying its own behaviour through a free function below.
enum class Severity {
    Low,
    High,
};

/// Name of a severity; the "method on an enum" C++ actually allows.
const char* label(Severity s) noexcept;

/// Outer class with a nested class and a nested enum.
class Analyzer {
public:
    /// Nested type: geo::tricky::Analyzer::Report.
    class Report {
    public:
        Report(int count, double score);

        /// Getter/setter pair over a private member.
        int count() const noexcept { return count_; }
        void set_count(int n) noexcept { count_ = n; }
        double score() const noexcept { return score_; }

    private:
        int count_;
        double score_;
    };

    /// Nested enum inside the outer class.
    enum class Mode { Fast, Thorough };

    explicit Analyzer(Mode mode = Mode::Fast);

    /// Three overloads of one name: the classic resolver trap.
    Report measure(const Shape& shape) const;
    Report measure(const std::vector<Shape*>& shapes) const;
    Report measure(double raw, Severity s) const;

    /// Static (class-level) factory plus a static data member.
    static Analyzer thorough();
    static int instances;

    /// Signature split over three lines with a default argument.
    Report combine(
        const Report& a,
        const Report& b = Report(0, 0.0)) const;

    Mode mode() const noexcept { return mode_; }

private:
    Mode mode_;
};

/// CRTP base: the derived type is a template parameter.
template <typename Derived>
class Counter {
public:
    int bump() { return static_cast<Derived*>(this)->step(); }
};

/// CRTP user, and the type that supplies `step`.
class StepCounter : public Counter<StepCounter> {
public:
    int step();

private:
    int calls_ = 0;
};

/// A callable object: operator() plus operator[].
class Weights {
public:
    explicit Weights(std::vector<double> w) : w_(std::move(w)) {}

    double operator()(std::size_t i) const;
    double& operator[](std::size_t i) { return w_[i]; }
    std::size_t size() const noexcept { return w_.size(); }

private:
    std::vector<double> w_;
};

/// Regression: a unique_ptr/shared_ptr field dispatches through its pointee,
/// exactly like Rust's Box/Rc — the wrapper itself must not shadow that
/// dispatch the way an opaque container (std::vector, ...) does.
class Engine {
public:
    int start() const { return 1; }
};

class Car {
public:
    Car(std::unique_ptr<Engine> engine, std::shared_ptr<Engine> shared)
        : engine_(std::move(engine)), shared_(std::move(shared)) {}

    int goUnique() const { return engine_->start(); }
    int goShared() const { return shared_->start(); }

private:
    std::unique_ptr<Engine> engine_;
    std::shared_ptr<Engine> shared_;
};

/// Primary template plus an explicit specialization.
template <typename T>
struct Describe {
    static std::string text();
};

template <>
struct Describe<double> {
    static std::string text();
};

double tricky_run();

}  // namespace geo::tricky

#endif  // GEO_TRICKY_CPP_HPP
