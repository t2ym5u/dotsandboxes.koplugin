-- ---------------------------------------------------------------------------
-- DotsBoard — Dots and Boxes rules (pure Lua, no KOReader dependency)
--
-- An n×n grid of boxes sits on (n+1)×(n+1) dots. Every line between two
-- adjacent dots is an edge, numbered once so the board and the AI can keep
-- flat arrays:
--   horizontal edge (r, c), r = 1..n+1, c = 1..n   → id (r-1)*n + c
--   vertical   edge (r, c), r = 1..n,   c = 1..n+1 → id NH + (r-1)*(n+1) + c
-- where NH = (n+1)*n. Box (r, c) has id (r-1)*n + c.
--
-- State the AI reads directly (and mutates through play/undo only):
--   drawn[e]  0 or the player (1/2) who drew edge e
--   cnt[b]    number of drawn sides of box b (0..4)
--   owner[b]  0 or the player who completed box b
-- ---------------------------------------------------------------------------

local SIZES = {
    { id = 3, label = "3×3" },
    { id = 4, label = "4×4" },
    { id = 5, label = "5×5" },
    { id = 6, label = "6×6" },
}
local DEFAULT_SIZE = 4

-- Topology depends on n alone, so it is built once per size and shared by
-- every board (and every AI search) of that size.
local topo_cache = {}

local function buildTopology(n)
    if topo_cache[n] then return topo_cache[n] end
    local NH = (n + 1) * n
    local E  = 2 * n * (n + 1)
    local edge_boxes = {}   -- e → { b1 [, b2] }
    local box_edges  = {}   -- b → { top, bottom, left, right }
    local edge_kind, edge_r, edge_c = {}, {}, {}
    for e = 1, E do edge_boxes[e] = {} end
    for r = 1, n + 1 do
        for c = 1, n do
            local e = (r - 1) * n + c
            edge_kind[e], edge_r[e], edge_c[e] = "h", r, c
        end
    end
    for r = 1, n do
        for c = 1, n + 1 do
            local e = NH + (r - 1) * (n + 1) + c
            edge_kind[e], edge_r[e], edge_c[e] = "v", r, c
        end
    end
    for r = 1, n do
        for c = 1, n do
            local b = (r - 1) * n + c
            local top    = (r - 1) * n + c
            local bottom = r * n + c
            local left   = NH + (r - 1) * (n + 1) + c
            local right  = left + 1
            box_edges[b] = { top, bottom, left, right }
            for _, e in ipairs(box_edges[b]) do
                local list = edge_boxes[e]
                list[#list + 1] = b
            end
        end
    end
    local t = {
        n = n, NH = NH, E = E, B = n * n,
        edge_boxes = edge_boxes, box_edges = box_edges,
        edge_kind = edge_kind, edge_r = edge_r, edge_c = edge_c,
    }
    topo_cache[n] = t
    return t
end

-- ---------------------------------------------------------------------------
-- DotsBoard
-- ---------------------------------------------------------------------------

local DotsBoard = {}
DotsBoard.__index = DotsBoard

DotsBoard.SIZES        = SIZES
DotsBoard.DEFAULT_SIZE = DEFAULT_SIZE
DotsBoard.topology     = buildTopology

local function validSize(n)
    for _, s in ipairs(SIZES) do
        if s.id == n then return n end
    end
    return DEFAULT_SIZE
end

function DotsBoard:new(opts)
    opts = opts or {}
    local obj = setmetatable({}, self)
    obj:reset(opts.n)
    return obj
end

function DotsBoard:reset(n)
    n = validSize(n or self.n)
    local t = buildTopology(n)
    self.n       = n
    self.topo    = t
    self.drawn   = {}
    self.cnt     = {}
    self.owner   = {}
    for e = 1, t.E do self.drawn[e] = 0 end
    for b = 1, t.B do self.cnt[b] = 0; self.owner[b] = 0 end
    self.turn    = 1
    self.score   = { 0, 0 }
    self.moves   = 0          -- edges drawn so far
    self.history = {}         -- { e = edge, p = player, boxes = {b...} }
    self.status  = "playing"  -- "playing" | "ended"
    self.winner  = nil        -- 1, 2, or 0 for a draw
end

-- ---------------------------------------------------------------------------
-- Edge helpers
-- ---------------------------------------------------------------------------

function DotsBoard:hEdge(r, c)
    return (r - 1) * self.n + c
end

function DotsBoard:vEdge(r, c)
    return self.topo.NH + (r - 1) * (self.n + 1) + c
end

-- Returns "h"|"v", r, c for edge e.
function DotsBoard:edgeInfo(e)
    local t = self.topo
    return t.edge_kind[e], t.edge_r[e], t.edge_c[e]
end

function DotsBoard:edgeCount()
    return self.topo.E
end

function DotsBoard:isDrawn(e)
    return self.drawn[e] ~= 0
end

function DotsBoard:lastEdge()
    local h = self.history[#self.history]
    return h and h.e
end

-- ---------------------------------------------------------------------------
-- Moves
-- ---------------------------------------------------------------------------

-- Draw edge e for the player to move. Returns:
--   "invalid" (no such edge), "drawn" (already drawn), "over" (game ended),
--   "box"   — at least one box completed: the same player moves again,
--   "ok"    — nothing completed: the turn passes,
--   "won"   — the move completed the last box (see self.winner).
-- The second return value is the number of boxes completed.
function DotsBoard:play(e)
    if self.status ~= "playing" then return "over", 0 end
    if type(e) ~= "number" or e < 1 or e > self.topo.E then return "invalid", 0 end
    if self.drawn[e] ~= 0 then return "drawn", 0 end

    local p = self.turn
    self.drawn[e] = p
    self.moves = self.moves + 1
    local done = {}
    for _, b in ipairs(self.topo.edge_boxes[e]) do
        local k = self.cnt[b] + 1
        self.cnt[b] = k
        if k == 4 then
            self.owner[b] = p
            done[#done + 1] = b
        end
    end
    self.history[#self.history + 1] = { e = e, p = p, boxes = done }
    self.score[p] = self.score[p] + #done

    if self.score[1] + self.score[2] == self.topo.B then
        self.status = "ended"
        if self.score[1] > self.score[2] then
            self.winner = 1
        elseif self.score[2] > self.score[1] then
            self.winner = 2
        else
            self.winner = 0
        end
        return "won", #done
    end
    if #done == 0 then
        self.turn = 3 - p
        return "ok", 0
    end
    return "box", #done
end

-- Take back the last line. Returns the undone history entry, or nil.
function DotsBoard:undo()
    local h = table.remove(self.history)
    if not h then return nil end
    self.drawn[h.e] = 0
    self.moves = self.moves - 1
    for _, b in ipairs(self.topo.edge_boxes[h.e]) do
        self.cnt[b] = self.cnt[b] - 1
        self.owner[b] = 0
    end
    self.score[h.p] = self.score[h.p] - #h.boxes
    self.turn   = h.p
    self.status = "playing"
    self.winner = nil
    return h
end

-- Undrawn edges, in id order.
function DotsBoard:legalMoves()
    local out = {}
    for e = 1, self.topo.E do
        if self.drawn[e] == 0 then out[#out + 1] = e end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

function DotsBoard:serialize()
    local hist = {}
    for i, h in ipairs(self.history) do hist[i] = h.e end
    return { n = self.n, history = hist }
end

-- The game is fully determined by its move list, so loading replays it:
-- scores, owners and the turn come out right by construction, and a corrupt
-- save (an illegal or repeated edge) is rejected instead of half-applied.
function DotsBoard:load(data)
    if type(data) ~= "table" or type(data.n) ~= "number" or type(data.history) ~= "table" then
        return false
    end
    if validSize(data.n) ~= data.n then return false end
    self:reset(data.n)
    for _, e in ipairs(data.history) do
        local res = self:play(e)
        if res == "invalid" or res == "drawn" or res == "over" then
            self:reset(data.n)
            return false
        end
    end
    return true
end

return DotsBoard
