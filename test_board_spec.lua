local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = DIR .. "?.lua;" .. package.path

describe("DotsBoard", function()
    local Board

    setup(function()
        Board = require("board")
    end)

    -- The four sides of box (r, c): top, bottom, left, right.
    local function sides(b, r, c)
        return { b:hEdge(r, c), b:hEdge(r + 1, c), b:vEdge(r, c), b:vEdge(r, c + 1) }
    end

    describe("new / reset", function()
        it("defaults to 4×4 boxes with every line undrawn", function()
            local b = Board:new()
            assert.are.equal(4, b.n)
            assert.are.equal(40, b:edgeCount())      -- 2·4·5
            assert.are.equal(1, b.turn)
            assert.are.equal("playing", b.status)
            for e = 1, b:edgeCount() do assert.is_false(b:isDrawn(e)) end
        end)

        it("supports 3×3 to 6×6 and falls back to the default otherwise", function()
            for n = 3, 6 do
                assert.are.equal(2 * n * (n + 1), Board:new{ n = n }:edgeCount())
            end
            assert.are.equal(4, Board:new{ n = 9 }.n)
        end)

        it("numbers edges so every box has four distinct sides", function()
            local b = Board:new{ n = 5 }
            local seen = {}
            for e = 1, b:edgeCount() do
                local kind, r, c = b:edgeInfo(e)
                local id = kind == "h" and b:hEdge(r, c) or b:vEdge(r, c)
                assert.are.equal(e, id)
                seen[e] = true
            end
            for bx = 1, 25 do
                local es = b.topo.box_edges[bx]
                local set = {}
                for _, e in ipairs(es) do set[e] = true end
                local k = 0
                for _ in pairs(set) do k = k + 1 end
                assert.are.equal(4, k)
            end
        end)
    end)

    describe("play", function()
        it("passes the turn when no box is completed", function()
            local b = Board:new{ n = 3 }
            assert.are.equal("ok", b:play(b:hEdge(1, 1)))
            assert.are.equal(2, b.turn)
            assert.is_true(b:isDrawn(b:hEdge(1, 1)))
        end)

        it("refuses a line already drawn and an unknown edge", function()
            local b = Board:new{ n = 3 }
            b:play(1)
            assert.are.equal("drawn", b:play(1))
            assert.are.equal("invalid", b:play(0))
            assert.are.equal("invalid", b:play(999))
            assert.are.equal(2, b.turn)
        end)

        it("scores a completed box and lets the same player move again", function()
            local b = Board:new{ n = 3 }
            local s = sides(b, 2, 2)
            b:play(s[1]); b:play(s[2]); b:play(s[3])  -- players 1, 2, 1
            assert.are.equal(2, b.turn)
            local res, k = b:play(s[4])
            assert.are.equal("box", res)
            assert.are.equal(1, k)
            assert.are.equal(2, b.turn)               -- still player 2
            assert.are.equal(1, b.score[2])
            assert.are.equal(2, b.owner[5])
        end)

        it("completes two boxes with one shared line", function()
            local b = Board:new{ n = 3 }
            local l, r = sides(b, 1, 1), sides(b, 1, 2)
            -- every side of both boxes except the shared one (l[4] == r[3])
            for _, e in ipairs({ l[1], l[2], l[3], r[1], r[2], r[4] }) do b:play(e) end
            local p = b.turn
            local res, k = b:play(l[4])
            assert.are.equal("box", res)
            assert.are.equal(2, k)
            assert.are.equal(2, b.score[p])
        end)

        it("ends the game with the last box and names the winner", function()
            local b = Board:new{ n = 3 }
            local res
            for e = 1, b:edgeCount() do res = b:play(e) end
            assert.are.equal("won", res)
            assert.are.equal("ended", b.status)
            assert.are.equal(9, b.score[1] + b.score[2])
            assert.are.equal(b.score[1] > b.score[2] and 1 or 2, b.winner)
            assert.are.equal("over", b:play(1))
        end)

        it("reports a draw on an even board split evenly", function()
            local d = Board:new{ n = 4 }
            for e = 1, d:edgeCount() - 1 do d:play(e) end
            d.score = { 7, 8 }
            d.turn = 1
            d:play(d:edgeCount())   -- completes the last box for player 1
            assert.are.equal(0, d.winner)
        end)
    end)

    describe("undo", function()
        it("restores lines, owners, scores and the turn", function()
            local b = Board:new{ n = 3 }
            local s = sides(b, 1, 1)
            b:play(s[1]); b:play(s[2]); b:play(s[3])
            local p = b.turn
            b:play(s[4])
            assert.are.equal(1, b.score[p])
            local h = b:undo()
            assert.are.equal(s[4], h.e)
            assert.are.equal(0, b.score[p])
            assert.are.equal(0, b.owner[1])
            assert.are.equal(3, b.cnt[1])
            assert.are.equal(p, b.turn)
            assert.is_false(b:isDrawn(s[4]))
        end)

        it("reopens a finished game", function()
            local b = Board:new{ n = 3 }
            for e = 1, b:edgeCount() do b:play(e) end
            b:undo()
            assert.are.equal("playing", b.status)
            assert.is_nil(b.winner)
        end)

        it("returns nil with no history", function()
            assert.is_nil(Board:new():undo())
        end)
    end)

    describe("serialize / load", function()
        it("round-trips a game in progress", function()
            math.randomseed(7)
            local b = Board:new{ n = 5 }
            for _ = 1, 30 do
                local moves = b:legalMoves()
                b:play(moves[math.random(#moves)])
            end
            local c = Board:new()
            assert.is_true(c:load(b:serialize()))
            assert.are.equal(5, c.n)
            assert.are.same(b.drawn, c.drawn)
            assert.are.same(b.owner, c.owner)
            assert.are.same(b.score, c.score)
            assert.are.equal(b.turn, c.turn)
            assert.are.equal(b:lastEdge(), c:lastEdge())
        end)

        it("rejects garbage and an illegal move list", function()
            local b = Board:new()
            assert.is_false(b:load(nil))
            assert.is_false(b:load({ n = 4 }))
            assert.is_false(b:load({ n = 7, history = {} }))
            assert.is_false(b:load({ n = 3, history = { 1, 1 } }))
            assert.are.equal(0, b.moves)
        end)
    end)
end)
