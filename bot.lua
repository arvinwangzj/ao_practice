-- 初始化全局变量来存储最新的游戏状态和游戏主机进程。
LatestGameState = LatestGameState or nil
InProgress = InProgress or false -- 防止代理同时采取多个操作。

Logs = Logs or {}

colors = {
  red = "\27[31m",
  green = "\27[32m",
  blue = "\27[34m",
  reset = "\27[0m",
  gray = "\27[90m"
}

local directionMap = {"Up", "Down", "Left", "Right", "UpRight", "UpLeft", "DownRight", "DownLeft"}
local directionMapMin = {"UpRight", "UpLeft", "DownRight", "DownLeft"}

local player_x, player_y = 0, 0

function addLog(msg, text) -- 函数定义注释用于性能，可用于调试
  Logs[msg] = Logs[msg] or {}
  table.insert(Logs[msg], text)
end

-- 检查两个点是否在给定范围内。
-- @param x1, y1: 第一个点的坐标
-- @param x2, y2: 第二个点的坐标
-- @param range: 点之间允许的最大距离
-- @return: Boolean 指示点是否在指定范围内
function inRange(x1, y1, x2, y2, range)
    return math.abs(x1 - x2) <= range and math.abs(y1 - y2) <= range
end

-- 根据玩家的距离和能量决定下一步行动。
-- 如果有玩家在范围内，则发起攻击； 否则，随机移动。
function decideNextAction()
  local player = LatestGameState.Players[ao.id]
  local player_e = player.energy
  local player_h = player.health
  local targetInRange = false

  local p_x =  0
  local p_y =  0
  local targetHealth = nil

  if player_x == player.x and player_y == player.y then
      -- 没有移动时，随机移动
      local randomIndex = math.random(#directionMapMin)
      ao.send({Target = Game, Action = "PlayerMove", Player = ao.id, Direction = directionMap[randomIndex]})
      player_x = player.x
      player_y = player.y
  end

  for target, state in pairs(LatestGameState.Players) do
      if target ~= ao.id and inRange(player.x, player.y, state.x, state.y, 1) then
          targetHealth = state.health

          p_x = player.x - state.x
          p_y = player.y - state.y

          targetInRange = true
          break
      end
  end
-- 如果能量大于目标的血量才攻击
  if player.energy > targetHealth  and targetInRange then
    print(colors.red .. "Player in range. Attacking." .. colors.reset)
    ao.send({Target = Game, Action = "PlayerAttack", Player = ao.id, AttackEnergy = tostring(player.energy)})
  elseif targetInRange then
    print(colors.red .. "Insufficient energy. Moving ." .. colors.reset)
    local dir = nil
    -- 沿着对手相反方向逃跑
    if p_x==-1 and p_y==-1 then
      dir = "DownLeft"
    elseif p_x==-1 and p_y==0 then
      dir = "Left"
    elseif p_x==-1 and p_y==1 then
      dir = "UpLeft"
    elseif p_x==0 and p_y==-1 then
      dir = "Down"
    elseif p_x==0 and p_y==0 then
      dir = "UpRight"
    elseif p_x==0 and p_y==1 then
      dir = "Up"
    elseif p_x==1 and p_y==-1 then
      dir = "DownRight"
    elseif p_x==1 and p_y==0 then
      dir = "Right"
    elseif p_x==1 and p_y==1 then
      dir = "UpRight"
    end
    ao.send({Target = Game, Action = "PlayerMove", Player = ao.id, Direction = dir})
  else
    -- 沿对角线随机走
    local randomIndex = math.random(#directionMapMin)
    ao.send({Target = Game, Action = "PlayerMove", Player = ao.id, Direction = directionMap[randomIndex]})
  end
  InProgress = false 
end

-- 打印游戏公告并触发游戏状态更新的handler。
Handlers.add(
  "PrintAnnouncements",
  Handlers.utils.hasMatchingTag("Action", "Announcement"),
  function (msg)
    if msg.Event == "Started-Waiting-Period" then
      ao.send({Target = ao.id, Action = "AutoPay"})
    elseif (msg.Event == "Tick" or msg.Event == "Started-Game") and not InProgress then
      InProgress = true 
      ao.send({Target = Game, Action = "GetGameState"})
    elseif InProgress then
      print("Previous action still in progress. Skipping.")
    end
    print(colors.green .. msg.Event .. ": " .. msg.Data .. colors.reset)
  end
)

-- 触发游戏状态更新的handler。
Handlers.add(
  "GetGameStateOnTick",
  Handlers.utils.hasMatchingTag("Action", "Tick"),
  function ()
    if not InProgress then
      InProgress = true
      print(colors.gray .. "Getting game state..." .. colors.reset)
      ao.send({Target = Game, Action = "GetGameState"})
    else
      print("Previous action still in progress. Skipping.")
    end
  end
)

-- 等待期开始时自动付款确认的handler。
Handlers.add(
  "AutoPay",
  Handlers.utils.hasMatchingTag("Action", "AutoPay"),
  function (msg)
    print("Auto-paying confirmation fees.")
    ao.send({ Target = Game, Action = "Transfer", Recipient = Game, Quantity = "1000"})
  end
)

-- 接收游戏状态信息后更新游戏状态的handler。
Handlers.add(
  "UpdateGameState",
  Handlers.utils.hasMatchingTag("Action", "GameState"),
  function (msg)
    local json = require("json")
    LatestGameState = json.decode(msg.Data)
    ao.send({Target = ao.id, Action = "UpdatedGameState"})
    print("Game state updated. Print \'LatestGameState\' for detailed view.")
  end
)

-- 决策下一个最佳操作的handler。
Handlers.add(
  "decideNextAction",
  Handlers.utils.hasMatchingTag("Action", "UpdatedGameState"),
  function ()
    if LatestGameState.GameMode ~= "Playing" then
      InProgress = false
      return
    end
    print("Deciding next action.")
    decideNextAction()
    ao.send({Target = ao.id, Action = "Tick"})
  end
)

-- 被其他玩家击中时自动攻击的handler。
Handlers.add(
  "ReturnAttack",
  Handlers.utils.hasMatchingTag("Action", "Hit"),
  function (msg)
    if not InProgress then
      InProgress = true
      local playerEnergy = LatestGameState.Players[ao.id].energy
      if playerEnergy == undefined then
        print(colors.red .. "Unable to read energy." .. colors.reset)
        ao.send({Target = Game, Action = "Attack-Failed", Reason = "Unable to read energy."})
      elseif playerEnergy == 0 then
        print(colors.red .. "Player has insufficient energy." .. colors.reset)
        ao.send({Target = Game, Action = "Attack-Failed", Reason = "Player has no energy."})
      elseif playerEnergy >=60 then
        print(colors.red .. "Returning attack." .. colors.reset)
        ao.send({Target = Game, Action = "PlayerAttack", Player = ao.id, AttackEnergy = tostring(playerEnergy)})
      else
        print(colors.red .. "energy not enough" .. colors.reset)
      end
      InProgress = true
      ao.send({Target = ao.id, Action = "s"})
    else
      print("Previous action still in progress. Skipping.")
    end
  end
)