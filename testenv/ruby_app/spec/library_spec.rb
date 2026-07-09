# Unit specs for the Library store. Lives under spec/ so navgraph's --no-test
# filter should treat symbols used only here as test-only.

require_relative "../lib/library"

# Minimal RSpec-flavoured harness so the file reads like a real spec without a
# gem dependency. Exercises Library#add_book and Library#checkout.
def describe(_name)
  yield
end

describe "Library" do
  # A book added to the library can be checked out once per copy.
  def test_add_and_checkout
    lib = Library.new("Test")
    lib.add_book(id: 1, title: "Dune", author: "Herbert", copies: 1)
    ref = lib.checkout(1)
    raise "expected book-1" unless ref == "book-1"
  end

  # Ebook rows come back with an unlimited-copies availability.
  def test_ebook_row
    lib = Library.new("Test")
    row = lib.add_book(id: 2, title: "Snow Crash", author: "Stephenson", ebook: true)
    raise "bad ref" unless row[:ref] == "ebook-2"
  end
end
