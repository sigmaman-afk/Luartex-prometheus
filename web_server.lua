-- Web Server for Lua Obfuscation
-- Uses Luvit HTTP server

local http = require('http')
local url = require('url')
local json = require('json')

-- Load Prometheus obfuscator
package.path = package.path .. ';./src/?.lua;./src/?/init.lua'
local Pipeline = require('prometheus.pipeline')
local Enums = require('prometheus.enums')

-- HTML page for the web interface
local HTML_PAGE = [[
<!DOCTYPE html>
<html>
<head>
    <title>Lua Obfuscator</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
            background: #1a1a2e;
            color: #eee;
        }
        h1 {
            color: #00d4ff;
            text-align: center;
        }
        .container {
            background: #16213e;
            padding: 20px;
            border-radius: 10px;
            margin-top: 20px;
        }
        textarea {
            width: 100%;
            height: 300px;
            background: #0f3460;
            color: #eee;
            border: 1px solid #00d4ff;
            border-radius: 5px;
            padding: 10px;
            font-family: 'Courier New', monospace;
            font-size: 14px;
            resize: vertical;
        }
        button {
            background: #00d4ff;
            color: #1a1a2e;
            border: none;
            padding: 15px 30px;
            font-size: 18px;
            border-radius: 5px;
            cursor: pointer;
            margin-top: 10px;
            width: 100%;
        }
        button:hover {
            background: #00a8cc;
        }
        .output {
            margin-top: 20px;
        }
        .output textarea {
            background: #0f3460;
        }
        .options {
            display: grid;
            grid-template-columns: repeat(2, 1fr);
            gap: 10px;
            margin-bottom: 20px;
        }
        .option {
            background: #0f3460;
            padding: 10px;
            border-radius: 5px;
        }
        .option label {
            display: flex;
            align-items: center;
            cursor: pointer;
        }
        .option input[type="checkbox"] {
            margin-right: 10px;
            width: 20px;
            height: 20px;
        }
        .status {
            text-align: center;
            padding: 10px;
            margin-top: 10px;
            border-radius: 5px;
            display: none;
        }
        .status.success {
            background: #4caf50;
            display: block;
        }
        .status.error {
            background: #f44336;
            display: block;
        }
    </style>
</head>
<body>
    <h1>🔒 Lua Obfuscator</h1>
    <div class="container">
        <h3>Input Lua Code:</h3>
        <textarea id="input" placeholder="Paste your Lua code here..."></textarea>
        
        <h3>Options:</h3>
        <div class="options">
            <div class="option">
                <label><input type="checkbox" id="vmify" checked> VM Protection</label>
            </div>
            <div class="option">
                <label><input type="checkbox" id="encryptStrings" checked> Encrypt Strings</label>
            </div>
            <div class="option">
                <label><input type="checkbox" id="advancedNumbers" checked> Advanced Numbers</label>
            </div>
            <div class="option">
                <label><input type="checkbox" id="antiTamper" checked> Anti-Tamper</label>
            </div>
            <div class="option">
                <label><input type="checkbox" id="antiDump"> Anti-Dump</label>
            </div>
            <div class="option">
                <label><input type="checkbox" id="robloxMode" checked> Roblox Mode</label>
            </div>
        </div>
        
        <button onclick="obfuscate()">🔐 Obfuscate Code</button>
        <div id="status" class="status"></div>
        
        <div class="output" id="outputSection" style="display:none;">
            <h3>Obfuscated Output:</h3>
            <textarea id="output" readonly></textarea>
            <button onclick="copyOutput()">📋 Copy to Clipboard</button>
            <button onclick="downloadOutput()">💾 Download File</button>
        </div>
    </div>

    <script>
        async function obfuscate() {
            const input = document.getElementById('input').value;
            const status = document.getElementById('status');
            const outputSection = document.getElementById('outputSection');
            const output = document.getElementById('output');
            
            if (!input.trim()) {
                status.className = 'status error';
                status.textContent = 'Please enter some Lua code!';
                return;
            }
            
            status.className = 'status';
            status.textContent = 'Obfuscating...';
            status.style.display = 'block';
            
            const options = {
                vmify: document.getElementById('vmify').checked,
                encryptStrings: document.getElementById('encryptStrings').checked,
                advancedNumbers: document.getElementById('advancedNumbers').checked,
                antiTamper: document.getElementById('antiTamper').checked,
                antiDump: document.getElementById('antiDump').checked,
                robloxMode: document.getElementById('robloxMode').checked
            };
            
            try {
                const response = await fetch('/obfuscate', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ code: input, options: options })
                });
                
                const data = await response.json();
                
                if (data.success) {
                    output.value = data.result;
                    outputSection.style.display = 'block';
                    status.className = 'status success';
                    status.textContent = 'Obfuscation successful!';
                } else {
                    status.className = 'status error';
                    status.textContent = 'Error: ' + data.error;
                }
            } catch (err) {
                status.className = 'status error';
                status.textContent = 'Error: ' + err.message;
            }
        }
        
        function copyOutput() {
            const output = document.getElementById('output');
            output.select();
            document.execCommand('copy');
            alert('Copied to clipboard!');
        }
        
        function downloadOutput() {
            const output = document.getElementById('output').value;
            const blob = new Blob([output], { type: 'text/plain' });
            const a = document.createElement('a');
            a.href = URL.createObjectURL(blob);
            a.download = 'obfuscated.lua';
            a.click();
        }
    </script>
</body>
</html>
]]

-- Obfuscation function
local function obfuscateCode(code, options)
    options = options or {}
    
    local pipeline = Pipeline:new({
        LuaVersion = Enums.LuaVersion.Lua51,
        Seed = math.random(1, 100000),
    })
    
    -- Add selected steps
    if options.advancedNumbers ~= false then
        pipeline:addStep(Pipeline.Steps.AdvancedNumbers:new({ Treshold = 1.0 }))
    end
    
    if options.encryptStrings ~= false then
        pipeline:addStep(Pipeline.Steps.EncryptStrings:new())
    end
    
    if options.vmify ~= false then
        pipeline:addStep(Pipeline.Steps.Vmify:new())
    end
    
    if options.antiTamper ~= false then
        pipeline:addStep(Pipeline.Steps.AntiTamper:new({ 
            RobloxMode = options.robloxMode,
            UseDebug = not options.robloxMode 
        }))
    end
    
    if options.antiDump then
        pipeline:addStep(Pipeline.Steps.AntiDump:new({ 
            RobloxMode = options.robloxMode 
        }))
    end
    
    local success, result = pcall(function()
        return pipeline:apply(code, "input.lua")
    end)
    
    if success then
        return { success = true, result = result }
    else
        return { success = false, error = tostring(result) }
    end
end

-- HTTP server
local server = http.createServer(function(req, res)
    local parsedUrl = url.parse(req.url, true)
    local path = parsedUrl.pathname
    
    -- CORS headers
    res:setHeader('Access-Control-Allow-Origin', '*')
    res:setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
    res:setHeader('Access-Control-Allow-Headers', 'Content-Type')
    
    if req.method == 'OPTIONS' then
        res:writeHead(200)
        res:finish()
        return
    end
    
    if path == '/' and req.method == 'GET' then
        -- Serve the HTML page
        res:setHeader('Content-Type', 'text/html')
        res:writeHead(200)
        res:finish(HTML_PAGE)
        
    elseif path == '/obfuscate' and req.method == 'POST' then
        -- Handle obfuscation request
        local body = ''
        req:on('data', function(chunk)
            body = body .. chunk
        end)
        
        req:on('end', function()
            local ok, data = pcall(json.parse, body)
            if ok and data and data.code then
                local result = obfuscateCode(data.code, data.options)
                res:setHeader('Content-Type', 'application/json')
                res:writeHead(200)
                res:finish(json.stringify(result))
            else
                res:setHeader('Content-Type', 'application/json')
                res:writeHead(400)
                res:finish(json.stringify({ success = false, error = 'Invalid request' }))
            end
        end)
        
    else
        res:writeHead(404)
        res:finish('Not Found')
    end
end)

-- Get port from environment or default to 8080
local PORT = os.getenv('PORT') or 8080

server:listen(PORT, function()
    print('🚀 Obfuscator server running on port ' .. PORT)
    print('🌐 Open http://localhost:' .. PORT .. ' in your browser')
end)
