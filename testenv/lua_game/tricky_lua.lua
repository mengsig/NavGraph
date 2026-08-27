--- Constructs that break heuristic parsers, gathered in one module.
-- Nothing in the game requires this file: tests/golden/lua.json records exactly
-- which definitions and reference edges a correct indexer must find here.

local Vec = require("vec")
local util = require("util")
local Game = require("game")
local Entity = require("entity")
-- Aliased require of a module already required under another name elsewhere.
local helpers = require("util")

--- Module-level constant a local below shadows.
local budget = 16

local M = {}

--- Nested table of tables, two levels deep, with a function at each level.
M.limits = {
  low = 1,
  high = 9,
  clampers = {
    --- Function field two tables deep.
    hard = function(v)
      return util.clamp(v, 1, 9)
    end,
  },
}

--- Class table with a metatable, an inherited base, and metamethods.
local Account = {}
Account.__index = Account

--- Metamethod: `a + b` on two accounts.
function Account.__add(a, b)
  return Account.new(a.cents + b.cents)
end

--- Metamethod: tostring(account).
function Account.__tostring(self)
  return "account:" .. self.cents
end

--- Dot-form constructor (no self).
function Account.new(cents)
  local self = setmetatable({}, Account)
  self.cents = cents or 0
  return self
end

--- Colon-form method: `self` is implicit.
function Account:deposit(amount)
  self.cents = self.cents + amount
  return self
end

--- Getter/setter pair over one field.
function Account:balance()
  return self.cents
end

function Account:setBalance(value)
  self.cents = value
end

--- Subclass table inheriting through the metatable chain.
local Savings = setmetatable({}, { __index = Account })
Savings.__index = Savings

function Savings.new(cents, rate)
  local self = Account.new(cents)
  self.rate = rate
  return setmetatable(self, Savings)
end

--- Overrides the base method and calls back into it.
function Savings:deposit(amount)
  Account.deposit(self, amount)
  self.cents = self.cents + math.floor(amount * self.rate)
  return self
end

--- Assignment-form method field (not `function M.x`).
M.describe = function(account)
  return account:balance() .. " cents"
end

--- A closure stored in a local, called only through that local.
local function doubleValue(v)
  return v * 2
end

local doubler = doubleValue

--- A closure returned by a factory: the classic nested-function case.
local function makeScaler(factor)
  return function(v)
    return v * factor
  end
end

--- Varargs plus multiple return values.
local function minmax(...)
  local lo, hi = nil, nil
  for _, v in ipairs({ ... }) do
    lo = (lo == nil or v < lo) and v or lo
    hi = (hi == nil or v > hi) and v or hi
  end
  return lo, hi
end

--- The local `budget` hides the module-level `budget`.
local function shadowBudget(n)
  local budget = 4
  return n * budget
end

--- Coroutine: lua's generator.
local function counter(n)
  return coroutine.wrap(function()
    for i = 1, n do
      coroutine.yield(i)
    end
  end)
end

--- Code-shaped text in a long string and in comments is data, not code.
local BANNER = [[
function phantomFromString() end
local PhantomTable = { field = 1 }
]]
-- function phantomFromComment() end

--- Same name as game.lua's module-private `reap`: two file-local definitions.
local function reap(list)
  local live = {}
  for _, item in ipairs(list) do
    if item ~= nil then
      table.insert(live, item)
    end
  end
  return live
end

--- Drives the engine modules through their public API, so the corpus carries
-- cross-file call edges through required modules as well as local ones.
function M.simulate(ticks)
  local world = Game.new()
  local hero = world:spawn(0, 0)
  hero:push(Vec.make(1, 1))
  hero:advance(0.5)

  local ghost = Entity.new(5, 5)
  ghost:push(Vec.scale(Vec.make(1, 0), 2))
  ghost:kill()

  for _ = 1, ticks do
    world:step(0.1)
  end

  local reach = Vec.lensq(Vec.add(hero.pos, ghost.pos))
  util.log("reach: " .. reach)
  return util.clamp(world:count(), 0, 10)
end

--- Drives every construct above from one place.
function M.run()
  local a = Account.new(100)
  local b = Account.new(50)
  a:deposit(25)
  local merged = a + b

  local s = Savings.new(200, 0.1)
  s:deposit(10)
  s:setBalance(s:balance() + 1)

  local scaled = makeScaler(3)(merged:balance())
  local lo, hi = minmax(1, 7, 3)
  local kept = reap({ 1, nil, 2 })

  local total = 0
  for i in counter(3) do
    total = total + i
  end

  helpers.log(M.describe(a))
  local capped = M.limits.clampers.hard(scaled)
  local pos = Vec.make(lo, hi)
  local flipped = Vec.dir.opposite(pos)

  return doubler(shadowBudget(budget)) + capped + total + #kept + #BANNER +
    flipped.x + util.clamp(0, 0, 1) + M.simulate(2)
end

return M
