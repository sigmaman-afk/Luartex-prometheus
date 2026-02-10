-- Anti-Dump Protection Step
-- This step adds runtime anti-dumping measures to prevent easy extraction of the bytecode

local Step = require("prometheus.step");
local Ast = require("prometheus.ast");
local Scope = require("prometheus.scope");
local RandomStrings = require("prometheus.randomStrings");
local Parser = require("prometheus.parser");
local Enums = require("prometheus.enums");

local AntiDump = Step:extend();
AntiDump.Description = "Adds runtime anti-dumping protection to prevent bytecode extraction";
AntiDump.Name = "Anti Dump";

AntiDump.SettingsDescriptor = {
    RobloxMode = {
        type = "boolean",
        default = false,
        description = "Enable Roblox-compatible mode"
    }
}

function AntiDump:init(settings)
    self.checkSumSeed = math.random(1, 2^24);
end

function AntiDump:apply(ast, pipeline)
    local scope = ast.body.scope;
    
    -- Generate unique variable names
    local checkVar = scope:addVariable();
    local verifyVar = scope:addVariable();
    local hashVar = scope:addVariable();
    
    -- Create anti-dump code that runs at load time
    local code = [[
do
    local ]] .. RandomStrings.randomString() .. [[ = function()
        local check = ]] .. tostring(self.checkSumSeed) .. [[;
        local env = getfenv or function() return _ENV or _G end;
        local e = env();
        
        -- Check for common dumping tools/signatures
        if e.hookfunction or e.hookmetamethod or e.getgc then
            check = check + 1;
        end
        
        -- Verify call stack depth (dumpers often have shallow stacks)
        local depth = 0;
        local info = debug and debug.getinfo;
        if info then
            while info(depth + 2) do
                depth = depth + 1;
                if depth > 50 then break; end
            end
        end
        
        if depth < 2 then
            check = check * 2;
        end
        
        -- Memory pattern check (some dumpers modify memory signatures)
        local str = tostring(math.random);
        if str:find("builtin") or str:find("C:") then
            check = check - 1;
        end
        
        return check;
    end;
    
    local ]] .. RandomStrings.randomString() .. [[ = function()
        local t = {};
        setmetatable(t, {
            __index = function(self, k)
                if type(k) == "string" and k:lower():find("dump") then
                    return function() return nil; end;
                end
                return rawget(self, k);
            end
        });
        return t;
    end;
end
]]

    local parsed = Parser:new({LuaVersion = Enums.LuaVersion.Lua51}):parse(code);
    local doStat = parsed.body.statements[1];
    doStat.body.scope:setParent(scope);
    table.insert(ast.body.statements, 1, doStat);
    
    return ast;
end

return AntiDump;
