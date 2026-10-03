module semantic.semantic;

import ast.ast;
import diagnostics.diagnostics : Diagnostics;
import symbols.symbols : FieldSymbol, FunctionSymbol, StructSymbol, SymbolTable;
import types.types : PrimitiveLayout, canConvert, isInteger, primitiveLayout, typeName;
import std.conv : to;

private class Scope {
    private Scope parent;
    private struct Binding {
        TypeKind type;
        string namedType;
        TypeKind elementType;
        size_t arrayLength;
    }
    private Binding[string] variables;

    this(Scope parent = null) {
        this.parent = parent;
    }

    bool define(string name, TypeKind type, string namedType = "",
            TypeKind elementType = TypeKind.invalid, size_t arrayLength = 0) {
        if (name in variables) {
            return false;
        }
        variables[name] = Binding(type, namedType, elementType, arrayLength);
        return true;
    }

    bool lookup(string name, out TypeKind type) const {
        string ignoredName;
        return lookup(name, type, ignoredName);
    }

    bool lookup(string name, out TypeKind type, out string namedType) const {
        TypeKind ignoredElementType;
        size_t ignoredLength;
        return lookup(name, type, namedType, ignoredElementType, ignoredLength);
    }

    bool lookup(string name, out TypeKind type, out string namedType,
            out TypeKind elementType, out size_t arrayLength) const {
        if (auto found = name in variables) {
            type = found.type;
            namedType = found.namedType;
            elementType = found.elementType;
            arrayLength = found.arrayLength;
            return true;
        }
        if (parent !is null) {
            return parent.lookup(name, type, namedType, elementType, arrayLength);
        }
        return false;
    }
}

public struct SemanticAnalyzer {
    private Diagnostics* diagnostics;
    private SymbolTable symbols;
    private bool importsWriteln;
    private size_t loopDepth;

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

        buildStructSymbols(program);

        foreach (index, declaration; program.functions) {
            FunctionSymbol symbol;
            symbol.name = declaration.name;
            symbol.sourceName = declaration.sourceName.length
                ? declaration.sourceName : declaration.name;
            symbol.ownerType = declaration.ownerType;
            symbol.returnType = declaration.returnType;
            symbol.declarationIndex = index;
            symbol.externC = declaration.externC;
            symbol.isConstructor = declaration.isConstructor;
            symbol.isMethod = declaration.isMethod;
            symbol.isDestructor = declaration.isDestructor;
            foreach (parameter; declaration.parameters) {
                symbol.parameterTypes ~= parameter.type;
            }
            if (symbols.containsFunction(symbol.name)) {
                diagnostics.error(declaration.location, "duplicate function symbol '" ~ symbol.name ~ "'");
                continue;
            }
            symbols.insertFunction(symbol);
            if (declaration.ownerType.length && declaration.ownerType in symbols.structs) {
                auto structure = symbols.structs[declaration.ownerType];
                if (declaration.isConstructor) {
                    structure.constructorNames ~= declaration.name;
                } else if (declaration.isMethod) {
                    structure.methods ~= symbol;
                } else if (declaration.isDestructor) {
                    structure.destructorName = declaration.name;
                }
                symbols.structs[declaration.ownerType] = structure;
            }
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

    private void buildStructSymbols(ref Program program) {
        foreach (ref structure; program.structs) {
            if (structure.name in symbols.structs) {
                diagnostics.error(structure.location, "duplicate struct '" ~ structure.name ~ "'");
                continue;
            }

            StructSymbol symbol;
            symbol.name = structure.name;
            symbol.alignment = 1;
            symbol.hasUserDestructor = structure.hasUserDestructor;
            symbol.destructorName = structure.destructorName;
            size_t offset;
            bool hasDestructibleField;
            foreach (ref field; structure.fields) {
                PrimitiveLayout layout;
                if (field.type == TypeKind.structType
                        || (field.type == TypeKind.fixedArray
                            && field.elementType == TypeKind.structType)) {
                    if (!(field.namedType in symbols.structs)) {
                        diagnostics.error(field.location, "struct field '" ~ field.name
                            ~ "' must use a previously declared complete struct type");
                        continue;
                    }
                    auto fieldSymbol = symbols.structs[field.namedType];
                    auto fieldCount = field.type == TypeKind.fixedArray
                        ? field.arrayLength : 1;
                    layout = PrimitiveLayout(fieldSymbol.size * fieldCount,
                        fieldSymbol.alignment);
                    hasDestructibleField = hasDestructibleField || fieldSymbol.needsDestruction;
                } else if (field.type == TypeKind.invalid || field.type == TypeKind.voidType) {
                    continue;
                } else {
                    layout = primitiveLayout(field.type);
                }
                offset = (offset + layout.alignment - 1) / layout.alignment * layout.alignment;
                field.offset = offset;
                offset += layout.size;
                if (layout.alignment > symbol.alignment) {
                    symbol.alignment = layout.alignment;
                }
                FieldSymbol fieldSymbol;
                fieldSymbol.name = field.name;
                fieldSymbol.type = field.type;
                fieldSymbol.namedType = field.namedType;
                fieldSymbol.offset = field.offset;
                fieldSymbol.elementType = field.elementType;
                fieldSymbol.arrayLength = field.arrayLength;
                symbol.fields ~= fieldSymbol;
            }
            symbol.size = (offset + symbol.alignment - 1) / symbol.alignment * symbol.alignment;
            symbol.needsDestruction = symbol.hasUserDestructor || hasDestructibleField;

            if (!symbol.hasUserDestructor && hasDestructibleField) {
                symbol.destructorName = "__dpp_dtor_" ~ structure.name;
                symbol.hasGeneratedDestructor = true;
                FunctionDecl generated;
                generated.name = symbol.destructorName;
                generated.sourceName = "~this";
                generated.returnType = TypeKind.voidType;
                generated.location = structure.location;
                generated.hasBody = true;
                generated.isDestructor = true;
                generated.isGenerated = true;
                generated.ownerType = structure.name;
                generated.parameters ~= Parameter("this", TypeKind.structType,
                    structure.location, structure.name, true);
                program.functions ~= generated;
            }

            structure.size = symbol.size;
            structure.alignment = symbol.alignment;
            structure.needsDestruction = symbol.needsDestruction;
            structure.hasGeneratedDestructor = symbol.hasGeneratedDestructor;
            structure.destructorName = symbol.destructorName;
            symbols.structs[structure.name] = symbol;
        }
    }

    private void analyzeFunction(ref FunctionDecl declaration) {
        if (declaration.returnType == TypeKind.structType) {
            diagnostics.error(declaration.location,
                "functions and methods cannot return structs in this compiler increment");
        }
        foreach (index, parameter; declaration.parameters) {
            auto implicitReceiver = index == 0 && parameter.isReference
                && parameter.type == TypeKind.structType
                && parameter.namedType == declaration.ownerType
                && (declaration.isDestructor || declaration.isConstructor || declaration.isMethod);
            if (parameter.type == TypeKind.structType && !implicitReceiver) {
                diagnostics.error(parameter.location,
                    "by-value struct parameters are not supported until copy semantics are implemented");
            }
        }
        if (!declaration.hasBody) {
            return;
        }
        loopDepth = 0;
        auto localScope = new Scope();
        foreach (parameter; declaration.parameters) {
            if (!localScope.define(parameter.name, parameter.type, parameter.namedType)) {
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
                TypeKind valueType = TypeKind.invalid;
                string valueNamedType;
                if (statement.hasExpression) {
                    valueType = analyzeExpression(statement.expression, localScope);
                    valueNamedType = statement.expression.inferredNamedType;
                }
                if (statement.inferredDeclaration) {
                    statement.declaredType = valueType;
                    statement.declaredNamedType = valueNamedType;
                    if (valueType == TypeKind.structType
                            && statement.expression.isConstructorCall) {
                        statement.selectedConstructor = statement.expression.resolvedFunction;
                    }
                } else if (statement.declaredType == TypeKind.fixedArray) {
                    if (statement.elementType != TypeKind.structType
                            || !(statement.declaredNamedType in symbols.structs)) {
                        diagnostics.error(statement.location,
                            "fixed arrays currently require a declared struct element type");
                    }
                    if (statement.hasExpression) {
                        diagnostics.error(statement.location,
                            "fixed-array initialization expressions are not supported");
                    }
                    if (statement.declaredNamedType in symbols.structs
                            && (!hasDefaultConstructor(statement.declaredNamedType)
                                || !hasDefaultConstructibleMembers(statement.declaredNamedType))) {
                        diagnostics.error(statement.location,
                            "fixed-array elements require default-constructible struct types");
                    }
                } else if (statement.declaredType == TypeKind.structType) {
                    if (!(statement.declaredNamedType in symbols.structs)) {
                        diagnostics.error(statement.location, "unknown struct type '"
                            ~ statement.declaredNamedType ~ "'");
                    } else if (statement.hasExpression
                            && (valueType != TypeKind.structType
                                || valueNamedType != statement.declaredNamedType
                                || statement.expression.kind != ExprKind.call
                                || !statement.expression.isConstructorCall)) {
                        diagnostics.error(statement.location,
                            "struct initialization requires a constructor call; copying is not supported");
                    } else if (statement.hasExpression) {
                        statement.selectedConstructor = statement.expression.resolvedFunction;
                    } else {
                        statement.selectedConstructor = resolveConstructor(
                            statement.declaredNamedType, [], statement.location);
                        if (!hasDefaultConstructibleMembers(statement.declaredNamedType)) {
                            diagnostics.error(statement.location, "struct '"
                                ~ statement.declaredNamedType
                                ~ "' contains a member without a default constructor");
                        }
                    }
                } else if (statement.hasExpression && !canConvert(valueType, statement.declaredType)) {
                    diagnostics.error(statement.location, "cannot initialize " ~ typeName(statement.declaredType)
                        ~ " variable '" ~ statement.name ~ "' with " ~ typeName(valueType));
                }
                if (statement.declaredType == TypeKind.voidType
                        || statement.declaredType == TypeKind.invalid
                        || (!statement.hasExpression
                            && statement.declaredType != TypeKind.structType
                            && statement.declaredType != TypeKind.fixedArray)) {
                    diagnostics.error(statement.location, "variable '" ~ statement.name ~ "' has invalid type");
                }
                if (statement.declaredType == TypeKind.structType
                        || statement.declaredType == TypeKind.fixedArray) {
                    statement.objectLifetime = ObjectLifetime.constructing;
                }
                if (!localScope.define(statement.name, statement.declaredType,
                        statement.declaredNamedType, statement.elementType,
                        statement.arrayLength)) {
                    diagnostics.error(statement.location, "variable '" ~ statement.name ~ "' is already declared in this scope");
                }
                return false;
            case StmtKind.expression:
                auto expressionType = analyzeExpression(statement.expression, localScope);
                if (expressionType == TypeKind.structType
                        && statement.expression.isConstructorCall) {
                    diagnostics.error(statement.location,
                        "constructed struct values must initialize a local variable");
                }
                return false;
            case StmtKind.scopeExit:
                analyzeExpression(statement.expression, localScope);
                return false;
            case StmtKind.breakStatement:
            case StmtKind.continueStatement:
                if (loopDepth == 0) {
                    diagnostics.error(statement.location, statement.kind == StmtKind.breakStatement
                        ? "break statement is only valid inside a loop"
                        : "continue statement is only valid inside a loop");
                }
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
                loopDepth++;
                analyzeStatements(statement.body, new Scope(localScope), returnType);
                loopDepth--;
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
                if (!localScope.lookup(expression.text, expression.inferredType,
                        expression.inferredNamedType, expression.elementType,
                        expression.arrayLength)) {
                    diagnostics.error(expression.location, "unknown variable '" ~ expression.text ~ "'");
                    expression.inferredType = TypeKind.invalid;
                }
                return expression.inferredType;
            case ExprKind.member:
                auto ownerType = analyzeExpression(expression.left, localScope);
                expression.memberOwnerType = expression.left.inferredNamedType;
                if ((expression.left.kind != ExprKind.variable
                        && expression.left.kind != ExprKind.member
                        && expression.left.kind != ExprKind.index)
                        || ownerType != TypeKind.structType
                        || !(expression.memberOwnerType in symbols.structs)) {
                    diagnostics.error(expression.location,
                        "field access currently requires an addressable struct variable");
                    expression.inferredType = TypeKind.invalid;
                    return expression.inferredType;
                }
                auto structure = symbols.structs[expression.memberOwnerType];
                foreach (index, field; structure.fields) {
                    if (field.name == expression.text) {
                        expression.fieldIndex = index;
                        expression.inferredType = field.type;
                        expression.inferredNamedType = field.namedType;
                        expression.elementType = field.elementType;
                        expression.arrayLength = field.arrayLength;
                        return expression.inferredType;
                    }
                }
                diagnostics.error(expression.location, "struct '" ~ expression.memberOwnerType
                    ~ "' has no field named '" ~ expression.text ~ "'");
                expression.inferredType = TypeKind.invalid;
                return expression.inferredType;
            case ExprKind.index:
                auto arrayType = analyzeExpression(expression.left, localScope);
                auto indexType = analyzeExpression(expression.right, localScope);
                if (arrayType != TypeKind.fixedArray) {
                    diagnostics.error(expression.location, "indexing requires a fixed-array value");
                    expression.inferredType = TypeKind.invalid;
                } else if (!isInteger(indexType)) {
                    diagnostics.error(expression.right.location, "array index must be an integer");
                    expression.inferredType = TypeKind.invalid;
                } else if (expression.right.kind != ExprKind.integer
                        || expression.right.integerValue < 0
                        || cast(ulong) expression.right.integerValue >= expression.left.arrayLength) {
                    diagnostics.error(expression.right.location,
                        "fixed-array index must be an in-range integer literal in this compiler increment");
                    expression.inferredType = TypeKind.invalid;
                } else {
                    expression.inferredType = expression.left.elementType;
                    expression.inferredNamedType = expression.left.inferredNamedType;
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
            if (expression.left.kind != ExprKind.variable
                    && expression.left.kind != ExprKind.member
                    && expression.left.kind != ExprKind.index) {
                diagnostics.error(expression.location, "assignment target must be a variable or field");
                return TypeKind.invalid;
            }
            if (!canConvert(rightType, leftType)) {
                diagnostics.error(expression.location, "cannot assign " ~ typeName(rightType)
                    ~ " to " ~ typeName(leftType));
            }
            if (leftType == TypeKind.structType) {
                diagnostics.error(expression.location,
                    "struct assignment would copy a value; copy semantics are not implemented");
                expression.inferredType = TypeKind.invalid;
                return expression.inferredType;
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
        if (expression.left.kind == ExprKind.variable
                && expression.left.text in symbols.structs) {
            TypeKind[] argumentTypes;
            foreach (ref argument; expression.arguments) {
                argumentTypes ~= analyzeExpression(argument, localScope);
            }
            expression.inferredType = TypeKind.structType;
            expression.inferredNamedType = expression.left.text;
            expression.isConstructorCall = true;
            expression.resolvedFunction = resolveConstructor(expression.left.text,
                expression.arguments, argumentTypes, expression.location);
            return expression.inferredType;
        }

        if (expression.left.kind == ExprKind.member) {
            auto receiver = expression.left.left;
            auto receiverType = analyzeExpression(receiver, localScope);
            auto receiverName = receiver.inferredNamedType;
            if ((receiver.kind != ExprKind.variable && receiver.kind != ExprKind.member
                    && receiver.kind != ExprKind.index)
                    || receiverType != TypeKind.structType
                    || !(receiverName in symbols.structs)) {
                diagnostics.error(expression.location,
                    "method call requires an addressable struct variable");
                return TypeKind.invalid;
            }
            TypeKind[] argumentTypes;
            foreach (ref argument; expression.arguments) {
                argumentTypes ~= analyzeExpression(argument, localScope);
            }
            auto structure = symbols.structs[receiverName];
            string[] candidates;
            foreach (method; structure.methods) {
                if (method.sourceName == expression.left.text) {
                    candidates ~= method.name;
                }
            }
            auto selected = resolveOverload(candidates, expression.arguments, argumentTypes,
                expression.location, receiverName ~ "." ~ expression.left.text, 1);
            if (selected.length == 0) {
                expression.inferredType = TypeKind.invalid;
                return expression.inferredType;
            }
            auto method = symbols.functions[selected];
            expression.resolvedFunction = method.name;
            expression.isMethodCall = true;
            expression.inferredType = method.returnType;
            return expression.inferredType;
        }

        if (expression.left.kind != ExprKind.variable) {
            diagnostics.error(expression.location, "only named functions and struct methods can be called");
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
        expression.resolvedFunction = target.name;
        expression.inferredType = target.returnType;
        return expression.inferredType;
    }

    private string resolveConstructor(string typeName, Expr[] arguments,
            SourceLocation location) {
        TypeKind[] argumentTypes;
        foreach (ref argument; arguments) {
            argumentTypes ~= argument.inferredType;
        }
        return resolveConstructor(typeName, arguments, argumentTypes, location);
    }

    private string resolveConstructor(string typeName, Expr[] arguments,
            TypeKind[] argumentTypes, SourceLocation location) {
        auto structure = symbols.structs[typeName];
        if (structure.constructorNames.length == 0) {
            if (arguments.length == 0) {
                return "";
            }
            diagnostics.error(location, "struct '" ~ typeName
                ~ "' has no constructor accepting arguments");
            return "";
        }
        auto selected = resolveOverload(structure.constructorNames, arguments, argumentTypes,
            location, typeName, 1);
        if (selected.length == 0 && arguments.length == 0) {
            diagnostics.error(location, "struct '" ~ typeName
                ~ "' has no default constructor");
        }
        return selected;
    }

    private string resolveOverload(string[] candidates, Expr[] arguments,
            TypeKind[] argumentTypes, SourceLocation location, string description,
            size_t implicitParameterCount) {
        string selected;
        size_t bestScore = size_t.max;
        bool ambiguous;
        foreach (candidateName; candidates) {
            auto candidate = symbols.functions[candidateName];
            if (candidate.parameterTypes.length != arguments.length + implicitParameterCount) {
                continue;
            }
            size_t score;
            bool matches = true;
            foreach (index, argumentType; argumentTypes) {
                auto expected = candidate.parameterTypes[index + implicitParameterCount];
                auto argument = arguments[index];
                auto cStringLiteral = expected == TypeKind.cStringPointer
                    && argument.kind == ExprKind.stringLiteral;
                auto nullPointer = expected == TypeKind.voidPointer
                    && argumentType == TypeKind.nullType;
                if (!cStringLiteral && !nullPointer && !canConvert(argumentType, expected)) {
                    matches = false;
                    break;
                }
                if (!cStringLiteral && !nullPointer && argumentType != expected) {
                    score++;
                }
            }
            if (!matches) {
                continue;
            }
            if (score < bestScore) {
                selected = candidate.name;
                bestScore = score;
                ambiguous = false;
            } else if (score == bestScore) {
                ambiguous = true;
            }
        }
        if (ambiguous) {
            diagnostics.error(location, "ambiguous overload for '" ~ description ~ "'");
            return "";
        }
        if (selected.length == 0 && candidates.length) {
            diagnostics.error(location, "no matching overload for '" ~ description ~ "'");
        }
        return selected;
    }

    private bool hasDefaultConstructibleMembers(string typeName) const {
        auto structure = symbols.structs[typeName];
        foreach (field; structure.fields) {
            if ((field.type == TypeKind.structType
                    || (field.type == TypeKind.fixedArray
                        && field.elementType == TypeKind.structType))
                    && (!hasDefaultConstructor(field.namedType)
                        || !hasDefaultConstructibleMembers(field.namedType))) {
                return false;
            }
        }
        return true;
    }

    private bool hasDefaultConstructor(string typeName) const {
        auto structure = symbols.structs[typeName];
        if (structure.constructorNames.length == 0) {
            return true;
        }
        foreach (constructorName; structure.constructorNames) {
            if (symbols.functions[constructorName].parameterTypes.length == 1) {
                return true;
            }
        }
        return false;
    }
}
