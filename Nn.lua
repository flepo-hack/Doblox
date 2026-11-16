--[[
	═══════════════════════════════════════════════════════════════════════
	  NN ORBITER  ·  v3.0   (network-ownership versio)
	───────────────────────────────────────────────────────────────────────
	  Ei poista mitään näkyvistä. Ei reparentointia. Ei feikki-/placebo-
	  vahinkoa. Kaikki tapahtuu oikealla fysiikalla ja replikoituu muille.

	  Toiminta:
	    1. Ottaa NETWORK OWNERSHIPIN kartalta irrallaan oleviin esineisiin
	       (SetNetworkOwner) → esine alkaa totella sinun clienttiäsi.
	    2. Pyörittää ne sinun ympärilläsi (CFrame joka frame; omistajana
	       clientti, joten muut näkevät saman).
	    3. Kun klikkaat (puhelimen näyttö / hiiri), heittää ne kohti maalia.
	    4. Kun heitetty esine osuu johonkin, se kerätään TAKAISIN
	       kiertoradalle (ei jää lojumaan).

	  Ei uudelleenvanhempaa: osat pysyvät alkuperäisessä paikassaan
	  hierarkiassa, joten ne EIVÄT katoa näkyvistä. Vain CFrame liikkuu.

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

local LocalPlayer = Players.LocalPlayer
local Mouse       = LocalPlayer:GetMouse()

local CONFIG = {
	radius         = 32,    -- kuinka kaukaa esineitä napataan
	minDistance    = 4,     -- ei napata aivan ihossa kiinni olevia
	orbitRadius    = 9,     -- kiertoradan säde
	orbitHeight    = 4,     -- korkeus pelaajan yläpuolella
	orbitSpeed     = 1.6,   -- rad/s
	maxObjects     = 24,    -- montako yhtä aikaa kiertoradalla
	scanInterval   = 0.2,   -- s skannausväli
	throwSpeed     = 150,   -- studs/s heitossa
	throwGravity   = 90,    -- keinotekoinen painovoima heitolle
	recallRadius   = 3.5,   -- osumaetäisyys, jolla esine kerätään takaisin
	allowAnchored  = true,  -- nappaa myös ankkuroidut osat
	maxPartSize    = 30,    -- ohita suuremmat (baseplate/maa)
	maxModelParts  = 40,    -- ohita isot mallit
	collectPlayers = false, -- nappaa myös muiden hahmot
	toggleKey      = Enum.KeyCode.RightShift,
}

local state = {
	running     = false,
	collecting  = true,
	list        = {},   -- { { obj=Instance, isModel=bool, anchored=bool } }
	index       = {},   -- [instance] = record
	thrown      = {},   -- lentävät esineet
	angle       = 0,
	scanClock   = 0,
	connections = {},
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

-- Palauttaa objektin hallinnan pelille (network ownership takaisin automaattiseksi).
local function giveBackOwnership(rec)
	local obj = rec.obj
	if rec.anchored or not obj or not obj.Parent then return end
	pcall(function()
		if rec.isModel then
			obj:SetNetworkOwnershipAuto()
		else
			obj:SetNetworkOwner(nil)
		end
	end)
end

-- Ottaa network ownershipin itselle (client).
local function takeOwnership(rec)
	local obj = rec.obj
	if rec.anchored or not obj or not obj.Parent then return end
	pcall(function()
		if rec.isModel then
			obj:SetNetworkOwner(LocalPlayer)
		else
			obj:SetNetworkOwner(LocalPlayer)
		end
	end)
end

local function releaseRecord(rec, restore)
	if restore then giveBackOwnership(rec) end
	state.index[rec.obj] = nil
	for i = #state.list, 1, -1 do
		if state.list[i] == rec then
			table.remove(state.list, i)
			break
		end
	end
end

-- ═══════════════════════════════════════════════════════════════════════
--  Keräys (network ownership otetaan heti nappauksessa)
-- ═══════════════════════════════════════════════════════════════════════

local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Exclude or Enum.RaycastFilterType.Blacklist
overlap.MaxParts = 400

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

local function isCollectable(part, char, origin)
	if typeof(part) ~= "Instance" or not part:IsA("BasePart") then return false end
	if part:IsDescendantOf(char) then return false end
	if state.index[part] then return false end
	if part:FindFirstAncestorOfClass("Humanoid") and not CONFIG.collectPlayers then return false end

	local model = part:FindFirstAncestorOfClass("Model")
	if model and state.index[model] then return false end

	local size = part.Size
	if math.max(size.X, size.Y, size.Z) > CONFIG.maxPartSize then return false end
	if not CONFIG.allowAnchored and part.Anchored then return false end

	local d = (part.Position - origin).Magnitude
	if d < CONFIG.minDistance or d > CONFIG.radius then return false end
	return true
end

local function register(part)
	local group = groupOf(part)
	if state.index[group] then return nil end

	local rec = {
		obj      = group,
		isModel  = group:IsA("Model"),
		anchored = part.Anchored,
	}
	if rec.isModel then
		rec.anchored = true
		for _, c in ipairs(group:GetDescendants()) do
			if c:IsA("BasePart") and not c.Anchored then
				rec.anchored = false
				break
			end
		end
	end

	takeOwnership(rec)
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

local function setCFrame(rec, cf)
	if rec.isModel then
		rec.obj:PivotTo(cf)
	else
		rec.obj.CFrame = cf
	end
end

local function getPos(rec)
	return rec.isModel and rec.obj:GetPivot().Position or rec.obj.Position
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

	-- Käännetty järjestys: releaseRecord voi poistaa alkion kesken silmukan.
	for i = n, 1, -1 do
		local rec = list[i]
		local obj = rec.obj
		if not obj or not obj.Parent then
			releaseRecord(rec, false)
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
--  Heitto & takaisinkeräys
-- ═══════════════════════════════════════════════════════════════════════

local function throwAll()
	local _, hrp = getCharacter()
	if not hrp then return end
	if #state.list == 0 then
		notify("Ei heitettäviä esineitä.")
		return
	end

	local hit = Mouse.Hit
	local target = hit and hit.Position or (hrp.Position + hrp.CFrame.LookVector * 120)

	local list = state.list
	for i = #list, 1, -1 do
		local rec = list[i]
		state.index[rec.obj] = nil
		table.remove(list, i)

		local pos = getPos(rec)
		local dir = target - pos
		if dir.Magnitude < 1e-3 then
			dir = hrp.CFrame.LookVector
		end
		rec.vel = dir.Unit * CONFIG.throwSpeed
		rec.spin = Vector3.new(
			(math.random() - 0.5) * 12,
			(math.random() - 0.5) * 12,
			(math.random() - 0.5) * 12
		)
		rec.rot = (rec.isModel and rec.obj:GetPivot().Rotation or rec.obj.CFrame.Rotation)
		state.thrown[#state.thrown + 1] = rec
	end
	notify("Heitetty!")
end

-- Etsii lähimmän osumakohteen (muut pelaajat) heitetyn esineen ympäriltä.
local function findHit(pos)
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LocalPlayer and p.Character then
			local r = p.Character:FindFirstChild("HumanoidRootPart")
			local h = p.Character:FindFirstChildOfClass("Humanoid")
			if r and h and h.Health > 0 and (r.Position - pos).Magnitude < CONFIG.recallRadius then
				return p
			end
		end
	end
	return nil
end

-- Palauttaa heitetyn esineen kiertoradalle (rekisteröi uudelleen + ownership).
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
			-- Painovoima + liike
			rec.vel = rec.vel - Vector3.new(0, CONFIG.throwGravity * dt, 0)
			local pos = getPos(rec) + rec.vel * dt

			rec.rot = rec.rot * CFrame.Angles(rec.spin.X * dt, rec.spin.Y * dt, rec.spin.Z * dt)
			setCFrame(rec, CFrame.new(pos) * rec.rot)

			local hitPlayer = findHit(pos)
			if hitPlayer then
				-- Kerää takaisin kiertoradalle osuman jälkeen.
				table.remove(list, i)
				recall(rec)
			else
				-- Kerää takaisin myös jos palasi lähelle pelaajaa (ei jää kauas).
				local _, hrp = getCharacter()
				if hrp and (hrp.Position - pos).Magnitude < CONFIG.orbitRadius + 2 then
					table.remove(list, i)
					recall(rec)
				end
			end
		end
	end
end

-- ═══════════════════════════════════════════════════════════════════════
--  Elinkaari
-- ═══════════════════════════════════════════════════════════════════════

local function releaseAll()
	for i = #state.list, 1, -1 do
		giveBackOwnership(state.list[i])
	end
	for i = #state.thrown, 1, -1 do
		giveBackOwnership(state.thrown[i])
	end
	state.list = {}
	state.index = {}
	state.thrown = {}
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
	updateThrown(dt)
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

	releaseAll()
	GENV.NN = nil
	print("[NN] Sammutettu – network ownership palautettu pelille.")
end

-- ═══════════════════════════════════════════════════════════════════════
--  Syöte: klikkaus (puhelin = touch, PC = hiiri)
-- ═══════════════════════════════════════════════════════════════════════

local function onInputBegan(input, gpe)
	if gpe then return end
	if input.UserInputType == Enum.UserInputType.Touch
		or input.UserInputType == Enum.UserInputType.MouseButton1 then
		throwAll()
	elseif input.KeyCode == CONFIG.toggleKey then
		toggleCollecting()
	end
end

-- ═══════════════════════════════════════════════════════════════════════
--  Käynnistys
-- ═══════════════════════════════════════════════════════════════════════

if GENV.NN and GENV.NN.running then
	GENV.NN_Unload()
end

state.running = true
state.connections[#state.connections + 1] = RunService.Heartbeat:Connect(onHeartbeat)
state.connections[#state.connections + 1] = UserInput.InputBegan:Connect(onInputBegan)
state.connections[#state.connections + 1] = LocalPlayer.CharacterRemoving:Connect(function()
	releaseAll()
end)

GENV.NN = {
	config  = CONFIG,
	state   = state,
	running = true,
	throw   = throwAll,
	toggle  = toggleCollecting,
	unload  = GENV.NN_Unload,
}

print("[NN] Orbiter v3.0 (network ownership) ladattu. Klikkaa / napauta heittääksesi, "
	.. tostring(CONFIG.toggleKey.Name) .. " = keräys.")
notify("Ladattu! Klikkaa heittääksesi.")
