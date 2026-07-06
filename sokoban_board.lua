local Blitbuffer = require("ffi/blitbuffer")
local Device    = require("device")
local Geom      = require("ui/geometry")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local Screen    = Device.screen
local UIManager = require("ui/uimanager")

local Game = require("sokoban_game")

local ICON_DIR -- set by init from plugin_path passed by main.lua

local CELL_LAYERS = {
    [Game.WALL]   = { "wall" },
    [Game.FLOOR]  = { "floor" },
    [Game.TARGET] = { "floor", "target" },
    [Game.BOX]    = { "floor", "crate" },
    [Game.BOX_ON] = { "floor", "crate_on_target", "target" },
    [Game.PLAYER] = { "floor", "player" },
    [Game.PLR_ON] = { "floor", "player", "target" },
}

local Board = InputContainer:extend{
    game          = nil,
    width         = nil,
    height        = nil,
    icon_dir      = nil,
    on_swipe_cb   = nil, -- called with (dr, dc) before move, for main.lua to react
    on_tap_cb     = nil, -- called with (r, c) grid coords on tap, for main.lua to react
    on_open_cb    = nil, -- called on Ctrl+O, for main.lua to react
    on_restart_cb = nil, -- called on Ctrl+R, for main.lua to react
    on_undo_cb    = nil, -- called on Ctrl+Z, for main.lua to react
    player_sprite = "player",
    selected_box  = nil, -- {r, c} of a box selected for pushing, or nil
    path_preview  = nil, -- list of {r, c} cells to draw as a path preview line, or nil
}

function Board:init()
    ICON_DIR = self.icon_dir

    -- compute cell size so the whole grid fits
    self.cell_size = math.min(
        math.floor(self.width  / self.game.cols),
        math.floor(self.height / self.game.rows)
    )

    -- offset to center grid in available space
    self.offset_x = math.floor((self.width  - self.cell_size * self.game.cols) / 2)
    self.offset_y = math.floor((self.height - self.cell_size * self.game.rows) / 2)

    self.dimen = Geom:new{ w = self.width, h = self.height }

    -- image cache: cell_size × cell_size renders, keyed by icon name
    self._img_cache = {}

    self:registerTouchZones({
        {
            id = "sokoban_swipe",
            ges = "swipe",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler = function(ges) return self:onSwipe(ges) end,
        },
        {
            id = "sokoban_tap",
            ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler = function(ges) return self:onTap(ges) end,
        },
    })

    self.key_events.MoveUp    = { { "Up" } }
    self.key_events.MoveDown  = { { "Down" } }
    self.key_events.MoveLeft  = { { "Left" } }
    self.key_events.MoveRight = { { "Right" } }

    if Device:hasKeyboard() then
        self.key_events.OpenLevel = { { "Ctrl", "O" } }
        self.key_events.Restart   = { { "Ctrl", "R" } }
        self.key_events.Undo      = { { "Ctrl", "Z" } }
    end
end

function Board:_getImage(icon_name)
    if not self._img_cache[icon_name] then
        local img = ImageWidget:new{
            file         = ICON_DIR .. "/" .. icon_name .. ".svg",
            width        = self.cell_size,
            height       = self.cell_size,
            scale_factor = 0,
            alpha        = true,
        }
        self._img_cache[icon_name] = img
    end
    return self._img_cache[icon_name]
end

function Board:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y

    local cs = self.cell_size
    local ox = x + self.offset_x
    local oy = y + self.offset_y

    for r = 1, self.game.rows do
        for c = 1, self.game.cols do
            local cell = self.game.grid[r][c]
            local layers
            if cell == Game.WALL then
                local below = self.game.grid[r + 1] and self.game.grid[r + 1][c]
                layers = { below == Game.WALL and "wall" or "wall_h" }
            else
                layers = CELL_LAYERS[cell] or { "floor" }
            end
            local px = ox + (c - 1) * cs
            local py = oy + (r - 1) * cs
            for _, icon_name in ipairs(layers) do
                local sprite = (icon_name == "player") and self.player_sprite or icon_name
                self:_getImage(sprite):paintTo(bb, px, py)
            end
            if self.selected_box and self.selected_box[1] == r and self.selected_box[2] == c then
                bb:paintBorder(px, py, cs, cs, Screen:scaleBySize(3), Blitbuffer.COLOR_BLACK)
            end
        end
    end

    if self.path_preview and #self.path_preview > 1 then
        local thickness = Screen:scaleBySize(6)
        local half = math.floor(thickness / 2)
        for i = 1, #self.path_preview - 1 do
            local r1, c1 = self.path_preview[i][1], self.path_preview[i][2]
            local r2, c2 = self.path_preview[i + 1][1], self.path_preview[i + 1][2]
            local cx1 = math.floor(ox + (c1 - 1) * cs + cs / 2)
            local cy1 = math.floor(oy + (r1 - 1) * cs + cs / 2)
            local cx2 = math.floor(ox + (c2 - 1) * cs + cs / 2)
            local cy2 = math.floor(oy + (r2 - 1) * cs + cs / 2)
            if r1 == r2 then
                bb:paintRect(math.min(cx1, cx2), cy1 - half, math.abs(cx2 - cx1), thickness, Blitbuffer.COLOR_BLACK)
            else
                bb:paintRect(cx1 - half, math.min(cy1, cy2), thickness, math.abs(cy2 - cy1), Blitbuffer.COLOR_BLACK)
            end
        end
    end
end

function Board:getSize()
    return self.dimen
end

function Board:_move(dr, dc, sprite)
    self.player_sprite = sprite
    if self.on_swipe_cb then
        self.on_swipe_cb(dr, dc)
    end
    return true
end

function Board:onSwipe(ges)
    local dir = ges.direction
    if     dir == "east"  then return self:_move( 0,  1, "player_right")
    elseif dir == "west"  then return self:_move( 0, -1, "player_left")
    elseif dir == "south" then return self:_move( 1,  0, "player")
    elseif dir == "north" then return self:_move(-1,  0, "player_up")
    end
    return false
end

function Board:onMoveUp()    return self:_move(-1,  0, "player_up") end
function Board:onMoveDown()  return self:_move( 1,  0, "player") end
function Board:onMoveLeft()  return self:_move( 0, -1, "player_left") end
function Board:onMoveRight() return self:_move( 0,  1, "player_right") end

function Board:onOpenLevel()
    if self.on_open_cb then self.on_open_cb() end
    return true
end

function Board:onRestart()
    if self.on_restart_cb then self.on_restart_cb() end
    return true
end

function Board:onUndo()
    if self.on_undo_cb then self.on_undo_cb() end
    return true
end

function Board:onTap(ges)
    local x = ges.pos.x - self.dimen.x - self.offset_x
    local y = ges.pos.y - self.dimen.y - self.offset_y
    local c = math.floor(x / self.cell_size) + 1
    local r = math.floor(y / self.cell_size) + 1
    if r < 1 or r > self.game.rows or c < 1 or c > self.game.cols then return false end

    if self.on_tap_cb then
        self.on_tap_cb(r, c)
    end
    return true
end

function Board:freeImages()
    for _, img in pairs(self._img_cache) do
        img:free()
    end
    self._img_cache = {}
end

return Board
