-- Projeto Delta – Correção ESP e Aimbot
local WHITELIST = { Users = { "gustavopcgamer204", "gustavodelicia01", "peaky", "Veiodoptduro06909" } }
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local localPlayer = Players.LocalPlayer
local camera = workspace.CurrentCamera

-- Whitelist
local function isWhitelisted(player)
    for _, entry in ipairs(WHITELIST.Users) do
        if type(entry) == "string" and player.Name == entry then return true
        elseif type(entry) == "number" and player.UserId == entry then return true end
    end
    return false
end
if not isWhitelisted(localPlayer) then
    local msg = Instance.new("Message", workspace)
    msg.Text = "Você não está na whitelist do Projeto Delta!"
    task.wait(3) msg:Destroy() return
end

print("[Delta] Whitelist passou. Iniciando...")

local CONFIG = {
    ESP = {
        Enabled = true,
        MaxDistance = 600,
        TeamCheck = false,
        SkeletonThickness = 2,
        ShowNames = true,
        FontSize = 10,
        MaxNPCs = 50,
        Colors = {
            Enemy   = Color3.fromRGB(255, 0, 0),
            Ally    = Color3.fromRGB(0, 255, 0),
            Neutral = Color3.fromRGB(255, 255, 0),
            NPC     = Color3.fromRGB(255, 200, 0)
        }
    },
    Aimbot = {
        Enabled = true,
        AimPart = "Head",
        FOV = 150,
        Smoothness = 0.3,
        MaxDistance = 1000,
        TeamCheck = false,
        AimKey = Enum.UserInputType.MouseButton2
    },
    SilentAim = {
        Enabled = false,
        FOV = 180,
        MaxDistance = 1000,
        TeamCheck = false,
        AimPart = "Head"
    }
}

local scriptEnabled = true
local playerESP = {}
local npcESP = {}
local npcCreationQueue = {}
local guiControls = {}
local mainGui = nil
local npcCount = 0
local silentAimHooked = false

-- Funções utilitárias
local function isValidTarget(character)
    if not character then return false end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    return humanoid and humanoid.Health > 0
end
local function getTargetColor(target)
    if typeof(target) == "Instance" then return CONFIG.ESP.Colors.NPC
    elseif CONFIG.ESP.TeamCheck and target.Team == localPlayer.Team then return CONFIG.ESP.Colors.Ally
    else return CONFIG.ESP.Colors.Enemy end
end
local function isInFov(worldPos, radius)
    local sp, onScreen = camera:WorldToViewportPoint(worldPos)
    if not onScreen then return false end
    local c = Vector2.new(camera.ViewportSize.X/2, camera.ViewportSize.Y/2)
    return (Vector2.new(sp.X, sp.Y) - c).Magnitude <= radius
end

-- Esqueleto
local R15_CONNS = { {"Head","UpperTorso"},{"UpperTorso","LowerTorso"},{"UpperTorso","LeftUpperArm"},{"LeftUpperArm","LeftLowerArm"},{"LeftLowerArm","LeftHand"},{"UpperTorso","RightUpperArm"},{"RightUpperArm","RightLowerArm"},{"RightLowerArm","RightHand"},{"LowerTorso","LeftUpperLeg"},{"LeftUpperLeg","LeftLowerLeg"},{"LeftLowerLeg","LeftFoot"},{"LowerTorso","RightUpperLeg"},{"RightUpperLeg","RightLowerLeg"},{"RightLowerLeg","RightFoot"} }
local R6_CONNS = { {"Head","Torso"},{"Torso","Left Arm"},{"Left Arm","LeftHand"},{"Torso","Right Arm"},{"Right Arm","RightHand"},{"Torso","Left Leg"},{"Left Leg","LeftFoot"},{"Torso","Right Leg"},{"Right Leg","RightFoot"} }
local function getPartPositions(character, rigType)
    local p = {}
    local function tryAdd(name) local part = character:FindFirstChild(name) if part and part:IsA("BasePart") then p[name]=part.Position end end
    if rigType == Enum.HumanoidRigType.R15 then
        tryAdd("Head"); tryAdd("UpperTorso"); tryAdd("LowerTorso"); tryAdd("LeftUpperArm"); tryAdd("LeftLowerArm"); tryAdd("LeftHand")
        tryAdd("RightUpperArm"); tryAdd("RightLowerArm"); tryAdd("RightHand"); tryAdd("LeftUpperLeg"); tryAdd("LeftLowerLeg"); tryAdd("LeftFoot")
        tryAdd("RightUpperLeg"); tryAdd("RightLowerLeg"); tryAdd("RightFoot")
        return p, R15_CONNS
    else
        tryAdd("Head"); tryAdd("Torso"); tryAdd("Left Arm"); tryAdd("Right Arm"); tryAdd("Left Leg"); tryAdd("Right Leg")
        tryAdd("LeftHand"); tryAdd("RightHand"); tryAdd("LeftFoot"); tryAdd("RightFoot")
        return p, R6_CONNS
    end
end

-- Criação de ESP (flexível)
local function createESP(character, displayName, color)
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid then return nil end
    local conns = (humanoid.RigType == Enum.HumanoidRigType.R15) and R15_CONNS or R6_CONNS
    local lines = {}
    for _=1, #conns do
        local ok, line = pcall(function() return Drawing.new("Line") end)
        if ok and line then
            line.Visible = false; line.Thickness = CONFIG.ESP.SkeletonThickness; line.Color = color; line.Transparency = 1
            table.insert(lines, line)
        end
    end
    local nameText = nil
    if CONFIG.ESP.ShowNames then
        local ok, text = pcall(function() return Drawing.new("Text") end)
        if ok and text then
            text.Visible = false; text.Text = displayName; text.Color = color; text.Size = CONFIG.ESP.FontSize
            text.Center = true; text.Outline = true; text.Font = Drawing.Fonts.Monospace
            nameText = text
        end
    end
    print("[Delta] ESP criado para " .. displayName)
    return { Lines = lines, Text = nameText, Name = displayName, Color = color }
end

local function removeESP(target, storage)
    local data = storage[target]
    if data then
        for _, line in ipairs(data.Lines) do pcall(function() line:Remove() end) end
        if data.Text then pcall(function() data.Text:Remove() end) end
        storage[target] = nil
    end
end
local function clearAllESP()
    for k in pairs(playerESP) do removeESP(k, playerESP) end
    for k in pairs(npcESP) do removeESP(k, npcESP) end
    npcCount = 0
    npcCreationQueue = {}
end

-- Atualização do ESP (tolerante a partes faltantes)
local function updateESPForTarget(character, data, colorOverride)
    if not character or not character.Parent then return false end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid or humanoid.Health <= 0 then return false end
    local rootPart = humanoid.RootPart or character:FindFirstChild("HumanoidRootPart") or character:FindFirstChild("Torso")
    if not rootPart then return false end
    local myChar = localPlayer.Character
    if not myChar then return false end
    local myRoot = myChar:FindFirstChild("HumanoidRootPart") or myChar:FindFirstChild("Torso")
    if not myRoot then return false end
    local dist = (rootPart.Position - myRoot.Position).Magnitude
    local visible = (dist <= CONFIG.ESP.MaxDistance)
    local color = colorOverride or data.Color
    local positions, connections = getPartPositions(character, humanoid.RigType)
    for i, conn in ipairs(connections) do
        local line = data.Lines[i]
        if line then
            if visible and positions[conn[1]] and positions[conn[2]] then
                local a, onA = camera:WorldToViewportPoint(positions[conn[1]])
                local b, onB = camera:WorldToViewportPoint(positions[conn[2]])
                if onA and onB then
                    line.From = Vector2.new(a.X, a.Y); line.To = Vector2.new(b.X, b.Y)
                    line.Color = color; line.Visible = true
                else line.Visible = false end
            else line.Visible = false end
        end
    end
    if data.Text then
        local head = character:FindFirstChild("Head")
        local textPart = head or rootPart
        if textPart and visible then
            local hp, onScreen = camera:WorldToViewportPoint(textPart.Position + Vector3.new(0, 2, 0))
            if onScreen then data.Text.Position = Vector2.new(hp.X, hp.Y); data.Text.Visible = true
            else data.Text.Visible = false end
        else data.Text.Visible = false end
    end
    return true
end

local function updateAllESP()
    local myChar = localPlayer.Character
    if not myChar then return end
    if not (myChar:FindFirstChild("HumanoidRootPart") or myChar:FindFirstChild("Torso")) then return end
    for player, data in pairs(playerESP) do
        local char = player.Character
        if char and isValidTarget(char) then
            if not updateESPForTarget(char, data, getTargetColor(player)) then removeESP(player, playerESP) end
        else removeESP(player, playerESP) end
    end
    for npc, data in pairs(npcESP) do
        if not isValidTarget(npc) then removeESP(npc, npcESP) end
    end
    local count = 0
    for npc, data in pairs(npcESP) do
        if count >= 15 then break end
        updateESPForTarget(npc, data)
        count = count + 1
    end
end

-- NPCs (criação gradual)
local function isNPC(character)
    if not character:IsA("Model") then return false end
    if character.Name == "" or character.Name == "Model" then return false end
    if not character:FindFirstChildOfClass("Humanoid") then return false end
    if not (character:FindFirstChild("HumanoidRootPart") or character:FindFirstChild("Torso") or character:FindFirstChild("Head")) then return false end
    if character == localPlayer.Character then return false end
    for _, plr in ipairs(Players:GetPlayers()) do if plr.Character == character then return false end end
    return true
end

local function tryAddNPC(model)
    if not scriptEnabled or not CONFIG.ESP.Enabled then return end
    if npcCount >= CONFIG.ESP.MaxNPCs then
        for target, _ in pairs(npcESP) do removeESP(target, npcESP); npcCount = npcCount - 1; break end
    end
    if not isNPC(model) or npcESP[model] then return end
    table.insert(npcCreationQueue, model)
end

spawn(function()
    while true do
        if #npcCreationQueue > 0 then
            local model = table.remove(npcCreationQueue, 1)
            if model and model.Parent and isNPC(model) and not npcESP[model] then
                local name = "[NPC] " .. model.Name
                local espData = createESP(model, name, CONFIG.ESP.Colors.NPC)
                if espData then npcESP[model] = espData; npcCount = npcCount + 1 end
            end
            task.wait(0.05)
        else task.wait(0.1) end
    end
end)

workspace.DescendantAdded:Connect(function(d)
    if d:IsA("Model") and d:FindFirstChildOfClass("Humanoid") and (d:FindFirstChild("Head") or d:FindFirstChild("HumanoidRootPart")) then
        tryAddNPC(d)
    end
end)
workspace.DescendantRemoving:Connect(function(d)
    if npcESP[d] then removeESP(d, npcESP); npcCount = npcCount - 1 end
end)
spawn(function()
    task.wait(1)
    for _, o in ipairs(workspace:GetDescendants()) do tryAddNPC(o) end
end)

-- Aimbot
local aimbotActive = false
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if input.UserInputType == CONFIG.Aimbot.AimKey then
        aimbotActive = true
        print("[Delta] Aimbot ativado (Mouse2 pressionado)")
    end
    if input.KeyCode == Enum.KeyCode.Insert and mainGui then
        mainGui.Enabled = not mainGui.Enabled
        print("[Delta] Menu " .. (mainGui.Enabled and "mostrado" or "escondido"))
    end
end)
UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == CONFIG.Aimbot.AimKey then
        aimbotActive = false
        print("[Delta] Aimbot desativado")
    end
end)

local function getBestTarget()
    if not localPlayer.Character then return nil end
    local myRoot = localPlayer.Character:FindFirstChild("HumanoidRootPart") or localPlayer.Character:FindFirstChild("Torso")
    if not myRoot then return nil end
    local best, bestDist = nil, math.huge
    local camPos = camera.CFrame.Position
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr == localPlayer then continue end
        if not isValidTarget(plr.Character) then continue end
        if CONFIG.Aimbot.TeamCheck and plr.Team == localPlayer.Team then continue end
        local aimPart = (CONFIG.Aimbot.AimPart == "Head" and plr.Character:FindFirstChild("Head")) or plr.Character:FindFirstChild("HumanoidRootPart") or plr.Character:FindFirstChild("Torso")
        if not aimPart then continue end
        local d = (aimPart.Position - camPos).Magnitude
        if d <= CONFIG.Aimbot.MaxDistance and isInFov(aimPart.Position, CONFIG.Aimbot.FOV) and d < bestDist then
            bestDist = d; best = plr
        end
    end
    return best
end

local function runAimbot()
    if not scriptEnabled or not CONFIG.Aimbot.Enabled or not aimbotActive then return end
    local target = getBestTarget()
    if target and target.Character then
        local aimPart = (CONFIG.Aimbot.AimPart == "Head" and target.Character:FindFirstChild("Head")) or target.Character:FindFirstChild("HumanoidRootPart") or target.Character:FindFirstChild("Torso")
        if aimPart then
            local dir = (aimPart.Position - camera.CFrame.Position).Unit
            local tCF = CFrame.new(camera.CFrame.Position, camera.CFrame.Position + dir)
            camera.CFrame = camera.CFrame:Lerp(tCF, math.clamp(CONFIG.Aimbot.Smoothness, 0.001, 1))
        end
    end
end

-- Silent Aim (mantido)
local function getSilentAimTarget()
    if not localPlayer.Character then return nil end
    local myRoot = localPlayer.Character:FindFirstChild("HumanoidRootPart") or localPlayer.Character:FindFirstChild("Torso")
    if not myRoot then return nil end
    local best, bestDist = nil, math.huge
    local camPos = camera.CFrame.Position
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr == localPlayer then continue end
        if not isValidTarget(plr.Character) then continue end
        if CONFIG.SilentAim.TeamCheck and plr.Team == localPlayer.Team then continue end
        local aimPart = (CONFIG.SilentAim.AimPart == "Head" and plr.Character:FindFirstChild("Head")) or plr.Character:FindFirstChild("HumanoidRootPart") or plr.Character:FindFirstChild("Torso")
        if not aimPart then continue end
        local d = (aimPart.Position - camPos).Magnitude
        if d <= CONFIG.SilentAim.MaxDistance and isInFov(aimPart.Position, CONFIG.SilentAim.FOV) and d < bestDist then
            bestDist = d; best = aimPart
        end
    end
    return best
end

local function enableSilentAim()
    if silentAimHooked then return end
    silentAimHooked = true
    print("[Delta] Silent Aim hook ativado")
    local function hookTool(tool)
        if tool:IsA("Tool") then
            local remote = tool:FindFirstChild("RemoteEvent") or tool:FindFirstChildOfClass("RemoteEvent")
            if remote and not remote:GetAttribute("DeltaHooked") then
                remote:SetAttribute("DeltaHooked", true)
                local oldFire = remote.FireServer
                remote.FireServer = function(self, ...)
                    if scriptEnabled and CONFIG.SilentAim.Enabled then
                        local tp = getSilentAimTarget()
                        if tp then
                            local args = {...}
                            if #args >= 1 and typeof(args[1]) == "Vector3" then args[1] = tp.Position
                            elseif #args >= 1 and typeof(args[1]) == "CFrame" then args[1] = CFrame.new(tp.Position) end
                            return oldFire(self, unpack(args))
                        end
                    end
                    return oldFire(self, ...)
                end
            end
        end
    end
    local char = localPlayer.Character
    if char then for _, t in ipairs(char:GetChildren()) do hookTool(t) end end
    localPlayer.CharacterAdded:Connect(function(newChar)
        newChar.ChildAdded:Connect(function(child) task.wait(0.2); hookTool(child) end)
        for _, t in ipairs(newChar:GetChildren()) do hookTool(t) end
    end)
    if char then char.ChildAdded:Connect(function(child) task.wait(0.2); hookTool(child) end) end
end
local function disableSilentAim() silentAimHooked = false end

-- GUI simples
local function createCheckbox(parent, text, initialState, position, callback)
    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(1,0,0,30); frame.Position = position; frame.BackgroundTransparency = 1; frame.Parent = parent
    local box = Instance.new("TextButton")
    box.Size = UDim2.new(0,20,0,20); box.Position = UDim2.new(0,5,0,5)
    box.BackgroundColor3 = initialState and Color3.fromRGB(0,200,0) or Color3.fromRGB(200,0,0)
    box.Text = initialState and "✓" or ""; box.TextColor3 = Color3.new(1,1,1)
    box.Font = Enum.Font.SourceSansBold; box.TextSize = 14; box.BorderSizePixel = 0; box.Parent = frame
    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1,-30,1,0); label.Position = UDim2.new(0,30,0,0); label.BackgroundTransparency = 1
    label.Text = text; label.TextColor3 = Color3.new(1,1,1); label.Font = Enum.Font.SourceSansBold; label.TextSize = 14; label.TextXAlignment = Enum.TextXAlignment.Left; label.Parent = frame
    local state = initialState
    local function updateVisual()
        box.BackgroundColor3 = state and Color3.fromRGB(0,200,0) or Color3.fromRGB(200,0,0)
        box.Text = state and "✓" or ""
    end
    box.MouseButton1Click:Connect(function() state = not state; updateVisual(); callback(state) end)
    return { frame = frame, setState = function(newState) state = newState; updateVisual() end }
end

local function createGUI()
    local playerGui = localPlayer:WaitForChild("PlayerGui")
    if playerGui:FindFirstChild("ProjetoDeltaGUI") then playerGui.ProjetoDeltaGUI:Destroy() end
    local gui = Instance.new("ScreenGui")
    gui.Name = "ProjetoDeltaGUI"; gui.ResetOnSpawn = false; gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling; gui.Enabled = true
    local main = Instance.new("Frame", gui)
    main.Size = UDim2.new(0, 200, 0, 130); main.Position = UDim2.new(0.5, -100, 0.1, 0)
    main.BackgroundColor3 = Color3.fromRGB(30,30,30); main.BorderSizePixel = 0; main.BackgroundTransparency = 0.2; main.Active = true; main.Draggable = true
    local title = Instance.new("TextLabel", main)
    title.Size = UDim2.new(1,0,0,25); title.BackgroundTransparency = 1; title.Text = "Projeto Delta"; title.TextColor3 = Color3.new(1,1,1); title.Font = Enum.Font.SourceSansBold; title.TextSize = 16

    local espCheck = createCheckbox(main, "ESP", CONFIG.ESP.Enabled, UDim2.new(0,0,0,30), function(s)
        CONFIG.ESP.Enabled = s
        if s then
            for _, plr in ipairs(Players:GetPlayers()) do
                if plr ~= localPlayer and plr.Character then
                    local esp = createESP(plr.Character, plr.Name, getTargetColor(plr))
                    if esp then playerESP[plr] = esp end
                end
            end
            for _, o in ipairs(workspace:GetDescendants()) do tryAddNPC(o) end
            print("[Delta] ESP ligado")
        else
            clearAllESP()
            print("[Delta] ESP desligado")
        end
    end)
    local aimCheck = createCheckbox(main, "Aimbot", CONFIG.Aimbot.Enabled, UDim2.new(0,0,0,65), function(s)
        CONFIG.Aimbot.Enabled = s
        print("[Delta] Aimbot " .. (s and "ligado" or "desligado"))
    end)
    local silentCheck = createCheckbox(main, "Silent Aim", CONFIG.SilentAim.Enabled, UDim2.new(0,0,0,100), function(s)
        CONFIG.SilentAim.Enabled = s
        if s then enableSilentAim() else disableSilentAim() end
        print("[Delta] Silent Aim " .. (s and "ligado" or "desligado"))
    end)

    gui.Parent = playerGui
    mainGui = gui
    guiControls.espCheck = espCheck; guiControls.aimCheck = aimCheck; guiControls.silentCheck = silentCheck
end

-- Inicialização melhorada (sem depender da cabeça)
local function onPlayerAdded(plr)
    if plr == localPlayer then return end
    local function onChar(char)
        -- Espera por uma parte raiz (HumanoidRootPart ou Torso) – a cabeça pode vir depois
        local rootPart = char:WaitForChild("HumanoidRootPart", 10) or char:WaitForChild("Torso", 10)
        if not rootPart then
            print("[Delta] Não foi possível encontrar parte raiz para " .. plr.Name)
            return
        end
        if scriptEnabled and CONFIG.ESP.Enabled then
            local esp = createESP(char, plr.Name, getTargetColor(plr))
            if esp then playerESP[plr] = esp end
        end
    end
    if plr.Character then onChar(plr.Character) end
    plr.CharacterAdded:Connect(onChar)
end

for _, plr in ipairs(Players:GetPlayers()) do onPlayerAdded(plr) end
Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(function(plr) removeESP(plr, playerESP) end)
localPlayer.CharacterAdded:Connect(function(char)
    local root = char:WaitForChild("HumanoidRootPart", 10) or char:WaitForChild("Torso", 10)
    if not root then return end
    print("[Delta] Personagem local renasceu. Recriando ESP...")
    clearAllESP()
    if scriptEnabled and CONFIG.ESP.Enabled then
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= localPlayer and plr.Character then
                local esp = createESP(plr.Character, plr.Name, getTargetColor(plr))
                if esp then playerESP[plr] = esp end
            end
        end
        for _, o in ipairs(workspace:GetDescendants()) do tryAddNPC(o) end
    end
end)
createGUI()

print("[Delta] Script carregado com sucesso!")

RunService.Heartbeat:Connect(function()
    if scriptEnabled and CONFIG.ESP.Enabled then updateAllESP() end
    runAimbot()
end)