local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = DIR .. "?.lua;" .. package.path

describe("DotsAI", function()
    local Board, AI

    setup(function()
        Board = require("board")
        AI    = require("ai")
    end)

    local function isSafe(b, e)
        if b.drawn[e] ~= 0 then return false end
        for _, x in ipairs(b.topo.edge_boxes[e]) do
            if b.cnt[x] >= 2 then return false end
        end
        return true
    end

    local function anySafe(b)
        for e = 1, b:edgeCount() do
            if isSafe(b, e) then return true end
        end
        return false
    end

    local function anyCapturable(b)
        for x = 1, b.topo.B do
            if b.cnt[x] == 3 then return true end
        end
        return false
    end

    -- Plays random safe lines until none is left: the start of the endgame.
    local function randomLoonyPosition(n)
        local b = Board:new{ n = n }
        while true do
            local safe = {}
            for e = 1, b:edgeCount() do
                if isSafe(b, e) then safe[#safe + 1] = e end
            end
            if #safe == 0 then return b end
            b:play(safe[math.random(#safe)])
        end
    end

    -- Unrestricted exact negamax (every line, every time): the reference
    -- the pruned search is checked against.
    local function bruteValue(b, memo)
        if b.status ~= "playing" then return 0 end
        local key = {}
        for e = 1, b:edgeCount() do key[e] = b.drawn[e] ~= 0 and "1" or "0" end
        key = table.concat(key)
        if memo[key] then return memo[key] end
        local best = -math.huge
        for _, e in ipairs(b:legalMoves()) do
            local p = b.turn
            b:play(e)
            local h = b.history[#b.history]
            local v
            if b.status ~= "playing" then
                v = #h.boxes
            elseif b.turn == p then
                v = #h.boxes + bruteValue(b, memo)
            else
                v = -bruteValue(b, memo)
            end
            b:undo()
            if v > best then best = v end
        end
        memo[key] = best
        return best
    end

    it("always returns an undrawn line, at every level and size", function()
        math.randomseed(11)
        for n = 3, 6 do
            for _, level in ipairs({ "easy", "medium", "hard" }) do
                local b = Board:new{ n = n }
                while b.status == "playing" do
                    local e = AI.chooseMove(b, level)
                    assert.is_number(e)
                    assert.are.equal(0, b.drawn[e])
                    b:play(e)
                end
                assert.are.equal(n * n, b.score[1] + b.score[2])
            end
        end
    end)

    it("returns nil once the game is over", function()
        local b = Board:new{ n = 3 }
        for e = 1, b:edgeCount() do b:play(e) end
        assert.is_nil(AI.chooseMove(b, "hard"))
    end)

    it("takes a box on offer at every level", function()
        for _, level in ipairs({ "easy", "medium", "hard" }) do
            local b = Board:new{ n = 4 }
            -- three sides of box (2,2), with no other box near three sides
            b:play(b:hEdge(2, 2)); b:play(b:hEdge(3, 2)); b:play(b:vEdge(2, 2))
            assert.are.equal(b:vEdge(2, 3), AI.chooseMove(b, level))
        end
    end)

    it("medium and hard never give a third side while a safe line remains", function()
        math.randomseed(5)
        for _, level in ipairs({ "medium", "hard" }) do
            for _ = 1, 10 do
                local b = Board:new{ n = 5 }
                while b.status == "playing" do
                    local safe_left = anySafe(b) and not anyCapturable(b)
                    local e = AI.chooseMove(b, level)
                    if safe_left then assert.is_true(isSafe(b, e)) end
                    b:play(e)
                end
            end
        end
    end)

    it("solves endgames exactly (checked against an unrestricted search)", function()
        math.randomseed(2026)
        local checked = 0
        for _ = 1, 150 do
            local b = randomLoonyPosition(3)
            if #b:legalMoves() <= 14 and b.status == "playing" then
                local exact = bruteValue(b, {})
                assert.are.equal(exact, AI.solve(b))
                -- and the move hard picks achieves that value
                local e = AI.chooseMove(b, "hard")
                local p = b.turn
                b:play(e)
                local h = b.history[#b.history]
                local v
                if b.status ~= "playing" then
                    v = #h.boxes
                elseif b.turn == p then
                    v = #h.boxes + bruteValue(b, {})
                else
                    v = -bruteValue(b, {})
                end
                assert.are.equal(exact, v)
                checked = checked + 1
            end
        end
        assert.is_true(checked >= 30)
    end)

    it("realises the solved value when it plays both sides of an endgame", function()
        -- Medium opens something from a random 4×4 endgame; from there hard
        -- plays both sides and must end exactly on the value it computed.
        math.randomseed(3)
        local wins = 0
        for _ = 1, 30 do
            local b = randomLoonyPosition(4)
            -- medium opens something, hard answers; hard must never score
            -- worse than the exact value of the position it was handed
            if b.status == "playing" then
                local e = AI.chooseMove(b, "medium")
                b:play(e)
                if b.status == "playing" then
                    local v = AI.solve(b)
                    if v then
                        local p = b.turn
                        local start = b.score[p] - b.score[3 - p]
                        while b.status == "playing" do b:play(AI.chooseMove(b, "hard")) end
                        local final = b.score[p] - b.score[3 - p]
                        assert.are.equal(v, final - start)
                        wins = wins + 1
                    end
                end
            end
        end
        assert.is_true(wins > 0)
    end)
end)
