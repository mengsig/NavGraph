//! A tiny arithmetic calculator CLI: `calc "1 + 2 * (3 - 4)"`.

mod eval;
mod lexer;
mod parser;
mod value;

use eval::Evaluate;
use parser::parse_str;

/// Program name shown in usage text.
const PROG: &str = "calc";

/// Count of expressions evaluated this run (illustrative mutable static).
static mut EVAL_COUNT: u64 = 0;

/// Inline module of user-facing rendering helpers.
mod ui {
    use crate::value::Value;

    /// Render a successful result value as an output line.
    pub fn render(value: &Value) -> String {
        format!("= {}", value)
    }

    /// Render an error message as an output line.
    pub fn render_error(msg: &str) -> String {
        format!("error: {}", msg)
    }
}

/// Evaluate one source line and return a printable result line.
fn run(src: &str) -> String {
    unsafe {
        EVAL_COUNT += 1;
    }
    match parse_str(src) {
        Ok(expr) => match expr.evaluate() {
            Ok(value) => ui::render(&value),
            Err(msg) => ui::render_error(&msg),
        },
        Err(msg) => ui::render_error(&msg),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() {
        eprintln!("usage: {} <expression>", PROG);
        return;
    }
    let src = args.join(" ");
    println!("{}", run(&src));
}
