-- Discord Bot for Lua Obfuscation
-- Uses Discordia library for Discord API

local discordia = require('discordia')
local client = discordia.Client()

-- Load Prometheus obfuscator
local Pipeline = require('src.prometheus.pipeline')
local Enums = require('src.prometheus.enums')

-- Bot token (provided)
local TOKEN = "MTQ2MjEzMDMxNzczMjM1MjExMw.GYqUkl.f61qDHlR9mk5PNCd4IyBfms0-L_CFaD9BWEi6Q"

-- Obfuscation configuration
local function obfuscateCode(code)
    local pipeline = Pipeline:new({
        LuaVersion = Enums.LuaVersion.Lua51,
        Seed = math.random(1, 100000),
    })
    
    -- Add obfuscation steps
    pipeline:addStep(Pipeline.Steps.WrapInFunction:new())
    pipeline:addStep(Pipeline.Steps.AdvancedNumbers:new({ Treshold = 1.0 }))
    pipeline:addStep(Pipeline.Steps.EncryptStrings:new())
    pipeline:addStep(Pipeline.Steps.Vmify:new())
    pipeline:addStep(Pipeline.Steps.AntiTamper:new({ RobloxMode = true, UseDebug = false }))
    pipeline:addStep(Pipeline.Steps.AntiDump:new({ RobloxMode = true }))
    
    local success, result = pcall(function()
        return pipeline:apply(code, "input.lua")
    end)
    
    if success then
        return result, nil
    else
        return nil, tostring(result)
    end
end

client:on('ready', function()
    print('Bot is ready!')
    print('Logged in as ' .. client.user.username)
end)

client:on('messageCreate', function(message)
    -- Ignore bot messages
    if message.author.bot then return end
    
    -- Check for .obf command
    local content = message.content
    if content:sub(1, 5) == ".obf " then
        -- Check if there's an attachment
        if #message.attachments > 0 then
            local attachment = message.attachments[1]
            
            -- Download the file
            local http = require('coro-http')
            local success, response, body = pcall(function()
                return http.request("GET", attachment.url)
            end)
            
            if success and body then
                local obfuscated, err = obfuscateCode(body)
                
                if obfuscated then
                    -- Send obfuscated code as file
                    message:reply({
                        content = "Here's your obfuscated code!",
                        file = { attachment.filename .. ".obf.lua", obfuscated }
                    })
                else
                    message:reply("Error obfuscating: " .. tostring(err))
                end
            else
                message:reply("Failed to download attachment")
            end
        else
            -- Try to get code from message content
            local code = content:sub(6)
            if #code > 0 then
                local obfuscated, err = obfuscateCode(code)
                
                if obfuscated then
                    -- Send as code block if short enough
                    if #obfuscated < 1900 then
                        message:reply("```lua\n" .. obfuscated .. "\n```")
                    else
                        -- Send as file
                        message:reply({
                            content = "Here's your obfuscated code!",
                            file = { "obfuscated.lua", obfuscated }
                        })
                    end
                else
                    message:reply("Error obfuscating: " .. tostring(err))
                end
            else
                message:reply("Please provide Lua code or attach a .lua file")
            end
        end
    end
end)

-- Run the bot
client:run(TOKEN)
