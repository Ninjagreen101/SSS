--!nocheck
-- Edit-time polish for the existing Lowharbor floor. No runtime scripts are installed.
-- Run on a fresh clone of this ModuleScript: require(clone).Apply().
-- Undo restores journaled properties and removes only this pass's additions.
local Polish = {}
local SS = game:GetService("ServerStorage")
local terrain = workspace.Terrain
local palette = {
    stone = Color3.fromHex("65706B"), dark = Color3.fromHex("343F40"),
    brass = Color3.fromHex("A28C57"), teal = Color3.fromHex("3FE0D0"),
    wood = Color3.fromHex("493F33"), cloth = Color3.fromHex("244D50"),
}
local function ground(x, z)
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Include
    rp.FilterDescendantsInstances = {terrain}
    rp.IgnoreWater = true
    return workspace:Raycast(Vector3.new(x, 500, z), Vector3.new(0, -800, 0), rp)
end
local function part(parent, name, size, cf, material, color, collide)
    local p = Instance.new("Part")
    p.Name, p.Size, p.CFrame = name, size, cf
    p.Anchored, p.CanCollide = true, collide == true
    p.CanTouch, p.CanQuery, p.CastShadow = false, collide == true, collide == true
    p.Material, p.Color = material or Enum.Material.Slate, color or palette.stone
    p.TopSurface, p.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
    p.Parent = parent
    return p
end
local function save(journal, obj, prop, value)
    local entry = Instance.new("ObjectValue")
    entry.Name, entry.Value = prop, obj
    entry:SetAttribute("Before", obj[prop])
    entry:SetAttribute("After", value)
    entry.Parent = journal
    obj[prop] = value
end
function Polish.Undo()
    local backup = SS:FindFirstChild("Floor1PolishJournal")
    if backup then
        for _,entry in backup:GetChildren() do
            if entry:IsA("ObjectValue") and entry.Value then
                -- Respect any subsequent edits made by another author.
                if entry.Value[entry.Name] == entry:GetAttribute("After") then
                    entry.Value[entry.Name] = entry:GetAttribute("Before")
                end
            end
        end
        backup:Destroy()
    end
    local f = workspace:FindFirstChild("Floor1")
    local additions = f and f:FindFirstChild("Polish")
    if additions then additions:Destroy() end
end
function Polish.Apply()
    assert(not game:GetService("RunService"):IsRunning(), "Apply in Edit mode")
    local floor = workspace:FindFirstChild("Floor1")
    assert(floor and floor:FindFirstChild("Waystones"), "Existing Lowharbor required")
    assert(not floor:FindFirstChild("Polish"), "Polish already applied; Undo before reapplying")
    local journal = Instance.new("Folder")
    journal.Name, journal.Parent = "Floor1PolishJournal", SS
    local root = Instance.new("Folder")
    root.Name, root.Parent = "Polish", floor
    root:SetAttribute("Version", 1)
    root:SetAttribute("Purpose", "Lowharbor route and landmark polish")
    local routes = Instance.new("Folder", root); routes.Name = "Routes"
    local rests = Instance.new("Folder", root); rests.Name = "RestAreas"
    local landmarks = Instance.new("Folder", root); landmarks.Name = "Landmarks"
    local L = require(SS.Tools.Layouts.Floor1)
    -- Smooth the join between kit stairs and voxel terrain. The original stair collider
    -- ends below the upper voxel lip, which trapped the playtest character at the Guild.
    for _,radius in {450,620,780,930} do
        local x=L.Bay.X+radius
        local a,b=ground(x-4,30),ground(x+44,30)
        if a and b then
            local va,vb=a.Position+Vector3.new(0,.16,0),b.Position+Vector3.new(0,.16,0)
            local cf=CFrame.lookAt((va+vb)/2,vb)
            -- Offset down half the slab thickness so its top meets both landings.
            part(routes,"AccessibleStairSurface",Vector3.new(6,.5,(vb-va).Magnitude),cf*CFrame.new(0,-.25,0),Enum.Material.Slate,palette.stone,true)
        end
    end
    local function sign(name, pos, target, title, detail)
        local hit = ground(pos.X, pos.Z)
        if not hit then return end
        local model = Instance.new("Model", landmarks); model.Name = name
        local base = Vector3.new(pos.X, hit.Position.Y, pos.Z)
        local cf = CFrame.lookAt(base, Vector3.new(target.X, base.Y, target.Z))
        part(model, "Post", Vector3.new(.6, 7, .6), cf*CFrame.new(0, 3.5, 0), Enum.Material.Wood, palette.wood)
        local board = part(model, "Board", Vector3.new(10, 3.8, .35), cf*CFrame.new(0, 6, 0), Enum.Material.Wood, palette.dark)
        for _,face in {Enum.NormalId.Front, Enum.NormalId.Back} do
            local gui = Instance.new("SurfaceGui", board)
            gui.Face, gui.CanvasSize = face, Vector2.new(640, 244)
            gui.AlwaysOnTop, gui.LightInfluence, gui.MaxDistance = false, .25, 90
            local text = Instance.new("TextLabel", gui)
            text.Size, text.BackgroundTransparency = UDim2.fromScale(1, 1), 1
            text.TextColor3, text.Font, text.TextSize = Color3.fromHex("E4DAC2"), Enum.Font.Garamond, 35
            text.Text = title.."\n"..detail
        end
        part(model, "Cap", Vector3.new(10.3, .22, .65), cf*CFrame.new(0, 8, 0), Enum.Material.Metal, palette.brass)
        model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
    end
    -- Paving follows the actual voxel surface, not the analytic terrain approximation.
    local paving = 0
    local function strip(name, points, width, spacing, color)
        for i = 1, #points-1 do
            local a, b = points[i], points[i+1]
            local delta = b-a
            local length = delta.Magnitude
            local steps = math.ceil(length/spacing)
            for n = 0, steps-1 do
                local pa, pb = a:Lerp(b,n/steps), a:Lerp(b,(n+1)/steps)
                local ha, hb = ground(pa.X,pa.Y), ground(pb.X,pb.Y)
                if ha and hb and math.abs(ha.Position.Y-hb.Position.Y) < (pb-pa).Magnitude*.65 then
                    local va, vb = ha.Position+Vector3.new(0,.11,0), hb.Position+Vector3.new(0,.11,0)
                    local mid = (va+vb)/2
                    local hc=ground(mid.X,mid.Z)
                    if hc and math.abs(mid.Y-hc.Position.Y)<.6 then
                        local tone=color:Lerp(palette.dark,(n%3)*.055)
                        part(routes, name, Vector3.new(width,.14,(vb-va).Magnitude-.18), CFrame.lookAt(mid,vb), Enum.Material.Slate, tone)
                        paving += 1
                    end
                end
            end
        end
    end
    -- A continuous centre ribbon ties the quay, Market and Guild together.
    strip("ClimbPaving", {Vector2.new(-730,30),Vector2.new(-40,30)}, 4.5, 8, palette.stone)
    for _,road in L.Roads do
        if road.Name == "EastRoad" or road.Name == "CisternSpur" then
            strip(road.Name.."Paving", road.Points, road.Name=="EastRoad" and 5 or 4, 10, palette.stone)
        end
        -- Sparse guide stones avoid turning the wilds into another paved town.
        if road.Name == "NorthRoad" or road.Name == "CoastRoad" or road.Name == "EastRoad" then
            for i=1,#road.Points-1 do
                local a,b=road.Points[i],road.Points[i+1]
                local d=(b-a).Unit;local side=Vector2.new(-d.Y,d.X)
                local count=math.ceil((b-a).Magnitude/85)
                for n=0,count-1 do
                    local v=a:Lerp(b,n/count)+side*(road.Width/2+2)
                    local h=ground(v.X,v.Y)
                    if h then
                        local pos=h.Position
                        part(routes,"Waymarker",Vector3.new(1.3,2.6,1.3),CFrame.new(pos+Vector3.new(0,1.3,0)),Enum.Material.Slate,palette.dark)
                        part(routes,"CurrentNotch",Vector3.new(1.35,.16,1.35),CFrame.new(pos+Vector3.new(0,2.3,0)),Enum.Material.Neon,palette.teal)
                    end
                end
            end
        end
    end
    local fixedSpawns=0
    for _,w in floor.Waystones:GetChildren() do
        local spawn=w:FindFirstChild("SpawnPoint")
        if spawn and spawn:IsA("BasePart") then
            local h=ground(spawn.Position.X,spawn.Position.Z)
            if h and spawn.Position.Y < h.Position.Y+.5 then
                save(journal,spawn,"CFrame",spawn.CFrame+Vector3.new(0,h.Position.Y+.5-spawn.Position.Y,0))
                fixedSpawns+=1
            end
        end
        -- Four low corner stones frame each checkpoint without enclosing its approach.
        local pos=w:GetPivot().Position
        local model=Instance.new("Model",rests);model.Name=w.Name.."Forecourt"
        for _,off in {Vector2.new(-11,-10),Vector2.new(11,-10),Vector2.new(-11,10),Vector2.new(11,10)} do
            local h=ground(pos.X+off.X,pos.Z+off.Y)
            if h then
                part(model,"CornerStone",Vector3.new(2,.5,2),CFrame.new(h.Position+Vector3.new(0,.25,0)),Enum.Material.Slate,palette.dark)
                part(model,"Inlay",Vector3.new(1.1,.07,1.1),CFrame.new(h.Position+Vector3.new(0,.54,0)),Enum.Material.Metal,palette.brass)
            end
        end
        model.ModelStreamingMode=Enum.ModelStreamingMode.Atomic
    end
    sign("Arrival",Vector3.new(-720,0,48),Vector3.new(-737,0,8),"LOWHARBOR", "Market & Guild — follow the Climb")
    sign("Market",Vector3.new(-578,0,49),Vector3.new(-620,0,30),"TIDEWATCH MARKET", "Provisions • Forge • Armoury • Bank")
    sign("EastRoad",Vector3.new(65,0,177),Vector3.new(40,0,190),"EAST ROAD", "Sunken Cistern • First Gate")
    sign("Cistern",Vector3.new(427,0,145),Vector3.new(420,0,120),"SUNKEN CISTERN", "Follow the stone descent")
    sign("NorthRoad",Vector3.new(-303,0,-615),Vector3.new(-350,0,-540),"RUSTWOOD", "Camp beyond the northern rise")
    sign("MarshRoad",Vector3.new(-706,0,448),Vector3.new(-720,0,420),"TIDEPOOL MARSH", "Reedwarden Post • Beware the deep lagoon")
    -- Small civic gardens soften the Market's empty ground without covering shop approaches.
    for _,spot in {Vector2.new(-580,75),Vector2.new(-580,-15),Vector2.new(-430,75),Vector2.new(-430,-15)} do
        local h=ground(spot.X,spot.Y)
        if h then
            local m=Instance.new("Model",landmarks);m.Name="MarketSaltGarden"
            local cf=CFrame.new(h.Position)
            part(m,"Planter",Vector3.new(7,1.2,3),cf*CFrame.new(0,.6,0),Enum.Material.Limestone,palette.dark)
            part(m,"Earth",Vector3.new(6.5,.15,2.5),cf*CFrame.new(0,1.25,0),Enum.Material.Ground,palette.wood)
            for i=-2,2 do
                part(m,"Saltgrass",Vector3.new(.25,1.8,.8),cf*CFrame.new(i,2,0)*CFrame.Angles(0,0,math.rad(i*9)),Enum.Material.Grass,Color3.fromHex("58654C"))
            end
            part(m,"BenchSeat",Vector3.new(7,.3,1.7),cf*CFrame.new(0,1.4,3.6),Enum.Material.WoodPlanks,palette.wood)
            for _,x in {-2.5,2.5} do part(m,"BenchFoot",Vector3.new(.5,1.25,1.2),cf*CFrame.new(x,.625,3.6),Enum.Material.Slate,palette.dark) end
            m.ModelStreamingMode=Enum.ModelStreamingMode.Atomic
        end
    end
    -- First Gate: a ceremonial approach, keeping the central combat space open.
    strip("GateProcessional",{Vector2.new(1065,0),Vector2.new(1240,0)},12,10,palette.stone)
    local gate=Instance.new("Model",landmarks);gate.Name="GateForecourt"
    for _,x in {1090,1130,1170,1210} do
        for _,z in {-25,25} do
            local h=ground(x,z)
            if h then
                local cf=CFrame.new(x,h.Position.Y,z)
                part(gate,"BannerPole",Vector3.new(.35,13,.35),cf*CFrame.new(0,6.5,0),Enum.Material.Metal,palette.brass)
                part(gate,"WatchBanner",Vector3.new(3.2,7,.15),cf*CFrame.new(1.6,8.5,0),Enum.Material.Fabric,palette.cloth)
                part(gate,"BannerHem",Vector3.new(3.2,.18,.18),cf*CFrame.new(1.6,5,0),Enum.Material.Metal,palette.brass)
            end
        end
    end
    gate.ModelStreamingMode=Enum.ModelStreamingMode.Atomic
    -- Small clutter can snag feet; large trees/rocks and all structural collision remain intact.
    local cleared=0
    for _,p in floor.Wild.Scatter:GetDescendants() do
        if p:IsA("BasePart") and p.CanCollide and math.max(p.Size.X,p.Size.Y,p.Size.Z)<8 then
            local near=false
            for _,road in L.Roads do
                local distance=L.PolylineDist(Vector2.new(p.Position.X,p.Position.Z),road.Points)
                if distance<road.Width/2+2 then near=true;break end
            end
            for _,w in floor.Waystones:GetChildren() do
                local v=w:GetPivot().Position-p.Position
                if Vector2.new(v.X,v.Z).Magnitude<15 then near=true;break end
            end
            if near then save(journal,p,"CanCollide",false);cleared+=1 end
        end
    end
    root:SetAttribute("PavingSegments",paving)
    root:SetAttribute("SpawnMarkersCorrected",fixedSpawns)
    root:SetAttribute("ClutterCollisionsCleared",cleared)
    -- Preview uses the existing game's daytime palette; runtime weather retains ownership.
    local lighting=game:GetService("Lighting")
    local key=require(game.ReplicatedStorage.Shared.Config.Environment).Keyframes[4]
    for property,value in {Brightness=key.Brightness,Ambient=Color3.fromHex(key.Ambient),OutdoorAmbient=Color3.fromHex(key.OutdoorAmbient),ExposureCompensation=key.Exposure,ClockTime=13} do save(journal,lighting,property,value) end
    local atmosphere=lighting:FindFirstChildOfClass("Atmosphere")
    if atmosphere then
        for property,value in {Color=Color3.fromHex(key.AtmosphereColor),Decay=Color3.fromHex(key.AtmosphereDecay),Density=key.Density,Haze=key.Haze,Glare=key.Glare} do save(journal,atmosphere,property,value)end
    end
    game:GetService("ChangeHistoryService"):SetWaypoint("Lowharbor first-floor polish")
    return {paving=paving,spawnMarkers=fixedSpawns,clutter=cleared,addedInstances=#root:GetDescendants()}
end
return Polish