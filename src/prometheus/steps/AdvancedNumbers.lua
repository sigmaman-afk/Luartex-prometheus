-- Advanced Number Encoding Step
-- Encodes numbers using hex, binary notation, and scientific expressions
-- Produces patterns like: {0x6A, 6.125e1-12.5, 0b110101, 0x73-0x0}

local Step = require("prometheus.step");
local Ast = require("prometheus.ast");
local visitast = require("prometheus.visitast");

local AdvancedNumbers = Step:extend();
AdvancedNumbers.Description = "Encodes numbers using hex, binary, and scientific notation for obfuscation";
AdvancedNumbers.Name = "Advanced Numbers";

AdvancedNumbers.SettingsDescriptor = {
    Treshold = {
        name = "Treshold",
        description = "The relative amount of number nodes that will be affected",
        type = "number",
        default = 1,
        min = 0,
        max = 1,
    }
}

function AdvancedNumbers:init(settings)
    self.affected = 0;
    self.total = 0;
end

-- Convert number to hex string (0x format)
local function toHex(n)
    return string.format("0x%X", n);
end

-- Convert number to binary string (0b format) - Roblox compatible
local function toBinary(n)
    if n == 0 then return "0b0"; end
    local bits = {};
    local num = math.floor(n);
    while num > 0 do
        table.insert(bits, 1, num % 2);
        num = math.floor(num / 2);
    end
    return "0b" .. table.concat(bits);
end

-- Generate random encoding for a number
function AdvancedNumbers:encodeNumber(n)
    local encodings = {};
    
    -- Option 1: Direct hex
    table.insert(encodings, function() return toHex(n); end);
    
    -- Option 2: Binary notation
    if n >= 0 and n <= 255 then
        table.insert(encodings, function() return toBinary(n); end);
    end
    
    -- Option 3: Scientific notation expression
    if n > 0 then
        table.insert(encodings, function()
            local mantissa = n / 10;
            return string.format("%.6fe1", mantissa);
        end);
    end
    
    -- Option 4: Subtraction expression (e.g., 0x73-0x0)
    table.insert(encodings, function()
        local offset = math.random(0, math.min(n, 50));
        return toHex(n - offset) .. "-" .. toHex(offset);
    end);
    
    -- Option 5: Addition expression (hex + hex)
    table.insert(encodings, function()
        local offset = math.random(0, math.min(n, 50));
        return toHex(n - offset) .. "+" .. toHex(offset);
    end);
    
    -- Option 6: Scientific with offset (e.g., 6.125e1-12.5)
    table.insert(encodings, function()
        local base = n + math.random(-20, 20);
        local offset = base - n;
        return string.format("%.3fe0-%.1f", base, offset);
    end);
    
    -- Option 7: Division expression
    table.insert(encodings, function()
        local mul = math.random(2, 8);
        return string.format("(%s/%d)", toHex(n * mul), mul);
    end);
    
    -- Pick random encoding
    local encoder = encodings[math.random(1, #encodings)];
    return encoder();
end

function AdvancedNumbers:apply(ast, pipeline)
    visitast(ast, nil, function(node, data)
        if node.kind == Ast.AstKind.NumberExpression then
            self.total = self.total + 1;
            
            if math.random() <= self.Treshold then
                self.affected = self.affected + 1;
                local encoded = self:encodeNumber(node.value);
                
                -- Parse the encoded expression
                local parser = require("prometheus.parser");
                local enums = require("prometheus.enums");
                
                local p = parser:new({ LuaVersion = enums.LuaVersion.Lua51 });
                local code = "return " .. encoded .. ";";
                local ok, parsed = pcall(function() return p:parse(code); end);
                
                if ok and parsed then
                    local returnStat = parsed.body.statements[1];
                    if returnStat and returnStat.args and returnStat.args[1] then
                        return returnStat.args[1];
                    end
                end
            end
        end
    end);
    
    return ast;
end

return AdvancedNumbers;
