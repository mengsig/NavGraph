#ifndef GEO_GEOMETRY_HPP
#define GEO_GEOMETRY_HPP

#include <cstddef>
#include <string>
#include <vector>

#include "shapes.hpp"

namespace geo {

/// Aggregate statistics computed over a collection of shapes.
struct AreaStats {
    double total;
    double largest;
    std::string largest_name;
};

namespace detail {
/// Clamp a value into the inclusive range [lo, hi]. (nested-namespace helper)
double clamp(double v, double lo, double hi) noexcept;

// intentionally dead (fixture): unused free function in a nested namespace.
double deadScale(double v) noexcept;
}  // namespace detail

/// Combined area, the largest shape's area, and that shape's name.
AreaStats summarize(const std::vector<Shape*>& shapes);

/// Sum of every shape's perimeter in the collection.
double total_perimeter(const std::vector<Shape*>& shapes);

/// A tiny append-only container, parameterized on element type.
///
/// Exercises a class template with inline members.
template <typename T>
class Registry {
public:
    /// Append an element and return its new index.
    std::size_t add(const T& item) {
        items_.push_back(item);
        return items_.size() - 1;
    }
    /// Number of stored elements (inline, const, noexcept).
    std::size_t size() const noexcept { return items_.size(); }
    /// Access by index (no bounds check).
    const T& at(std::size_t i) const { return items_[i]; }

private:
    std::vector<T> items_;
};

}  // namespace geo

#endif  // GEO_GEOMETRY_HPP
