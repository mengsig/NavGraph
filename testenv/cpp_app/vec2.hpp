#ifndef GEO_VEC2_HPP
#define GEO_VEC2_HPP

#include <cmath>

namespace geo {

/// A 2D vector/point parameterized on its scalar type.
///
/// Exercises a class template with operator overloads and an out-of-line
/// template method definition.
template <typename T>
class Vec2 {
public:
    T x;
    T y;

    /// Construct the zero vector.
    Vec2() : x(T{}), y(T{}) {}
    /// Construct from explicit components.
    Vec2(T x_, T y_) : x(x_), y(y_) {}

    /// Component-wise addition.
    Vec2 operator+(const Vec2& rhs) const noexcept {
        return Vec2(x + rhs.x, y + rhs.y);
    }
    /// Component-wise subtraction.
    Vec2 operator-(const Vec2& rhs) const noexcept {
        return Vec2(x - rhs.x, y - rhs.y);
    }
    /// Uniform scale by a scalar.
    Vec2 operator*(T k) const noexcept {
        return Vec2(x * k, y * k);
    }
    /// Exact component-wise equality.
    bool operator==(const Vec2& rhs) const noexcept {
        return x == rhs.x && y == rhs.y;
    }

    /// Euclidean length measured from the origin.
    double magnitude() const noexcept;
};

/// Dot product of two vectors (free function template).
template <typename T>
T dot(const Vec2<T>& a, const Vec2<T>& b) noexcept {
    return a.x * b.x + a.y * b.y;
}

// Out-of-line definition of a template member function.
template <typename T>
double Vec2<T>::magnitude() const noexcept {
    return std::sqrt(static_cast<double>(dot(*this, *this)));
}

}  // namespace geo

#endif  // GEO_VEC2_HPP
