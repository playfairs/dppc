module ctfe.ctfe;

import ast.ast;

private struct Constant {
    bool valid;
    TypeKind type;
    long integer;
    bool boolean;
}

public struct CompileTimeEvaluator {
    public void evaluate(ref Program program) {
        foreach (ref declaration; program.functions) {
            evaluateStatements(declaration.body);
        }
    }

    private void evaluateStatements(ref Stmt[] statements) {
        foreach (ref statement; statements) {
            evaluateExpression(statement.expression);
            evaluateStatements(statement.body);
            evaluateStatements(statement.alternate);
        }
    }

    private void evaluateExpression(ref Expr expression) {
        if (expression is null) {
            return;
        }
        foreach (ref argument; expression.arguments) {
            evaluateExpression(argument);
        }
        evaluateExpression(expression.left);
        evaluateExpression(expression.right);

        if (expression.kind != ExprKind.unary && expression.kind != ExprKind.binary) {
            return;
        }
        auto value = constantValue(expression);
        if (!value.valid) {
            return;
        }
        expression.kind = value.type == TypeKind.boolType ? ExprKind.boolean : ExprKind.integer;
        expression.integerValue = value.integer;
        expression.booleanValue = value.boolean;
        expression.text = "";
        expression.left = null;
        expression.right = null;
        expression.arguments = null;
    }

    private Constant constantValue(ref Expr expression) {
        if (expression is null) {
            return Constant.init;
        }
        if (expression.kind == ExprKind.integer) {
            return Constant(true, expression.inferredType, expression.integerValue, false);
        }
        if (expression.kind == ExprKind.boolean) {
            return Constant(true, TypeKind.boolType, 0, expression.booleanValue);
        }
        if (expression.kind != ExprKind.unary && expression.kind != ExprKind.binary) {
            return Constant.init;
        }

        auto left = constantValue(expression.left);
        if (!left.valid) {
            return Constant.init;
        }
        if (expression.kind == ExprKind.unary) {
            if (expression.text == "-" && left.type != TypeKind.boolType) {
                return Constant(true, left.type, -left.integer, false);
            }
            if (expression.text == "!") {
                return Constant(true, TypeKind.boolType, 0, !left.boolean);
            }
            return Constant.init;
        }

        auto right = constantValue(expression.right);
        if (!right.valid) {
            return Constant.init;
        }
        if (left.type == TypeKind.boolType && right.type == TypeKind.boolType) {
            if (expression.text == "==") {
                return Constant(true, TypeKind.boolType, 0, left.boolean == right.boolean);
            }
            if (expression.text == "!=") {
                return Constant(true, TypeKind.boolType, 0, left.boolean != right.boolean);
            }
            if (expression.text == "&&") {
                return Constant(true, TypeKind.boolType, 0, left.boolean && right.boolean);
            }
            if (expression.text == "||") {
                return Constant(true, TypeKind.boolType, 0, left.boolean || right.boolean);
            }
            return Constant.init;
        }
        auto commonType = left.type == TypeKind.longType || right.type == TypeKind.longType
            ? TypeKind.longType : left.type;
        switch (expression.text) {
            case "+":
                return Constant(true, commonType, left.integer + right.integer, false);
            case "-":
                return Constant(true, commonType, left.integer - right.integer, false);
            case "*":
                return Constant(true, commonType, left.integer * right.integer, false);
            case "/":
                if (right.integer != 0) {
                    return Constant(true, commonType, left.integer / right.integer, false);
                }
                return Constant.init;
            case "%":
                if (right.integer != 0) {
                    return Constant(true, commonType, left.integer % right.integer, false);
                }
                return Constant.init;
            case "==": return Constant(true, TypeKind.boolType, 0, left.integer == right.integer);
            case "!=": return Constant(true, TypeKind.boolType, 0, left.integer != right.integer);
            case "<": return Constant(true, TypeKind.boolType, 0, left.integer < right.integer);
            case "<=": return Constant(true, TypeKind.boolType, 0, left.integer <= right.integer);
            case ">": return Constant(true, TypeKind.boolType, 0, left.integer > right.integer);
            case ">=": return Constant(true, TypeKind.boolType, 0, left.integer >= right.integer);
            default: return Constant.init;
        }
    }
}
