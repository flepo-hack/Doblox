-- Tämä skripti on tarkoitettu käytettäväksi Roblox-ympäristössä.
-- Se käyttää pelin fyysikkaa ja objekteja käyttäjän koneella.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local LocalPlayer = Players.LocalPlayer
local Mouse = LocalPlayer:GetMouse()

local orbitingObjects = {}
local orbitRadius = 10 -- Kuinka kaukana esineet kiertävät pelaajaa
local orbitSpeed = 0.1 -- Kuinka nopeasti esineet kiertävät
local shootForce = 5000 -- Kuinka kovalla voimalla esineet singotaan
local returnSpeed = 0.1 -- Kuinka nopeasti esineet palaavat kiertoradalle ampumisen jälkeen
local maxOrbitObjects = 20 -- Maksimimäärä esineitä kiertoradalla

local function createShootTool()
    local tool = Instance.new("Tool")
    tool.Name = "Shoot Orbiter"
    tool.Parent = LocalPlayer.Backpack

    local part = Instance.new("Part")
    part.Name = "Handle"
    part.Size = Vector3.new(0.5, 0.5, 0.5)
    part.Transparency = 1
    part.CanCollide = false
    part.Parent = tool

    tool.Equipped:Connect(function()
        print("Shoot Orbiter Equipped. Click to shoot!")
        -- Käynnistetään keräys ja orbittaaminen, kun työkalu on varustettu
        -- Tämä on hyvä paikka kutsua orbittausfunktiota
    end)

    tool.Unequipped:Connect(function()
        print("Shoot Orbiter Unequipped.")
        -- Pysäytetään orbittaminen ja vapautetaan esineet, jos halutaan
    end)

    tool.Activated:Connect(function()
        if #orbitingObjects > 0 and Mouse.Target then
            local targetPosition = Mouse.Hit.p
            local playerPosition = LocalPlayer.Character.HumanoidRootPart.Position

            for i, obj in ipairs(orbitingObjects) do
                if obj and obj.PrimaryPart and obj.PrimaryPart:IsDescendantOf(Workspace) then
                    local direction = (targetPosition - obj.PrimaryPart.Position).unit
                    -- Varmistetaan, että objectilla on BodyVelocity tai vastaava fyysikkaa manipuloiva objekti
                    local bv = Instance.new("BodyVelocity")
                    bv.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
                    bv.Velocity = direction * shootForce
                    bv.Parent = obj.PrimaryPart
                    game:GetService("Debris"):AddItem(bv, 0.1) -- Poista BodyVelocity nopeasti

                    -- Jos kohde on pelaaja, tehdään vahinkoa
                    local hitPlayer = Players:GetPlayerFromCharacter(obj)
                    if hitPlayer and hitPlayer ~= LocalPlayer then
                        local humanoid = obj:FindFirstChildOfClass("Humanoid")
                        if humanoid then
                            humanoid:TakeDamage(50) -- Esimerkiksi 50 vahinkoa
                        end
                    end
                end
            end
            orbitingObjects = {} -- Tyhjennä kiertorata ampumisen jälkeen
        end
    end)
end

local function findAndOrbitObjects()
    local playerCharacter = LocalPlayer.Character
    if not playerCharacter then return end
    local hrp = playerCharacter:FindFirstChild("HumanoidRootPart")
    if not hrp then return end

    local newFoundObjects = {}
    local currentOrbitCount = #orbitingObjects

    for i, v in ipairs(Workspace:GetDescendants()) do
        if v:IsA("BasePart") and v.CanCollide and v.Parent ~= playerCharacter and v.Anchored == false and v.Parent and not v.Parent:FindFirstChildOfClass("Humanoid") then
            -- Tarkista, onko jo kiertoradalla
            local alreadyOrbiting = false
            for _, orbitedObj in ipairs(orbitingObjects) do
                if orbitedObj == v.Parent then
                    alreadyOrbiting = true
                    break
                end
            end

            if not alreadyOrbiting and (currentOrbitCount + #newFoundObjects) < maxOrbitObjects then
                local distance = (hrp.Position - v.Position).Magnitude
                if distance < 30 and distance > 5 then -- Kerää lähellä olevat, mutta ei liian lähellä olevat
                    local model = v.Parent
                    if model:IsA("Model") and model.PrimaryPart then
                        table.insert(newFoundObjects, model)
                    else
                        -- Jos ei malli, käytä itse parttia
                        local tempModel = Instance.new("Model")
                        tempModel.Name = "OrbiterPart_" .. v.Name
                        v.Parent = tempModel
                        tempModel.PrimaryPart = v
                        table.insert(newFoundObjects, tempModel)
                    end
                end
            end
        elseif v:IsA("Model") and v:FindFirstChildOfClass("Humanoid") and v ~= playerCharacter then
            -- Kerää myös muut pelaajat (heidän hahmonsa)
            local alreadyOrbiting = false
            for _, orbitedObj in ipairs(orbitingObjects) do
                if orbitedObj == v then
                    alreadyOrbiting = true
                    break
                end
            end
            if not alreadyOrbiting and (currentOrbitCount + #newFoundObjects) < maxOrbitObjects then
                local distance = (hrp.Position - v.PrimaryPart.Position).Magnitude
                if distance < 30 and distance > 5 then
                    table.insert(newFoundObjects, v)
                end
            end
        end
    end

    -- Lisää uudet löydetyt objektit kiertoradalle
    for _, obj in ipairs(newFoundObjects) do
        table.insert(orbitingObjects, obj)
    end

    -- Poista kiertoradalta objektit, jotka ovat poissa pelistä
    for i = #orbitingObjects, 1, -1 do
        local obj = orbitingObjects[i]
        if not obj or not obj.PrimaryPart or not obj.PrimaryPart:IsDescendantOf(Workspace) then
            table.remove(orbitingObjects, i)
        end
    end
end

local function updateOrbit()
    local playerCharacter = LocalPlayer.Character
    if not playerCharacter then return end
    local hrp = playerCharacter:FindFirstChild("HumanoidRootPart")
    if not hrp then return end

    local angleIncrement = 2 * math.pi / #orbitingObjects
    local currentAngle = 0

    for i, obj in ipairs(orbitingObjects) do
        if obj and obj.PrimaryPart and obj.PrimaryPart:IsDescendantOf(Workspace) then
            local targetX = hrp.Position.X + orbitRadius * math.cos(currentAngle)
            local targetZ = hrp.Position.Z + orbitRadius * math.sin(currentAngle)
            local targetY = hrp.Position.Y + 5 -- Kiertää hieman pelaajan yläpuolella

            local targetPosition = Vector3.new(targetX, targetY, targetZ)

            -- Luo BodyPosition ja BodyGyro, jos niitä ei ole jo
            local bp = obj.PrimaryPart:FindFirstChild("BodyPosition")
            if not bp then
                bp = Instance.new("BodyPosition")
                bp.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
                bp.D = 1000 -- Vaimennus
                bp.P = 10000 -- Proportionaalinen vahvistus
                bp.Parent = obj.PrimaryPart
            end
            bp.Position = targetPosition

            local bg = obj.PrimaryPart:FindFirstChild("BodyGyro")
            if not bg then
                bg = Instance.new("BodyGyro")
                bg.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
                bg.CFrame = CFrame.new(obj.PrimaryPart.Position, hrp.Position) -- Kääntää objektin kohti pelaajaa
                bg.Parent = obj.PrimaryPart
            end
            bg.CFrame = CFrame.new(obj.PrimaryPart.Position, hrp.Position)

            currentAngle = currentAngle + angleIncrement
        else
            -- Objekti on poistunut, poista se listalta seuraavassa siivouksessa
        end
    end
end

-- Luo "Shoot Orbiter" -työkalu heti kun skripti suoritetaan
createShootTool()

-- Päivitä orbittavat objektit ja niiden kiertorata jatkuvasti
game:GetService("RunService").Heartbeat:Connect(function()
    findAndOrbitObjects() -- Päivitä lista kerättävistä objekteista
    updateOrbit()        -- Päivitä orbittavien objektien sijainti
end)

print("Orbiter Shoot exploit script loaded. Look for 'Shoot Orbiter' in your backpack.")
