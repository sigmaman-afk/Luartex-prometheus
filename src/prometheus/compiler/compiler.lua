-- Bytecode Compiler Module
-- Compiles AST to custom VM bytecode with advanced obfuscation
-- Core component of the code protection system

-- VM Configuration Constants
local MAX_REGS = 100;
local MAX_REGS_MUL = 0;
local VM_VERSION = 0x03; -- Incremented to mark changes from original Prometheus

local Compiler = {};

local Ast = require("prometheus.ast");
local Scope = require("prometheus.scope");
local logger = require("logger");
local util = require("prometheus.util");
local visitast = require("prometheus.visitast")
local randomStrings = require("prometheus.randomStrings")
local bit32 = require("prometheus.bit").bit32;
local bit = require("prometheus.bit").bit;

local lookupify = util.lookupify;
local AstKind = Ast.AstKind;

local unpack = unpack or table.unpack;

function Compiler:new()
    local compiler = {
        blocks = {};
        registers = {
        };
        activeBlock = nil;
        registersForVar = {};
        usedRegisters = 0;
        maxUsedRegister = 0;
        registerVars = {};

        -- Encoded instruction pointer (pos) hardening.
        -- Each block has a random raw id, but the VM uses an encoded id (posId)
        -- to make static control-flow reconstruction harder.
        posKey = 0;
        posIdMap = {}; -- rawId -> posId

        -- Roblox-compatible unique tokens (newproxy not available)
        VAR_REGISTER = {};
        RETURN_ALL = {};
        POS_REGISTER = {};
        RETURN_REGISTER = {};
        UPVALUE = {};

        BIN_OPS = lookupify{
            "+", "-", "*", "/", "//", "^", "%", 
            "&", "~", "|", ">>", "<<",
            ".."
        };

        CMP_OPS = lookupify{
            "==", "~=", ">", "<", ">=", "<="
        };

        LOGICAL_OPS = lookupify{
            "and", "or"
        };

        UNARY_OPS = lookupify{
            "-", "not", "#", "~"
        };
    };
    setmetatable(compiler, self);
    self.__index = self;
    return compiler;
end

function Compiler:compile(ast, settings)
    settings = settings or {};
    self.settings = settings;
    
    -- Initialize pos encoding key (random per compile for uniqueness)
    self.posKey = math.random(1, 2^31 - 1);
    self.posIdMap = {};
    
    -- Roblox mode detection
    self.robloxMode = settings.RobloxMode or false;
    
    -- VM bytecode encryption key
    self.vmKey = settings.VmKey or math.random(1, 255);
    
    self.containerFuncVar = nil;
    self.containerFuncScope = nil;
    self.posVar = nil;
    self.containerFuncArgVar = nil;
    self.envVar = nil;

    self.blocks = {};
    self.registers = {};
    self.activeBlock = nil;
    self.registersForVar = {};
    self.usedRegisters = 0;
    self.maxUsedRegister = 0;
    self.registerVars = {};

    self.topLevelVar = nil;
    self.createVarargClosureVar = nil;

    self.upvaluesProxyVar = nil;
    self.allocUpvalVar = nil;
    self.upvaluesTable = nil;
    self.upvaluesReferenceCountsTable = nil;
    self.currentUpvalId = nil;
    self.upvaluesGcFunctionVar = nil;
    self.upvalsProxyLenReturn = nil;

    self:setActiveBlock(self:createBlock());

    local topLevelScope = ast.body.scope;

    self.scope = topLevelScope;
    
    self.topLevelVar = topLevelScope:addVariable();
    self.containerFuncVar = topLevelScope:addVariable();
    self.containerFuncScope = Scope:new(topLevelScope);
    self.posVar = self.containerFuncScope:addVariable();
    self.containerFuncArgVar = self.containerFuncScope:addVariable();
    self.envVar = self.containerFuncScope:addVariable();
    self.createVarargClosureVar = topLevelScope:addVariable();

    self.upvaluesProxyVar = topLevelScope:addVariable();
    self.allocUpvalVar = topLevelScope:addVariable();
    self.upvaluesTable = topLevelScope:addVariable();
    self.upvaluesReferenceCountsTable = topLevelScope:addVariable();
    self.currentUpvalId = topLevelScope:addVariable();
    self.upvaluesGcFunctionVar = topLevelScope:addVariable();
    self.upvalsProxyLenReturn = math.random(1, 10);

    self.setmetatableVar = topLevelScope:addVariable();
    self.getmetatableVar = topLevelScope:addVariable();
    self.assertVar = topLevelScope:addVariable();
    self.errorVar = topLevelScope:addVariable();
    self.pcallVar = topLevelScope:addVariable();
    self.selectVar = topLevelScope:addVariable();
    self.typeVar = topLevelScope:addVariable();
    self.stringSubVar = topLevelScope:addVariable();
    self.stringCharVar = topLevelScope:addVariable();
    self.stringByteVar = topLevelScope:addVariable();
    self.stringLenVar = topLevelScope:addVariable();
    self.mathFloorVar = topLevelScope:addVariable();
    self.tonumberVar = topLevelScope:addVariable();
    self.unpackVar = topLevelScope:addVariable();
    self.tableConcatVar = topLevelScope:addVariable();
    self.tableInsertVar = topLevelScope:addVariable();
    self.tableRemoveVar = topLevelScope:addVariable();
    self.coroutineWrapVar = topLevelScope:addVariable();
    self.coroutineYieldVar = topLevelScope:addVariable();
    self.nextVar = topLevelScope:addVariable();
    self.pairsVar = topLevelScope:addVariable();
    self.ipairsVar = topLevelScope:addVariable();
    self.rawsetVar = topLevelScope:addVariable();
    self.rawgetVar = topLevelScope:addVariable();
    self.rawequalVar = topLevelScope:addVariable();

    self.activeBlock:emitStatement(Ast.AssignmentStatement({
            Ast.AssignmentVariable(topLevelScope, self.topLevelVar),
        }, {
            Ast.FunctionLiteralExpression({Ast.VarargExpression()}, ast.body)
        }
    ));

    -- Create Container Function
    self.activeBlock:emitStatement(Ast.AssignmentStatement({
            var = Ast.AssignmentVariable(self.scope, self.containerFuncVar),
            val = Ast.FunctionLiteralExpression({
                Ast.VariableExpression(self.containerFuncScope, self.posVar),
                Ast.VarargExpression(),
            }, self:emitContainerFuncBody())
        }
    ));

    -- Create Vararg Closure Function
    local createClosureScope = Scope:new(topLevelScope);
    local createClosurePosArg = createClosureScope:addVariable();
    self.activeBlock:emitStatement(Ast.AssignmentStatement({
            var = Ast.AssignmentVariable(self.scope, self.createVarargClosureVar),
            val = Ast.FunctionLiteralExpression({
                    Ast.VariableExpression(createClosureScope, createClosurePosArg),
                    Ast.VarargExpression(),
                }, Ast.Block({
                    Ast.LocalVariableDeclaration(createClosureScope, {createClosureScope:addVariable()}, {
                        Ast.FunctionCallExpression(Ast.VariableExpression(self.scope, self.containerFuncVar), {
                            Ast.VariableExpression(createClosureScope, createClosurePosArg),
                            Ast.FunctionCallExpression(Ast.VariableExpression(self.scope, self.coroutineWrapVar), {
                                Ast.FunctionLiteralExpression({
                                    Ast.VarargExpression();
                                }, Ast.Block({
                                    Ast.ReturnStatement({
                                        Ast.FunctionCallExpression(Ast.VariableExpression(self.scope, self.containerFuncVar), {
                                            Ast.NumberExpression(0),
                                            Ast.VarargExpression(),
                                        })
                                    });
                                }, Scope:new(createClosureScope)))
                            }),
                            Ast.VarargExpression(),
                        })
                    });
                    Ast.ReturnStatement({
                        Ast.IndexExpression(Ast.VariableExpression(createClosureScope, createClosureScope:addVariable()), Ast.NumberExpression(1))
                    });
                }, createClosureScope))
        }
    ));

    -- Compile Top Level
    self:emitStatement(Ast.FunctionCallExpression(Ast.VariableExpression(self.scope, self.containerFuncVar), {
        Ast.NumberExpression(0),
        Ast.VarargExpression(),
    }));

    -- Emit Code
    local functionNode = Ast.FunctionLiteralExpression({
        Ast.VariableExpression(self.scope, self.envVar),
        Ast.VarargExpression(),
    }, Ast.Block(self.activeBlock.statements, self.scope));

    -- Wrap in IIFE with environment capture
    return Ast.Block({
        Ast.FunctionCallExpression(Ast.FunctionLiteralExpression({
            Ast.VarargExpression(),
        }, Ast.Block({
            Ast.LocalVariableDeclaration(self.scope, {self.setmetatableVar}, {Ast.IndexExpression(Ast.VariableExpression(self.scope, self.envVar), Ast.StringExpression("setmetatable"))});
            Ast.LocalVariableDeclaration(self.scope, {self.getmetatableVar}, {Ast.IndexExpression(Ast.VariableExpression(self.scope, self.envVar), Ast.StringExpression("getmetatable"))});
            Ast.LocalVariableDeclaration(self.scope, {self.assertVar}, {Ast.IndexExpression(Ast.VariableExpression(self.scope, self.envVar), Ast.StringExpression("assert"))});
            Ast.LocalVariableDeclaration(self.scope, {self.errorVar}, {Ast.IndexExpression(Ast.VariableExpression(self.scope, self.envVar), Ast.StringExpression("error"))});
            Ast.LocalVariableDeclaration(self.scope, {self.pcallVar}, {Ast.IndexExpression(Ast.VariableExpression(self.scope, self.envVar), Ast.StringExpression("pcall"))});
            Ast.LocalVariableDeclaration(self.scope, {self.selectVar}, {Ast.IndexExpression(Ast.VariableExpression(self.scope, self.envVar), Ast.StringExpression("select"))});
            Ast.LocalVariableDeclaration(self.scope, {self.typeVar}, {Ast.IndexExpression(Ast.VariableExpression(self.scope, self.envVar), Ast.StringExpression("type"))});
            Ast.LocalVariableDeclaration(self.scope, {self.stringSubVar}, {Ast.IndexExpression(Ast.IndexExpression(Ast.VariableExpression(self.scope, self.envVar), Ast.StringExpression("string")), Ast.StringExpression("sub"))});
            Ast.LocalVariableDeclaration(self.scope, {self.stringCharVar}, {Ast.IndexExpression(Ast.IndexExpression(Ast.VariableExpression(self.scope, self.envVar), Ast.StringExpression("string")), Ast.StringExpression("char"))});
            Ast.LocalVariableDeclaration(self.scope, {self.stringByteVar}, {Ast.IndexExpression(Ast.IndexExpression(Ast.VariableExpression(self.scope, self.envVar), Ast.StringExpression("string")), Ast.StringExpression("byte"))});
            Ast.LocalVariableDeclaration(self.scope, {self.stringLenVar}, {Ast.IndexExpression(Ast.IndexExpression(Ast.VariableExpression(self.scope, self.envVar), Ast.StringExpression("string")), Ast.StringExpression("len"))});
            Ast.LocalVariableDeclaration(self.scope, {self.mathFloorVar}, {Ast.IndexExpression(Ast.IndexExpression(Ast.VariableExpression(self.scope, self.envVar), Ast.StringExpression("math")), Ast.StringExpression("floor"))});
            Ast.LocalVariableDeclaration(self.scope, {self.tonumberVar}, {Ast.IndexExpression(Ast.VariableExpression(self.scope, self.envVar), Ast.StringExpression("tonumber"))});
            Ast.LocalVariableDeclaration(self.scope, {self.unpackVar}, {Ast.IndexExpression(Ast.VariableExpression(self.scope, self.envVar), Ast.StringExpression("unpack"))});
            Ast.LocalVariableDeclaration(self.scope, {self.tableConcatVar}, {Ast.IndexExpression(Ast.IndexExpression(Ast.VariableExpression(self.scope, self.envVar), Ast.StringExpression("table")), Ast.StringExpression("concat"))});
            Ast.LocalVariableDeclaration(self.scope, {self.tableInsertVar}, {Ast.IndexExpression(Ast.IndexExpression(Ast.VariableExpression(self.scope, self.envVar), Ast.StringExpression("table")), Ast.StringExpression("insert"))});
            Ast.LocalVariableDeclaration(self.scope, {self.tableRemoveVar}, {Ast.IndexExpression(Ast.IndexExpression(Ast.VariableExpression(self.scope, self.envVar), Ast.StringExpression("table")), Ast.StringExpression("remove"))});
            Ast.LocalVariableDeclaration(self.scope, {self.coroutineWrapVar}, {Ast.IndexExpression(Ast.IndexExpression(Ast.VariableExpression(self.scope, self.envVar), Ast.StringExpression("coroutine")), Ast.StringExpression("wrap"))});
            Ast.LocalVariableDeclaration(self.scope, {self.coroutineYieldVar}, {Ast.IndexExpression(Ast.IndexExpression(Ast.VariableExpression(self.scope, self.envVar), Ast.StringExpression("coroutine")), Ast.StringExpression("yield"))});
            Ast.LocalVariableDeclaration(self.scope, {self.nextVar}, {Ast.IndexExpression(Ast.VariableExpression(self.scope, self.envVar), Ast.StringExpression("next"))});
            Ast.LocalVariableDeclaration(self.scope, {self.pairsVar}, {Ast.IndexExpression(Ast.VariableExpression(self.scope, self.envVar), Ast.StringExpression("pairs"))});
            Ast.LocalVariableDeclaration(self.scope, {self.ipairsVar}, {Ast.IndexExpression(Ast.VariableExpression(self.scope, self.envVar), Ast.StringExpression("ipairs"))});
            Ast.LocalVariableDeclaration(self.scope, {self.rawsetVar}, {Ast.IndexExpression(Ast.VariableExpression(self.scope, self.envVar), Ast.StringExpression("rawset"))});
            Ast.LocalVariableDeclaration(self.scope, {self.rawgetVar}, {Ast.IndexExpression(Ast.VariableExpression(self.scope, self.envVar), Ast.StringExpression("rawget"))});
            Ast.LocalVariableDeclaration(self.scope, {self.rawequalVar}, {Ast.IndexExpression(Ast.VariableExpression(self.scope, self.envVar), Ast.StringExpression("rawequal"))});
            functionNode
        }, self.scope)), {
            Ast.IndexExpression(Ast.VariableExpression(self.scope, self.envVar), Ast.StringExpression("_G")),
            Ast.VarargExpression(),
        })
    }, topLevelScope);
end

function Compiler:createClosureFunction(funcNode, posId)
    local createClosureScope = Scope:new(self.scope);
    local createClosurePosArg = createClosureScope:addVariable();

    local val = Ast.FunctionLiteralExpression({
        Ast.VariableExpression(createClosureScope, createClosurePosArg),
        Ast.VarargExpression(),
    }, Ast.Block({
        Ast.LocalVariableDeclaration(createClosureScope, {createClosureScope:addVariable()}, {
            Ast.FunctionCallExpression(Ast.VariableExpression(self.scope, self.containerFuncVar), {
                Ast.VariableExpression(createClosureScope, createClosurePosArg),
                Ast.FunctionCallExpression(Ast.VariableExpression(self.scope, self.coroutineWrapVar), {
                    Ast.FunctionLiteralExpression(funcNode.args,
                    Ast.Block({
                        Ast.ReturnStatement({
                            Ast.FunctionCallExpression(Ast.VariableExpression(self.scope, self.containerFuncVar), {
                                Ast.NumberExpression(posId),
                                Ast.VarargExpression(),
                            })
                        });
                    }, Scope:new(createClosureScope)))
                }),
                Ast.VarargExpression(),
            })
        });
        Ast.ReturnStatement({
            Ast.IndexExpression(Ast.VariableExpression(createClosureScope, createClosureScope:addVariable()), Ast.NumberExpression(1))
        });
    }, createClosureScope));

    return val;
end

function Compiler:createUpvaluesIteratorFunc()
    local scope = Scope:new(self.scope);
    local selfVar = scope:addVariable();
    scope:addReferenceToHigherScope(self.scope, self.upvaluesTable);
    scope:addReferenceToHigherScope(self.scope, self.allocUpvalVar);
    scope:addReferenceToHigherScope(self.scope, self.upvaluesReferenceCountsTable);

    return Ast.FunctionLiteralExpression({Ast.VariableExpression(scope, selfVar)}, Ast.Block({
        Ast.LocalVariableDeclaration(scope, {scope:addVariable(), scope:addVariable()}, {Ast.NumberExpression(1), Ast.IndexExpression(Ast.VariableExpression(scope, selfVar), Ast.NumberExpression(1))}),
        Ast.ReturnStatement({Ast.FunctionLiteralExpression({}, Ast.Block({
            Ast.LocalVariableDeclaration(scope, {scope:addVariable()}, {Ast.IndexExpression(Ast.VariableExpression(scope, selfVar), Ast.NumberExpression(2))}),
            Ast.IfStatement({
                condition = Ast.LessThanExpression(Ast.IndexExpression(Ast.VariableExpression(scope, selfVar), Ast.NumberExpression(1)), Ast.LenExpression(Ast.VariableExpression(scope, scope:addVariable()))),
                body = Ast.Block({
                    Ast.LocalVariableDeclaration(scope, {scope:addVariable()}, {Ast.IndexExpression(Ast.VariableExpression(scope, scope:addVariable()), Ast.IndexExpression(Ast.VariableExpression(scope, selfVar), Ast.NumberExpression(1)))}),
                    Ast.AssignmentStatement({
                        Ast.AssignmentIndexing(Ast.VariableExpression(scope, selfVar), Ast.NumberExpression(1)),
                    }, {
                        Ast.AddExpression(unpack(util.shuffle{
                            Ast.IndexExpression(Ast.VariableExpression(scope, selfVar), Ast.NumberExpression(1)),
                            Ast.NumberExpression(1),
                        })),
                    }),
                    Ast.ReturnStatement({Ast.IndexExpression(Ast.VariableExpression(scope, scope:addVariable()), Ast.NumberExpression(1)), Ast.IndexExpression(Ast.VariableExpression(scope, scope:addVariable()), Ast.NumberExpression(2))}),
                }, Scope:new(scope)),
            }, {}, Ast.Block({
                Ast.ReturnStatement({}),
            }, Scope:new(scope)))
        }, Scope:new(scope))}),
    }, scope))
end

function Compiler:createUpvaluesGcFunc()
    local scope = Scope:new(self.scope);
    local argVar = scope:addVariable();
    scope:addReferenceToHigherScope(self.scope, self.upvaluesReferenceCountsTable, 2);
    scope:addReferenceToHigherScope(self.scope, self.upvaluesTable, 2);
    return Ast.FunctionLiteralExpression({Ast.VariableExpression(scope, argVar)}, Ast.Block({
        Ast.AssignmentStatement({
            Ast.AssignmentIndexing(Ast.VariableExpression(self.scope, self.upvaluesReferenceCountsTable), Ast.VariableExpression(scope, argVar)),
        }, {
            Ast.SubExpression(unpack(util.shuffle{
                Ast.IndexExpression(Ast.VariableExpression(self.scope, self.upvaluesReferenceCountsTable), Ast.VariableExpression(scope, argVar)),
                Ast.NumberExpression(1),
            })),
        }),
        Ast.IfStatement({
            condition = Ast.LessThanExpression(Ast.IndexExpression(Ast.VariableExpression(self.scope, self.upvaluesReferenceCountsTable), Ast.VariableExpression(scope, argVar)), Ast.NumberExpression(1)),
            body = Ast.Block({
                Ast.AssignmentStatement({
                    Ast.AssignmentIndexing(Ast.VariableExpression(self.scope, self.upvaluesReferenceCountsTable), Ast.VariableExpression(scope, argVar)),
                    Ast.AssignmentIndexing(Ast.VariableExpression(self.scope, self.upvaluesTable), Ast.VariableExpression(scope, argVar)),
                }, {
                    Ast.NilExpression(),
                    Ast.NilExpression(),
                })
            }, Scope:new(scope)),
        }, {}, nil)
    }, scope))
end

function Compiler:createUpvaluesProxyFunc()
    local scope = Scope:new(self.scope);
    -- newproxy not available in Roblox; use table-based proxy fallback
    scope:addReferenceToHigherScope(self.scope, self.setmetatableVar);

    local entriesVar = scope:addVariable();

    local ifScope = Scope:new(scope);
    local proxyVar = ifScope:addVariable();
    local metatableVar = ifScope:addVariable();
    local elseScope = Scope:new(scope);
    ifScope:addReferenceToHigherScope(self.scope, self.setmetatableVar);
    ifScope:addReferenceToHigherScope(self.scope, self.getmetatableVar);
    ifScope:addReferenceToHigherScope(self.scope, self.upvaluesGcFunctionVar);
    ifScope:addReferenceToHigherScope(scope, entriesVar);
    elseScope:addReferenceToHigherScope(self.scope, self.setmetatableVar);
    elseScope:addReferenceToHigherScope(scope, entriesVar);
    elseScope:addReferenceToHigherScope(self.scope, self.upvaluesGcFunctionVar);

    local forScope = Scope:new(scope);
    local forArg = forScope:addVariable();
    forScope:addReferenceToHigherScope(self.scope, self.upvaluesReferenceCountsTable, 2);
    forScope:addReferenceToHigherScope(scope, entriesVar, 2);

    -- Build function body statements
    local bodyStatements = {}
    
    -- For loop
    table.insert(bodyStatements, Ast.ForStatement(forScope, forArg, Ast.NumberExpression(1), Ast.LenExpression(Ast.VariableExpression(scope, entriesVar)), Ast.NumberExpression(1), Ast.Block({
        Ast.AssignmentStatement({
            Ast.AssignmentIndexing(Ast.VariableExpression(self.scope, self.upvaluesReferenceCountsTable), Ast.IndexExpression(Ast.VariableExpression(scope, entriesVar), Ast.VariableExpression(forScope, forArg)))
        }, {
            Ast.AddExpression(unpack(util.shuffle{
                Ast.IndexExpression(Ast.VariableExpression(self.scope, self.upvaluesReferenceCountsTable), Ast.IndexExpression(Ast.VariableExpression(scope, entriesVar), Ast.VariableExpression(forScope, forArg))),
                Ast.NumberExpression(1),
            }))
        })
    }, forScope), scope))
    
    -- Roblox: use table-based proxy instead of newproxy
    table.insert(bodyStatements, Ast.LocalVariableDeclaration(ifScope, {proxyVar}, {
        Ast.TableConstructorExpression({})
    }))
    table.insert(bodyStatements, Ast.LocalVariableDeclaration(ifScope, {metatableVar}, {
        Ast.TableConstructorExpression({
            Ast.KeyedTableEntry(Ast.StringExpression("__index"), Ast.VariableExpression(scope, entriesVar)),
            Ast.KeyedTableEntry(Ast.StringExpression("__len"), Ast.FunctionLiteralExpression({}, Ast.Block({
                Ast.ReturnStatement({Ast.NumberExpression(self.upvalsProxyLenReturn)})
            }, Scope:new(ifScope))))
        })
    }))
    table.insert(bodyStatements, Ast.ReturnStatement({
        Ast.VariableExpression(ifScope, proxyVar)
    }))
    
    return Ast.FunctionLiteralExpression({Ast.VariableExpression(scope, entriesVar)}, Ast.Block(bodyStatements, scope))
end

function Compiler:createAllocUpvalFunction()
    local scope = Scope:new(self.scope);
    scope:addReferenceToHigherScope(self.scope, self.currentUpvalId, 4);
    scope:addReferenceToHigherScope(self.scope, self.upvaluesReferenceCountsTable, 1);

    return Ast.FunctionLiteralExpression({}, Ast.Block({
        Ast.AssignmentStatement({
                Ast.AssignmentVariable(self.scope, self.currentUpvalId),
            },{
                Ast.AddExpression(unpack(util.shuffle({
                    Ast.VariableExpression(self.scope, self.currentUpvalId),
                    Ast.NumberExpression(1),
                }))),
            }
        ),
        Ast.AssignmentStatement({
            Ast.AssignmentIndexing(Ast.VariableExpression(self.scope, self.upvaluesReferenceCountsTable), Ast.VariableExpression(self.scope, self.currentUpvalId)),
        }, {
            Ast.NumberExpression(1),
        }),
        Ast.ReturnStatement({
            Ast.VariableExpression(self.scope, self.currentUpvalId),
        })
    }, scope));
end

function Compiler:emitContainerFuncBody()
    local blocks = {};

    util.shuffle(self.blocks);

    for _, block in ipairs(self.blocks) do
        local id = block.posId;
        local blockstats = block.statements;
        local stats = {};

        for _, stat in ipairs(blockstats) do
            table.insert(stats, stat);
        end

        table.insert(blocks, Ast.IfStatement({
            condition = Ast.EqualExpression(Ast.VariableExpression(self.containerFuncScope, self.posVar), Ast.NumberExpression(id)),
            body = Ast.Block(stats, Scope:new(self.containerFuncScope)),
        }));
    end

    return Ast.Block({
        Ast.WhileStatement(
            Ast.BooleanExpression(true),
            Ast.Block({
                Ast.IfStatement(blocks, {}, Ast.Block({
                    Ast.BreakStatement(),
                }, Scope:new(self.containerFuncScope))),
            }, Scope:new(self.containerFuncScope))
        ),
    }, self.containerFuncScope);
end

function Compiler:createBlock()
    local block = {
        rawId = #self.blocks;
        posId = nil;
        statements = {};
    };
    block.posId = self:encodePos(block.rawId);
    table.insert(self.blocks, block);
    return block;
end

-- Encode a raw block ID to an obfuscated posId using XOR with key
function Compiler:encodePos(rawId)
    if self.posIdMap[rawId] then
        return self.posIdMap[rawId];
    end
    local encoded = bit32.bxor(rawId, self.posKey);
    self.posIdMap[rawId] = encoded;
    return encoded;
end

function Compiler:setActiveBlock(block)
    self.activeBlock = block;
end

function Compiler:emitStatement(stat)
    self.activeBlock:emitStatement(stat);
end

function Compiler:allocateRegister()
    local reg = #self.registers;
    table.insert(self.registers, self.VAR_REGISTER);
    self.usedRegisters = self.usedRegisters + 1;
    if self.usedRegisters > self.maxUsedRegister then
        self.maxUsedRegister = self.usedRegisters;
    end
    return reg;
end

function Compiler:freeRegister()
    self.usedRegisters = self.usedRegisters - 1;
end

function Compiler:getRegisterCount()
    return self.usedRegisters;
end

function Compiler:registerForVar(var)
    if not self.registersForVar[var] then
        self.registersForVar[var] = self:allocateRegister();
    end
    return self.registersForVar[var];
end

function Compiler:compileExpression(expr)
    local kind = expr.kind;
    
    if kind == AstKind.NumberExpression then
        return self:compileNumberExpression(expr);
    elseif kind == AstKind.StringExpression then
        return self:compileStringExpression(expr);
    elseif kind == AstKind.BooleanExpression then
        return self:compileBooleanExpression(expr);
    elseif kind == AstKind.NilExpression then
        return self:compileNilExpression();
    elseif kind == AstKind.VariableExpression then
        return self:compileVariableExpression(expr);
    elseif kind == AstKind.BinaryExpression then
        return self:compileBinaryExpression(expr);
    elseif kind == AstKind.UnaryExpression then
        return self:compileUnaryExpression(expr);
    elseif kind == AstKind.FunctionCallExpression then
        return self:compileFunctionCallExpression(expr);
    elseif kind == AstKind.TableConstructorExpression then
        return self:compileTableConstructorExpression(expr);
    elseif kind == AstKind.IndexExpression then
        return self:compileIndexExpression(expr);
    elseif kind == AstKind.FunctionLiteralExpression then
        return self:compileFunctionLiteralExpression(expr);
    elseif kind == AstKind.VarargExpression then
        return self:compileVarargExpression();
    else
        logger:error("Unsupported expression kind: " .. tostring(kind));
    end
end

function Compiler:compileNumberExpression(expr)
    local reg = self:allocateRegister();
    self:emitStatement(Ast.AssignmentStatement({
        Ast.AssignmentVariable(self.scope, reg),
    }, {
        expr,
    }));
    return reg;
end

function Compiler:compileStringExpression(expr)
    local reg = self:allocateRegister();
    self:emitStatement(Ast.AssignmentStatement({
        Ast.AssignmentVariable(self.scope, reg),
    }, {
        expr,
    }));
    return reg;
end

function Compiler:compileBooleanExpression(expr)
    local reg = self:allocateRegister();
    self:emitStatement(Ast.AssignmentStatement({
        Ast.AssignmentVariable(self.scope, reg),
    }, {
        expr,
    }));
    return reg;
end

function Compiler:compileNilExpression()
    local reg = self:allocateRegister();
    self:emitStatement(Ast.AssignmentStatement({
        Ast.AssignmentVariable(self.scope, reg),
    }, {
        Ast.NilExpression(),
    }));
    return reg;
end

function Compiler:compileVariableExpression(expr)
    local reg = self:allocateRegister();
    self:emitStatement(Ast.AssignmentStatement({
        Ast.AssignmentVariable(self.scope, reg),
    }, {
        expr,
    }));
    return reg;
end

function Compiler:compileBinaryExpression(expr)
    local leftReg = self:compileExpression(expr.left);
    local rightReg = self:compileExpression(expr.right);
    local resultReg = self:allocateRegister();
    
    self:emitStatement(Ast.AssignmentStatement({
        Ast.AssignmentVariable(self.scope, resultReg),
    }, {
        Ast.BinaryExpression(expr.operator, 
            Ast.VariableExpression(self.scope, leftReg),
            Ast.VariableExpression(self.scope, rightReg)
        ),
    }));
    
    self:freeRegister();
    self:freeRegister();
    
    return resultReg;
end

function Compiler:compileUnaryExpression(expr)
    local operandReg = self:compileExpression(expr.operand);
    local resultReg = self:allocateRegister();
    
    self:emitStatement(Ast.AssignmentStatement({
        Ast.AssignmentVariable(self.scope, resultReg),
    }, {
        Ast.UnaryExpression(expr.operator, Ast.VariableExpression(self.scope, operandReg)),
    }));
    
    self:freeRegister();
    
    return resultReg;
end

function Compiler:compileFunctionCallExpression(expr)
    local funcReg = self:compileExpression(expr.func);
    local argRegs = {};
    
    for _, arg in ipairs(expr.args) do
        table.insert(argRegs, self:compileExpression(arg));
    end
    
    local resultRegs = {};
    for i = 1, #expr.returnValues do
        table.insert(resultRegs, self:allocateRegister());
    end
    
    local callArgs = {Ast.VariableExpression(self.scope, funcReg)};
    for _, reg in ipairs(argRegs) do
        table.insert(callArgs, Ast.VariableExpression(self.scope, reg));
    end
    
    self:emitStatement(Ast.AssignmentStatement(
        util.shuffle(resultRegs),
        {Ast.FunctionCallExpression(Ast.VariableExpression(self.scope, funcReg), callArgs)}
    ));
    
    for _ = 1, #argRegs do
        self:freeRegister();
    end
    self:freeRegister();
    
    return resultRegs[1] or self:allocateRegister();
end

function Compiler:compileTableConstructorExpression(expr)
    local reg = self:allocateRegister();
    self:emitStatement(Ast.AssignmentStatement({
        Ast.AssignmentVariable(self.scope, reg),
    }, {
        Ast.TableConstructorExpression({}),
    }));
    
    for _, entry in ipairs(expr.entries) do
        if entry.kind == AstKind.KeyedTableEntry then
            local keyReg = self:compileExpression(entry.key);
            local valueReg = self:compileExpression(entry.value);
            self:emitStatement(Ast.AssignmentStatement({
                Ast.AssignmentIndexing(Ast.VariableExpression(self.scope, reg), Ast.VariableExpression(self.scope, keyReg)),
            }, {
                Ast.VariableExpression(self.scope, valueReg),
            }));
            self:freeRegister();
            self:freeRegister();
        elseif entry.kind == AstKind.NumberKeyedTableEntry then
            local valueReg = self:compileExpression(entry.value);
            self:emitStatement(Ast.AssignmentStatement({
                Ast.AssignmentIndexing(Ast.VariableExpression(self.scope, reg), Ast.NumberExpression(entry.key)),
            }, {
                Ast.VariableExpression(self.scope, valueReg),
            }));
            self:freeRegister();
        elseif entry.kind == AstKind.StringKeyedTableEntry then
            local valueReg = self:compileExpression(entry.value);
            self:emitStatement(Ast.AssignmentStatement({
                Ast.AssignmentIndexing(Ast.VariableExpression(self.scope, reg), Ast.StringExpression(entry.key)),
            }, {
                Ast.VariableExpression(self.scope, valueReg),
            }));
            self:freeRegister();
        end
    end
    
    return reg;
end

function Compiler:compileIndexExpression(expr)
    local baseReg = self:compileExpression(expr.base);
    local indexReg = self:compileExpression(expr.index);
    local resultReg = self:allocateRegister();
    
    self:emitStatement(Ast.AssignmentStatement({
        Ast.AssignmentVariable(self.scope, resultReg),
    }, {
        Ast.IndexExpression(
            Ast.VariableExpression(self.scope, baseReg),
            Ast.VariableExpression(self.scope, indexReg)
        ),
    }));
    
    self:freeRegister();
    self:freeRegister();
    
    return resultReg;
end

function Compiler:compileFunctionLiteralExpression(expr)
    -- Create a closure that will be called by the VM
    local posId = self:createBlock().posId;
    return self:createClosureFunction(expr, posId);
end

function Compiler:compileVarargExpression()
    local reg = self:allocateRegister();
    self:emitStatement(Ast.AssignmentStatement({
        Ast.AssignmentVariable(self.scope, reg),
    }, {
        Ast.VarargExpression(),
    }));
    return reg;
end

function Compiler:compileStatement(stat)
    local kind = stat.kind;
    
    if kind == AstKind.AssignmentStatement then
        self:compileAssignmentStatement(stat);
    elseif kind == AstKind.LocalVariableDeclaration then
        self:compileLocalVariableDeclaration(stat);
    elseif kind == AstKind.FunctionCallStatement then
        self:compileFunctionCallStatement(stat);
    elseif kind == AstKind.IfStatement then
        self:compileIfStatement(stat);
    elseif kind == AstKind.WhileStatement then
        self:compileWhileStatement(stat);
    elseif kind == AstKind.RepeatStatement then
        self:compileRepeatStatement(stat);
    elseif kind == AstKind.ForStatement then
        self:compileForStatement(stat);
    elseif kind == AstKind.ForInStatement then
        self:compileForInStatement(stat);
    elseif kind == AstKind.DoStatement then
        self:compileDoStatement(stat);
    elseif kind == AstKind.ReturnStatement then
        self:compileReturnStatement(stat);
    elseif kind == AstKind.BreakStatement then
        self:compileBreakStatement();
    elseif kind == AstKind.ContinueStatement then
        self:compileContinueStatement();
    else
        logger:error("Unsupported statement kind: " .. tostring(kind));
    end
end

function Compiler:compileAssignmentStatement(stat)
    local valueRegs = {};
    for _, value in ipairs(stat.values) do
        table.insert(valueRegs, self:compileExpression(value));
    end
    
    for i, target in ipairs(stat.targets) do
        local valueReg = valueRegs[i] or valueRegs[#valueRegs];
        if target.kind == AstKind.AssignmentVariable then
            self:emitStatement(Ast.AssignmentStatement({
                Ast.AssignmentVariable(self.scope, target.id),
            }, {
                Ast.VariableExpression(self.scope, valueReg),
            }));
        elseif target.kind == AstKind.AssignmentIndexing then
            local baseReg = self:compileExpression(target.base);
            local indexReg = self:compileExpression(target.index);
            self:emitStatement(Ast.AssignmentStatement({
                Ast.AssignmentIndexing(
                    Ast.VariableExpression(self.scope, baseReg),
                    Ast.VariableExpression(self.scope, indexReg)
                ),
            }, {
                Ast.VariableExpression(self.scope, valueReg),
            }));
            self:freeRegister();
            self:freeRegister();
        end
    end
    
    for _ = 1, #valueRegs do
        self:freeRegister();
    end
end

function Compiler:compileLocalVariableDeclaration(stat)
    for i, var in ipairs(stat.ids) do
        local value = stat.values[i];
        if value then
            local valueReg = self:compileExpression(value);
            self:emitStatement(Ast.LocalVariableDeclaration(self.scope, {var}, {
                Ast.VariableExpression(self.scope, valueReg),
            }));
            self:freeRegister();
        else
            self:emitStatement(Ast.LocalVariableDeclaration(self.scope, {var}, {
                Ast.NilExpression(),
            }));
        end
    end
end

function Compiler:compileFunctionCallStatement(stat)
    self:compileFunctionCallExpression(stat.expression);
end

function Compiler:compileIfStatement(stat)
    for _, clause in ipairs(stat.clauses) do
        local conditionReg = self:compileExpression(clause.condition);
        -- Emit conditional jump
        self:emitStatement(Ast.IfStatement({
            condition = Ast.VariableExpression(self.scope, conditionReg),
            body = self:compileBlock(clause.body),
        }));
        self:freeRegister();
    end
    
    if stat.elseBody then
        self:emitStatement(Ast.DoStatement(self:compileBlock(stat.elseBody)));
    end
end

function Compiler:compileWhileStatement(stat)
    local conditionReg = self:compileExpression(stat.condition);
    self:emitStatement(Ast.WhileStatement(
        Ast.VariableExpression(self.scope, conditionReg),
        self:compileBlock(stat.body)
    ));
    self:freeRegister();
end

function Compiler:compileRepeatStatement(stat)
    self:emitStatement(Ast.RepeatStatement(
        self:compileBlock(stat.body),
        self:compileExpression(stat.condition)
    ));
end

function Compiler:compileForStatement(stat)
    local initReg = self:compileExpression(stat.init);
    local limitReg = self:compileExpression(stat.limit);
    local stepReg = stat.step and self:compileExpression(stat.step) or nil;
    
    self:emitStatement(Ast.ForStatement(
        stat.scope,
        stat.var,
        Ast.VariableExpression(self.scope, initReg),
        Ast.VariableExpression(self.scope, limitReg),
        stepReg and Ast.VariableExpression(self.scope, stepReg) or Ast.NumberExpression(1),
        self:compileBlock(stat.body)
    ));
    
    self:freeRegister();
    self:freeRegister();
    if stepReg then self:freeRegister(); end
end

function Compiler:compileForInStatement(stat)
    local exprRegs = {};
    for _, expr in ipairs(stat.expressions) do
        table.insert(exprRegs, self:compileExpression(expr));
    end
    
    self:emitStatement(Ast.ForInStatement(
        stat.scope,
        stat.vars,
        util.shuffle(exprRegs),
        self:compileBlock(stat.body)
    ));
    
    for _ = 1, #exprRegs do
        self:freeRegister();
    end
end

function Compiler:compileDoStatement(stat)
    self:emitStatement(Ast.DoStatement(self:compileBlock(stat.body)));
end

function Compiler:compileReturnStatement(stat)
    local returnRegs = {};
    for _, expr in ipairs(stat.values) do
        table.insert(returnRegs, self:compileExpression(expr));
    end
    
    self:emitStatement(Ast.ReturnStatement(util.shuffle(returnRegs)));
    
    for _ = 1, #returnRegs do
        self:freeRegister();
    end
end

function Compiler:compileBreakStatement()
    self:emitStatement(Ast.BreakStatement());
end

function Compiler:compileContinueStatement()
    self:emitStatement(Ast.ContinueStatement());
end

function Compiler:compileBlock(block)
    local oldBlock = self.activeBlock;
    local newBlock = self:createBlock();
    self:setActiveBlock(newBlock);
    
    for _, stat in ipairs(block.statements) do
        self:compileStatement(stat);
    end
    
    self:setActiveBlock(oldBlock);
    return Ast.Block(newBlock.statements, block.scope);
end

return Compiler;
