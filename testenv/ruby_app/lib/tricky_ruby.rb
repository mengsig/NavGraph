# Constructs that break heuristic parsers, gathered in one file.
#
# Nothing in the app requires it: tests/golden/ruby.json records exactly which
# definitions and reference edges a correct indexer must find here.

require_relative "book"
require_relative "catalog"

# Module-level constant a local below shadows.
BUDGET = 16

# Namespace module holding a nested module, a nested class, and class methods.
module Tricky
  # Nested constant inside a module.
  WIDTH = 4

  # Mixin providing a comparison so Ledger can be sorted.
  module Rankable
    def rank
      size
    end

    # Spaceship operator: the method name is punctuation.
    def <=>(other)
      rank <=> other.rank
    end
  end

  # Mixin sharing no method name with the Ledger hierarchy, so a correct
  # `super` walk through it must fall through to a real ancestor.
  module Loud
    def volume
      1
    end
  end

  # Module of singleton (module-level) helpers.
  module Format
    # Defined with `def self.` inside a module: a module function.
    def self.cents(amount)
      "#{amount}c"
    end

    # Shares its simple name with Catalog::Sorting.by_title.
    def self.by_title(rows)
      rows.sort_by { |row| row[:title] }
    end
  end

  # A ledger of book rows, with operators, accessors and a block-taking method.
  class Ledger
    include Rankable
    include Comparable

    attr_reader :owner
    attr_accessor :tag

    # Class-level constant and a class variable.
    DEFAULT_TAG = "none"
    @@created = 0

    # Keyword arguments with a default.
    def initialize(owner, tag: DEFAULT_TAG)
      @owner = owner
      @tag = tag
      @rows = []
      @@created += 1
    end

    # Reader for the class variable, defined on the singleton class.
    def self.created
      @@created
    end

    # Splat arguments.
    def post(*rows)
      rows.each { |row| @rows << row }
      size
    end

    def size
      @rows.length
    end

    # Operator overloading: `ledger + other`.
    def +(other)
      merged = Ledger.new(@owner, tag: @tag)
      merged.post(*@rows, *other.rows)
      merged
    end

    # Index operator.
    def [](index)
      @rows[index]
    end

    # A method that yields to a block.
    def each_title
      @rows.each { |row| yield row[:title] }
    end

    # Serialized rows, ordered through the sibling module.
    def titles
      Format.by_title(@rows).map { |row| row[:title] }
    end

    protected

    # Protected reader used by `+` on another instance.
    def rows
      @rows
    end
  end

  # Subclass overriding a method and calling `super`.
  class TaggedLedger < Ledger
    def initialize(owner, tag)
      super(owner, tag: tag)
    end

    def titles
      super.map { |title| "#{@tag}:#{title}" }
    end
  end

  # Regression: a class that both inherits from Ledger and mixes in Loud, then
  # overrides an inherited method and calls `super`. `type_bases[LoudLedger]`
  # used to close a cycle through the reverse mixin edge on `Loud`, so `super`
  # here resolved to `LoudLedger#size` itself instead of `Ledger#size`.
  class LoudLedger < Ledger
    include Loud

    def size
      super + 1
    end
  end

  # Metaprogramming: three readers created at load time. A lexical scan sees
  # no `def scale_by_two`, only the loop that defines it.
  class Scaler
    { two: 2, three: 3 }.each do |name, factor|
      define_method("scale_by_#{name}") { |value| value * factor }
    end

    # Dynamic dispatch fallback.
    def method_missing(name, *args)
      return 0 unless name.to_s.start_with?("scale_")
      args.first.to_i
    end

    def respond_to_missing?(name, include_private = false)
      name.to_s.start_with?("scale_") || super
    end
  end
end

# A lambda held in a constant, called only through that constant.
DOUBLER = ->(value) { value * 2 }

# A method, then an alias for it.
def double_value(value)
  value * 2
end

alias_method_target = method(:double_value)

# The local BUDGET hides the top-level constant.
def shadow_budget(n)
  budget = 4
  n * budget
end

# Same name as app.rb's top-level helper: two definitions, one name, two files.
def parse_body(raw)
  raw.to_s
end

# Code-shaped text in a heredoc and in comments: data, not symbols.
BANNER = <<~TEXT
  def phantom_from_string
  end
  class PhantomClass
  end
TEXT
# def phantom_from_comment; end

# Drives every construct above from one place.
def tricky_run
  ledger = Tricky::Ledger.new("root", tag: "a")
  ledger.post({ id: 1, title: "Dune" }, { id: 2, title: "Emma" })

  tagged = Tricky::TaggedLedger.new("root", "b")
  tagged.post({ id: 3, title: "Ada" })

  merged = ledger + tagged
  first = merged[0]

  titles = []
  merged.each_title { |title| titles << title }

  scaler = Tricky::Scaler.new
  scaled = scaler.scale_by_two(3) + scaler.scale_by_three(3)

  loud = Tricky::LoudLedger.new("root", tag: "c")
  loud.post({ id: 5, title: "Echo" })
  loud_size = loud.size

  book = Book.from_hash(id: 4, title: "Ruby", author: "Y", copies: 2)
  shelf = Catalog::Shelf.new("new")
  shelf.add(book)

  [
    Tricky::Format.cents(scaled),
    Tricky::Ledger.created,
    ledger.rank,
    tagged.titles.length,
    shelf.titles.length,
    book.lend,
    first[:title],
    DOUBLER.call(shadow_budget(BUDGET)),
    parse_body(BANNER).length,
    Tricky::WIDTH,
    loud_size
  ].join(" ")
end
