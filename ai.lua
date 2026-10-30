-- ---------------------------------------------------------------------------
-- DotsAI — computer opponent for Dots and Boxes (pure Lua)
--
--   easy   — takes any box on offer; otherwise draws a random line, which is
--            "safe" (gives no box a third side) only half the time.
--   medium — takes any box on offer; never gives a third side while a safe
--            line remains; once every line gives something away, sacrifices
--            the chain that hands the opponent the fewest boxes.
--   hard   — medium's play while the board is wide open, then an exact
--            search as soon as it fits the budget: the whole endgame once no
--            safe line is left, and the run-in to it while few safe lines
--            remain. The search knows the two moves the whole game turns on:
--            the double-cross (decline the last two boxes of a chain, or the
--            last four of a loop, so the opponent has to open the next one)
--            and the hard-hearted handout (open a 2-chain in its middle so it
--            cannot be declined). That is what "keeping control" means, and
--            it is what decides most games between players who never give a
--            third side away for free.
--
-- The search only considers safe lines while one exists (no early
-- sacrifices), captures without branching when a box's capture opens nothing
-- else, and branches on capture-or-decline at the end of a chain. Values are
-- exact under those restrictions and are memoised by the set of drawn lines:
-- the score still to be won depends on nothing else, whoever is to move.
-- ---------------------------------------------------------------------------

local DotsAI = {}

-- Search size limits. Measured on a desktop (see README): with these the
-- worst move on 6×6 stays well under the 1.5 s budget.
DotsAI.SAFE_LIMIT  = 12       -- search the run-in once at most this many safe lines remain
DotsAI.NODE_BUDGET = 150000   -- abort and fall back to medium past this...
DotsAI.LOONY_BUDGET = 600000  -- ...or past this once no safe line is left,
                              -- where a fallback would throw the game away

-- Deterministic per-edge hash keys (a sum of random 45-bit integers stays
-- exact in a double, and does not touch math.random's sequence).
local KEYS = {}
do
    local x = 12345
    local function nxt()
        x = (x * 1103515245 + 12345) % 2147483648
        return x
    end
    for e = 1, 2 * 6 * 7 + 8 do
        KEYS[e] = nxt() * 16384 + (nxt() % 16384)
    end
end

-- ---------------------------------------------------------------------------
-- Search state: flat copies of the board's arrays, mutated in place.
-- ---------------------------------------------------------------------------

local function newState(board)
    local t = board.topo
    local s = { t = t, drawn = {}, cnt = {}, left = 0, hash = 0 }
    for e = 1, t.E do
        local d = board.drawn[e] ~= 0
        s.drawn[e] = d
        if d then s.hash = s.hash + KEYS[e] end
    end
    for b = 1, t.B do
        s.cnt[b] = board.cnt[b]
        if board.cnt[b] < 4 then s.left = s.left + 1 end
    end
    return s
end

-- Draw e; returns the number of boxes it completed.
local function apply(s, e)
    s.drawn[e] = true
    s.hash = s.hash + KEYS[e]
    local g = 0
    local cnt = s.cnt
    for _, b in ipairs(s.t.edge_boxes[e]) do
        local k = cnt[b] + 1
        cnt[b] = k
        if k == 4 then g = g + 1 end
    end
    s.left = s.left - g
    return g
end

local function unapply(s, e, g)
    s.drawn[e] = false
    s.hash = s.hash - KEYS[e]
    local cnt = s.cnt
    for _, b in ipairs(s.t.edge_boxes[e]) do cnt[b] = cnt[b] - 1 end
    s.left = s.left + g
end

-- The undrawn edge of a box with three sides (or the first undrawn one).
local function openEdge(s, b)
    for _, e in ipairs(s.t.box_edges[b]) do
        if not s.drawn[e] then return e end
    end
end

-- The other undrawn edge of a two-sided box b, given one of them.
local function otherOpenEdge(s, b, e0)
    for _, e in ipairs(s.t.box_edges[b]) do
        if e ~= e0 and not s.drawn[e] then return e end
    end
end

local function acrossEdge(s, e, b)
    local bs = s.t.edge_boxes[e]
    if bs[1] == b then return bs[2] end
    return bs[1]
end

local function isSafe(s, e)
    if s.drawn[e] then return false end
    for _, b in ipairs(s.t.edge_boxes[e]) do
        if s.cnt[b] >= 2 then return false end
    end
    return true
end

local function safeEdges(s)
    local out = {}
    for e = 1, s.t.E do
        if isSafe(s, e) then out[#out + 1] = e end
    end
    return out
end

local function capturables(s)
    local out = {}
    for b = 1, s.t.B do
        if s.cnt[b] == 3 then out[#out + 1] = b end
    end
    return out
end

-- Boxes the player to move can take by just taking everything on offer.
-- Leaves the state unchanged.
local function greedyTake(s)
    local stack, total = {}, 0
    while true do
        local caps = capturables(s)
        if #caps == 0 then break end
        local e = openEdge(s, caps[1])
        local g = apply(s, e)
        stack[#stack + 1] = { e, g }
        total = total + g
    end
    for i = #stack, 1, -1 do unapply(s, stack[i][1], stack[i][2]) end
    return total
end

-- ---------------------------------------------------------------------------
-- Move options at a node: a list of { e, kind } where kind is "take" (the
-- mover keeps the turn if it completes something) or "give" (the turn
-- passes). Shared by the search and the root so they agree exactly.
-- ---------------------------------------------------------------------------

local function options(s)
    local caps = capturables(s)
    if #caps > 0 then
        -- A box whose capture opens nothing new (its open side borders
        -- nothing, a junction, or a box that is itself ready): just take it.
        for _, a in ipairs(caps) do
            local e = openEdge(s, a)
            local b = acrossEdge(s, e, a)
            if not b or s.cnt[b] ~= 2 then return { e } , false end
        end
        -- Every ready box leads into a chain. Take the first; consider
        -- declining only where it leaves exactly two boxes (end of a
        -- chain) or four (end of a loop) — anywhere else it hands over more.
        local a = caps[1]
        local e = openEdge(s, a)
        local b = acrossEdge(s, e, a)
        local f = otherOpenEdge(s, b, e)
        local c = f and acrossEdge(s, f, b)
        local decline = false
        if #caps == 1 then
            decline = (not c) or s.cnt[c] <= 1
        elseif #caps == 2 and c and s.cnt[c] == 2 then
            local g = otherOpenEdge(s, c, f)
            local d = g and acrossEdge(s, g, c)
            decline = d ~= nil and d == caps[2]
        end
        if decline then return { e, f }, true end
        return { e }, false
    end
    local safe = safeEdges(s)
    if #safe > 0 then return safe, false end
    local all = {}
    for e = 1, s.t.E do
        if not s.drawn[e] then all[#all + 1] = e end
    end
    return all, false
end

-- ---------------------------------------------------------------------------
-- Exact negamax: best (mover's boxes − opponent's boxes) over what is left.
-- ---------------------------------------------------------------------------

local Abort = {}

-- Alpha-beta over the options above, with a transposition table of bounds
-- (tt_lo / tt_hi) keyed by the set of drawn lines. Values are integers, so
-- the root can widen its window by one to keep ties exact.
local function solve(s, alpha, beta, tt, budget)
    if s.left == 0 then return 0 end
    local key = s.hash
    local lo, hi = tt.lo[key], tt.hi[key]
    if lo or hi then
        lo, hi = lo or -math.huge, hi or math.huge
        if lo == hi or lo >= beta then return lo end
        if hi <= alpha then return hi end
        if lo > alpha then alpha = lo end
        if hi < beta then beta = hi end
    end
    budget.nodes = budget.nodes + 1
    if budget.nodes > budget.max then error(Abort) end

    local alpha0 = alpha
    local best = -math.huge
    for _, e in ipairs((options(s))) do
        local g = apply(s, e)
        local val
        if g > 0 then
            val = g + solve(s, alpha - g, beta - g, tt, budget)
        else
            val = -solve(s, -beta, -alpha, tt, budget)
        end
        unapply(s, e, g)
        if val > best then
            best = val
            if val > alpha then alpha = val end
            if alpha >= beta then break end
        end
    end
    if best <= alpha0 then
        tt.hi[key] = best
    elseif best >= beta then
        tt.lo[key] = best
    else
        tt.lo[key], tt.hi[key] = best, best
    end
    return best
end

-- Bounds depend on the position alone, not on how it was reached, so the
-- table survives from one move to the next (and across games of the same
-- size): the captures that follow a decision then cost next to nothing, which
-- keeps a whole multi-capture turn as fast as its first move.
local TT_MAX = 150000
local shared = { n = nil, tt = nil, size = 0 }

local function newTT()
    return { lo = {}, hi = {} }
end

local function sharedTT(n)
    if shared.n ~= n or shared.size > TT_MAX then
        shared.n, shared.tt, shared.size = n, newTT(), 0
    end
    return shared.tt
end

-- Tests and match scripts start each measurement from a cold table.
function DotsAI.clearCache()
    shared.n, shared.tt, shared.size = nil, nil, 0
end

-- Scores the root options: the best ones exactly, the others as "worse".
-- Returns { {e=, v=} ... }, or nil when the search ran over budget.
local function searchRoot(s, max_nodes)
    local tt, budget = sharedTT(s.t.n), { nodes = 0, max = max_nodes or DotsAI.NODE_BUDGET }
    local scored = {}
    local ok, err = pcall(function()
        local best = -math.huge
        for _, e in ipairs((options(s))) do
            local g = apply(s, e)
            local a = best - 1   -- one below: a move as good as the best stays exact
            local val
            if g > 0 then
                val = g + solve(s, a - g, math.huge, tt, budget)
            else
                val = -solve(s, -math.huge, -a, tt, budget)
            end
            unapply(s, e, g)
            scored[#scored + 1] = { e = e, v = val }
            if val > best then best = val end
        end
    end)
    shared.size = shared.size + budget.nodes
    if not ok then
        if err == Abort then return nil, budget.nodes end
        error(err)
    end
    return scored, budget.nodes
end

-- ---------------------------------------------------------------------------
-- Level policies
-- ---------------------------------------------------------------------------

local function pick(list, rng)
    return list[rng(#list)]
end

local function allUndrawn(s)
    local out = {}
    for e = 1, s.t.E do
        if not s.drawn[e] then out[#out + 1] = e end
    end
    return out
end

local function takeAny(s)
    local caps = capturables(s)
    if #caps > 0 then return openEdge(s, caps[1]) end
end

-- Among the lines that all give something away, the ones that give least.
local function smallestSacrifice(s, rng)
    local best, best_cost = {}, math.huge
    for _, e in ipairs(allUndrawn(s)) do
        local g = apply(s, e)
        local cost = greedyTake(s) - g
        unapply(s, e, g)
        if cost < best_cost then
            best, best_cost = { e }, cost
        elseif cost == best_cost then
            best[#best + 1] = e
        end
    end
    return pick(best, rng)
end

local function easyMove(s, rng)
    local e = takeAny(s)
    if e then return e end
    local safe = safeEdges(s)
    if #safe > 0 and rng(2) == 1 then return pick(safe, rng) end
    return pick(allUndrawn(s), rng)
end

local function mediumMove(s, rng)
    local e = takeAny(s)
    if e then return e end
    local safe = safeEdges(s)
    if #safe > 0 then return pick(safe, rng) end
    return smallestSacrifice(s, rng)
end

local function hardMove(board, rng, stats)
    local s = newState(board)
    local safe = safeEdges(s)
    -- A box on offer while many safe lines remain is simply taken (medium
    -- does that); the search starts once the safe lines run low.
    if #safe <= DotsAI.SAFE_LIMIT then
        -- An aborted search unwinds by error and leaves its state half
        -- applied, so it gets a copy; the fallback reads the clean one.
        local scored, nodes = searchRoot(newState(board),
            #safe == 0 and DotsAI.LOONY_BUDGET or DotsAI.NODE_BUDGET)
        if stats then stats.nodes = nodes; stats.searched = scored ~= nil; stats.safe = #safe end
        if scored and #scored > 0 then
            local best, bv = {}, -math.huge
            for _, m in ipairs(scored) do
                if m.v > bv then
                    best, bv = { m.e }, m.v
                elseif m.v == bv then
                    best[#best + 1] = m.e
                end
            end
            return pick(best, rng)
        end
    end
    return mediumMove(s, rng)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Returns the edge the AI draws for the player to move on `board`.
-- level: "easy" | "medium" | "hard". rng(n) → integer in 1..n (defaults to
-- math.random). stats (optional table) receives search diagnostics.
function DotsAI.chooseMove(board, level, rng, stats)
    if board.status ~= "playing" then return nil end
    rng = rng or math.random
    if level == "hard" then
        return hardMove(board, rng, stats)
    end
    local s = newState(board)
    if level == "easy" then
        return easyMove(s, rng)
    end
    return mediumMove(s, rng)
end

-- Exposed for tests: exact value (mover's net boxes) of the position, or nil
-- if it does not fit the node budget.
function DotsAI.solve(board, max_nodes)
    local s = newState(board)
    local budget = { nodes = 0, max = max_nodes or DotsAI.NODE_BUDGET }
    local ok, v = pcall(solve, s, -math.huge, math.huge, newTT(), budget)
    if ok then return v end
    if v == Abort then return nil end
    error(v)
end

return DotsAI
