--[[
	═══════════════════════════════════════════════════════════════════════
	  NN ORBITER  ·  v2.0
	  Kerää fyysisiä objekteja ympäriltäsi, kiertää ne pelaajan ympärillä
	  ja ampuu ne maalia kohti.

	  Ajetaan Roblox-executorissa (client-side). Skripti EI muokkaa pelin
	  objektihierarkiaa: se ei uudelleenvanhempaa (reparent) osia eikä
	  tuhoa pelin rakenteita – kierto ja ampuminen tehdään CFrame:llä.

	  Optimointi vs. v1.0:
	    · tilakysely GetPartBoundsInRadius:lla  (O(lähellä olevat) eikä
	      O(kaikki Workspacen lapset) joka frame)
	    · skannaus on rajoitettu (scanInterval) eikä aja joka Heartbeat
	    · objekteja ei uudelleenvanhempita → ei Instance-luontia per frame
	    · enintään maxObjects objektia, dynaamiset liikkuvat osat ohitetaan
	    · kunnollinen siivous: ei vuotavia liikkuja/instansseja
	═══════════════════════════════════════════════════════════════════════
]]

-- ═══════════════════════════════════════════════════════════════════════
--  LOADSTRING-LATURI
--  Aja yhdellä rivillä:
--      loadstring(game:HttpGet("https://raw.githubusercontent.com/flepo-hack/Doblox/main/Nn.lua"))()
--  Sisäänrakennettu API (executorin getgenv):
--      getgenv().NN_Load()      -- lataa & suorita tämä skripti uudelleen
--      getgenv().NN_Load(url)   -- lataa & suorita mikä tahansa URL
--      getgenv().NN_Unload()    -- sammuttaa ja siivoaa kaiken
-- ═══════════════════════════════════════════════════════════════════════

local GENV = (getgenv and getgenv()) or _G
local LOADER_URL = "https://raw.githubusercontent.com/flepo-hack/Doblox/main/Nn.lua"

local function compileChunk(chunk, name)
	local loader = loadstring or load
	if not loader then
		error("[NN] loadstring puuttuu – käytä loadstringia tukevaa executoria", 0)
	end
	local fn, err = loader(chunk, name)
	if not fn then
		error("[NN] Latausvirhe: " .. tostring(err), 0)
	end
	return fn
end

function GENV.NN_Load(url)
	url = url or LOADER_URL
	local ok, body = pcall(function()
		return game:HttpGet(url)
	end)
	if not ok then
		warn("[NN] Lataus epäonnistui: " .. tostring(body))
		return false
	end
	local fn = compileChunk(body, "@NN_Orbiter")
	if GENV.NN_Unload then GENV.NN_Unload() end
	local ran, err = pcall(fn)
	if not ran then
		warn("[NN] Suoritusvirhe: " .. tostring(err))
	end
	return ran
end

-- ═══════════════════════════════════════════════════════════════════════
--  Palvelut & tila
-- ═══════════════════════════════════════════════════════════════════════

local Players     = game:GetService("Players")
local RunService  = game:GetService("RunService")
local Workspace   = game:GetService("Workspace")
local UserInput   = game:GetService("UserInputService")
local StarterGui  = game:GetService("StarterGui")

local LocalPlayer = Players.LocalPlayer
local Mouse       = LocalPlayer:GetMouse()

local CONFIG = {
	radius         = 28,    -- kuinka kaukaa objekteja kerätään
	minDistance    = 5,     -- ei kerätä aivan ihossa kiinni olevia
	orbitRadius    = 10,    -- kiertoradan säde
	orbitHeight    = 5,     -- korkeus pelaajan yläpuolella
	orbitSpeed     = 1.2,   -- rad/s
	maxObjects     = 20,    -- kiertoradalla yhtä aikaa
	scanInterval   = 0.25,  -- s skannausväli (ei joka frame)
	shootSpeed     = 220,   -- studs/s ammuttaessa
	projectileLife = 1.5,   -- s lentoaika ennen vapautusta
	returnAfterShot= false, -- palaako objekti kiertoradalle osuman jälkeen
	collectPlayers = false, -- kerää myös muiden hahmot
	allowAnchored  = true,  -- kerää myös ankkuroidut osat
	maxPartSize    = 24,    -- ohita suuremmat osat (esim. maa/baseplate)
	maxModelParts  = 40,    -- ohita suuret mallit
	toggleKey      = Enum.KeyCode.RightShift,
	damage         = 25,    -- client-side vahinko osumasta (ei aina replikoidu)
}

local state = {
	running     = false,
	collecting  = true,
	list        = {},   -- järjestetty lista: { obj, isModel, anchored }
	index       = {},   -- [instance] = record  (O(1)-jäsenyys)
	projectiles = {},
	angle       = 0,
	scanClock   = 0,
	connections = {},
	tool        = nil,
}

-- ═══════════════════════════════════════════════════════════════════════
--  Apufunktiot
-- ═══════════════════════════════════════════════════════════════════════

local function getCharacter()
	local char = LocalPlayer.Character
	if not char or not char.Parent then return nil end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp then return nil end
	return char, hrp
end

local function notify(text)
	pcall(function()
		StarterGui:SetCore("SendNotification", { Title = "NN Orbiter", Text = text, Duration = 3 })
	end)
end

local function removeFromList(rec)
	for i = #state.list, 1, -1 do
		if state.list[i] == rec then
			table.remove(state.list, i)
			return
		end
	end
end

-- Vapauttaa objektin kiertoradalta (ei tuhoa pelin osia).
local function release(rec, zeroVelocity)
	local obj = rec.obj
	state.index[obj] = nil
	removeFromList(rec)
	if zeroVelocity and not rec.anchored and obj and obj.Parent then
		pcall(function() obj.AssemblyLinearVelocity = Vector3.zero end)
	end
end

-- ═══════════════════════════════════════════════════════════════════════
--  Keräys – tilakysely rajoitetulla skannauksella
-- ═══════════════════════════════════════════════════════════════════════

local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Exclude or Enum.RaycastFilterType.Blacklist
overlap.MaxParts = 400

local function isCollectable(part, char, origin)
	if typeof(part) ~= "Instance" or not part:IsA("BasePart") then return false end
	if part:IsDescendantOf(char) then return false end
	if state.index[part] then return false end

	local model = part:FindFirstAncestorOfClass("Model")
	if model and state.index[model] then return false end
	if not CONFIG.collectPlayers and part:FindFirstAncestorOfClass("Humanoid") then return false end

	local size = part.Size
	if math.max(size.X, size.Y, size.Z) > CONFIG.maxPartSize then return false end
	if not CONFIG.allowAnchored and part.Anchored then return false end

	local d = (part.Position - origin).Magnitude
	if d < CONFIG.minDistance or d > CONFIG.radius then return false end
	return true
end

-- Ryhmittelee osan mallikseen vain jos malli on järkevän kokoinen.
local function groupOf(part)
	local model = part.Parent
	if model and model:IsA("Model") then
		local kids = model:GetChildren()
		if #kids <= CONFIG.maxModelParts and model:FindFirstChildWhichIsA("BasePart") then
			return model
		end
	end
	return part
end

local function register(part)
	local group = groupOf(part)
	if state.index[group] then return nil end

	local rec = {
		obj     = group,
		isModel = group:IsA("Model"),
		anchored = part.Anchored,
	}
	if rec.isModel then
		-- Malli on ankkuroitu vain jos kaikki sen osat ovat ankkuroituja.
		rec.anchored = true
		for _, c in ipairs(group:GetDescendants()) do
			if c:IsA("BasePart") and not c.Anchored then
				rec.anchored = false
				break
			end
		end
	end

	state.index[group] = rec
	state.list[#state.list + 1] = rec
	return rec
end

local function scan()
	local char, hrp = getCharacter()
	if not hrp then return end

	local origin = hrp.Position
	local filter = { char }
	if not CONFIG.collectPlayers then
		for _, p in ipairs(Players:GetPlayers()) do
			if p ~= LocalPlayer and p.Character then
				filter[#filter + 1] = p.Character
			end
		end
	end
	overlap.FilterDescendantsInstances = filter

	local parts
	if Workspace.GetPartBoundsInRadius then
		parts = Workspace:GetPartBoundsInRadius(origin, CONFIG.radius, overlap)
	else
		parts = Workspace:GetDescendants()
	end

	local budget = CONFIG.maxObjects - #state.list
	if budget <= 0 then return end

	for _, part in ipairs(parts) do
		if budget <= 0 then break end
		if isCollectable(part, char, origin) then
			if register(part) then
				budget = budget - 1
			end
		end
	end
end

-- ═══════════════════════════════════════════════════════════════════════
--  Kierto
-- ═══════════════════════════════════════════════════════════════════════

local function placeObject(rec, targetPos, facePos)
	local obj = rec.obj
	local cf = CFrame.lookAt(targetPos, facePos)
	if rec.isModel then
		obj:PivotTo(cf)
	else
		obj.CFrame = cf
		if not rec.anchored then
			obj.AssemblyLinearVelocity = Vector3.zero
			obj.AssemblyAngularVelocity = Vector3.zero
		end
	end
end

local function updateOrbit(dt)
	local _, hrp = getCharacter()
	if not hrp then return end

	state.angle = state.angle + CONFIG.orbitSpeed * dt

	local list = state.list
	local n = #list
	if n == 0 then return end
	local step = (2 * math.pi) / n
	local center = hrp.Position

	-- Käännetty järjestys: release() voi poistaa alkion kesken silmukan,
	-- jolloin eteenpäin iteroitaessa indeksi osoittaisi nil:iin.
	for i = n, 1, -1 do
		local rec = list[i]
		local obj = rec.obj
		if not obj or not obj.Parent then
			release(rec, false)
		else
			local a = state.angle + (i - 1) * step
			local target = Vector3.new(
				center.X + CONFIG.orbitRadius * math.cos(a),
				center.Y + CONFIG.orbitHeight,
				center.Z + CONFIG.orbitRadius * math.sin(a)
			)
			placeObject(rec, target, center)
		end
	end
end

-- ═══════════════════════════════════════════════════════════════════════
--  Ampuminen
-- ═══════════════════════════════════════════════════════════════════════

local function launch(rec, targetPos)
	local obj = rec.obj
	local pos = rec.isModel and obj:GetPivot().Position or obj.Position
	local dir = targetPos - pos
	if dir.Magnitude < 1e-4 then
		dir = Vector3.new(0, 0, 1)
	end
	rec.vel = dir.Unit * CONFIG.shootSpeed
	rec.life = CONFIG.projectileLife
	state.projectiles[#state.projectiles + 1] = rec
end

local function shoot()
	local _, hrp = getCharacter()
	if not hrp then return end
	if #state.list == 0 then
		notify("Ei ammuttavia objekteja.")
		return
	end

	local targetPos
	local hit = Mouse.Hit
	if hit then
		targetPos = hit.Position
	else
		targetPos = hrp.Position + hrp.CFrame.LookVector * 100
	end

	-- Siirrä kaikki kiertoradalta ammuksiin.
	local list = state.list
	for i = #list, 1, -1 do
		local rec = list[i]
		state.index[rec.obj] = nil
		table.remove(list, i)
		launch(rec, targetPos)
	end
	notify("Ammuttu!")
end

local function damageIfHit(pos)
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LocalPlayer and p.Character then
			local h = p.Character:FindFirstChildOfClass("Humanoid")
			local r = p.Character:FindFirstChild("HumanoidRootPart")
			if h and r and (r.Position - pos).Magnitude < 4 then
				pcall(function() h:TakeDamage(CONFIG.damage) end)
				return true
			end
		end
	end
	return false
end

local function updateProjectiles(dt)
	local list = state.projectiles
	for i = #list, 1, -1 do
		local rec = list[i]
		local obj = rec.obj
		if not obj or not obj.Parent then
			table.remove(list, i)
		else
			rec.life = rec.life - dt
			local cur = rec.isModel and obj:GetPivot().Position or obj.Position
			local nextPos = cur + rec.vel * dt

			local rot = rec.isModel and obj:GetPivot().Rotation or obj.CFrame.Rotation
			local cf = CFrame.new(nextPos) * rot
			if rec.isModel then
				obj:PivotTo(cf)
			else
				obj.CFrame = cf
				if not rec.anchored then
					obj.AssemblyLinearVelocity = Vector3.zero
				end
			end

			damageIfHit(nextPos)

			if rec.life <= 0 then
				table.remove(list, i)
				if CONFIG.returnAfterShot then
					-- Palauta kiertoradalle.
					state.index[obj] = rec
					state.list[#state.list + 1] = rec
				end
			end
		end
	end
end

-- ═══════════════════════════════════════════════════════════════════════
--  Työkalu
-- ═══════════════════════════════════════════════════════════════════════

local function createTool()
	local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
	if not backpack then return nil end

	local tool = Instance.new("Tool")
	tool.Name = "Shoot Orbiter"
	tool.RequiresHandle = true
	tool.CanBeDropped = false

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.5, 0.5, 0.5)
	handle.Transparency = 1
	handle.CanCollide = false
	handle.Massless = true
	handle.Parent = tool

	tool.Activated:Connect(shoot)
	tool.Parent = backpack
	return tool
end

-- ═══════════════════════════════════════════════════════════════════════
--  Elinkaari
-- ═══════════════════════════════════════════════════════════════════════

local function releaseAll(zeroVelocity)
	for i = #state.list, 1, -1 do
		release(state.list[i], zeroVelocity)
	end
	state.list = {}
	state.index = {}
	state.projectiles = {}
end

local function onHeartbeat(dt)
	if not state.running then return end

	if state.collecting then
		state.scanClock = state.scanClock + dt
		if state.scanClock >= CONFIG.scanInterval then
			state.scanClock = 0
			scan()
		end
	end

	updateOrbit(dt)
	updateProjectiles(dt)
end

local function toggleCollecting()
	state.collecting = not state.collecting
	notify(state.collecting and "Keräys: PÄÄLLÄ" or "Keräys: POIS")
end

function GENV.NN_Unload()
	if not state.running then return end
	state.running = false

	for _, c in ipairs(state.connections) do
		pcall(function() c:Disconnect() end)
	end
	state.connections = {}

	releaseAll(true)
	if state.tool then
		pcall(function() state.tool:Destroy() end)
		state.tool = nil
	end

	GENV.NN = nil
	print("[NN] Sammutettu ja siivottu.")
end

-- ═══════════════════════════════════════════════════════════════════════
--  Käynnistys
-- ═══════════════════════════════════════════════════════════════════════

-- Estä tuplakäynnistys (esim. NN_Load uudelleenlatauksen yhteydessä).
if GENV.NN and GENV.NN.running then
	GENV.NN_Unload()
end

state.running = true
state.tool = createTool()

state.connections[#state.connections + 1] = RunService.Heartbeat:Connect(onHeartbeat)

state.connections[#state.connections + 1] = LocalPlayer.CharacterRemoving:Connect(function()
	releaseAll(true)
end)

state.connections[#state.connections + 1] = UserInput.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.KeyCode == CONFIG.toggleKey then
		toggleCollecting()
	end
end)

GENV.NN = {
	config  = CONFIG,
	state   = state,
	running = true,
	shoot   = shoot,
	toggle  = toggleCollecting,
	unload  = GENV.NN_Unload,
}

print("[NN] Orbiter v2.0 ladattu. 'Shoot Orbiter' repussa – klikkaa ampuaksesi, "
	.. tostring(CONFIG.toggleKey.Name) .. " vaihtaaksesi keräyksen.")
notify("Ladattu! Klikkaa ampuaksesi (" .. tostring(CONFIG.toggleKey.Name) .. " = keräys)")
