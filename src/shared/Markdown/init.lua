
--[[
    This is a fork of Corecii's Markdowner (https://devforum.roblox.com/t/markdowner/327165)
    Markdowner generates Roblox guis to display markdown, supporting:
    * Paragraphs
    * Bullet point lists
    * Numbered lists
    * Nested lists
    * Code blocks
    * Syntax highlighting Lua code
    * Inline code
    * Horizontal rule (line)
    * Blockquotes
    * Images
    * Preserving original links while showing Roblox asset images *only* when viewed in Roblox i.e. markdown with images that can be viewed both in- and out-of Roblox
    
    Markdowner uses the following open-source modules:
    * [markdown.lua](https://github.com/mpeterv/markdown)
    * [xmlSimple](https://github.com/Cluain/Lua-Simple-XML-Parser)
    * [Lexer](https://devforum.roblox.com/t/lexer-for-rbx-lua/183115)
    
    Markdown is turned into html which is then turned into Roblox gui.
        
    Markdowner Documentation
    
    Markdowner returns a function, `getMarkdownGui`:
        Instance baseGui,  MarkdownContainer container = getMarkdownGui({
            String text,
            Instance gui (optional),
            Bool relayoutOnResize (optional),
            Bool dontCreateLayouts (optional),
        })
        A gui for the given markdown text will be generated and placed inside `gui`.
        If `gui` is missing then a new Frame with `BackgroundTransparency = 1` will be created.
        If `relayoutOnResize` is true, the markdown will be updated any time `gui`'s AbsoluteSize changes. The connection for this is *not* exposed.
        By default, getMarkdownGui will clone a default UIListLayout and a default UIPadding into your gui if your gui is missing children with those names. At least a UIListLayout is required for Markdowner to display markdown. If you don't want Markdowner to place this in your gui, set `dontCreateLayouts` to true.
    
    class MarkdownContainer:
        Vector2 :GetSize()
            Returns the absolute size of the generated markdown
        Vector2 :GetMaxSize(Bool forChildren)
            Get the maximum size that the generated markdown will take up.
            If `forChildren` is true, this will be the maximum space minus the padding.
        void :Relayout()
            Updates all the contained markdown elements' positions.
            If there is no gui connected to this container, nothing is updated. Relayout requirs an AbsoluteSize to update  element positions.
    
    Replacing non-roblox images with Roblox images:
        You have two choices:
        1. Replace the actual link with a Roblox content id (e.g. `rbxassetid://12345678`)
        2. Add a tag anywhere in the markdown to indicate that the original image link needs to be replaced with a roblox link:
            2.1: without size title: assumes 100x100 px image [roblox original_link_full]: roblox_content_id
            2.2: with size title:[roblox original_link_full]: roblox_content_id "=90x20"
        Option 2 lets you use markdown on both Roblox and in a normal markdown viewer since the original image link is preserved. The roblox link tags are *not* visible in a normal markdown viewer.
--]]

local TextService = game:GetService('TextService')
local Create = require(script.Create)

local markdownToHtml = require(script.markdown)
local xmlSimple = require(script.xmlSimple)
local function readXml(input)
    return xmlSimple.New():ParseXmlText(input)
end
local lexer = require(script.lexer)
local lexerScan = lexer.scan

---

local bigVector2 = Vector2.new(100000, 100000)

local headers = {
    h1 = 36,
    h2 = 32,
    h3 = 28,
    h4 = 24,
    h5 = 20,
    h6 = 16,
}

local baseTextSize = 16

local function getPaddingSize(gui, size)
    local size = size or gui.AbsoluteSize
    local padding = gui:FindFirstChildWhichIsA('UIPadding')
    if not padding then
        return Vector2.new(0, 0)
    end
    return Vector2.new(
        size.x*(padding.PaddingLeft.Scale  + padding.PaddingRight.Scale)
             + (padding.PaddingLeft.Offset + padding.PaddingRight.Offset),
        size.y*(padding.PaddingTop.Scale  + padding.PaddingBottom.Scale)
             + (padding.PaddingTop.Offset + padding.PaddingBottom.Offset)
    )
end

local function getGuiChildSpace(gui, size)
    local size = size or gui.AbsoluteSize
    local padding = gui:FindFirstChildWhichIsA('UIPadding')
    if padding then
        size = size - getPaddingSize(gui, size)
    end
    return size
end

local MarkdownElement = setmetatable({}, {
    __index = {
        className = 'MarkdownElement',
        Extend = function(self, meta)
            for k, v in next, getmetatable(self) do
                if meta[k] == nil then
                    meta[k] = v
                elseif typeof(v) == 'table' and typeof(meta[k]) == 'table' then
                    for ik, iv in next, v do
                        if meta[k][ik] == nil then
                            meta[k][ik] = iv
                        end
                    end
                end
                if k == '__index' and typeof(meta[k]) == 'table' then
                    meta[k].super = self
                end
            end
            return setmetatable({}, meta)
        end,
        New = function(self, ...)
            return setmetatable({}, getmetatable(self)):Construct(...)
        end,
        Construct = function(self, args)
            if args and args.gui then
                self.gui = args.gui
            elseif self.templateName then
                if args and args[self.templateName] then
                    self.gui = args[self.templateName]:Clone()
                elseif script:FindFirstChild(self.templateName) then
                    self.gui = script:FindFirstChild(self.templateName):Clone()
                end
            end
            self.children = {}
            self.childrenDict = {}
            return self
        end,
        
        Add = function(self, element)
            if self.childrenDict[element] then
                return
            end
            self.children[#self.children + 1] = element
            self.childrenDict[element] = true
            if element.parent ~= nil then
                element.parent:Remove(element)
            end
            element.parent = self
        end,
        Remove = function(self, element)
            if not self.childrenDict[element] then
                return
            end
            for i, v in next, self.children do
                if v == element then
                    table.remove(self.children, i)
                    break
                end
            end
            self.childrenDict[element] = nil
            if element.parent == self then
                element.parent = nil
            end
        end,
        
        GetSize = function(self)
            return self.size or Vector2.new(0, 0)
        end,
        Relayout = function(self)
            local guiParent = self.guiParent or self.gui
            if not guiParent then
                return
            end
            local padding = 0
            local list = guiParent:FindFirstChildWhichIsA('UIListLayout')
            if list then
                padding = guiParent.AbsoluteSize.y*list.Padding.Scale + list.Padding.Offset
            end
            local width, height = 0, 0
            for index, child in next, self.children do
                if child.gui then
                    child.gui.Parent = guiParent
                    child.gui.LayoutOrder = index
                    child:Relayout()
                    local childSize = child:GetSize()
                    width = math.max(width, childSize.x)
                    height = height + childSize.y + padding
                end
            end
            self.size = Vector2.new(width, height - padding)
            if self.padding then
                self.size = self.size + self.padding
            end
            if self.minSize then
                self.size = Vector2.new(math.max(self.minSize.x, self.size.x), math.max(self.minSize.y, self.size.y))
            end
            if not self.keepGuiSize then
                self.gui.Size = UDim2.new(0, self.size.x, 0, self.size.y)
            end
        end,
        GetMaxSize = function(self, forChildren)
            if self.parent then
                if forChildren and self.padding then
                    return self.parent:GetMaxSize(true) - self.padding
                else
                    return self.parent:GetMaxSize(true)
                end
            end
            return Vector2.new(0, 0)
        end,
    }
})

local MarkdownContainer;
MarkdownContainer = MarkdownElement:Extend({
    __index = {
        className = 'MarkdownContainer',
        keepGuiSize = true,
        Construct = function(self, args)
            MarkdownContainer.super.Construct(self, args)
            return self
        end,
        GetMaxSize = function(self, forChildren)
            if self.gui then
                local space = getGuiChildSpace(self.gui)
                return space
            end
            return Vector2.new(0, 0)
        end,
    }
})

local MarkdownRule;
MarkdownRule = MarkdownElement:Extend({
    __index = {
        className = 'MarkdownRule',
        templateName = 'ruleTemplate',
        Construct = function(self, args)
            MarkdownRule.super.Construct(self, args)
            return self
        end,
        Relayout = function(self)
            return
        end,
        GetSize = function(self)
            local max = self:GetMaxSize(false)
            return Vector2.new(max.x, self.gui.Size.Y.Offset)
        end
    }
})

local MarkdownText;
MarkdownText = MarkdownElement:Extend({
    __index = {
        className = 'MarkdownText',
        templateName = 'textTemplate',
        Construct = function(self, args)
            MarkdownText.super.Construct(self, args)
            self.text = args.text
            if args.font then
                self.gui.FontFace = args.font
            end
            if args.fontSize then
                self.gui.TextSize = args.fontSize
            end
            if args.color then
                self.gui.TextColor3 = args.color
            end
            self.font = self.gui.FontFace
            self.fontSize = self.gui.TextSize
            self.color = self.gui.TextColor3
            return self
        end,
        MakeGui = function(self)
            return self.gui:Clone()
        end,
    }
})

local MarkdownLineBreak;
MarkdownLineBreak = MarkdownElement:Extend({
    __index = {
        className = 'MarkdownLineBreak',
        templateName = 'lineBreakTemplate',
        isLineBreak = true,
        Construct = function(self, args)
            MarkdownLineBreak.super.Construct(self, args)
            return self
        end,
    }
})

local MarkdownImage;
MarkdownImage = MarkdownElement:Extend({
    __index = {
        className = 'MarkdownImage',
        templateName = 'imageTemplate',
        isImage = true,
        Construct = function(self, args)
            MarkdownImage.super.Construct(self, args)
            self.image = args.image or ''
            self.gui:FindFirstChild('ImageLabel', true).Image = args.image
            self.size = args.size or Vector2.new(100, 100)
            self.gui.Size = UDim2.new(0, self.size.x, 0, self.size.y)
            -- TODO: alt text
            return self
        end,
        Relayout = function(self)
            return
        end,
    }
})

local MarkdownParagraph;
MarkdownParagraph = MarkdownElement:Extend({
    __index = {
        className = 'MarkdownParagraph',
        templateName = 'paragraphTemplate',
        Construct = function(self, args)
            MarkdownParagraph.super.Construct(self, args)
            self.size = Vector2.new(0, 0)
            return self
        end,
        Relayout = function(self)
            if self.guis then
                for _, gui in next, self.guis do
                    gui:Destroy()
                end
            end
            local guiParent = self.guiParent or self.gui
            local guis = {}
            local height = 0
            local maxLineFontSize = 0
            local width = 0
            local maxSize = self:GetMaxSize(true)
            for i, child in next, self.children do
                if child.isLineBreak then
                    width = 0
                    height = height + maxLineFontSize
                    maxLineFontSize = 0
                elseif child.isImage then
                    child:Relayout()
                    local size = child:GetSize()
                    if width + size.x + 3 <= maxSize.x then
                        child.gui.Position = UDim2.new(0, width + 3, 0, height)
                        if size.y > maxLineFontSize then
                            maxLineFontSize = size.y + 3
                        end
                        width = width + size.x + 3
                    else
                        width = size.x + 3
                        height = height + maxLineFontSize
                        maxLineFontSize = size.y + 3
                        child.gui.Position = UDim2.new(0, 0, 0, height)
                    end
                    child.gui.Parent = guiParent
                else
                    local childText = child.text:gsub('[\r\n]+', ' ')
                    local font, fontSize = child.font, child.fontSize
                    maxLineFontSize = math.max(maxLineFontSize, math.floor(fontSize*1.2))
                    local fullSize = TextService:GetTextBoundsAsync(Create("GetTextBoundsParams",nil,{Text = childText,Font = font, Size = fontSize, Width = bigVector2}))
                    if width + fullSize.x <= maxSize.x then
                        local gui = child:MakeGui()
                        gui.Text = childText
                        gui.Size = UDim2.new(0, fullSize.x, 0, fullSize.y)
                        gui.Position = UDim2.new(0, width, 0, height)
                        gui.Parent = guiParent
                        guis[#guis + 1] = gui
                        width = width + fullSize.x
                    else
                        for space, word in childText:gmatch('(%s*)(%S*)') do
                            local addWordSize = TextService:GetTextBoundsAsync(Create("GetTextBoundsParams",nil,{Text = space..word,Font = font, Size = fontSize, Width = bigVector2}))
                            if width + addWordSize.x <= maxSize.x then
                                local gui = child:MakeGui()
                                gui.Text = space..word
                                gui.Size = UDim2.new(0, addWordSize.x, 0, addWordSize.y)
                                gui.Position = UDim2.new(0, width, 0, height)
                                gui.Parent = guiParent
                                guis[#guis + 1] = gui
                                width = width + addWordSize.x
                            else
                                local wordSize = TextService:GetTextBoundsAsync(Create("GetTextBoundsParams",nil,{Text = word,Font = font, Size = fontSize, Width = bigVector2}))
                                if wordSize.x <= maxSize.x then
                                    height = height + maxLineFontSize
                                    maxLineFontSize = math.floor(fontSize*1.2)
                                    local gui = child:MakeGui()
                                    gui.Text = word
                                    gui.Size = UDim2.new(0, wordSize.x, 0, wordSize.y)
                                    gui.Position = UDim2.new(0, 0, 0, height)
                                    gui.Parent = guiParent
                                    guis[#guis + 1] = gui
                                    width = wordSize.x
                                else
                                    local text
                                    local spaceSize = TextService:GetTextBoundsAsync(Create("GetTextBoundsParams",nil,{Text = space,Font = font, Size = fontSize, Width = bigVector2}))
                                    if width + spaceSize.x > maxSize.x then
                                        width, height = 0, height + maxLineFontSize
                                        maxLineFontSize = math.floor(fontSize*1.2)
                                        text = word
                                    else
                                        text = space..word
                                    end
                                    local built = ''
                                    for char in text:gmatch('.') do
                                        local nextSize = TextService:GetTextBoundsAsync(Create("GetTextBoundsParams",nil,{Text = built..char,Font = font, Size = fontSize, Width = bigVector2}))
                                        if width + nextSize.x > maxSize.x then
                                            local gui = child:MakeGui()
                                            gui.Text = built
                                            gui.Size = UDim2.new(0, maxSize.x - width, 0, fontSize)
                                            gui.Position = UDim2.new(0, width, 0, height)
                                            gui.Parent = guiParent
                                            guis[#guis + 1] = gui
                                            width, height = 0, height + maxLineFontSize
                                            maxLineFontSize = math.floor(fontSize*1.2)
                                            built = ''
                                        end
                                        built = built..char
                                    end
                                    if built ~= '' then
                                        local textSize = TextService:GetTextBoundsAsync(Create("GetTextBoundsParams",nil,{Text = built,Font = font, Size = fontSize, Width = bigVector2}))
                                        local gui = child:MakeGui()
                                        gui.Text = built
                                        gui.Size = UDim2.new(0, textSize.x, 0, fontSize)
                                        gui.Position = UDim2.new(0, width, 0, height)
                                        gui.Parent = guiParent
                                        guis[#guis + 1] = gui
                                        width = width + textSize.x
                                    end
                                end
                            end
                        end
                    end
                end
            end
            self.guis = guis
            self.size = Vector2.new(maxSize.x, height + (width > 0 and maxLineFontSize or 0))
            if self.padding then
                self.size = self.size + self.padding
            end
            self.gui.Size = UDim2.new(0, self.size.x, 0, self.size.y)
        end,
    }
})

local MarkdownCode;
MarkdownCode = MarkdownParagraph:Extend({
    __index = {
        className = 'MarkdownCode',
        templateName = 'codeTemplate',
        textColors = {
            base     = Color3.fromRGB(230, 230, 230),
            operator = Color3.fromRGB(204, 204, 204),
            keyword  = Color3.fromRGB(248, 109, 124),
            string   = Color3.fromRGB(173, 241, 149),
            number   = Color3.fromRGB(255, 198, 0),
            comment  = Color3.fromRGB(102, 102, 102),
            builtin  = Color3.fromRGB(132, 214, 247),
        },
        operators = {
            ['='] = true,
            ['+'] = true,
            ['-'] = true,
            ['*'] = true,
            ['/'] = true,
            ['^'] = true,
            ['%'] = true,
            ['#'] = true,
        },
        padding = Vector2.new(10, 10),
        Construct = function(self, args)
            MarkdownCode.super.Construct(self, args)
            self.guiParent = self.gui:FindFirstChild('Content', true)
            self.text = args.text or ''
            self.lang = args.lang
            if self.lang and self.lang:lower() == 'lua' then
                for token, text in lexerScan(self.text) do
                    local colorName = token
                    if self.operators[token] then
                        colorName = 'operator'
                    elseif token == 'iden' and self.customBuiltins and self.customBuiltins[txt] then
                        colorName = 'builtin'
                    end 
                    local color = self.textColors[colorName] or self.textColors.base
                    if text:find('[\r\n]') then
                        text = text:gsub('\r\n', '\n'):gsub('\r','\n')
                        local addLine = false
                        for line in (text..'\n'):gmatch('([^\n]*)\n') do
                            if addLine then
                                self:Add(MarkdownLineBreak:New())
                            end
                            self:Add(MarkdownText:New({text = line, font = Font.fromEnum(Enum.Font.Code), color = color}))
                            addLine = true
                        end
                    else
                        self:Add(MarkdownText:New({text = text, font = Font.fromEnum(Enum.Font.Code), color = color}))
                    end
                end
            else
                local text = self.text:gsub('\r\n', '\n'):gsub('\r', '\n')
                local addLine = false
                for line in (text..'\n'):gmatch('([^\n]*)\n') do
                    if addLine then
                        self:Add(MarkdownLineBreak:New())
                    end
                    self:Add(MarkdownText:New({text = line, font = Font.fromEnum(Enum.Font.Code)}))
                    addLine = true
                end
            end
            return self
        end,
    }
})

local MarkdownBlockquote;
MarkdownBlockquote = MarkdownElement:Extend({
    __index = {
        className = 'MarkdownBlockquote',
        templateName = 'blockquoteTemplate',
        padding = Vector2.new(10, 0),
        Construct = function(self, args)
            MarkdownBlockquote.super.Construct(self, args)
            self.guiParent = self.gui:FindFirstChild('Content', true)
            return self
        end,
    }
})

local MarkdownListItem;
MarkdownListItem = MarkdownElement:Extend({
    __index = {
        className = 'MarkdownListItem',
        templateName = 'listItemTemplate',
        isListItem = true,
        Construct = function(self, args)
            MarkdownListItem.super.Construct(self, args)
            self.guiParent = self.gui:FindFirstChild('Content', true)
            self.imageBullet = self.gui:FindFirstChild('ImageLabel', true)
            self.textBullet = self.gui:FindFirstChild('TextLabel', true)
            return self
        end,
        SetBullet = function(self, number, padding)
            local isNumber = typeof(number) == 'number'
            self.textBullet.Visible = isNumber
            self.imageBullet.Visible = not isNumber
            local preSize
            if isNumber then
                local text = ('%d. '):format(number)
                self.textBullet.Text = text
                if padding then
                    preSize = Vector2.new(padding, self.textBullet.TextSize)
                else
                    preSize = TextService:GetTextBoundsAsync(Create("GetTextBoundsParams",nil,{Text = text,Font = self.textBullet.FontFace, Size = self.textBullet.TextSize, Width = bigVector2})) + Vector2.new(4,3)
                end
            else
                preSize = Vector2.new(baseTextSize, baseTextSize)
            end
            self.padding = Vector2.new(preSize.x, 0)
            self.minSize = preSize
            self.guiParent.Size = UDim2.new(1, -preSize.x, 1, 0)
            return preSize.x
        end,
    }
})

local MarkdownList;
MarkdownList = MarkdownElement:Extend({
    __index = {
        className = 'MarkdownList',
        templateName = 'listTemplate',
        Construct = function(self, args)
            MarkdownList.super.Construct(self, args)
            self.isOrdered = args.ordered and true or false
            return self
        end,
        Relayout = function(self)
            local guiParent = self.guiParent or self.gui
            if not guiParent then
                return
            end
            local padding = 0
            local list = guiParent:FindFirstChildWhichIsA('UIListLayout')
            if list then
                padding = guiParent.AbsoluteSize.y*list.Padding.Scale + list.Padding.Offset
            end
            local leftPadding
            local width, height = 0, 0
            local children = self.children
            for index = #children, 1, -1 do
                local child = children[index]
                if leftPadding then
                    child:SetBullet(self.isOrdered and index, leftPadding)
                else
                    leftPadding = child:SetBullet(self.isOrdered and index)
                end
                if child.gui then
                    child.gui.Parent = guiParent
                    child.gui.LayoutOrder = index
                    child:Relayout()
                    local childSize = child:GetSize()
                    width = math.max(width, childSize.x)
                    height = height + childSize.y + padding
                end
            end
            self.size = Vector2.new(width, height - padding)
            if self.padding then
                self.size = self.size + self.padding
            end
            if self.minSize then
                self.size = Vector2.new(math.max(self.minSize.x, self.size.x), math.max(self.minSize.y, self.size.y))
            end
            self.gui.Size = UDim2.new(0, self.size.x, 0, self.size.y)
        end
    }
})

local function getMarkdownGui(args)
    local html, linkDb = markdownToHtml(args.text)
    local xml = readXml(html)
    
    local baseGui
    if args.gui then
        baseGui = args.gui
    else
        baseGui = Instance.new('Frame')
        baseGui.BackgroundTransparency = 1
    end
    if not args.dontCreateLayouts then
        for _, child in next, script.LayoutTemplates:GetChildren() do
            if not baseGui:FindFirstChild(child.Name) then
                child:Clone().Parent = baseGui
            end
        end
    end
    
    local lang
    local href
    
    local tags = {}
    local function addTag(tag)
        tags[tag] = (tags[tag] or 0) + 1
    end
    local function remTag(tag)
        tags[tag] = (tags[tag] or 1) - 1
        if tags[tag] == 0 then
            tags[tag] = nil
        end
    end
    
    local container = MarkdownContainer:New({gui = baseGui})
    local currentItem = container
    local function add(obj)
        if currentItem.className == 'MarkdownParagraph' then -- bugfix for li (list item) w/ p (paragraph)
            currentItem = currentItem.parent
        end
        currentItem:Add(obj)
        currentItem = obj
        return obj
    end
    local function rev(obj)
        while currentItem ~= obj do
            currentItem = currentItem.parent
        end
        currentItem = currentItem.parent
    end
    
    local function resolveUrl(url, title)
        local size
        local found = linkDb['roblox '..url]
        if found then
            url = found.url or url
            title = found.title or title
        end
        if title and (url:match('^rbxasset') or url:match('^https?://%d+%.roblox.com') or url:match('^https?://roblox.com')) then
            -- only match the title for size if this is a roblox asset
            local realTitle, w, h = title:match('^(.*) ?=(%d+)x(%d+)$')
            if realTitle then
                local fixTitle1, fixTitle2 = title:match('^(.*)\\( ?=%d+x%d+)$') -- allow escaping
                if fixTitle1 then
                    title = fixTitle1..fixTitle2
                else
                    title = realTitle
                    size = Vector2.new(tonumber(w), tonumber(h))
                end
            end
        end
        return url, title, size
    end
    
    local function make(parent)
        for _, node in next, parent:children() do
            local nodeType = node:name()
            if nodeType == '___value' then
                local value = node:value()
                if tags.pre and tags.code then
                    currentItem:Add(
                        MarkdownCode:New({
                            text = value,
                            lang = lang,
                        })
                    )
                else
                    if currentItem.className ~= 'MarkdownParagraph' then -- bugfix for li (list item) w/ p (paragraph)
                        add(
                            MarkdownParagraph:New()
                        )
                    end
                    local font, fontSize, color
                    if tags.code then
                        font = Font.fromEnum(Enum.Font.Code)
                    elseif tags.em and tags.strong then
                        font = Font.new("rbxasset://fonts/families/SourceSansPro.json",Enum.FontWeight.Bold,Enum.FontStyle.Italic)
                    elseif tags.em then
                        font = Font.fromEnum(Enum.Font.SourceSansItalic)
                    elseif tags.strong then
                        font = Font.fromEnum(Enum.Font.SourceSansBold)
                    end
                    for tag, size in next, headers do
                        if tags[tag] then
                            fontSize = size
                            break
                        end
                    end
                    if tags.a then
                        color = Color3.fromRGB(80, 217, 255)
                        if href then
                            local url, title, size = unpack(href)
                            -- TODO: make and listen to button
                        end
                    end
                    currentItem:Add(
                        MarkdownText:New({
                            text = value:gsub('%s+', ' '),
                            font = font,
                            fontSize = fontSize,
                            color = color,
                        })
                    )
                end
            elseif nodeType == 'br' then
                currentItem:Add(
                    MarkdownLineBreak:New()
                )
            elseif nodeType == 'hr' then
                currentItem:Add(
                    MarkdownRule:New()
                )
            else
                addTag(nodeType)
                local obj
                if nodeType == 'p' or headers[nodeType] then
                    obj = add(
                        MarkdownParagraph:New()
                    )
                elseif nodeType == 'blockquote' then
                    obj = add(
                        MarkdownBlockquote:New()
                    )
                elseif nodeType == 'ol' or nodeType == 'ul' then
                    obj = add(
                        MarkdownList:New({
                            ordered = nodeType == 'ol'
                        })
                    )
                elseif nodeType == 'li' then
                    obj = add(
                        MarkdownListItem:New()
                    )
                elseif nodeType == 'code' then
                    lang = node['@lang']
                elseif nodeType == 'a' then
                    href = {resolveUrl(node['@href'], node['@alt'], node['@title'])}
                elseif nodeType == 'img' then
                    local url, title, size = resolveUrl(node['@src'], node['@title'])
                    -- TODO: implement title text
                    currentItem:Add(
                        MarkdownImage:New({
                            image = url,
                            size = size,
                        })
                    )
                end
                make(node)
                if obj then
                    rev(obj)
                elseif nodeType == 'code' then
                    lang = nil
                elseif nodeType == 'a' then
                    href = nil
                end
                remTag(nodeType)
            end
        end
    end
    make(xml)
    
    container:Relayout()
    if args.relayoutOnResize then
        local lastAbsoluteSize = baseGui.AbsoluteSize
        baseGui:GetPropertyChangedSignal('AbsoluteSize'):Connect(function()
            if baseGui.AbsoluteSize == lastAbsoluteSize then
                return
            end
            lastAbsoluteSize = baseGui.AbsoluteSize
            container:Relayout()
        end)
    end
    
    return baseGui, container
end

return getMarkdownGui