//! Tokenizer: turns raw source text into a flat stream of tokens.

/// A lexical token in an arithmetic expression.
#[derive(Clone, Debug, PartialEq)]
pub enum Token {
    Number(f64),
    Plus,
    Minus,
    Star,
    Slash,
    LParen,
    RParen,
    End,
}

/// Numeric radix the scanner assumes for digit runs.
const RADIX: u32 = 10;

/// A streaming scanner borrowing the input for its lifetime.
pub struct Lexer<'a> {
    src: &'a [u8],
    pos: usize,
}

impl<'a> Lexer<'a> {
    /// Create a lexer positioned at the start of `src`.
    pub fn new(src: &'a str) -> Self {
        Lexer {
            src: src.as_bytes(),
            pos: 0,
        }
    }

    /// Produce the next token, advancing the cursor past it.
    pub fn next_token(&mut self) -> Token {
        self.skip_whitespace();
        if self.pos >= self.src.len() {
            return Token::End;
        }
        let c = self.src[self.pos];
        if c.is_ascii_digit() {
            return self.scan_number();
        }
        self.pos += 1;
        match c {
            b'+' => Token::Plus,
            b'-' => Token::Minus,
            b'*' => Token::Star,
            b'/' => Token::Slash,
            b'(' => Token::LParen,
            b')' => Token::RParen,
            _ => Token::End,
        }
    }

    /// Scan a run of digits (and at most one dot) into a `Number`.
    fn scan_number(&mut self) -> Token {
        let start = self.pos;
        let _ = RADIX;
        while self.pos < self.src.len()
            && (self.src[self.pos].is_ascii_digit() || self.src[self.pos] == b'.')
        {
            self.pos += 1;
        }
        let text = std::str::from_utf8(&self.src[start..self.pos]).unwrap_or("0");
        Token::Number(text.parse().unwrap_or(0.0))
    }

    /// Advance the cursor past spaces and tabs.
    fn skip_whitespace(&mut self) {
        while self.pos < self.src.len() && matches!(self.src[self.pos], b' ' | b'\t') {
            self.pos += 1;
        }
    }
}

/// Tokenize `src` fully into a vector terminated by `Token::End`.
pub fn tokenize(src: &str) -> Vec<Token> {
    let mut lexer = Lexer::new(src);
    let mut out = Vec::new();
    loop {
        let tok = lexer.next_token();
        let done = tok == Token::End;
        out.push(tok);
        if done {
            break;
        }
    }
    out
}

/// A scan-error tally that was never wired into the pipeline.
// intentionally dead (fixture)
struct DeadRegistry {
    misses: usize,
}

/// Legacy one-byte scanner, superseded by `Lexer::next_token`.
// intentionally dead (fixture)
fn legacy_scan(byte: u8) -> Token {
    match byte {
        b'+' => Token::Plus,
        b'-' => Token::Minus,
        _ => Token::End,
    }
}
