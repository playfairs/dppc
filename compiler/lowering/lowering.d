module lowering.lowering;

import ast.ast : Expr, ExprKind, FunctionDecl, Program, Stmt, StmtKind, TypeKind;
import ir.ir;
import symbols.symbols : FunctionSymbol, SymbolTable;
import std.algorithm.searching : canFind;
import std.conv : to;

private struct Value {
    string name;
    TypeKind type;
}

private class LocalScope {
    private LocalScope parent;
    private string[string] slots;

    this(LocalScope parent = null) {
        this.parent = parent;
    }

    void define(string name, string slot) {
        slots[name] = slot;
    }

    bool lookup(string name, out string slot) const {
        if (auto value = name in slots) {
            slot = *value;
            return true;
        }
        return parent !is null && parent.lookup(name, slot);
    }
}

private class FunctionLowerer {
    private Function loweredFunction;
    private FunctionSymbol[string] symbols;
    private size_t temporaryIndex;
    private size_t labelIndex;

    this(FunctionDecl declaration, FunctionSymbol[string] symbols) {
        loweredFunction.name = declaration.name;
        loweredFunction.returnType = declaration.returnType;
        loweredFunction.externC = declaration.externC;
        loweredFunction.hasBody = declaration.hasBody;
        this.symbols = symbols;
        foreach (parameter; declaration.parameters) {
            loweredFunction.parameters ~= ir.ir.Parameter(parameter.name, parameter.type);
        }
    }

    Function lower(FunctionDecl declaration) {
        auto locals = new LocalScope();
        emitLabel("entry");
        foreach (index, parameter; declaration.parameters) {
            auto slot = newTemporary();
            emit(Instruction(Opcode.alloca, parameter.type, [], slot));
            emit(Instruction(Opcode.store, parameter.type, [parameter.type],
                "", "", "", [slot, "%arg" ~ to!string(index)]));
            locals.define(parameter.name, slot);
        }

        auto terminated = lowerStatements(declaration.body, locals);
        if (!terminated) {
            if (loweredFunction.returnType == TypeKind.voidType) {
                emit(Instruction(Opcode.returnVoid));
            } else {
                emit(Instruction(Opcode.returnValue, loweredFunction.returnType, [loweredFunction.returnType],
                    "", "", "", ["0"]));
            }
        }
        return loweredFunction;
    }

    private bool lowerStatements(ref Stmt[] statements, LocalScope locals) {
        foreach (ref statement; statements) {
            if (lowerStatement(statement, locals)) {
                return true;
            }
        }
        return false;
    }

    private bool lowerStatement(ref Stmt statement, LocalScope locals) {
        final switch (statement.kind) {
            case StmtKind.block:
                return lowerStatements(statement.body, new LocalScope(locals));
            case StmtKind.variable:
                auto value = lowerExpression(statement.expression, locals);
                value = convert(value, statement.declaredType);
                auto slot = newTemporary();
                emit(Instruction(Opcode.alloca, statement.declaredType, [], slot));
                emit(Instruction(Opcode.store, statement.declaredType, [statement.declaredType],
                    "", "", "", [slot, value.name]));
                locals.define(statement.name, slot);
                return false;
            case StmtKind.expression:
                lowerExpression(statement.expression, locals);
                return false;
            case StmtKind.returnStatement:
                if (!statement.hasExpression) {
                    emit(Instruction(Opcode.returnVoid));
                } else {
                    auto value = lowerExpression(statement.expression, locals);
                    value = convert(value, loweredFunction.returnType);
                    emit(Instruction(Opcode.returnValue, loweredFunction.returnType,
                        [loweredFunction.returnType], "", "", "", [value.name]));
                }
                return true;
            case StmtKind.ifStatement:
                return lowerIf(statement, locals);
            case StmtKind.whileStatement:
                lowerWhile(statement, locals);
                return false;
        }
    }

    private bool lowerIf(ref Stmt statement, LocalScope locals) {
        auto condition = lowerExpression(statement.expression, locals);
        auto thenLabel = newLabel("if.then");
        auto elseLabel = newLabel(statement.alternate.length ? "if.else" : "if.end");
        auto endLabel = statement.alternate.length ? newLabel("if.end") : elseLabel;
        emit(Instruction(Opcode.conditionalBranch, TypeKind.voidType, [TypeKind.boolType],
            "", "", "", [condition.name, thenLabel, elseLabel]));

        emitLabel(thenLabel);
        auto thenReturns = lowerStatements(statement.body, new LocalScope(locals));
        if (!thenReturns) {
            emitBranch(endLabel);
        }

        if (statement.alternate.length) {
            emitLabel(elseLabel);
            auto elseReturns = lowerStatements(statement.alternate, new LocalScope(locals));
            if (!elseReturns) {
                emitBranch(endLabel);
            }
            if (thenReturns && elseReturns) {
                return true;
            }
            emitLabel(endLabel);
            return false;
        }

        emitLabel(endLabel);
        return false;
    }

    private void lowerWhile(ref Stmt statement, LocalScope locals) {
        auto conditionLabel = newLabel("while.cond");
        auto bodyLabel = newLabel("while.body");
        auto endLabel = newLabel("while.end");
        emitBranch(conditionLabel);
        emitLabel(conditionLabel);
        auto condition = lowerExpression(statement.expression, locals);
        emit(Instruction(Opcode.conditionalBranch, TypeKind.voidType, [TypeKind.boolType],
            "", "", "", [condition.name, bodyLabel, endLabel]));
        emitLabel(bodyLabel);
        if (!lowerStatements(statement.body, new LocalScope(locals))) {
            emitBranch(conditionLabel);
        }
        emitLabel(endLabel);
    }

    private Value lowerExpression(ref Expr expression, LocalScope locals) {
        final switch (expression.kind) {
            case ExprKind.invalid:
                return Value("0", TypeKind.invalid);
            case ExprKind.integer:
                auto result = newTemporary();
                emit(Instruction(Opcode.integerConstant, expression.inferredType, [],
                    result, "", to!string(expression.integerValue)));
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
                auto result = newTemporary();
                emit(Instruction(Opcode.load, expression.inferredType, [expression.inferredType],
                    result, "", "", [slot]));
                return Value(result, expression.inferredType);
            case ExprKind.unary:
                auto operand = lowerExpression(expression.left, locals);
                auto result = newTemporary();
                if (expression.text == "!") {
                    emit(Instruction(Opcode.booleanConstant, TypeKind.boolType, [],
                        result, "not", operand.name));
                } else {
                    emit(Instruction(Opcode.binary, operand.type, [operand.type, operand.type],
                        result, "sub", "0", [operand.name]));
                }
                return Value(result, expression.inferredType);
            case ExprKind.binary:
                return lowerBinary(expression, locals);
            case ExprKind.call:
                return lowerCall(expression, locals);
        }
    }

    private Value lowerBinary(ref Expr expression, LocalScope locals) {
        if (expression.text == "&&" || expression.text == "||") {
            return lowerShortCircuit(expression, locals);
        }

        if (expression.text == "=") {
            auto value = lowerExpression(expression.right, locals);
            value = convert(value, expression.left.inferredType);
            string slot;
            locals.lookup(expression.left.text, slot);
            emit(Instruction(Opcode.store, expression.left.inferredType,
                [expression.left.inferredType], "", "", "", [slot, value.name]));
            return value;
        }

        auto left = lowerExpression(expression.left, locals);
        auto right = lowerExpression(expression.right, locals);
        auto commonType = expression.inferredType == TypeKind.boolType
            ? (left.type == TypeKind.longType || right.type == TypeKind.longType
                ? TypeKind.longType : TypeKind.intType)
            : expression.inferredType;
        if ((left.type == TypeKind.voidPointer || left.type == TypeKind.cStringPointer)
                || (right.type == TypeKind.voidPointer || right.type == TypeKind.cStringPointer)) {
            commonType = left.type == TypeKind.nullType ? right.type : left.type;
        }
        left = convert(left, commonType);
        right = convert(right, commonType);
        auto result = newTemporary();
        auto comparisons = ["==", "!=", "<", "<=", ">", ">="];
        if (comparisons.canFind(expression.text)) {
            emit(Instruction(Opcode.compare, commonType, [commonType, commonType],
                result, expression.text, "", [left.name, right.name]));
        } else {
            emit(Instruction(Opcode.binary, commonType, [commonType, commonType],
                result, expression.text, "", [left.name, right.name]));
        }
        return Value(result, expression.inferredType);
    }

    private Value lowerShortCircuit(ref Expr expression, LocalScope locals) {
        auto left = lowerExpression(expression.left, locals);
        auto leftBlock = currentBlock;
        auto rightLabel = newLabel("logic.rhs");
        auto endLabel = newLabel("logic.end");
        if (expression.text == "&&") {
            emit(Instruction(Opcode.conditionalBranch, TypeKind.voidType, [TypeKind.boolType],
                "", "", "", [left.name, rightLabel, endLabel]));
        } else {
            emit(Instruction(Opcode.conditionalBranch, TypeKind.voidType, [TypeKind.boolType],
                "", "", "", [left.name, endLabel, rightLabel]));
        }
        emitLabel(rightLabel);
        auto right = lowerExpression(expression.right, locals);
        auto rightBlock = currentBlock;
        emitBranch(endLabel);
        emitLabel(endLabel);
        auto result = newTemporary();
        auto shortValue = expression.text == "&&" ? "false" : "true";
        emit(Instruction(Opcode.phi, TypeKind.boolType,
            [TypeKind.boolType, TypeKind.boolType], result, "",
            shortValue ~ "@" ~ leftBlock ~ ";" ~ right.name ~ "@" ~ rightBlock));
        return Value(result, TypeKind.boolType);
    }

    private Value lowerCall(ref Expr expression, LocalScope locals) {
        string[] arguments;
        TypeKind[] argumentTypes;
        foreach (ref argument; expression.arguments) {
            auto value = lowerExpression(argument, locals);
            if (expression.left.text != "writeln") {
                auto calleeSymbol = symbols[expression.left.text];
                auto argumentIndex = arguments.length;
                if (argumentIndex < calleeSymbol.parameterTypes.length) {
                    value = convert(value, calleeSymbol.parameterTypes[argumentIndex]);
                }
            }
            arguments ~= value.name;
            argumentTypes ~= value.type;
        }
        if (expression.left.text == "writeln") {
            emit(Instruction(Opcode.call, TypeKind.voidType, argumentTypes,
                "", "writeln", "", arguments));
            return Value("", TypeKind.voidType);
        }
        auto result = expression.inferredType == TypeKind.voidType ? "" : newTemporary();
        emit(Instruction(Opcode.call, expression.inferredType, argumentTypes,
            result, expression.left.text, "", arguments,
            symbols[expression.left.text].externC));
        return Value(result, expression.inferredType);
    }

    private Value convert(Value value, TypeKind target) {
        if (value.type == target) {
            return value;
        }
        if ((value.type == TypeKind.stringType || value.type == TypeKind.cStringPointer)
                && (target == TypeKind.stringType || target == TypeKind.cStringPointer)) {
            return Value(value.name, target);
        }
        if ((value.type == TypeKind.nullType || value.type == TypeKind.voidPointer
                || value.type == TypeKind.cStringPointer)
                && (target == TypeKind.nullType || target == TypeKind.voidPointer
                    || target == TypeKind.cStringPointer)) {
            return Value(value.name, target);
        }
        auto result = newTemporary();
        emit(Instruction(Opcode.signExtend, target, [value.type], result, "", "", [value.name]));
        return Value(result, target);
    }

    private string currentBlock;

    private void emitLabel(string name) {
        currentBlock = name;
        emit(Instruction(Opcode.label, TypeKind.voidType, [], "", "", name));
    }

    private void emitBranch(string destination) {
        emit(Instruction(Opcode.branch, TypeKind.voidType, [], "", "", destination));
    }

    private void emit(Instruction instruction) {
        loweredFunction.instructions ~= instruction;
    }

    private string newTemporary() {
        return "%v" ~ to!string(temporaryIndex++);
    }

    private string newLabel(string prefix) {
        return prefix ~ "." ~ to!string(labelIndex++);
    }
}

public struct Lowerer {
    public IRProgram lower(Program program, SymbolTable symbols) {
        IRProgram result;
        foreach (declaration; program.functions) {
            if (!declaration.hasBody) {
                auto external = Function();
                external.name = declaration.name;
                external.returnType = declaration.returnType;
                external.externC = declaration.externC;
                external.hasBody = false;
                foreach (parameter; declaration.parameters) {
                    external.parameters ~= ir.ir.Parameter(parameter.name, parameter.type);
                }
                result.functions ~= external;
                continue;
            }
            auto lowerer = new FunctionLowerer(declaration, symbols.functions);
            result.functions ~= lowerer.lower(declaration);
        }
        return result;
    }
}
