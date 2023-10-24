-- Stonetr03

local Fusion = require(game.ReplicatedStorage.Packages.Fusion)
local markdowner = require(game.ReplicatedStorage.Markdown)
local Text = require(game.ReplicatedStorage.Test)

local New = Fusion.New
local Value = Fusion.Value
local Children = Fusion.Children

local CanvasSize = Value(UDim2.new(0,0,0,15))
local resize

local LastSize = Vector2.new(0,0)
local Doc = New "Frame" {
    BackgroundTransparency = 1;
    Size = UDim2.new(1,0,1,-2);

    [Fusion.OnChange "AbsoluteSize"] = function(NewSize)
        if typeof(resize) == "function" and (LastSize.X ~= math.round(NewSize.X) or LastSize.Y ~= math.round(NewSize.Y)) then
            resize()
            LastSize = Vector2.new(math.round(NewSize.X),math.round(NewSize.Y))
        end
    end
}

New "ScreenGui" {
    Parent = game.Players.LocalPlayer:WaitForChild("PlayerGui");
    Name = "Example";

    [Children] = New "ScrollingFrame" {
        AnchorPoint = Vector2.new(1,0);
        BackgroundColor3 = Color3.fromRGB(40,40,40);
        Position = UDim2.new(0.95,0,0.1,0);
        Size = UDim2.new(0.4,0,0.8,0);
        VerticalScrollBarInset = Enum.ScrollBarInset.Always;
        CanvasSize = CanvasSize;

        [Children] = Doc;
    }
}

local gui, element = markdowner({
    text = Text,
    gui = Doc,
    relayoutOnResize = true,
    links = {
        a = function()
            print("a")
        end,
        b = function()
            print("b")
        end,
        c = function()
            print("c")
        end,
        d = function()
            print("d")
        end
    }
})

resize = function()
    CanvasSize:set(UDim2.new(0, 0, 0, element.size.y + 15))
end
CanvasSize:set(UDim2.new(0, 0, 0, element.size.y + 15))
