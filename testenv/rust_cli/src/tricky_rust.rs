//! Constructs that break heuristic parsers, gathered in one module.
//!
//! Nothing in the calculator calls it: `tests/golden/rust.json` records exactly
//! which definitions and reference edges a correct indexer must find here.

use crate::lexer::{tokenize, Token};
use crate::parser::{BinOp, Expr};
// Aliased import of a type already imported elsewhere under its own name.
use crate::value::Value as Val;
use std::collections::HashMap;
use std::fmt;
use std::ops::Add;

/// Module-level constant a local below shadows.
pub const BUDGET: usize = 16;

/// Re-export: `Tokens` names the same enum as `lexer::Token`.
pub use crate::lexer::Token as Tokens;

/// Declarative macro that DEFINES a function; the definition only exists after
/// expansion, so a lexical scan never sees `scale_by_two`.
macro_rules! define_scaler {
    ($name:ident, $factor:expr) => {
        pub fn $name(v: f64) -> f64 {
            v * $factor
        }
    };
}

define_scaler!(scale_by_two, 2.0);
define_scaler!(scale_by_three, 3.0);

/// Trait with an associated type, an associated const, and a default method.
pub trait Summarize {
    /// The unit this summary is measured in.
    type Unit;

    /// How many entries a short summary shows.
    const WIDTH: usize;

    fn summary(&self) -> Self::Unit;

    /// Default method built on `summary`.
    fn short(&self) -> String
    where
        Self::Unit: fmt::Debug,
    {
        format!("{:?}", self.summary())
    }
}

/// A newtype carrying its own arithmetic.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Cents(pub i64);

/// Operator overloading through the standard `Add` trait.
impl Add for Cents {
    type Output = Cents;

    fn add(self, rhs: Cents) -> Cents {
        Cents(self.0 + rhs.0)
    }
}

impl Cents {
    /// Associated const on an inherent impl.
    pub const ZERO: Cents = Cents(0);

    /// Associated function with no `self`: Rust's static method.
    pub fn from_value(value: &Val) -> Cents {
        match value {
            Val::Number(n) => Cents((*n * 100.0) as i64),
            _ => Cents::ZERO,
        }
    }

    /// Getter/setter pair over the tuple field.
    pub fn get(&self) -> i64 {
        self.0
    }

    pub fn set(&mut self, value: i64) {
        self.0 = value;
    }
}

/// A ledger generic over its entry type, with a where clause.
pub struct Ledger<T>
where
    T: Clone,
{
    owner: String,
    entries: Vec<T>,
    tags: HashMap<String, usize>,
}

impl<T: Clone> Ledger<T> {
    /// Signature split over three lines.
    pub fn new(
        owner: &str,
        entries: Vec<T>,
    ) -> Self {
        Ledger {
            owner: owner.to_string(),
            entries,
            tags: HashMap::new(),
        }
    }

    pub fn push(&mut self, entry: T) -> usize {
        self.entries.push(entry);
        self.tags.insert(self.owner.clone(), self.entries.len());
        self.entries.len()
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }
}

/// Trait implementation for a generic type: `impl Trait for Type`.
impl<T: Clone> Summarize for Ledger<T> {
    type Unit = usize;
    const WIDTH: usize = 4;

    fn summary(&self) -> usize {
        self.len()
    }
}

/// Iterator implementation: Rust's generator shape.
pub struct Countdown {
    remaining: usize,
}

impl Iterator for Countdown {
    type Item = usize;

    fn next(&mut self) -> Option<usize> {
        if self.remaining == 0 {
            return None;
        }
        self.remaining -= 1;
        Some(self.remaining)
    }
}

/// Nested inline module, with a function that shares a name with a sibling.
pub mod render {
    use super::Cents;

    /// Same simple name as `crate::main::ui::render`: two functions, one name.
    pub fn render(cents: &Cents) -> String {
        format!("{}c", cents.get())
    }
}

fn double_value(v: f64) -> f64 {
    v * 2.0
}

/// A function bound to a static: calls through it reach `double_value`.
pub static DOUBLER: fn(f64) -> f64 = double_value;

/// A boxed closure held in a local, called through the binding.
pub fn make_scaler(factor: f64) -> Box<dyn Fn(f64) -> f64> {
    Box::new(move |v| v * factor)
}

/// The local `BUDGET` hides the module-level constant.
pub fn shadow_budget(n: usize) -> usize {
    const BUDGET: usize = 4;
    n * BUDGET
}

/// Destructuring a struct-variant pattern and a tuple at once.
pub fn split(expr: &Expr) -> (BinOp, usize) {
    match expr {
        Expr::Binary { op, lhs, rhs } => {
            let (a, b) = (lhs, rhs);
            let _ = (a, b);
            (*op, 2)
        }
        _ => (BinOp::Add, 0),
    }
}

/// Code-shaped text in a raw string and in comments: data, not symbols.
const BANNER: &str = r#"
pub fn phantom_from_string() {}
pub struct PhantomStruct { pub x: i32 }
"#;

// pub fn phantom_from_comment() {}

/// Drives every construct above from one place.
pub fn tricky_run(src: &str) -> String {
    let tokens: Vec<Token> = tokenize(src);
    let mut ledger: Ledger<Tokens> = Ledger::new("root", Vec::new());
    for token in tokens {
        ledger.push(token);
    }

    let mut cents = Cents::from_value(&Val::Number(2.5));
    cents.set(cents.get() + 1);
    let total = cents + Cents(5);

    let counted: usize = Countdown { remaining: 3 }.sum();
    let scaled = make_scaler(3.0)(scale_by_two(1.0)) + scale_by_three(1.0);
    let doubled = DOUBLER(scaled);

    let (op, arity) = split(&Expr::Literal(1.0));
    let width = <Ledger<Tokens> as Summarize>::WIDTH;

    format!(
        "{} {} {:?} {} {} {} {} {}",
        render::render(&total),
        ledger.short(),
        op,
        arity + counted + width,
        doubled,
        shadow_budget(BUDGET),
        ledger.summary(),
        BANNER.len()
    )
}
