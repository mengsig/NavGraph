# In-memory library store wiring the domain models together.
#
# Exercises `require_relative` across files plus cross-file method calls into
# Book (lib/book.rb) and Catalog (lib/catalog.rb).

require_relative "book"
require_relative "catalog"

# Keeps books in a hash keyed by id and exposes the operations the HTTP layer
# needs. Holds no framework code so it is trivially unit-testable.
class Library
  attr_accessor :name

  def initialize(name)
    @name = name
    @books = {}
  end

  # Register a book built from a params hash; returns its serialized row.
  def add_book(params)
    book = Book.from_hash(params)
    @books[book.id] = book
    book.to_row
  end

  # Look up a stored book by id, or nil when absent.
  def find(id)
    @books[id]
  end

  # Lend the book with `id`; returns the lent identifier, or nil when the book
  # is missing or has no copies left.
  def checkout(id)
    book = find(id)
    return nil unless book && book.available?
    book.lend
  end

  # Every stored book as a serialized row, used by the index route.
  def rows
    @books.values.map(&:to_row)
  end

  # Snapshot of every stored title, arranged on a Catalog::Shelf.
  def shelf_titles
    shelf = Catalog::Shelf.new(@name)
    @books.each_value { |book| shelf.add(book) }
    shelf.titles
  end

  private

  # intentionally dead (fixture): helper kept for a future stats endpoint.
  def total_copies
    @books.values.sum(&:copies)
  end
end
