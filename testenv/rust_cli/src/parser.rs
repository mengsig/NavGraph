//! Recursive-descent parser building an expression tree from a token stream.

use crate::lexer::{tokenize, Token};

/// Binary operators the grammar recognizes.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum BinOp {
    Add,
    Sub,
    Mul,
    Div,
}

/// A node in the arithmetic expression tree.
#[derive(Clone, Debug, PartialEq)]
pub enum Expr {
    /// A numeric literal.
    Literal(f64),
    /// A pre-folded negation carrying its sign.
    Unary(f64),
    /// A binary operation with boxed operands.
    Binary {
        op: BinOp,
        lhs: Box<Expr>,
        rhs: Box<Expr>,
    },
}

/// A cursor over a token slice with one-token lookahead.
pub struct Parser {
    tokens: Vec<Token>,
    pos: usize,
}

impl Parser {
    /// Build a parser over an already-tokenized stream.
    pub fn new(tokens: Vec<Token>) -> Self {
        Parser { tokens, pos: 0 }
    }

    /// Parse a full expression, consuming the stream.
    pub fn parse(&mut self) -> Result<Expr, String> {
        self.parse_additive()
    }

    /// Grammar: `additive := multiplicative ( ('+'|'-') multiplicative )*`.
    fn parse_additive(&mut self) -> Result<Expr, String> {
        let mut lhs = self.parse_multiplicative()?;
        while let Some(op) = self.match_additive() {
            let rhs = self.parse_multiplicative()?;
            lhs = Expr::Binary {
                op,
                lhs: Box::new(lhs),
                rhs: Box::new(rhs),
            };
        }
        Ok(lhs)
    }

    /// Grammar: `multiplicative := primary ( ('*'|'/') primary )*`.
    fn parse_multiplicative(&mut self) -> Result<Expr, String> {
        let mut lhs = self.parse_primary()?;
        while let Some(op) = self.match_multiplicative() {
            let rhs = self.parse_primary()?;
            lhs = Expr::Binary {
                op,
                lhs: Box::new(lhs),
                rhs: Box::new(rhs),
            };
        }
        Ok(lhs)
    }

    /// Grammar: `primary := number | '(' additive ')' | '-' primary`.
    fn parse_primary(&mut self) -> Result<Expr, String> {
        match self.advance() {
            Token::Number(n) => Ok(Expr::Literal(n)),
            Token::Minus => {
                let inner = self.parse_primary()?;
                match inner {
                    Expr::Literal(n) => Ok(Expr::Unary(-n)),
                    other => Ok(Expr::Binary {
                        op: BinOp::Sub,
                        lhs: Box::new(Expr::Literal(0.0)),
                        rhs: Box::new(other),
                    }),
                }
            }
            Token::LParen => {
                let inner = self.parse_additive()?;
                match self.advance() {
                    Token::RParen => Ok(inner),
                    other => Err(format!("expected ')', got {:?}", other)),
                }
            }
            other => Err(format!("unexpected token {:?}", other)),
        }
    }

    fn match_additive(&mut self) -> Option<BinOp> {
        match self.peek() {
            Token::Plus => {
                self.pos += 1;
                Some(BinOp::Add)
            }
            Token::Minus => {
                self.pos += 1;
                Some(BinOp::Sub)
            }
            _ => None,
        }
    }

    fn match_multiplicative(&mut self) -> Option<BinOp> {
        match self.peek() {
            Token::Star => {
                self.pos += 1;
                Some(BinOp::Mul)
            }
            Token::Slash => {
                self.pos += 1;
                Some(BinOp::Div)
            }
            _ => None,
        }
    }

    fn peek(&self) -> Token {
        self.tokens.get(self.pos).cloned().unwrap_or(Token::End)
    }

    fn advance(&mut self) -> Token {
        let tok = self.peek();
        self.pos += 1;
        tok
    }
}

/// Convenience: tokenize then parse a source string in one call.
pub fn parse_str(src: &str) -> Result<Expr, String> {
    let tokens = tokenize(src);
    Parser::new(tokens).parse()
}
