# Domain models for the tiny lending library.
#
# Exercises a mixin module (`Identifiable`), attr_accessor, a `self.` class
# factory, an instance predicate method, and a subclass (`Ebook < Book`).

# Mixin that gives any id-bearing object a stable, human-readable identifier.
# Included into Book, and therefore inherited by Ebook.
module Identifiable
  # Identifier such as "book-7", built from the concrete class's prefix.
  def identifier
    "#{prefix}-#{id}"
  end

  # Default namespace prefix; concrete classes override this.
  def prefix
    "item"
  end
end

# A single catalogue entry describing a physical book and its stock level.
class Book
  include Identifiable

  attr_accessor :id, :title, :author, :copies

  # Build a Book (or Ebook) from a symbol-keyed params hash. Digital rows
  # (`ebook: true`) are instantiated as the Ebook subclass.
  def self.from_hash(row)
    klass = row[:ebook] ? Ebook : self
    klass.new(row[:id], row[:title], row[:author], row[:copies] || 1)
  end

  def initialize(id, title, author, copies = 1)
    @id = id
    @title = title
    @author = author
    @copies = copies
  end

  # Override the mixin default so identifiers read "book-<id>".
  def prefix
    "book"
  end

  # True when at least one copy is on the shelf.
  def available?
    @copies > 0
  end

  # Lend a copy, decrementing stock; returns the lent identifier.
  def lend
    @copies -= 1 if available?
    identifier
  end

  # Serialize to a plain hash suitable for a JSON response body.
  def to_row
    { id: @id, title: @title, author: @author, copies: @copies, ref: identifier }
  end
end

# An electronic edition: effectively unlimited copies and its own prefix.
class Ebook < Book
  # Ebooks never run out of copies.
  def available?
    true
  end

  def prefix
    "ebook"
  end
end
