-- Pure game logic, no KOReader dependencies.
-- Test with: luajit game.lua

local WALL   = 0
local FLOOR  = 1
local TARGET = 2
local BOX    = 3
local BOX_ON = 4
local PLAYER = 5
local PLR_ON = 6

local Game = {}
Game.__index = Game

-- Export constants so board.lua can use them
Game.WALL   = WALL
Game.FLOOR  = FLOOR
Game.TARGET = TARGET
Game.BOX    = BOX
Game.BOX_ON = BOX_ON
Game.PLAYER = PLAYER
Game.PLR_ON = PLR_ON

local XSB_MAP = {
    ["#"] = WALL,
    [" "] = FLOOR,
    ["."] = TARGET,
    ["@"] = PLAYER,
    ["+"] = PLR_ON,
    ["$"] = BOX,
    ["*"] = BOX_ON,
    ["-"] = FLOOR,  -- some sets use - for floor
    ["_"] = FLOOR,
}

function Game.from_xsb(xsb)
    local self = setmetatable({}, Game)
    self.grid = {}
    self.rows = 0
    self.cols = 0
    self.player_r = 1
    self.player_c = 1
    self.moves = 0
    self.pushes = 0
    self.history = {}

    local lines = {}
    for line in (xsb .. "\n"):gmatch("([^\n]*)\n") do
        -- skip comment lines (XSB uses ';')
        if line:sub(1,1) ~= ";" then
            table.insert(lines, line)
        end
    end
    -- strip leading/trailing blank lines
    while #lines > 0 and lines[1]:match("^%s*$") do table.remove(lines, 1) end
    while #lines > 0 and lines[#lines]:match("^%s*$") do table.remove(lines) end

    local max_cols = 0
    for _, line in ipairs(lines) do
        if #line > max_cols then max_cols = #line end
    end

    self.rows = #lines
    self.cols = max_cols

    for r, line in ipairs(lines) do
        self.grid[r] = {}
        for c = 1, max_cols do
            local ch = line:sub(c, c)
            local cell = XSB_MAP[ch] or FLOOR
            self.grid[r][c] = cell
            if cell == PLAYER or cell == PLR_ON then
                self.player_r = r
                self.player_c = c
            end
        end
    end

    return self
end

function Game:_snapshot()
    local snap = {
        player_r = self.player_r,
        player_c = self.player_c,
        moves    = self.moves,
        pushes   = self.pushes,
        grid     = {},
    }
    for r = 1, self.rows do
        snap.grid[r] = {}
        for c = 1, self.cols do
            snap.grid[r][c] = self.grid[r][c]
        end
    end
    return snap
end

function Game:move(dr, dc)
    local nr = self.player_r + dr
    local nc = self.player_c + dc
    if nr < 1 or nr > self.rows or nc < 1 or nc > self.cols then return false end
    local dest = self.grid[nr][nc]
    if dest == WALL then return false end

    local snap = self:_snapshot()

    if dest == BOX or dest == BOX_ON then
        local br = nr + dr
        local bc = nc + dc
        if br < 1 or br > self.rows or bc < 1 or bc > self.cols then return false end
        local behind = self.grid[br][bc]
        if behind == WALL or behind == BOX or behind == BOX_ON then return false end
        -- move box
        self.grid[br][bc] = (behind == TARGET) and BOX_ON or BOX
        self.grid[nr][nc] = (dest  == BOX_ON)  and TARGET or FLOOR
        self.pushes = self.pushes + 1
    end

    -- vacate current cell
    local old = self.grid[self.player_r][self.player_c]
    self.grid[self.player_r][self.player_c] = (old == PLR_ON) and TARGET or FLOOR

    -- occupy new cell
    local new_dest = self.grid[nr][nc]
    self.grid[nr][nc] = (new_dest == TARGET) and PLR_ON or PLAYER

    self.player_r = nr
    self.player_c = nc
    self.moves = self.moves + 1

    if #self.history >= 500 then table.remove(self.history, 1) end
    table.insert(self.history, snap)
    return true
end

function Game:undo()
    if #self.history == 0 then return false end
    local snap = table.remove(self.history)
    self.player_r = snap.player_r
    self.player_c = snap.player_c
    self.moves    = snap.moves
    self.pushes   = snap.pushes
    self.grid     = snap.grid
    return true
end

function Game:is_solved()
    for r = 1, self.rows do
        for c = 1, self.cols do
            if self.grid[r][c] == BOX then return false end
        end
    end
    return true
end

function Game:box_count()
    local n = 0
    for r = 1, self.rows do
        for c = 1, self.cols do
            local v = self.grid[r][c]
            if v == BOX or v == BOX_ON then n = n + 1 end
        end
    end
    return n
end

function Game:boxes_on_target()
    local n = 0
    for r = 1, self.rows do
        for c = 1, self.cols do
            if self.grid[r][c] == BOX_ON then n = n + 1 end
        end
    end
    return n
end

local DIRS = { {1,0}, {-1,0}, {0,1}, {0,-1} }

-- BFS shortest path from (sr,sc) to (tr,tc) avoiding cells where blocked[r][c]
-- is true. Returns a list of {dr,dc} unit steps, or nil if unreachable.
local function bfs_path(rows, cols, sr, sc, tr, tc, blocked)
    if sr == tr and sc == tc then return {} end
    local visited = {}
    local prev = {}
    for r = 1, rows do visited[r] = {} end
    visited[sr][sc] = true
    local queue = { {sr, sc} }
    local qi = 1
    while qi <= #queue do
        local r, c = queue[qi][1], queue[qi][2]
        qi = qi + 1
        for _, d in ipairs(DIRS) do
            local nr, nc = r + d[1], c + d[2]
            if nr >= 1 and nr <= rows and nc >= 1 and nc <= cols
                and not visited[nr][nc]
                and not (blocked[nr] and blocked[nr][nc]) then
                visited[nr][nc] = true
                prev[nr * (cols + 1) + nc] = { r, c, d[1], d[2] }
                if nr == tr and nc == tc then
                    local path = {}
                    local cr, cc = nr, nc
                    while not (cr == sr and cc == sc) do
                        local p = prev[cr * (cols + 1) + cc]
                        table.insert(path, 1, { p[3], p[4] })
                        cr, cc = p[1], p[2]
                    end
                    return path
                end
                table.insert(queue, { nr, nc })
            end
        end
    end
    return nil
end

-- Find a walking path (no box pushes) from the player to an empty tile.
-- Returns a list of {dr,dc} unit steps suitable for Game:move, or nil.
function Game:find_walk_path(tr, tc)
    if tr < 1 or tr > self.rows or tc < 1 or tc > self.cols then return nil end
    local dest = self.grid[tr][tc]
    if dest == WALL or dest == BOX or dest == BOX_ON then return nil end

    local blocked = {}
    for r = 1, self.rows do
        blocked[r] = {}
        for c = 1, self.cols do
            local v = self.grid[r][c]
            blocked[r][c] = (v == WALL or v == BOX or v == BOX_ON)
        end
    end
    return bfs_path(self.rows, self.cols, self.player_r, self.player_c, tr, tc, blocked)
end

-- Find a sequence of player moves (walks + pushes) that pushes the box at
-- (box_r,box_c) to (tr,tc), without moving any other box. Other boxes act as
-- static obstacles throughout. Returns a list of {dr,dc} unit steps suitable
-- for feeding to Game:move one at a time, or nil if there is no such sequence.
function Game:find_push_path(box_r, box_c, tr, tc)
    local start_cell = self.grid[box_r] and self.grid[box_r][box_c]
    if start_cell ~= BOX and start_cell ~= BOX_ON then return nil end
    if tr < 1 or tr > self.rows or tc < 1 or tc > self.cols then return nil end
    if box_r == tr and box_c == tc then return {} end
    local dest_cell = self.grid[tr][tc]
    if dest_cell == WALL or dest_cell == BOX or dest_cell == BOX_ON then return nil end

    local walls = {}
    local other_boxes = {}
    for r = 1, self.rows do
        walls[r] = {}
        other_boxes[r] = {}
        for c = 1, self.cols do
            local v = self.grid[r][c]
            walls[r][c] = (v == WALL)
            other_boxes[r][c] = (v == BOX or v == BOX_ON) and not (r == box_r and c == box_c)
        end
    end

    local function state_key(br, bc, pr, pc)
        return br .. "," .. bc .. "," .. pr .. "," .. pc
    end

    local visited = { [state_key(box_r, box_c, self.player_r, self.player_c)] = true }
    local queue = { { box_r, box_c, self.player_r, self.player_c, {} } }
    local qi = 1
    while qi <= #queue do
        local state = queue[qi]
        qi = qi + 1
        local br, bc, pr, pc, path = state[1], state[2], state[3], state[4], state[5]

        -- player cannot walk through walls, other boxes, or the box being pushed
        local blocked = {}
        for r = 1, self.rows do
            blocked[r] = {}
            for c = 1, self.cols do
                blocked[r][c] = walls[r][c] or other_boxes[r][c] or (r == br and c == bc)
            end
        end

        for _, d in ipairs(DIRS) do
            local dr, dc = d[1], d[2]
            local from_r, from_c = br - dr, bc - dc
            local dest_r, dest_c = br + dr, bc + dc
            if dest_r >= 1 and dest_r <= self.rows and dest_c >= 1 and dest_c <= self.cols
                and not walls[dest_r][dest_c] and not other_boxes[dest_r][dest_c]
                and from_r >= 1 and from_r <= self.rows and from_c >= 1 and from_c <= self.cols
                and not blocked[from_r][from_c] then
                local walk_path = bfs_path(self.rows, self.cols, pr, pc, from_r, from_c, blocked)
                if walk_path then
                    local new_br, new_bc = dest_r, dest_c
                    local new_pr, new_pc = br, bc -- player ends up where the box was
                    local key = state_key(new_br, new_bc, new_pr, new_pc)
                    if not visited[key] then
                        visited[key] = true
                        local new_path = {}
                        for _, step in ipairs(path) do table.insert(new_path, step) end
                        for _, step in ipairs(walk_path) do table.insert(new_path, step) end
                        table.insert(new_path, { dr, dc })
                        if new_br == tr and new_bc == tc then
                            return new_path
                        end
                        table.insert(queue, { new_br, new_bc, new_pr, new_pc, new_path })
                    end
                end
            end
        end
    end
    return nil
end

-- Self-test when run directly with luajit
if arg and arg[0] and arg[0]:match("game%.lua$") then
    local level = [[
####
# .#
#  ###
#*@  #
#  $ #
#  ###
####]]
    local g = Game.from_xsb(level)
    print("rows="..g.rows.." cols="..g.cols)
    print("player at "..g.player_r..","..g.player_c)
    print("boxes="..g:box_count().." on_target="..g:boxes_on_target())
    print("solved="..tostring(g:is_solved()))
    g:move(0, 1)  -- push box right
    print("after move right: player="..g.player_r..","..g.player_c.." moves="..g.moves)
    g:undo()
    print("after undo: player="..g.player_r..","..g.player_c.." moves="..g.moves)
end

return Game
