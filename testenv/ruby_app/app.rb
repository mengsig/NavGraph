# Classic Sinatra front-end for the lending library.
#
# Exercises Sinatra's bare-verb routes (get/post/put/delete), a top-level
# require plus a require_relative into lib/, and route bodies that call across
# files into Library (lib/library.rb).

require "sinatra"
require "json"
require_relative "lib/library"

# Shared in-memory library backing every route below.
LIBRARY = Library.new("Central")

# GET /books — list every catalogued book.
get "/books" do
  json LIBRARY.rows
end

# GET /books/:id — fetch a single book row, 404 when unknown.
get "/books/:id" do
  book = LIBRARY.find(params[:id].to_i)
  halt 404 unless book
  json book.to_row
end

# GET /shelf — every stored title arranged on the central shelf.
get "/shelf" do
  json LIBRARY.shelf_titles
end

# POST /books — add a new book from the JSON request body.
post "/books" do
  row = LIBRARY.add_book(parse_body)
  status 201
  json row
end

# PUT /books/:id/checkout — lend a copy, 409 when unavailable.
put "/books/:id/checkout" do
  ref = LIBRARY.checkout(params[:id].to_i)
  halt 409 unless ref
  json({ lent: ref })
end

# DELETE /books/:id — removal is not implemented yet.
delete "/books/:id" do
  status 501
end

# Decode the request body into a symbol-keyed hash.
def parse_body
  JSON.parse(request.body.read, symbolize_names: true)
end

# Render an object as a JSON response body.
def json(obj)
  content_type :json
  obj.to_json
end
