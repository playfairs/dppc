module lowering.lowering;

import ast.ast : Expr, ExprKind, FunctionDecl, ObjectLifetime, Program, Stmt, StmtKind, TypeKind;
import ir.ir;
import symbols.symbols : FunctionSymbol, StructSymbol, SymbolTable;
import std.algorithm.searching : canFind;
import std.conv : to;

private struct Value
{
    string name;
    TypeKind type;
    string namedType;
}

private class LocalScope
{
    private LocalScope parent;
    private string[string] slots;
    private string[string] namedTypes;

    this(LocalScope parent = null)
    {
        this.parent = parent;
    }

    void define(string name, string slot, string namedType = "")
    {
        slots[name] = slot;
        namedTypes[name] = namedType;
    }

    bool lookup(string name, out string slot) const
    {
        if (auto value = name in slots)
        {
            slot = *value;
            return true;
        }
        return parent !is null && parent.lookup(name, slot);
    }

    bool lookupNamedType(string name, out string namedType) const
    {
        if (auto value = name in namedTypes)
        {
            namedType = *value;
            return true;
        }
        return parent !is null && parent.lookupNamedType(name, namedType);
    }
}

private struct CleanupAction
{
    Expr expression;
    string destructorName;
    string[] arguments;
    TypeKind[] argumentTypes;
    bool isDestructor;
    bool[] indirectArguments;
}

private class CleanupFrame
{
    private CleanupAction[] actions;
    private LocalScope locals;

    this(LocalScope locals)
    {
        this.locals = locals;
    }
}

private struct LoopFrame
{
    string breakLabel;
    string continueLabel;
    size_t cleanupDepth;
}

private class FunctionLowerer
{
    private Function loweredFunction;
    private FunctionSymbol[string] symbols;
    private size_t temporaryIndex;
    private size_t labelIndex;
    private CleanupFrame[] cleanupFrames;
    private LoopFrame[] loopFrames;
    private string[string] destructors;
    private StructSymbol[string] structures;
    private FunctionDecl declaration;

    this(FunctionDecl declaration, FunctionSymbol[string] symbols,
            string[string] destructors, StructSymbol[string] structures)
    {
        this.declaration = declaration;
        loweredFunction.name = declaration.name;
        loweredFunction.returnType = declaration.returnType;
        loweredFunction.externC = declaration.externC;
        loweredFunction.hasBody = declaration.hasBody;
        this.symbols = symbols;
        this.destructors = destructors;
        this.structures = structures;
        foreach (parameter; declaration.parameters)
        {
            loweredFunction.parameters ~= ir.ir.Parameter(parameter.name,
                    parameter.type, parameter.isReference);
        }
    }

    Function lower(FunctionDecl declaration)
    {
        auto locals = new LocalScope();
        emitLabel("entry");
        foreach (index, parameter; declaration.parameters)
        {
            if (parameter.isReference)
            {
                locals.define(parameter.name, "%arg" ~ to!string(index), parameter.namedType);
                continue;
            }
            auto slot = newTemporary();
            auto allocation = Instruction(Opcode.alloca, parameter.type, [], slot);
            allocation.namedType = parameter.namedType;
            emit(allocation);
            auto initialization = Instruction(Opcode.store, parameter.type,
                    [parameter.type], "", "", "", [
                        slot, "%arg" ~ to!string(index)
            ]);
            initialization.namedType = parameter.namedType;
            emit(initialization);
            locals.define(parameter.name, slot, parameter.namedType);
        }

        auto terminated = lowerStatements(declaration.body, locals);
        if (!terminated)
        {
            if (loweredFunction.returnType == TypeKind.voidType)
            {
                emit(Instruction(Opcode.returnVoid));
            }
            else
            {
                emit(Instruction(Opcode.returnValue, loweredFunction.returnType,
                        [loweredFunction.returnType], "", "", "", ["0"]));
            }
        }
        return loweredFunction;
    }

    private bool lowerStatements(ref Stmt[] statements, LocalScope locals)
    {
        auto frame = new CleanupFrame(locals);
        cleanupFrames ~= frame;
        if (cleanupFrames.length == 1 && declaration.isDestructor)
        {
            registerMemberDestructors(frame, declaration.ownerType, "%arg0");
        }
        bool terminated;
        foreach (ref statement; statements)
        {
            if (lowerStatement(statement, locals))
            {
                terminated = true;
                break;
            }
        }
        if (!terminated)
        {
            emitCleanups(frame);
        }
        cleanupFrames = cleanupFrames[0 .. $ - 1];
        return terminated;
    }

    private bool lowerStatement(ref Stmt statement, LocalScope locals)
    {
        final switch (statement.kind)
        {
        case StmtKind.block:
            return lowerStatements(statement.body, new LocalScope(locals));
        case StmtKind.variable:
            if (statement.declaredType == TypeKind.fixedArray)
            {
                lowerStructArrayVariable(statement, locals);
                return false;
            }
            if (statement.declaredType == TypeKind.structType)
            {
                lowerStructVariable(statement, locals);
                return false;
            }
            auto value = lowerExpression(statement.expression, locals);
            value = convert(value, statement.declaredType);
            auto slot = newTemporary();
            emit(Instruction(Opcode.alloca, statement.declaredType, [], slot));
            emit(Instruction(Opcode.store, statement.declaredType,
                    [statement.declaredType], "", "", "", [slot, value.name]));
            locals.define(statement.name, slot);
            return false;
        case StmtKind.expression:
            lowerExpression(statement.expression, locals);
            return false;
        case StmtKind.scopeExit:
            cleanupFrames[$ - 1].actions ~= CleanupAction(statement.expression,
                    "", [], [], false, []);
            return false;
        case StmtKind.breakStatement:
            emitLoopExit(true);
            return true;
        case StmtKind.continueStatement:
            emitLoopExit(false);
            return true;
        case StmtKind.returnStatement:
            Value returnValue;
            if (!statement.hasExpression)
            {
                returnValue = Value("", TypeKind.voidType);
            }
            else
            {
                returnValue = lowerExpression(statement.expression, locals);
                returnValue = convert(returnValue, loweredFunction.returnType);
            }
            emitActiveCleanups();
            if (!statement.hasExpression)
            {
                emit(Instruction(Opcode.returnVoid));
            }
            else
            {
                emit(Instruction(Opcode.returnValue, loweredFunction.returnType,
                        [loweredFunction.returnType], "", "", "", [
                            returnValue.name
                ]));
            }
            return true;
        case StmtKind.ifStatement:
            return lowerIf(statement, locals);
        case StmtKind.whileStatement:
            lowerWhile(statement, locals);
            return false;
        }
    }

    private void lowerStructVariable(ref Stmt statement, LocalScope locals)
    {
        Value[] arguments;
        if (statement.hasExpression)
        {
            foreach (ref argument; statement.expression.arguments)
            {
                arguments ~= lowerExpression(argument, locals);
            }
        }

        auto slot = newTemporary();
        auto allocation = Instruction(Opcode.alloca, TypeKind.structType, [], slot);
        allocation.namedType = statement.declaredNamedType;
        emit(allocation);
        auto initialization = Instruction(Opcode.store, TypeKind.structType,
                [TypeKind.structType], "", "", "", [slot, "zeroinitializer"]);
        initialization.namedType = statement.declaredNamedType;
        emit(initialization);

        statement.objectLifetime = ObjectLifetime.constructing;
        initializeStructMembers(statement.declaredNamedType, slot);
        if (statement.selectedConstructor.length)
        {
            invokeConstructor(statement.selectedConstructor, slot, arguments);
        }
        statement.objectLifetime = ObjectLifetime.live;
        locals.define(statement.name, slot, statement.declaredNamedType);

        auto structure = structures[statement.declaredNamedType];
        if (structure.needsDestruction)
        {
            appendDestructorAction(cleanupFrames[$ - 1], structure.destructorName, slot);
        }
    }

    private void lowerStructArrayVariable(ref Stmt statement, LocalScope locals)
    {
        auto slot = newTemporary();
        auto allocation = Instruction(Opcode.alloca, TypeKind.fixedArray, [], slot);
        allocation.namedType = statement.declaredNamedType;
        allocation.arrayLength = statement.arrayLength;
        emit(allocation);
        auto initialization = Instruction(Opcode.store, TypeKind.fixedArray,
                [TypeKind.fixedArray], "", "", "", [slot, "zeroinitializer"]);
        initialization.namedType = statement.declaredNamedType;
        initialization.arrayLength = statement.arrayLength;
        emit(initialization);

        statement.objectLifetime = ObjectLifetime.constructing;
        auto elementType = statement.declaredNamedType;
        foreach (index; 0 .. statement.arrayLength)
        {
            auto elementSlot = emitArrayElementAddress(slot, elementType,
                    statement.arrayLength, index);
            initializeStructMembers(elementType, elementSlot);
            auto defaultConstructor = defaultConstructorName(elementType);
            if (defaultConstructor.length)
            {
                invokeConstructor(defaultConstructor, elementSlot, []);
            }
            auto elementMetadata = structures[elementType];
            if (elementMetadata.needsDestruction)
            {
                appendDestructorAction(cleanupFrames[$ - 1],
                        elementMetadata.destructorName, elementSlot);
            }
        }
        statement.objectLifetime = ObjectLifetime.live;
        locals.define(statement.name, slot, statement.declaredNamedType);
    }

    private void initializeStructMembers(string typeName, string slot)
    {
        auto structure = structures[typeName];
        foreach (index, field; structure.fields)
        {
            if (field.type != TypeKind.structType && field.type != TypeKind.fixedArray)
            {
                continue;
            }
            if (field.type == TypeKind.fixedArray)
            {
                foreach (elementIndex; 0 .. field.arrayLength)
                {
                    auto arraySlot = emitFieldAddress(slot, typeName, index);
                    auto elementSlot = emitArrayElementAddress(arraySlot,
                            field.namedType, field.arrayLength, elementIndex);
                    initializeStructMembers(field.namedType, elementSlot);
                    auto defaultConstructor = defaultConstructorName(field.namedType);
                    if (defaultConstructor.length)
                    {
                        invokeConstructor(defaultConstructor, elementSlot, []);
                    }
                }
            }
            else
            {
                auto fieldSlot = emitFieldAddress(slot, typeName, index);
                initializeStructMembers(field.namedType, fieldSlot);
                auto defaultConstructor = defaultConstructorName(field.namedType);
                if (defaultConstructor.length)
                {
                    invokeConstructor(defaultConstructor, fieldSlot, []);
                }
            }
        }
    }

    private string defaultConstructorName(string typeName)
    {
        auto structure = structures[typeName];
        foreach (name; structure.constructorNames)
        {
            if (symbols[name].parameterTypes.length == 1)
            {
                return name;
            }
        }
        return "";
    }

    private void invokeConstructor(string name, string slot, Value[] arguments)
    {
        auto constructor = symbols[name];
        string[] operands = [slot];
        TypeKind[] operandTypes = [TypeKind.structType];
        bool[] indirectArguments = [true];
        foreach (index, value; arguments)
        {
            auto targetType = constructor.parameterTypes[index + 1];
            auto converted = convert(value, targetType);
            operands ~= converted.name;
            operandTypes ~= targetType;
            indirectArguments ~= false;
        }
        auto call = Instruction(Opcode.call, TypeKind.voidType, operandTypes,
                "", name, "", operands);
        call.indirectArguments = indirectArguments;
        emit(call);
    }

    private void registerMemberDestructors(CleanupFrame frame, string typeName, string receiver)
    {
        auto structure = structures[typeName];
        foreach (index, field; structure.fields)
        {
            if (field.type != TypeKind.structType && field.type != TypeKind.fixedArray)
            {
                continue;
            }
            auto nested = structures[field.namedType];
            if (!nested.needsDestruction)
            {
                continue;
            }
            if (field.type == TypeKind.fixedArray)
            {
                foreach (elementIndex; 0 .. field.arrayLength)
                {
                    auto arraySlot = emitFieldAddress(receiver, typeName, index);
                    auto fieldSlot = emitArrayElementAddress(arraySlot,
                            field.namedType, field.arrayLength, elementIndex);
                    appendDestructorAction(frame, nested.destructorName, fieldSlot);
                }
            }
            else
            {
                auto fieldSlot = emitFieldAddress(receiver, typeName, index);
                appendDestructorAction(frame, nested.destructorName, fieldSlot);
            }
        }
    }

    private void appendDestructorAction(CleanupFrame frame, string destructorName, string slot)
    {
        frame.actions ~= CleanupAction(Expr.init, destructorName, [slot],
                [TypeKind.structType], true, [true]);
    }

    private string emitFieldAddress(string base, string ownerType, size_t index)
    {
        auto result = newTemporary();
        auto instruction = Instruction(Opcode.fieldAddress, TypeKind.structType,
                [], result, to!string(index), ownerType, [base]);
        instruction.namedType = ownerType;
        emit(instruction);
        return result;
    }

    private string emitArrayElementAddress(string base, string elementType,
            size_t length, size_t index)
    {
        auto result = newTemporary();
        auto instruction = Instruction(Opcode.arrayElementAddress,
                TypeKind.structType, [], result, "", "", [
                    base, to!string(index)
        ]);
        instruction.namedType = elementType;
        instruction.arrayLength = length;
        emit(instruction);
        return result;
    }

    private void emitActiveCleanups()
    {
        for (size_t frameIndex = cleanupFrames.length; frameIndex > 0; frameIndex--)
        {
            emitCleanups(cleanupFrames[frameIndex - 1]);
        }
    }

    private void emitCleanups(CleanupFrame frame)
    {
        for (size_t actionIndex = frame.actions.length; actionIndex > 0; actionIndex--)
        {
            auto action = frame.actions[actionIndex - 1];
            if (action.isDestructor)
            {
                auto call = Instruction(Opcode.call, TypeKind.voidType,
                        action.argumentTypes, "", action.destructorName, "", action.arguments);
                call.indirectArguments = action.indirectArguments;
                emit(call);
            }
            else
            {
                lowerExpression(action.expression, frame.locals);
            }
        }
    }

    private void emitLoopExit(bool breaking)
    {
        auto loop = loopFrames[$ - 1];
        for (size_t frameIndex = cleanupFrames.length; frameIndex > loop.cleanupDepth;
                frameIndex--)
        {
            emitCleanups(cleanupFrames[frameIndex - 1]);
        }
        emitBranch(breaking ? loop.breakLabel : loop.continueLabel);
    }

    private bool lowerIf(ref Stmt statement, LocalScope locals)
    {
        auto condition = lowerExpression(statement.expression, locals);
        auto thenLabel = newLabel("if.then");
        auto elseLabel = newLabel(statement.alternate.length ? "if.else" : "if.end");
        auto endLabel = statement.alternate.length ? newLabel("if.end") : elseLabel;
        emit(Instruction(Opcode.conditionalBranch, TypeKind.voidType,
                [TypeKind.boolType], "", "", "", [
                    condition.name, thenLabel, elseLabel
        ]));

        emitLabel(thenLabel);
        auto thenReturns = lowerStatements(statement.body, new LocalScope(locals));
        if (!thenReturns)
        {
            emitBranch(endLabel);
        }

        if (statement.alternate.length)
        {
            emitLabel(elseLabel);
            auto elseReturns = lowerStatements(statement.alternate, new LocalScope(locals));
            if (!elseReturns)
            {
                emitBranch(endLabel);
            }
            if (thenReturns && elseReturns)
            {
                return true;
            }
            emitLabel(endLabel);
            return false;
        }

        emitLabel(endLabel);
        return false;
    }

    private void lowerWhile(ref Stmt statement, LocalScope locals)
    {
        auto conditionLabel = newLabel("while.cond");
        auto bodyLabel = newLabel("while.body");
        auto endLabel = newLabel("while.end");
        emitBranch(conditionLabel);
        emitLabel(conditionLabel);
        auto condition = lowerExpression(statement.expression, locals);
        emit(Instruction(Opcode.conditionalBranch, TypeKind.voidType,
                [TypeKind.boolType], "", "", "", [
                    condition.name, bodyLabel, endLabel
        ]));
        emitLabel(bodyLabel);
        loopFrames ~= LoopFrame(endLabel, conditionLabel, cleanupFrames.length);
        if (!lowerStatements(statement.body, new LocalScope(locals)))
        {
            emitBranch(conditionLabel);
        }
        loopFrames = loopFrames[0 .. $ - 1];
        emitLabel(endLabel);
    }

    private Value lowerExpression(ref Expr expression, LocalScope locals)
    {
        final switch (expression.kind)
        {
        case ExprKind.invalid:
            return Value("0", TypeKind.invalid);
        case ExprKind.integer:
            auto result = newTemporary();
            emit(Instruction(Opcode.integerConstant, expression.inferredType,
                    [], result, "", to!string(expression.integerValue)));
            return Value(result, expression.inferredType);
        case ExprKind.boolean:
            auto result = newTemporary();
            emit(Instruction(Opcode.booleanConstant, TypeKind.boolType, [],
                    result, "", expression.booleanValue ? "true" : "false"));
            return Value(result, TypeKind.boolType);
        case ExprKind.stringLiteral:
            auto result = newTemporary();
            emit(Instruction(Opcode.stringConstant, TypeKind.stringType, [],
                    result, "", expression.text));
            return Value(result, TypeKind.stringType);
        case ExprKind.nullLiteral:
            auto result = newTemporary();
            emit(Instruction(Opcode.nullPointer, TypeKind.nullType, [], result));
            return Value(result, TypeKind.nullType);
        case ExprKind.variable:
            string slot;
            locals.lookup(expression.text, slot);
            string namedType;
            locals.lookupNamedType(expression.text, namedType);
            auto result = newTemporary();
            auto instruction = Instruction(Opcode.load, expression.inferredType,
                    [expression.inferredType], result, "", "", [slot]);
            instruction.namedType = namedType;
            emit(instruction);
            return Value(result, expression.inferredType, namedType);
        case ExprKind.member:
            auto slot = lowerAddress(expression, locals);
            auto result = newTemporary();
            auto instruction = Instruction(Opcode.load, expression.inferredType,
                    [expression.inferredType], result, "", "", [slot]);
            instruction.namedType = expression.inferredNamedType;
            emit(instruction);
            return Value(result, expression.inferredType, expression.inferredNamedType);
        case ExprKind.index:
            auto slot = lowerAddress(expression, locals);
            auto result = newTemporary();
            auto instruction = Instruction(Opcode.load, expression.inferredType,
                    [expression.inferredType], result, "", "", [slot]);
            instruction.namedType = expression.inferredNamedType;
            emit(instruction);
            return Value(result, expression.inferredType, expression.inferredNamedType);
        case ExprKind.unary:
            auto operand = lowerExpression(expression.left, locals);
            auto result = newTemporary();
            if (expression.text == "!")
            {
                emit(Instruction(Opcode.booleanConstant, TypeKind.boolType, [],
                        result, "not", operand.name));
            }
            else
            {
                emit(Instruction(Opcode.binary, operand.type, [
                        operand.type, operand.type
                ], result, "sub", "0", [operand.name]));
            }
            return Value(result, expression.inferredType);
        case ExprKind.binary:
            return lowerBinary(expression, locals);
        case ExprKind.call:
            return lowerCall(expression, locals);
        }
    }

    private Value lowerBinary(ref Expr expression, LocalScope locals)
    {
        if (expression.text == "&&" || expression.text == "||")
        {
            return lowerShortCircuit(expression, locals);
        }

        if (expression.text == "=")
        {
            auto value = lowerExpression(expression.right, locals);
            value = convert(value, expression.left.inferredType);
            auto slot = lowerAddress(expression.left, locals);
            emit(Instruction(Opcode.store, expression.left.inferredType,
                    [expression.left.inferredType], "", "", "", [
                        slot, value.name
            ]));
            return value;
        }

        auto left = lowerExpression(expression.left, locals);
        auto right = lowerExpression(expression.right, locals);
        auto commonType = expression.inferredType == TypeKind.boolType ? (left.type == TypeKind.longType
                || right.type == TypeKind.longType ? TypeKind.longType : TypeKind.intType)
            : expression.inferredType;
        if ((left.type == TypeKind.voidPointer || left.type == TypeKind.cStringPointer)
                || (right.type == TypeKind.voidPointer || right.type == TypeKind.cStringPointer))
        {
            commonType = left.type == TypeKind.nullType ? right.type : left.type;
        }
        left = convert(left, commonType);
        right = convert(right, commonType);
        auto result = newTemporary();
        auto comparisons = ["==", "!=", "<", "<=", ">", ">="];
        if (comparisons.canFind(expression.text))
        {
            emit(Instruction(Opcode.compare, commonType, [
                    commonType, commonType
            ], result, expression.text, "", [left.name, right.name]));
        }
        else
        {
            emit(Instruction(Opcode.binary, commonType, [commonType,
                    commonType], result, expression.text, "", [
                    left.name, right.name
            ]));
        }
        return Value(result, expression.inferredType);
    }

    private string lowerAddress(ref Expr expression, LocalScope locals)
    {
        if (expression.kind == ExprKind.variable)
        {
            string slot;
            locals.lookup(expression.text, slot);
            return slot;
        }
        if (expression.kind == ExprKind.index)
        {
            auto arraySlot = lowerAddress(expression.left, locals);
            return emitArrayElementAddress(arraySlot, expression.left.inferredNamedType,
                    expression.left.arrayLength, cast(size_t) expression.right.integerValue);
        }
        auto base = lowerAddress(expression.left, locals);
        auto address = newTemporary();
        auto instruction = Instruction(Opcode.fieldAddress, expression.inferredType, [
        ], address, to!string(expression.fieldIndex), expression.memberOwnerType, [
            base
        ]);
        instruction.namedType = expression.memberOwnerType;
        emit(instruction);
        return address;
    }

    private Value lowerShortCircuit(ref Expr expression, LocalScope locals)
    {
        auto left = lowerExpression(expression.left, locals);
        auto leftBlock = currentBlock;
        auto rightLabel = newLabel("logic.rhs");
        auto endLabel = newLabel("logic.end");
        if (expression.text == "&&")
        {
            emit(Instruction(Opcode.conditionalBranch, TypeKind.voidType,
                    [TypeKind.boolType], "", "", "", [
                        left.name, rightLabel, endLabel
            ]));
        }
        else
        {
            emit(Instruction(Opcode.conditionalBranch, TypeKind.voidType,
                    [TypeKind.boolType], "", "", "", [
                        left.name, endLabel, rightLabel
            ]));
        }
        emitLabel(rightLabel);
        auto right = lowerExpression(expression.right, locals);
        auto rightBlock = currentBlock;
        emitBranch(endLabel);
        emitLabel(endLabel);
        auto result = newTemporary();
        auto shortValue = expression.text == "&&" ? "false" : "true";
        emit(Instruction(Opcode.phi, TypeKind.boolType, [
                TypeKind.boolType, TypeKind.boolType
        ], result, "", shortValue ~ "@" ~ leftBlock ~ ";" ~ right.name ~ "@" ~ rightBlock));
        return Value(result, TypeKind.boolType);
    }

    private Value lowerCall(ref Expr expression, LocalScope locals)
    {
        string[] arguments;
        TypeKind[] argumentTypes;
        bool[] indirectArguments;
        auto targetName = expression.resolvedFunction;
        if (expression.isConstructorCall)
        {
            return Value("", TypeKind.structType, expression.inferredNamedType);
        }
        if (expression.isMethodCall)
        {
            auto receiverSlot = lowerAddress(expression.left.left, locals);
            arguments ~= receiverSlot;
            argumentTypes ~= TypeKind.structType;
            indirectArguments ~= true;
        }
        foreach (ref argument; expression.arguments)
        {
            auto value = lowerExpression(argument, locals);
            if (expression.left.text != "writeln")
            {
                auto calleeSymbol = symbols[targetName];
                auto argumentIndex = arguments.length - (expression.isMethodCall ? 1 : 0);
                if (argumentIndex < calleeSymbol.parameterTypes.length - (expression.isMethodCall
                        ? 1 : 0))
                {
                    auto parameterIndex = argumentIndex + (expression.isMethodCall ? 1 : 0);
                    value = convert(value, calleeSymbol.parameterTypes[parameterIndex]);
                }
            }
            arguments ~= value.name;
            argumentTypes ~= value.type;
            indirectArguments ~= false;
        }
        if (expression.left.text == "writeln")
        {
            emit(Instruction(Opcode.call, TypeKind.voidType, argumentTypes, "",
                    "writeln", "", arguments));
            return Value("", TypeKind.voidType);
        }
        auto result = expression.inferredType == TypeKind.voidType ? "" : newTemporary();
        emit(Instruction(Opcode.call, expression.inferredType, argumentTypes, result,
                targetName, "", arguments, symbols[targetName].externC, "", indirectArguments));
        return Value(result, expression.inferredType);
    }

    private Value convert(Value value, TypeKind target)
    {
        if (value.type == target)
        {
            return value;
        }
        if ((value.type == TypeKind.stringType || value.type == TypeKind.cStringPointer)
                && (target == TypeKind.stringType || target == TypeKind.cStringPointer))
        {
            return Value(value.name, target);
        }
        if ((value.type == TypeKind.nullType || value.type == TypeKind.voidPointer
                || value.type == TypeKind.cStringPointer) && (target == TypeKind.nullType
                || target == TypeKind.voidPointer || target == TypeKind.cStringPointer))
        {
            return Value(value.name, target);
        }
        auto result = newTemporary();
        emit(Instruction(Opcode.signExtend, target, [value.type], result, "", "", [
                value.name
        ]));
        return Value(result, target);
    }

    private string currentBlock;

    private void emitLabel(string name)
    {
        currentBlock = name;
        emit(Instruction(Opcode.label, TypeKind.voidType, [], "", "", name));
    }

    private void emitBranch(string destination)
    {
        emit(Instruction(Opcode.branch, TypeKind.voidType, [], "", "", destination));
    }

    private void emit(Instruction instruction)
    {
        loweredFunction.instructions ~= instruction;
    }

    private string newTemporary()
    {
        return "%v" ~ to!string(temporaryIndex++);
    }

    private string newLabel(string prefix)
    {
        return prefix ~ "." ~ to!string(labelIndex++);
    }
}

public struct Lowerer
{
    public IRProgram lower(Program program, SymbolTable symbols)
    {
        IRProgram result;
        string[string] destructors;
        foreach (structure; program.structs)
        {
            StructType loweredStruct;
            loweredStruct.name = structure.name;
            loweredStruct.size = structure.size;
            loweredStruct.alignment = structure.alignment;
            loweredStruct.hasUserDestructor = structure.hasUserDestructor;
            loweredStruct.hasGeneratedDestructor = structure.hasGeneratedDestructor;
            loweredStruct.needsDestruction = structure.needsDestruction;
            loweredStruct.constructorNames = structure.constructorNames.dup;
            foreach (field; structure.fields)
            {
                loweredStruct.fieldTypes ~= field.type;
                loweredStruct.fieldNamedTypes ~= field.namedType;
                loweredStruct.fieldArrayLengths ~= field.arrayLength;
                loweredStruct.fieldElementTypes ~= field.elementType;
            }
            result.structs ~= loweredStruct;
            auto typeMetadata = symbols.structs[structure.name];
            if (typeMetadata.needsDestruction)
            {
                destructors[structure.name] = typeMetadata.destructorName;
            }
        }
        foreach (declaration; program.functions)
        {
            if (!declaration.hasBody)
            {
                auto external = Function();
                external.name = declaration.name;
                external.returnType = declaration.returnType;
                external.externC = declaration.externC;
                external.hasBody = false;
                foreach (parameter; declaration.parameters)
                {
                    external.parameters ~= ir.ir.Parameter(parameter.name,
                            parameter.type, parameter.isReference);
                }
                result.functions ~= external;
                continue;
            }
            auto lowerer = new FunctionLowerer(declaration, symbols.functions,
                    destructors, symbols.structs);
            result.functions ~= lowerer.lower(declaration);
        }
        return result;
    }
}
