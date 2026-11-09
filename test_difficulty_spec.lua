-- Difficulty guarantees of the Dots and Boxes computer opponent: every level
-- draws legal lines and takes a box on offer; Easy gives third sides away
-- where Medium and Hard never do; Hard plays endgames exactly where Medium
-- does not; the same rng gives the same game; and Hard stays within its
-- think time at Kobo speed.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = DIR .. "?.lua;" .. package.path

describe("Dots and Boxes difficulty", function()
    local Board, AI

    setup(function()
        Board = require("board")
        AI    = require("ai")
    end)

    local IDS = { "easy", "medium", "hard" }

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

    -- Unrestricted exact negamax: the boxes the side to move can still win
    -- over its opponent, the reference both levels are measured against.
    local function bruteValue(b, memo)
        if b.status ~= "playing" then return 0 end
        local key = {}
        for e = 1, b:edgeCount() do key[e] = b.drawn[e] ~= 0 and "1" or "0" end
        key = table.concat(key)
        if memo[key] then return memo[key] end
        local best = -math.huge
        for _, e in ipairs(b:legalMoves()) do
            local v = (function()
                local p = b.turn
                b:play(e)
                local h = b.history[#b.history]
                local r
                if b.status ~= "playing" then r = #h.boxes
                elseif b.turn == p then r = #h.boxes + bruteValue(b, memo)
                else r = -bruteValue(b, memo) end
                b:undo()
                return r
            end)()
            if v > best then best = v end
        end
        memo[key] = best
        return best
    end

    -- Exact value of drawing line e (for the side to move).
    local function moveValue(b, e, memo)
        local p = b.turn
        b:play(e)
        local h = b.history[#b.history]
        local v
        if b.status ~= "playing" then v = #h.boxes
        elseif b.turn == p then v = #h.boxes + bruteValue(b, memo)
        else v = -bruteValue(b, memo) end
        b:undo()
        return v
    end

    -- Deterministic rng(n) -> 1..n.
    local function lcg(seed)
        local x = seed
        return function(n)
            x = (x * 1103515245 + 12345) % 2147483648
            return x % n + 1
        end
    end

    it("always returns an undrawn line, at every level and size", function()
        math.randomseed(11)
        for n = 3, 6 do
            for _, level in ipairs(IDS) do
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

    it("takes a box on offer at every level", function()
        for _, level in ipairs(IDS) do
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

    it("Easy does give third sides away while safe lines remain", function()
        -- Count Easy's free gifts over the opening of seeded games: the
        -- difference from Medium that makes it the easy level.
        local gifts, chances = 0, 0
        for seed = 1, 6 do
            local rng = lcg(seed)
            local b = Board:new{ n = 4 }
            while b.status == "playing" and anySafe(b) do
                if not anyCapturable(b) then
                    local e = AI.chooseMove(b, "easy", rng)
                    chances = chances + 1
                    if not isSafe(b, e) then gifts = gifts + 1 end
                    b:play(e)
                else
                    b:play(AI.chooseMove(b, "medium", rng))
                end
            end
        end
        assert.is_true(chances >= 20)
        assert.is_true(gifts >= 3, "Easy gave " .. gifts .. " of " .. chances)
    end)

    it("Hard plays 3x3 endgames exactly, and beats Medium's choice on some", function()
        math.randomseed(2027)
        local checked, medium_worse = 0, 0
        for _ = 1, 60 do
            local b = randomLoonyPosition(3)
            if b.status == "playing" and #b:legalMoves() <= 12 then
                local memo = {}
                local exact = bruteValue(b, memo)
                local hv = moveValue(b, AI.chooseMove(b, "hard", lcg(1)), memo)
                local mv = moveValue(b, AI.chooseMove(b, "medium", lcg(1)), memo)
                assert.are.equal(exact, hv)
                assert.is_true(mv <= exact)
                if mv < exact then medium_worse = medium_worse + 1 end
                checked = checked + 1
            end
        end
        assert.is_true(checked >= 20, "only " .. checked .. " endgames")
        assert.is_true(medium_worse >= 1, "Medium was exact on all " .. checked)
    end)

    it("plays the same game under the same rng, at every level", function()
        local function game(level, seed)
            AI.clearCache()
            local rng = lcg(seed)
            local b = Board:new{ n = 4 }
            local seq = {}
            while b.status == "playing" do
                local e = AI.chooseMove(b, level, rng)
                seq[#seq + 1] = e
                b:play(e)
            end
            return table.concat(seq, ",")
        end
        for _, level in ipairs(IDS) do
            assert.are.equal(game(level, 7), game(level, 7))
        end
        assert.are_not.equal(game("easy", 1), game("easy", 2))
    end)

    it("keeps a 6x6 hard move under the Kobo budget (simulated)", function()
        local saved = AI.time_scale
        AI.time_scale = 0.04           -- a Kobo is ~25x slower
        local worst = 0
        for g = 1, 4 do
            math.randomseed(g)
            AI.clearCache()
            local b = Board:new{ n = 6 }
            while b.status == "playing" do
                local t0 = os.clock()
                local e = AI.chooseMove(b, "hard")
                worst = math.max(worst, os.clock() - t0)
                b:play(e)
            end
        end
        AI.time_scale = saved
        -- 2.5 s x 0.04 = 100 ms; generous margin for a loaded machine.
        assert.is_true(worst < 0.3)
    end)
end)
