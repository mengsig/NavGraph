//! Evaluation: fold an expression tree down into a runtime `Value`.

use crate::parser::{BinOp, Expr};
use crate::value::{num, EvalResult, Value};

/// Anything that can be reduced to a runtime `Value`.
pub trait Evaluate {
    /// Evaluate `self` into a `Value`, or an error message.
    fn evaluate(&self) -> EvalResult;

    /// Evaluate and coerce straight to `f64`, for numeric callers.
    /// Default method built on top of `evaluate`.
    fn evaluate_number(&self) -> Result<f64, String> {
        self.evaluate()?.as_number()
    }
}

impl Evaluate for Expr {
    fn evaluate(&self) -> EvalResult {
        match self {
            Expr::Literal(n) => Ok(num!(*n)),
            Expr::Unary(n) => Ok(num!(*n)),
            Expr::Binary { op, lhs, rhs } => {
                let a = lhs.evaluate_number()?;
                let b = rhs.evaluate_number()?;
                Ok(num!(apply(*op, a, b)?))
            }
        }
    }
}

/// Apply a binary operator to two concrete numbers.
fn apply(op: BinOp, a: f64, b: f64) -> Result<f64, String> {
    match op {
        BinOp::Add => Ok(a + b),
        BinOp::Sub => Ok(a - b),
        BinOp::Mul => Ok(a * b),
        BinOp::Div => {
            if b == 0.0 {
                Err("division by zero".to_string())
            } else {
                Ok(a / b)
            }
        }
    }
}

/// Sum the numeric value of every evaluable in `items`.
/// Generic over any `T` that implements [`Evaluate`].
pub fn sum_all<T: Evaluate>(items: &[T]) -> Result<f64, String> {
    let mut total = 0.0;
    for item in items {
        total += item.evaluate_number()?;
    }
    Ok(total)
}

/// A boolean-typed wrapper value, unused for now.
// intentionally dead (fixture)
type Flag = Value;
