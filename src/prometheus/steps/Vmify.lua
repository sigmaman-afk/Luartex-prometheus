-- VM-based Code Protection
-- Compiles source to custom bytecode executed by an embedded interpreter
-- Provides stronger protection than standard obfuscation techniques

local Step = require("prometheus.step");
local Compiler = require("prometheus.compiler.compiler");

local Vmify = Step:extend();
Vmify.Description = "This Step will Compile your script into a fully-custom (not a half custom like other lua obfuscators) Bytecode Format and emit a vm for executing it.";
Vmify.Name = "Vmify";

Vmify.SettingsDescriptor = {
}

function Vmify:init(settings)
	
end

function Vmify:apply(ast)
    -- Create Compiler
	local compiler = Compiler:new();
    
    -- Compile the Script into a bytecode vm
    return compiler:compile(ast);
end

return Vmify;