-- ---------------------------------------------------------------------------
-- DotsScreen — full-screen UI for Dots and Boxes
-- ---------------------------------------------------------------------------

local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")
local T               = require("ffi/util").template

local MenuHelper  = require("menu_helper")
local ScreenBase  = require("screen_base")

local DotsBoard       = lrequire("board")
local DotsAI          = lrequire("ai")
local DotsBoardWidget = lrequire("board_widget")

local BLACK, WHITE = 1, 2

local GAME_RULES_EN = _([[
Dots and Boxes — Rules

Two players take turns drawing one line between two neighbouring dots. Black draws first.

• Tap anywhere near a free line to draw it: each box is split into four triangles, one per side.
• Drawing the fourth side of a box claims it (a black square for Black, a framed white one for White), and you must draw another line.
• Turns that take boxes can therefore draw several lines; the lines of the last turn are drawn hollow.
• When every box is claimed, the player with more boxes wins.

Strategy:
• Avoid drawing the third side of a box: your opponent takes it.
• Late in the game every line gives something away. Give away the shortest chain.
• When you take a long chain, you can leave its last two boxes to your opponent (the double-cross): they must then open the next chain for you.
]])

local GAME_RULES_FR = [[
Pipopipette — Règles

Chacun son tour, les joueurs tracent un trait entre deux points voisins. Les Noirs commencent.

• Touchez près d'un trait libre pour le tracer : chaque case est découpée en quatre triangles, un par côté.
• Tracer le quatrième côté d'une case la gagne (carré noir pour les Noirs, carré blanc encadré pour les Blancs), et vous devez rejouer.
• Un tour qui prend des cases peut donc tracer plusieurs traits ; les traits du dernier tour sont dessinés en creux.
• Quand toutes les cases sont prises, celui qui en a le plus gagne.

Stratégie :
• Évitez de tracer le troisième côté d'une case : l'adversaire la prend.
• En fin de partie, chaque trait offre quelque chose. Offrez la chaîne la plus courte.
• Quand vous prenez une longue chaîne, vous pouvez laisser ses deux dernières cases à l'adversaire (le coup double) : il devra alors vous ouvrir la chaîne suivante.
]]

local DotsScreen = ScreenBase:extend{}

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function DotsScreen:init()
    local state = self.plugin:loadState()
    self.board  = DotsBoard:new{ n = self.plugin:getSetting("size", DotsBoard.DEFAULT_SIZE) }
    if not self.board:load(state) then
        self.board:reset(self.plugin:getSetting("size", DotsBoard.DEFAULT_SIZE))
    end
    ScreenBase.init(self)
    if self:_isAITurn() then
        UIManager:scheduleIn(0.1, function() self:triggerAI() end)
    end
end

-- Every box claimed ends the game.
function DotsScreen:isRoundOver()
    return self.board.status ~= "playing"
end

function DotsScreen:serializeState()
    return self.board:serialize()
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

function DotsScreen:buildLayout()
    local is_landscape = self:isLandscape()

    local title_bar = self:buildTitleBar(_("Dots and Boxes"), function()
        local items = {
            { text = _("New game"),          callback = function() self:onNewGame() end },
            { text = self:_sizeLabel(),      callback = function() self:openSizeMenu() end },
            { text = self:_diffLabel(),      callback = function() self:openDifficultyMenu() end },
            { text = self:_playersLabel(),   callback = function() self:openPlayersMenu() end },
        }
        if self.plugin:getSetting("players", 1) == 1 then
            items[#items + 1] = { text = self:_playAsLabel(), callback = function() self:openPlayAsMenu() end }
        end
        items[#items + 1] = self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR)
        return items
    end)

    local controls_w = self:getControlsWidth()
    self.status_text:setMaxWidth(controls_w)
    local controls = VerticalGroup:new{
        align = "center",
        self.status_text,
        VerticalSpan:new{ width = Size.span.vertical_large },
        self:buildActionBar({
            { text = _("Undo"), callback = function() self:onUndo() end },
        }),
    }

    local frame_pad = Size.padding.default
    local budget_w, budget_h = self:getBoardBudget(title_bar, controls)
    self.board_widget = DotsBoardWidget:new{
        board        = self.board,
        size         = math.min(budget_w, budget_h) - 2 * frame_pad,
        onEdgeAction = function(e) self:onEdgeAction(e) end,
    }
    local board_frame = FrameContainer:new{
        padding    = frame_pad,
        margin     = 0,
        bordersize = 0,
        self.board_widget,
    }

    if is_landscape then
        local content = HorizontalGroup:new{
            align = "center",
            board_frame,
            HorizontalSpan:new{ width = self:getGutter() },
            controls,
        }
        self:buildLandscapeLayout(title_bar, content)
    else
        self:buildPortraitLayout(title_bar, board_frame,
            VerticalGroup:new{ align = "center", controls, VerticalSpan:new{ width = self:getGutter() } })
    end
    self:updateStatus()
end

-- ---------------------------------------------------------------------------
-- Turn helpers
-- ---------------------------------------------------------------------------

function DotsScreen:_humanColor()
    return self.plugin:getSetting("player_color", BLACK)
end

function DotsScreen:_isAITurn()
    if self.board.status ~= "playing" then return false end
    if self.plugin:getSetting("players", 1) ~= 1 then return false end
    return self.board.turn ~= self:_humanColor()
end

-- ---------------------------------------------------------------------------
-- Moves
-- ---------------------------------------------------------------------------

function DotsScreen:onEdgeAction(e)
    local board = self.board
    if board.status ~= "playing" or self:_isAITurn() or self.ai_pending then return end

    local result = board:play(e)
    if result == "drawn" or result == "invalid" or result == "over" then return end

    self.board_widget:refresh()
    self.plugin:saveState(self:serializeState())
    self:updateStatus()

    if result == "won" then
        self:onGameEnd()
    elseif self:_isAITurn() then
        self:triggerAI()
    end
end

-- The computer plays its whole turn — every box it takes and the line that
-- ends the turn — before the board is repainted once: on e-ink, a refresh
-- per line would flash the screen for nothing. The hollow lines then show
-- the player everything it drew.
function DotsScreen:triggerAI()
    if not self:_isAITurn() then return end
    self.ai_pending = true
    self:updateStatus(_("AI is thinking..."))
    local level = self.plugin:getSetting("difficulty", "medium")

    UIManager:scheduleIn(0.05, function()
        self.ai_pending = false
        local board = self.board
        local result
        while self:_isAITurn() do
            local e = DotsAI.chooseMove(board, level)
            if not e then break end
            result = board:play(e)
        end
        self.board_widget:refresh()
        self.plugin:saveState(self:serializeState())
        self:updateStatus()
        if result == "won" then self:onGameEnd() end
    end)
end

-- Against the computer, undo goes back to before the player's last line,
-- taking the computer's reply with it; in a two-player game it takes back
-- one line.
function DotsScreen:onUndo()
    local board = self.board
    if board.status ~= "playing" or self.ai_pending then return end
    if #board.history == 0 then return end
    if self.plugin:getSetting("players", 1) == 1 then
        local human = self:_humanColor()
        -- Nothing of the player's to take back (the computer opened).
        local found = false
        for _, h in ipairs(board.history) do
            if h.p == human then found = true; break end
        end
        if not found then return end
        while #board.history > 0 do
            local h = board:undo()
            if h.p == human then break end
        end
    else
        board:undo()
    end
    self.board_widget:refresh()
    self.plugin:saveState(self:serializeState())
    self:updateStatus()
end

-- ---------------------------------------------------------------------------
-- New game / end
-- ---------------------------------------------------------------------------

function DotsScreen:onNewGame()
    self.ai_pending = false
    self.board = DotsBoard:new{ n = self.plugin:getSetting("size", DotsBoard.DEFAULT_SIZE) }
    self.plugin:saveState(self.board:serialize())
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    if self:_isAITurn() then
        UIManager:scheduleIn(0.1, function() self:triggerAI() end)
    end
end

function DotsScreen:_resultText()
    local w = self.board.winner
    if w == BLACK then return _("Black wins!") end
    if w == WHITE then return _("White wins!") end
    return _("Draw!")
end

function DotsScreen:onGameEnd()
    self:showMessage(self:joinStatus(self:_resultText(), self:_scoreText()), 4)
end

-- ---------------------------------------------------------------------------
-- Status bar
-- ---------------------------------------------------------------------------

function DotsScreen:_scoreText()
    local s = self.board.score
    return T(_("Black %1 – White %2"), s[1], s[2])
end

function DotsScreen:_colorName(p)
    return p == BLACK and _("Black") or _("White")
end

function DotsScreen:updateStatus(msg)
    local board = self.board
    local status
    if msg then
        status = self:joinStatus(self:_scoreText(), msg)
    elseif board.status ~= "playing" then
        status = self:joinStatus(self:_resultText(), self:_scoreText())
    else
        local dlabel
        if self.plugin:getSetting("players", 1) == 1 then
            local diff = self.plugin:getSetting("difficulty", "medium")
            dlabel = MenuHelper.DIFFICULTY_LABELS[diff] or diff
        end
        status = self:joinStatus(
            T("%1×%1", board.n),
            dlabel,
            self:_scoreText(),
            T(_("%1 to move"), self:_colorName(board.turn)))
    end
    ScreenBase.updateStatus(self, status)
    -- Every line (player's or computer's), undo and new game ends here.
    self:refreshActionBar()
end

-- ---------------------------------------------------------------------------
-- Menu labels
-- ---------------------------------------------------------------------------

function DotsScreen:_sizeLabel()
    local n = self.plugin:getSetting("size", DotsBoard.DEFAULT_SIZE)
    return T(_("Size: %1"), T("%1×%1", n))
end

function DotsScreen:_diffLabel()
    local diff = self.plugin:getSetting("difficulty", "medium")
    return T(_("Difficulty: %1"), MenuHelper.DIFFICULTY_LABELS[diff] or diff)
end

function DotsScreen:_playersLabel()
    return T(_("Players: %1"), self.plugin:getSetting("players", 1))
end

function DotsScreen:_playAsLabel()
    return T(_("Play as: %1"), self:_colorName(self:_humanColor()))
end

-- ---------------------------------------------------------------------------
-- Menus
-- ---------------------------------------------------------------------------

function DotsScreen:openSizeMenu()
    local items = {}
    for _, s in ipairs(DotsBoard.SIZES) do
        items[#items + 1] = { id = s.id, text = s.label }
    end
    MenuHelper.openSizeMenu{
        title     = _("Size"),
        sizes     = items,
        current   = self.plugin:getSetting("size", DotsBoard.DEFAULT_SIZE),
        on_select = function(id)
            self.plugin:saveSetting("size", id)
            self:onNewGame()
        end,
        parent = self,
    }
end

function DotsScreen:openDifficultyMenu()
    MenuHelper.openDifficultyMenu{
        current   = self.plugin:getSetting("difficulty", "medium"),
        on_select = function(id)
            self.plugin:saveSetting("difficulty", id)
            self:updateStatus()
        end,
        parent = self,
    }
end

function DotsScreen:openPlayersMenu()
    MenuHelper.openPickerMenu{
        title      = _("Players"),
        items      = {
            { id = 1, text = _("1 player (vs AI)") },
            { id = 2, text = _("2 players") },
        },
        current_id = self.plugin:getSetting("players", 1),
        on_select  = function(id)
            self.plugin:saveSetting("players", id)
            self:onNewGame()
        end,
        parent = self,
    }
end

function DotsScreen:openPlayAsMenu()
    MenuHelper.openPickerMenu{
        title      = _("Play as"),
        items      = {
            { id = BLACK, text = _("Black") },
            { id = WHITE, text = _("White") },
        },
        current_id = self:_humanColor(),
        on_select  = function(id)
            self.plugin:saveSetting("player_color", id)
            self:onNewGame()
        end,
        parent = self,
    }
end

return DotsScreen
