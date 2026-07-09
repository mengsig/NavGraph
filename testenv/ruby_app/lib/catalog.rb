# Cataloguing helpers organised under a single namespace module.
#
# Exercises a nested class (`Catalog::Shelf`), a nested module of class
# methods (`Catalog::Sorting`), and intentional dead code.

# Namespace for everything to do with arranging books.
module Catalog
  # A named grouping of books, e.g. "New Arrivals".
  class Shelf
    attr_accessor :name

    def initialize(name)
      @name = name
      @books = []
    end

    # Add a book to this shelf; returns self so calls can be chained.
    def add(book)
      @books << book
      self
    end

    # Titles on the shelf, ordered by the Sorting strategy.
    def titles
      Sorting.by_title(@books).map(&:title)
    end
  end

  # Ordering strategies used by Shelf#titles.
  module Sorting
    # Order books alphabetically by title.
    def self.by_title(books)
      books.sort_by(&:title)
    end

    # intentionally dead (fixture): no caller references by_author.
    def self.by_author(books)
      books.sort_by(&:author)
    end
  end

  # intentionally dead (fixture): a storage-box type nothing references yet.
  class ArchiveBox
    attr_accessor :label

    def initialize(label)
      @label = label
    end
  end
end
