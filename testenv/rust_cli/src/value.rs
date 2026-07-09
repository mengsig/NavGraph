//! Runtime values produced by the evaluator, plus a tiny constructor macro.

use std::fmt;

/// A computed value in the calculator's minimal type system.
#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    Number(f64),
    Boolean(bool),
    Unit,
}

/// Result type threaded through every evaluation step.
pub type EvalResult = Result<Value, String>;

impl Value {
    /// Coerce the value to an `f64`, erroring on non-numeric kinds.
    pub fn as_number(&self) -> Result<f64, String> {
        match self {
            Value::Number(n) => Ok(*n),
            other => Err(format!("expected number, got {:?}", other)),
        }
    }

    /// Whether the value counts as "truthy" for a conditional.
    pub fn truthy(&self) -> bool {
        match self {
            Value::Boolean(b) => *b,
            Value::Number(n) => *n != 0.0,
            Value::Unit => false,
        }
    }
}

impl fmt::Display for Value {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Value::Number(n) => write!(f, "{}", n),
            Value::Boolean(b) => write!(f, "{}", b),
            Value::Unit => write!(f, "()"),
        }
    }
}

/// Build a `Value::Number` tersely at a call site: `num!(3.0)`.
macro_rules! num {
    ($n:expr) => {
        $crate::value::Value::Number($n)
    };
}

// Make the macro visible to sibling modules within the crate.
pub(crate) use num;
