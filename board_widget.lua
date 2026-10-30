local Blitbuffer     = require("ffi/blitbuffer")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager      = require("ui/uimanager")

local C_BG        = Blitbuffer.COLOR_WHITE
local C_DOT       = Blitbuffer.COLOR_BLACK
local C_LINE      = Blitbuffer.COLOR_BLACK
local C_FREE      = Blitbuffer.COLOR_GRAY_D   -- where a line can still go
local C_BOX_BLACK = Blitbuffer.COLOR_BLACK
local C_BOX_WHITE = Blitbuffer.COLOR_WHITE
local C_BOX_EDGE  = Blitbuffer.COLOR_BLACK

-- ---------------------------------------------------------------------------
-- DotsBoardWidget — dots, lines and claimed boxes.
--
-- Lines live between the dots rather than in cells, so like go's widget this
-- one draws its own grid instead of using GridWidgetBase's filled cells.
--
-- Tapping: every point of the board belongs to the line it is closest to.
-- A box is cut by its diagonals into four triangles, one per side, so the
-- whole box is a hit zone for its four sides — far larger than the line
-- itself, which a finger on e-ink would rarely hit. Only the corner of a dot,
-- where a horizontal and a vertical line are equally close, is ignored:
-- guessing there would draw a line the player did not mean.
--
-- The lines of the last turn (all of them: a turn that takes boxes draws
-- several) are drawn hollow, so after the computer's turn the player sees
-- exactly what changed.
-- ---------------------------------------------------------------------------

local DotsBoardWidget = InputContainer:extend{
    board        = nil,
    onEdgeAction = nil,   -- callback(edge)
    size         = 300,
}

function DotsBoardWidget:init()
    local n = self.board.n
    self.n = n
    -- A margin of about a third of a box around the dots keeps edge lines
    -- tappable from outside the board too.
    self.cell   = math.floor(self.size / (n + 0.7))
    self.margin = math.floor((self.size - n * self.cell) / 2)
    self.line_w = math.max(3, math.floor(self.cell * 0.08))
    self.dot_r  = math.max(3, math.floor(self.cell * 0.075))

    self.dimen = Geom:new{ w = self.size, h = self.size }
    self.paint_rect = Geom:new{ x = 0, y = 0, w = self.size, h = self.size }

    self.ges_events = {
        Tap = {
            GestureRange:new{
                ges   = "tap",
                range = function() return self.paint_rect end,
            },
        },
    }
end

-- Pixel position of dot (i, j), 1-indexed, relative to the widget.
function DotsBoardWidget:_dotXY(i, j)
    return self.margin + (j - 1) * self.cell, self.margin + (i - 1) * self.cell
end

-- Maps a point (widget-local pixels) to an edge id, or nil.
function DotsBoardWidget:edgeAt(lx, ly)
    local n, cell = self.n, self.cell
    local u = (lx - self.margin) / cell     -- column, in boxes
    local v = (ly - self.margin) / cell     -- row, in boxes
    local slack = 0.45                      -- reach beyond the outer dots
    if u < -slack or v < -slack or u > n + slack or v > n + slack then return nil end

    -- Nearest horizontal line: row of dots round(v), between columns floor(u).
    local hr = math.floor(v + 0.5)
    local hc = math.floor(u)
    local dh = math.abs(v - hr)
    -- Nearest vertical line: column of dots round(u), between rows floor(v).
    local vc = math.floor(u + 0.5)
    local vr = math.floor(v)
    local dv = math.abs(u - vc)

    local h_ok = hr >= 0 and hr <= n and hc >= 0 and hc < n
    local v_ok = vc >= 0 and vc <= n and vr >= 0 and vr < n
    if h_ok and v_ok and math.abs(dh - dv) < 0.06 and dh < 0.3 then
        return nil   -- right on a dot's diagonal: ambiguous
    end
    if h_ok and (not v_ok or dh <= dv) then
        return self.board:hEdge(hr + 1, hc + 1)
    elseif v_ok then
        return self.board:vEdge(vr + 1, vc + 1)
    end
    return nil
end

function DotsBoardWidget:onTap(_, ges)
    if not (ges and ges.pos) then return false end
    local rect = self.paint_rect
    local e = self:edgeAt(ges.pos.x - rect.x, ges.pos.y - rect.y)
    if e and self.onEdgeAction then self.onEdgeAction(e) end
    return true
end

function DotsBoardWidget:refresh()
    local rect = self.paint_rect
    UIManager:setDirty(self, function()
        return "ui", Geom:new{ x = rect.x, y = rect.y, w = rect.w, h = rect.h }
    end)
end

-- Edges drawn during the most recent turn: the trailing run of history
-- entries made by the same player.
function DotsBoardWidget:_lastTurnEdges()
    local hist, set = self.board.history, {}
    local last = hist[#hist]
    if not last then return set end
    for i = #hist, 1, -1 do
        if hist[i].p ~= last.p then break end
        set[hist[i].e] = true
    end
    return set
end

function DotsBoardWidget:_paintEdge(bb, x, y, e, style)
    local board = self.board
    local kind, r, c = board:edgeInfo(e)
    local x1, y1 = self:_dotXY(r, c)
    local w, h
    if kind == "h" then
        w, h = self.cell, 0
    else
        w, h = 0, self.cell
    end
    if style == "free" then
        -- A thin grey guide, centred on where the line would go.
        local t = math.max(1, math.floor(self.line_w / 3))
        bb:paintRect(x + x1 - (h > 0 and math.floor(t / 2) or 0),
                     y + y1 - (w > 0 and math.floor(t / 2) or 0),
                     w > 0 and w or t, h > 0 and h or t, C_FREE)
        return
    end
    local t = self.line_w
    local half = math.floor(t / 2)
    if style == "recent" then t = math.floor(t * 1.6); half = math.floor(t / 2) end
    bb:paintRect(x + x1 - half, y + y1 - half, (w > 0 and w or 0) + t, (h > 0 and h or 0) + t, C_LINE)
    if style == "recent" then
        -- Hollow: a white core between the dots marks the last turn.
        local core = math.max(1, math.floor(t * 0.4))
        local inset = self.dot_r + 2
        if w > 0 then
            bb:paintRect(x + x1 + inset, y + y1 - math.floor(core / 2), w - 2 * inset, core, C_BG)
        else
            bb:paintRect(x + x1 - math.floor(core / 2), y + y1 + inset, core, h - 2 * inset, C_BG)
        end
    end
end

function DotsBoardWidget:paintTo(bb, x, y)
    self.paint_rect = Geom:new{ x = x, y = y, w = self.size, h = self.size }
    bb:paintRect(x, y, self.size, self.size, C_BG)

    local board = self.board
    local n, cell = self.n, self.cell

    -- Claimed boxes: a black square for Black, a white one with a thick
    -- black frame for White, inset so the lines around stay readable.
    local inset = math.floor(cell * 0.22)
    local side  = cell - 2 * inset
    local frame = math.max(2, math.floor(cell * 0.07))
    for r = 1, n do
        for c = 1, n do
            local o = board.owner[(r - 1) * n + c]
            if o ~= 0 then
                local bx, by = self:_dotXY(r, c)
                bx, by = x + bx + inset, y + by + inset
                if o == 1 then
                    bb:paintRect(bx, by, side, side, C_BOX_BLACK)
                else
                    bb:paintRect(bx, by, side, side, C_BOX_EDGE)
                    bb:paintRect(bx + frame, by + frame, side - 2 * frame, side - 2 * frame, C_BOX_WHITE)
                end
            end
        end
    end

    -- Lines: free guides first, then drawn lines over them.
    local recent = self:_lastTurnEdges()
    for e = 1, board:edgeCount() do
        if board.drawn[e] == 0 then self:_paintEdge(bb, x, y, e, "free") end
    end
    for e = 1, board:edgeCount() do
        if board.drawn[e] ~= 0 then
            self:_paintEdge(bb, x, y, e, recent[e] and "recent" or "drawn")
        end
    end

    -- Dots on top.
    for i = 1, n + 1 do
        for j = 1, n + 1 do
            local dx, dy = self:_dotXY(i, j)
            bb:paintCircle(x + dx, y + dy, self.dot_r, C_DOT)
        end
    end
end

return DotsBoardWidget
