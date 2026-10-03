module semantic.semantic;

import ast.ast;
import diagnostics.diagnostics : Diagnostics;
import symbols.symbols : FunctionSymbol, SymbolTable;
import types.types : canConvert, isInteger, typeName;
import std.conv : to;

private class Scope {
    private Scope parent;
    private TypeKind[string] variables;

    this(Scope parent = null) {
        this.parent = parent;
    }

    bool define(string name, TypeKind type) {
        if (name in variables) {
            return false;
        }
        variables[name] = type;
        return true;
    }

    bool lookup(string name, out TypeKind type) const {
        if (auto found = name in variables) {
            type = *found;
            return true;
        }
        if (parent !is null) {
            return parent.lookup(name, type);
        }
        return false;
    }
}

public struct SemanticAnalyzer {
    private Diagnostics* diagnostics;
    private SymbolTable symbols;
    private bool importsWriteln;

    this(Diagnostics* diagnostics) {
        this.diagnostics = diagnostics;
    }

    public SymbolTable analyze(ref Program program) {
        foreach (importDecl; program.imports) {
            if (importDecl.moduleName == "std.stdio" && importDecl.symbols.length == 1
                    && importDecl.symbols[0] == "writeln") {
                importsWriteln = true;
            } else {
                diagnostics.error(importDecl.location, "unsupported import '" ~ importDecl.moduleName
                    ~ "'; this compiler increment provides only std.stdio:writeln");
            }
        }

        foreach (index, declaration; program.functions) {
            if (symbols.containsFunction(declaration.name)) {
                diagnostics.error(declaration.location, "duplicate function '" ~ declaration.name ~ "'");
                continue;
            }
            FunctionSymbol symbol;
            symbol.name = declaration.name;
            symbol.returnType = declaration.returnType;
            symbol.declarationIndex = index;
            symbol.externC = declaration.externC;
            foreach (parameter; declaration.parameters) {
                symbol.parameterTypes ~= parameter.type;
            }
            symbols.insertFunction(symbol);
        }

        if (!symbols.containsFunction("main")) {
            diagnostics.error(SourceLocation("<program>", 1, 1), "program must define main()");
        } else {
            auto mainSymbol = symbols.functions["main"];
            auto mainDeclaration = program.functions[mainSymbol.declarationIndex];
            if (!mainDeclaration.hasBody || mainSymbol.returnType != TypeKind.intType
                    || mainSymbol.parameterTypes.length != 0) {
                diagnostics.error(mainDeclaration.location,
                    "main must have signature int main()");
            }
        }

        foreach (ref declaration; program.functions) {
            analyzeFunction(declaration);
        }
        return symbols;
    }

    private void analyzeFunction(ref FunctionDecl declaration) {
        if (!declaration.hasBody) {
            return;
        }
        auto localScope = new Scope();
        foreach (parameter; declaration.parameters) {
            if (!localScope.define(parameter.name, parameter.type)) {
                diagnostics.error(parameter.location, "duplicate parameter '" ~ parameter.name ~ "'");
            }
        }

        auto returns = analyzeStatements(declaration.body, localScope, declaration.returnType);
        if (declaration.returnType != TypeKind.voidType && !returns) {
            diagnostics.error(declaration.location, "non-void function '" ~ declaration.name
                ~ "' must return a value on every path");
        }
    }

    private bool analyzeStatements(ref Stmt[] statements, Scope localScope, TypeKind returnType) {
        bool alwaysReturns;
        foreach (ref statement; statements) {
            auto statementReturns = analyzeStatement(statement, localScope, returnType);
            if (!alwaysReturns) {
                alwaysReturns = statementReturns;
            }
        }
        return alwaysReturns;
    }

    private bool analyzeStatement(ref Stmt statement, Scope localScope, TypeKind returnType) {
        final switch (statement.kind) {
            case StmtKind.block:
                return analyzeStatements(statement.body, new Scope(localScope), returnType);
            case StmtKind.variable:
                auto valueType = analyzeExpression(statement.expression, localScope);
                if (statement.inferredDeclaration) {
                    statement.declaredType = valueType;
                } else if (!canConvert(valueType, statement.declaredType)) {
                    diagnostics.error(statement.location, "cannot initialize " ~ typeName(statement.declaredType)
                        ~ " variable '" ~ statement.name ~ "' with " ~ typeName(valueType));
                }
                if (statement.declaredType == TypeKind.voidType
                        || statement.declaredType == TypeKind.invalid) {
                    diagnostics.error(statement.location, "variable '" ~ statement.name ~ "' has invalid type");
                }
                if (!localScope.define(statement.name, statement.declaredType)) {
                    diagnostics.error(statement.location, "variable '" ~ statement.name ~ "' is already declared in this scope");
                }
                return false;
            case StmtKind.expression:
                analyzeExpression(statement.expression, localScope);
                return false;
            case StmtKind.returnStatement:
                if (!statement.hasExpression) {
                    if (returnType != TypeKind.voidType) {
                        diagnostics.error(statement.location, "return statement requires a value");
                    }
                } else {
                    auto valueType = analyzeExpression(statement.expression, localScope);
                    if (!canConvert(valueType, returnType)) {
                        diagnostics.error(statement.location, "cannot return " ~ typeName(valueType)
                            ~ " from a function returning " ~ typeName(returnType));
                    }
                }
                return true;
            case StmtKind.ifStatement:
                auto conditionType = analyzeExpression(statement.expression, localScope);
                if (conditionType != TypeKind.boolType) {
                    diagnostics.error(statement.expression.location, "if condition must have type bool");
                }
                auto thenReturns = analyzeStatements(statement.body, new Scope(localScope), returnType);
                auto elseReturns = statement.alternate.length != 0
                    && analyzeStatements(statement.alternate, new Scope(localScope), returnType);
                return thenReturns && elseReturns;
            case StmtKind.whileStatement:
                auto whileType = analyzeExpression(statement.expression, localScope);
                if (whileType != TypeKind.boolType) {
                    diagnostics.error(statement.expression.location, "while condition must have type bool");
                }
                analyzeStatements(statement.body, new Scope(localScope), returnType);
                return false;
        }
    }

    private TypeKind analyzeExpression(ref Expr expression, Scope localScope) {
        final switch (expression.kind) {
            case ExprKind.invalid:
                expression.inferredType = TypeKind.invalid;
                return expression.inferredType;
            case ExprKind.integer:
                expression.inferredType = expression.integerValue > int.max || expression.integerValue < int.min
                    ? TypeKind.longType : TypeKind.intType;
                return expression.inferredType;
            case ExprKind.boolean:
                expression.inferredType = TypeKind.boolType;
                return expression.inferredType;
            case ExprKind.stringLiteral:
                expression.inferredType = TypeKind.stringType;
                return expression.inferredType;
            case ExprKind.nullLiteral:
                expression.inferredType = TypeKind.nullType;
                return expression.inferredType;
            case ExprKind.variable:
                if (!localScope.lookup(expression.text, expression.inferredType)) {
                    diagnostics.error(expression.location, "unknown variable '" ~ expression.text ~ "'");
                    expression.inferredType = TypeKind.invalid;
                }
                return expression.inferredType;
            case ExprKind.unary:
                auto operandType = analyzeExpression(expression.left, localScope);
                if (expression.text == "!" && operandType == TypeKind.boolType) {
                    expression.inferredType = TypeKind.boolType;
                } else if (expression.text == "-" && isInteger(operandType)) {
                    expression.inferredType = operandType;
                } else {
                    diagnostics.error(expression.location, "operator '" ~ expression.text
                        ~ "' does not accept " ~ typeName(operandType));
                    expression.inferredType = TypeKind.invalid;
                }
                return expression.inferredType;
            case ExprKind.binary:
                return analyzeBinary(expression, localScope);
            case ExprKind.call:
                return analyzeCall(expression, localScope);
        }
    }

    private TypeKind analyzeBinary(ref Expr expression, Scope localScope) {
        auto leftType = analyzeExpression(expression.left, localScope);
        auto rightType = analyzeExpression(expression.right, localScope);
        auto operation = expression.text;

        if (operation == "=") {
            if (expression.left.kind != ExprKind.variable) {
                diagnostics.error(expression.location, "assignment target must be a variable");
                return TypeKind.invalid;
            }
            if (!canConvert(rightType, leftType)) {
                diagnostics.error(expression.location, "cannot assign " ~ typeName(rightType)
                    ~ " to " ~ typeName(leftType));
            }
            expression.inferredType = leftType;
            return expression.inferredType;
        }

        if (operation == "&&" || operation == "||") {
            if (leftType != TypeKind.boolType || rightType != TypeKind.boolType) {
                diagnostics.error(expression.location, "logical operators require bool operands");
                expression.inferredType = TypeKind.invalid;
            } else {
                expression.inferredType = TypeKind.boolType;
            }
            return expression.inferredType;
        }

        if (operation == "==" || operation == "!=") {
            auto pointers = (leftType == TypeKind.voidPointer || leftType == TypeKind.cStringPointer)
                && (rightType == TypeKind.voidPointer || rightType == TypeKind.cStringPointer
                    || rightType == TypeKind.nullType);
            auto nullLeft = leftType == TypeKind.nullType
                && (rightType == TypeKind.voidPointer || rightType == TypeKind.cStringPointer);
            auto integerPair = isInteger(leftType) && isInteger(rightType);
            auto booleanPair = leftType == TypeKind.boolType && rightType == TypeKind.boolType;
            if (!pointers && !nullLeft && !integerPair && !booleanPair) {
                diagnostics.error(expression.location, "equality operands have incompatible types");
                expression.inferredType = TypeKind.invalid;
            } else {
                expression.inferredType = TypeKind.boolType;
            }
            return expression.inferredType;
        }

        if (operation == "<" || operation == "<=" || operation == ">" || operation == ">=") {
            if (!isInteger(leftType) || !isInteger(rightType)) {
                diagnostics.error(expression.location, "comparison requires integer operands");
                expression.inferredType = TypeKind.invalid;
            } else {
                expression.inferredType = TypeKind.boolType;
            }
            return expression.inferredType;
        }

        if (!isInteger(leftType) || !isInteger(rightType)) {
            diagnostics.error(expression.location, "arithmetic operator requires integer operands");
            expression.inferredType = TypeKind.invalid;
        } else {
            expression.inferredType = leftType == TypeKind.longType || rightType == TypeKind.longType
                ? TypeKind.longType : TypeKind.intType;
        }
        return expression.inferredType;
    }

    private TypeKind analyzeCall(ref Expr expression, Scope localScope) {
        if (expression.left.kind != ExprKind.variable) {
            diagnostics.error(expression.location, "only named function calls are supported");
            return TypeKind.invalid;
        }

        if (expression.left.text == "writeln") {
            if (!importsWriteln) {
                diagnostics.error(expression.location, "writeln requires 'import std.stdio : writeln;'");
            }
            foreach (ref argument; expression.arguments) {
                auto argumentType = analyzeExpression(argument, localScope);
                    if (argumentType != TypeKind.intType && argumentType != TypeKind.longType
                        && argumentType != TypeKind.boolType && argumentType != TypeKind.stringType) {
                    diagnostics.error(argument.location, "writeln does not support " ~ typeName(argumentType));
                }
            }
            expression.inferredType = TypeKind.voidType;
            return expression.inferredType;
        }

        if (!symbols.containsFunction(expression.left.text)) {
            diagnostics.error(expression.location, "unknown function '" ~ expression.left.text ~ "'");
            return TypeKind.invalid;
        }

        auto target = symbols.functions[expression.left.text];
        if (target.parameterTypes.length != expression.arguments.length) {
            diagnostics.error(expression.location, "function '" ~ target.name ~ "' expects "
                ~ to!string(target.parameterTypes.length) ~ " arguments, got "
                ~ to!string(expression.arguments.length));
        }
        foreach (index, ref argument; expression.arguments) {
            auto argumentType = analyzeExpression(argument, localScope);
            auto compatibleCStringLiteral = index < target.parameterTypes.length
                && target.parameterTypes[index] == TypeKind.cStringPointer
                && argument.kind == ExprKind.stringLiteral;
            auto compatibleNullPointer = index < target.parameterTypes.length
                && target.parameterTypes[index] == TypeKind.voidPointer
                && argumentType == TypeKind.nullType;
            if (index < target.parameterTypes.length && !compatibleCStringLiteral
                    && !compatibleNullPointer
                    && !canConvert(argumentType, target.parameterTypes[index])) {
                diagnostics.error(argument.location, "argument " ~ to!string(index + 1) ~ " to '"
                    ~ target.name ~ "' has type " ~ typeName(argumentType) ~ ", expected "
                    ~ typeName(target.parameterTypes[index]));
            }
        }
        expression.inferredType = target.returnType;
        return expression.inferredType;
    }
}
