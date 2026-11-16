--[[
	═══════════════════════════════════════════════════════════════════════
	  NN ORBITER  ·  v4.0   (network-ownership + fly + noclip)
	───────────────────────────────────────────────────────────────────────
	  Ei feikkiä, ei placebota, ei reparentointia.

	  Toiminta:
	    · Nappaa VAIN PIENIÄ irtonaisia esineitä (oletus max koko 4 studsia)
	      → ei ota mitään mikä vaikuttaa sinuun (isot osat/rakenteet ohitetaan).
	    · Enintään 5 esinettä kiertoradalla.
	    · Kun klikkaat / napautat:
	        – orbittaus PYSÄHTYY heti.
	        – esineet lähtevät JONOSSA: eka ensin, sitten toka, kolmas…
	        – koko heitto kestää ~3 s (peräkkäiset lähdöt).
	    · Kun heitetty esine osuu johonkin, se FLINGAA kohteen
	      (AssemblyLinearVelocity + AssemblyAngularVelocity → oikea fysiikka,
	      replikoituu koska omistat verkkoliikenteen).
	    · FLY (lentäminen) ja NOCLIP (ei törmäyksiä).
	    · Mobiilissa näytölle tulee napit.

	  Optimointi: GetPartBoundsInRadius (ei koko Workspace), rajoitettu
	  skannaus, O(1)-indeksi, ei Instance-luontia per frame.
	═══════════════════════════════════════════════════════════════════════
]]

-- ═══════════════════════════════════════════════════════════════════════
--  LOADSTRING-LATURI
--      loadstring(game:HttpGet("https://raw.githubusercontent.com/flepo-hack/Doblox/main/Nn.lua"))()
--  API (executorin getgenv):
--      getgenv().NN_Load([url])   -- lataa & suorita
--      getgenv().NN_Unload()      -- sammuttaa, palauttaa omistajuuden
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
--  Palvelut & asetukset
-- ═══════════════════════════════════════════════════════════════════════

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace  = game:GetService("Workspace")
local UserInput  = game:GetService("UserInputService")
local StarterGui = game:GetService("StarterGui")
local Lighting   = game:GetService("Lighting")

local LocalPlayer = Players.LocalPlayer
local Mouse       = LocalPlayer:GetMouse()
local Camera      = Workspace.CurrentCamera

local CONFIG = {
	-- Keräys: VAIN pieniä esineitä, max 5
	radius        = 34,    -- kuinka kaukaa napataan
	minDistance   = 3,     -- ei aivan ihossa kiinni
	maxSmallSize  = 4,     -- PIENI = suurin sivu <= 4 studsia
	maxObjects    = 5,     -- MAX 5 kiertoradalla
	scanInterval  = 0.25,

	-- Kierto
	orbitRadius   = 8,
	orbitHeight   = 3,
	orbitSpeed    = 1.8,

	-- Heitto (jono, ~3 s kokonaiskesto)
	throwTotalTime = 3.0,  -- koko heiton kesto sekunteina
	throwSpeed     = 130,  -- studs/s
	throwGravity   = 90,   -- keinotekoinen painovoima
	throwLife      = 3.0,  -- kuinka kauan esine lentää ennen vapautusta

	-- Fling
	flingPower     = 260,
	flingSpin      = 45,
	hitRadius      = 4,    -- osumaetäisyys

	-- Fly
	flySpeed       = 60,
	flyLift        = 60,

	-- Näppäimet
	keyThrow       = Enum.KeyCode.F,
	keyToggle      = Enum.KeyCode.RightShift,
	keyFly         = Enum.KeyCode.E,
	keyNoclip      = Enum.KeyCode.N,
}

local state = {
	running     = false,
	collecting  = true,
	list        = {},     -- { rec }  (kiertoradalla)
	index       = {},     -- [instance] = rec
	queue       = {},     -- heittojono (odottaa vuoroaan)
	thrown      = {},     -- ilmassa olevat
	angle       = 0,
	scanClock   = 0,
	throwing    = false,
	throwClock  = 0,
	connections = {},
	gui         = nil,

	fly        = false,
	noclip     = false,
	flyVel     = Vector3.zero,
	flyConn    = nil,
}

-- ═══════════════════════════════════════════════════════════════════════
--  Apurit
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
		StarterGui:SetCore("SendNotification", { Title = "NN Orbiter", Text = text, Duration = 2.5 })
	end)
end

local function takeOwnership(rec)
	local obj = rec.obj
	if rec.anchored or not obj or not obj.Parent then return end
	pcall(function() obj:SetNetworkOwner(LocalPlayer) end)
end

local function giveBackOwnership(rec)
	local obj = rec.obj
	if rec.anchored or not obj or not obj.Parent then return end
	pcall(function()
		if rec.isModel then obj:SetNetworkOwnershipAuto() else obj:SetNetworkOwner(nil) end
	end)
end

local function unindex(rec)
	state.index[rec.obj] = nil
end

local function removeFromList(rec)
	for i = #state.list, 1, -1 do
		if state.list[i] == rec then
			table.remove(state.list, i)
			return
		end
	end
end

local function setCFrame(rec, cf)
	if rec.isModel then rec.obj:PivotTo(cf) else rec.obj.CFrame = cf end
end

local function getPos(rec)
	return rec.isModel and rec.obj:GetPivot().Position or rec.obj.Position
end

-- ═══════════════════════════════════════════════════════════════════════
--  Keräys: vain pienet esineet, max 5
-- ═══════════════════════════════════════════════════════════════════════

local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Exclude or Enum.RaycastFilterType.Blacklist
overlap.MaxParts = 400

local function isSmallLoose(part)
	if typeof(part) ~= "Instance" or not part:IsA("BasePart") then return false end
	if part.Anchored then return false end
	local s = part.Size
	if math.max(s.X, s.Y, s.Z) > CONFIG.maxSmallSize then return false end
	return true
end

local function isCollectable(part, char, origin)
	if not isSmallLoose(part) then return false end
	if part:IsDescendantOf(char) then return false end
	if state.index[part] then return false end
	if part:FindFirstAncestorOfClass("Humanoid") then return false end

	-- Älä ota pelaajien hahmojen osia äläkä aseita (Tool).
	local model = part:FindFirstAncestorOfClass("Model")
	if model and state.index[model] then return false end
	if part:FindFirstAncestorWhichIsA("Tool") then return false end

	local d = (part.Position - origin).Magnitude
	if d < CONFIG.minDistance or d > CONFIG.radius then return false end
	return true
end

local function register(part)
	if state.index[part] then return nil end
	local rec = { obj = part, isModel = false, anchored = false }
	takeOwnership(rec)
	state.index[part] = rec
	state.list[#state.list + 1] = rec
	return rec
end

local function scan()
	local char, hrp = getCharacter()
	if not hrp then return end

	local origin = hrp.Position
	overlap.FilterDescendantsInstances = { char }

	local parts = Workspace.GetPartBoundsInRadius
		and Workspace:GetPartBoundsInRadius(origin, CONFIG.radius, overlap)
		or Workspace:GetDescendants()

	local budget = CONFIG.maxObjects - #state.list
	if budget <= 0 then return end

	-- Lajittele lähimmät ensin, jotta otetaan oikeat "pienet asiat".
	table.sort(parts, function(a, b)
		return (a.Position - origin).Magnitude < (b.Position - origin).Magnitude
	end)

	for _, part in ipairs(parts) do
		if budget <= 0 then break end
		if isCollectable(part, char, origin) then
			if register(part) then budget = budget - 1 end
		end
	end
end

-- ═══════════════════════════════════════════════════════════════════════
--  Kierto (pysähtyy heiton ajaksi)
-- ═══════════════════════════════════════════════════════════════════════

local function updateOrbit(dt)
	if state.throwing then return end  -- orbittaus pysähtyy heitossa
	local _, hrp = getCharacter()
	if not hrp then return end

	state.angle = state.angle + CONFIG.orbitSpeed * dt

	local list = state.list
	local n = #list
	if n == 0 then return end
	local step = (2 * math.pi) / n
	local center = hrp.Position

	for i = n, 1, -1 do
		local rec = list[i]
		if not rec.obj or not rec.obj.Parent then
			unindex(rec); removeFromList(rec)
		else
			local a = state.angle + (i - 1) * step
			local target = Vector3.new(
				center.X + CONFIG.orbitRadius * math.cos(a),
				center.Y + CONFIG.orbitHeight,
				center.Z + CONFIG.orbitRadius * math.sin(a)
			)
			setCFrame(rec, CFrame.lookAt(target, center))
		end
	end
end

-- ═══════════════════════════════════════════════════════════════════════
--  Heitto jonossa
-- ═══════════════════════════════════════════════════════════════════════

local function throwStart()
	if state.throwing or #state.list == 0 then
		if #state.list == 0 then notify("Ei heitettäviä esineitä.") end
		return
	end
	state.throwing = true
	state.throwClock = 0
	state._started = 0
	state.queue = {}
	-- Jono: indeksi 1 lähtee ensin (state.list on järjestyksessä).
	for i = 1, #state.list do
		state.queue[#state.queue + 1] = state.list[i]
	end
	state._total = #state.queue
	state.list = {}
	notify("Heitto alkaa…")
end

local function throwRelease(rec)
	local _, hrp = getCharacter()
	local pos = getPos(rec)
	local target
	local hit = Mouse.Hit
	if hit then
		target = hit.Position
	elseif hrp then
		target = hrp.Position + hrp.CFrame.LookVector * 120
	else
		target = pos + Vector3.new(0, 0, 100)
	end
	local dir = target - pos
	if dir.Magnitude < 1e-3 then dir = Vector3.new(0, 0, 1) end
	rec.vel = dir.Unit * CONFIG.throwSpeed
	rec.life = CONFIG.throwLife
	rec.rot = (rec.isModel and rec.obj:GetPivot().Rotation or rec.obj.CFrame.Rotation)
	rec.spin = Vector3.new(
		(math.random() - 0.5) * 10,
		(math.random() - 0.5) * 10,
		(math.random() - 0.5) * 10
	)
	state.thrown[#state.thrown + 1] = rec
end

local function updateThrowQueue(dt)
	if not state.throwing then return end
	state.throwClock = state.throwClock + dt

	local q = state.queue
	local n = #q
	if n == 0 then
		state.throwing = false
		state._started = 0
		return
	end

	-- Lähtöajat: eka heti (t=0), viimeinen ~ throwTotalTime kohdalla.
	local total = state._total or n
	local spacing = total > 1 and (CONFIG.throwTotalTime / (total - 1)) or 0
	local due = state._started * spacing

	while #q > 0 and state.throwClock >= due do
		local rec = table.remove(q, 1)
		state._started = state._started + 1
		throwRelease(rec)
		due = state._started * spacing
	end

	if #q == 0 then
		state.throwing = false
		state._started = 0
	end
end

-- ═══════════════════════════════════════════════════════════════════════
--  Fling: osuma sinkoaa kohteen
-- ═══════════════════════════════════════════════════════════════════════

local function flingTarget(root)
	local pos = getPos({ obj = root, isModel = false })
	local dir
	local _, hrp = getCharacter()
	if hrp then
		dir = (pos - hrp.Position)
	else
		dir = Vector3.new(0, 0, 1)
	end
	if dir.Magnitude < 1e-3 then dir = Vector3.new(0, 0, 1) end
	dir = dir.Unit

	pcall(function()
		root.AssemblyLinearVelocity = dir * CONFIG.flingPower + Vector3.new(0, CONFIG.flingPower * 0.5, 0)
		root.AssemblyAngularVelocity = Vector3.new(
			(math.random() - 0.5) * CONFIG.flingSpin,
			(math.random() - 0.5) * CONFIG.flingSpin,
			(math.random() - 0.5) * CONFIG.flingSpin
		)
	end)
end

local function findHitPlayer(pos)
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LocalPlayer and p.Character then
			local root = p.Character:FindFirstChild("HumanoidRootPart")
			local h = p.Character:FindFirstChildOfClass("Humanoid")
			if root and h and h.Health > 0 and (root.Position - pos).Magnitude < CONFIG.hitRadius then
				return root
			end
		end
	end
	return nil
end

local function recall(rec)
	if not rec.obj or not rec.obj.Parent then return end
	if #state.list >= CONFIG.maxObjects then
		giveBackOwnership(rec)
		return
	end
	takeOwnership(rec)
	state.index[rec.obj] = rec
	state.list[#state.list + 1] = rec
end

local function updateThrown(dt)
	local list = state.thrown
	for i = #list, 1, -1 do
		local rec = list[i]
		local obj = rec.obj
		if not obj or not obj.Parent then
			table.remove(list, i)
		else
			rec.vel = rec.vel - Vector3.new(0, CONFIG.throwGravity * dt, 0)
			local pos = getPos(rec) + rec.vel * dt
			rec.rot = rec.rot * CFrame.Angles(rec.spin.X * dt, rec.spin.Y * dt, rec.spin.Z * dt)
			setCFrame(rec, CFrame.new(pos) * rec.rot)

			local root = findHitPlayer(pos)
			if root then
				flingTarget(root)
				table.remove(list, i)
				recall(rec)
			else
				rec.life = rec.life - dt
				if rec.life <= 0 then
					-- Ei osunut: vapauta hallinta, jotta ei jää ikuisesti lentämään.
					table.remove(list, i)
					giveBackOwnership(rec)
				end
			end
		end
	end
end

-- ═══════════════════════════════════════════════════════════════════════
--  FLY
-- ═══════════════════════════════════════════════════════════════════════

local function flyStep(dt)
	local _, hrp = getCharacter()
	if not hrp then return end
	local cam = Camera.CFrame
	local move = Vector3.zero
	local up = Vector3.new(0, 1, 0)

	-- WASD / kosketusohjain (Humanoid.MoveDirection) suhteessa kameraan
	local h = LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
	local md = h and h.MoveDirection or Vector3.zero
	if md.Magnitude > 0 then
		move = move + (cam.LookVector * md.Z + cam.RightVector * md.X)
	end

	-- Nuolinäppäimet / nousu-lasku
	if UserInput:IsKeyDown(Enum.KeyCode.Space) then move = move + up end
	if UserInput:IsKeyDown(Enum.KeyCode.LeftControl) then move = move - up end

	if move.Magnitude > 1e-3 then
		move = move.Unit * CONFIG.flySpeed
	else
		move = Vector3.zero
	end

	-- Pehmeä kiihdytys
	state.flyVel = state.flyVel + (move - state.flyVel) * math.min(dt * 8, 1)
	-- Kanna ylhäällä: pieni nosto, jotta ei valu alas.
	hrp.AssemblyLinearVelocity = state.flyVel + up * (CONFIG.flyLift * 0.15)
end

local function setFly(on)
	local char = getCharacter()
	if on then
		if not char then notify("Ei hahmoa.") return end
		state.fly = true
		state.flyVel = Vector3.zero
		local h = char:FindFirstChildOfClass("Humanoid")
		if h then pcall(function() h.PlatformStand = true end) end
		if not state.flyConn then
			state.flyConn = RunService.Heartbeat:Connect(flyStep)
		end
		notify("Fly: PÄÄLLÄ (Space ylös, Ctrl alas)")
	else
		state.fly = false
		if state.flyConn then state.flyConn:Disconnect(); state.flyConn = nil end
		local h = char and char:FindFirstChildOfClass("Humanoid")
		if h then pcall(function() h.PlatformStand = false end) end
		notify("Fly: POIS")
	end
end

-- ═══════════════════════════════════════════════════════════════════════
--  NOCLIP
-- ═══════════════════════════════════════════════════════════════════════

local function applyNoclip()
	local char = getCharacter()
	if not char then return end
	for _, d in ipairs(char:GetDescendants()) do
		if d:IsA("BasePart") and d.CanCollide then
			d.CanCollide = false
			d:SetAttribute("NN_Noclip", true)
		end
	end
end

local function restoreNoclip()
	local char = getCharacter()
	if not char then return end
	for _, d in ipairs(char:GetDescendants()) do
		if d:IsA("BasePart") and d:GetAttribute("NN_Noclip") then
			d.CanCollide = true
			d:SetAttribute("NN_Noclip", nil)
		end
	end
end

local function setNoclip(on)
	state.noclip = on
	if on then
		applyNoclip()
		notify("Noclip: PÄÄLLÄ")
	else
		restoreNoclip()
		notify("Noclip: POIS")
	end
end

-- ═══════════════════════════════════════════════════════════════════════
--  Mobiilinapit (kosketusnäyttö)
-- ═══════════════════════════════════════════════════════════════════════

local function makeButton(text, y, onTap)
	local gui = state.gui
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(0, 110, 0, 46)
	btn.Position = UDim2.new(0, 16, 0, y)
	btn.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	btn.BackgroundTransparency = 0.35
	btn.TextColor3 = Color3.fromRGB(255, 255, 255)
	btn.TextScaled = true
	btn.Text = text
	btn.Font = Enum.Font.GothamBold
	btn.Parent = gui
	btn.MouseButton1Click:Connect(onTap)
	btn.TouchTap:Connect(onTap)
	return btn
end

local function buildGui()
	local gui = Instance.new("ScreenGui")
	gui.Name = "NN_Orbiter"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
	state.gui = gui

	makeButton("THROW", 100, throwStart)
	makeButton("FLY", 156, function() setFly(not state.fly) end)
	makeButton("NOCLIP", 212, function() setNoclip(not state.noclip) end)
end

-- ═══════════════════════════════════════════════════════════════════════
--  Elinkaari
-- ═══════════════════════════════════════════════════════════════════════

local function releaseAll()
	for i = #state.list, 1, -1 do giveBackOwnership(state.list[i]) end
	for i = #state.queue, 1, -1 do giveBackOwnership(state.queue[i]) end
	for i = #state.thrown, 1, -1 do giveBackOwnership(state.thrown[i]) end
	state.list, state.index, state.queue, state.thrown = {}, {}, {}, {}
	state.throwing = false
	state._started = 0
end

local function onHeartbeat(dt)
	if not state.running then return end

	if state.collecting and not state.throwing then
		state.scanClock = state.scanClock + dt
		if state.scanClock >= CONFIG.scanInterval then
			state.scanClock = 0
			scan()
		end
	end

	updateOrbit(dt)
	updateThrowQueue(dt)
	updateThrown(dt)

	if state.noclip then applyNoclip() end
end

local function onInputBegan(input, gpe)
	if gpe then return end
	if input.UserInputType == Enum.UserInputType.Touch
		or input.UserInputType == Enum.UserInputType.MouseButton1 then
		throwStart()
	elseif input.KeyCode == CONFIG.keyThrow then
		throwStart()
	elseif input.KeyCode == CONFIG.keyToggle then
		state.collecting = not state.collecting
		notify(state.collecting and "Keräys: PÄÄLLÄ" or "Keräys: POIS")
	elseif input.KeyCode == CONFIG.keyFly then
		setFly(not state.fly)
	elseif input.KeyCode == CONFIG.keyNoclip then
		setNoclip(not state.noclip)
	end
end

function GENV.NN_Unload()
	if not state.running then return end
	state.running = false

	for _, c in ipairs(state.connections) do
		pcall(function() c:Disconnect() end)
	end
	state.connections = {}

	if state.flyConn then pcall(function() state.flyConn:Disconnect() end); state.flyConn = nil end
	if state.fly then setFly(false) end
	if state.noclip then setNoclip(false) end

	releaseAll()
	if state.gui then pcall(function() state.gui:Destroy() end); state.gui = nil end

	GENV.NN = nil
	print("[NN] Sammutettu – network ownership palautettu pelille.")
end

-- ═══════════════════════════════════════════════════════════════════════
--  Käynnistys
-- ═══════════════════════════════════════════════════════════════════════

if GENV.NN and GENV.NN.running then GENV.NN_Unload() end

state.running = true
state.connections[#state.connections + 1] = RunService.Heartbeat:Connect(onHeartbeat)
state.connections[#state.connections + 1] = UserInput.InputBegan:Connect(onInputBegan)
state.connections[#state.connections + 1] = LocalPlayer.CharacterRemoving:Connect(function()
	releaseAll()
end)

pcall(buildGui)

GENV.NN = {
	config  = CONFIG,
	state   = state,
	running = true,
	throw   = throwStart,
	fly     = function(v) setFly(v == nil and not state.fly or v) end,
	noclip  = function(v) setNoclip(v == nil and not state.noclip or v) end,
	unload  = GENV.NN_Unload,
}

print("[NN] Orbiter v4.0 ladattu. THROW/F-kirjain = heitä, E = fly, N = noclip, "
	.. tostring(CONFIG.keyToggle.Name) .. " = keräys.")
notify("Ladattu! Pienet esineet (max 5) kiertävät – klikkaa heittääksesi.")
