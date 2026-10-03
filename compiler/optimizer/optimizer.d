module optimizer.optimizer;

import ir.ir;
import std.conv : to;

public struct Optimizer {
    public void optimize(ref IRProgram program) {
        foreach (ref declaration; program.functions) {
            optimizeFunction(declaration);
        }
    }

    private void optimizeFunction(ref Function declaration) {
        long[string] integers;
        bool[string] booleans;

        foreach (ref instruction; declaration.instructions) {
            switch (instruction.opcode) {
                case Opcode.integerConstant:
                    integers[instruction.result] = to!long(instruction.value);
                    break;
                case Opcode.booleanConstant:
                    if (instruction.operation == "not") {
                        if (auto operand = instruction.value in booleans) {
                            instruction.value = *operand ? "false" : "true";
                            instruction.operation = "";
                        }
                    }
                    booleans[instruction.result] = instruction.value == "true";
                    break;
                case Opcode.binary:
                    if (instruction.operands.length != 2) {
                        break;
                    }
                    auto left = instruction.operands[0] in integers;
                    auto right = instruction.operands[1] in integers;
                    if (left is null || right is null) {
                        break;
                    }
                    long folded;
                    bool valid = true;
                    switch (instruction.operation) {
                        case "+": folded = *left + *right; break;
                        case "-": folded = *left - *right; break;
                        case "*": folded = *left * *right; break;
                        case "/":
                            if (*right == 0) valid = false;
                            else folded = *left / *right;
                            break;
                        case "%":
                            if (*right == 0) valid = false;
                            else folded = *left % *right;
                            break;
                        default: valid = false;
                    }
                    if (valid) {
                        instruction.opcode = Opcode.integerConstant;
                        instruction.operation = "";
                        instruction.value = to!string(folded);
                        instruction.operands = null;
                        integers[instruction.result] = folded;
                    }
                    break;
                case Opcode.compare:
                    if (instruction.operands.length != 2) {
                        break;
                    }
                    auto left = instruction.operands[0] in integers;
                    auto right = instruction.operands[1] in integers;
                    if (left is null || right is null) {
                        break;
                    }
                    bool folded;
                    switch (instruction.operation) {
                        case "==": folded = *left == *right; break;
                        case "!=": folded = *left != *right; break;
                        case "<": folded = *left < *right; break;
                        case "<=": folded = *left <= *right; break;
                        case ">": folded = *left > *right; break;
                        case ">=": folded = *left >= *right; break;
                        default: break;
                    }
                    instruction.opcode = Opcode.booleanConstant;
                    instruction.operation = "";
                    instruction.value = folded ? "true" : "false";
                    instruction.operands = null;
                    booleans[instruction.result] = folded;
                    break;
                case Opcode.signExtend:
                    if (instruction.operands.length == 1) {
                        if (auto integer = instruction.operands[0] in integers) {
                            integers[instruction.result] = *integer;
                        }
                    }
                    break;
                case Opcode.label, Opcode.stringConstant, Opcode.nullPointer, Opcode.alloca,
                        Opcode.fieldAddress, Opcode.arrayElementAddress, Opcode.load,
                        Opcode.store, Opcode.call, Opcode.phi, Opcode.branch,
                        Opcode.conditionalBranch, Opcode.returnValue, Opcode.returnVoid:
                    break;
                default:
                    break;
            }
        }
    }
}
