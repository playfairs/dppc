module backend.llvm_backend;

import ast.ast : TypeKind;
import ir.ir;
import std.array : Appender, appender;
import std.conv : to;
import std.format : format;
import std.string : split;

private class StringPool {
    private string[] values;
    private size_t[string] indices;

    size_t intern(string value) {
        if (auto found = value in indices) {
            return *found;
        }
        auto index = values.length;
        values ~= value;
        indices[value] = index;
        return index;
    }

    string pointer(string value) {
        auto index = intern(value);
        return format("getelementptr inbounds ([%s x i8], ptr @.dpp.str.%s, i64 0, i64 0)",
            value.length + 1, index);
    }

    string instructionPointer(string value) {
        auto index = intern(value);
        return format("getelementptr inbounds [%s x i8], ptr @.dpp.str.%s, i64 0, i64 0",
            value.length + 1, index);
    }

    void emitGlobals(ref Appender!string output) const {
        foreach (index, value; values) {
            output.put(format("@.dpp.str.%s = private unnamed_addr constant [%s x i8] c\"%s\\00\", align 1\n",
                index, value.length + 1, escape(value)));
        }
    }

    private static string escape(string value) {
        auto result = appender!string();
        foreach (ubyte octet; value) {
            if (octet >= 32 && octet <= 126 && octet != '"' && octet != '\\') {
                result.put(cast(char) octet);
            } else {
                result.put(format("\\%02X", octet));
            }
        }
        return result.data;
    }
}

public class LLVMBackend {
    private StringPool strings;
    private bool usesPrintf;
    private size_t temporaryIndex;

    public string emit(IRProgram program) {
        strings = new StringPool();
        usesPrintf = false;
        foreach (declaration; program.functions) {
            foreach (instruction; declaration.instructions) {
                if (instruction.opcode == Opcode.stringConstant) {
                    strings.intern(instruction.value);
                }
                if (instruction.opcode == Opcode.call && instruction.operation == "writeln") {
                    strings.intern(writelnFormat(instruction.operandTypes));
                    usesPrintf = true;
                }
            }
        }

        auto output = appender!string();
        strings.emitGlobals(output);
        if (usesPrintf) {
            output.put("declare i32 @printf(ptr, ...)\n\n");
        }
        foreach (declaration; program.functions) {
            emitFunction(output, declaration);
            output.put("\n");
        }
        return output.data;
    }

    private void emitFunction(ref Appender!string output, Function declaration) {
        output.put(format("%s %s @%s(", declaration.hasBody ? "define" : "declare",
            llvmType(declaration.returnType), functionName(declaration.name, declaration.externC)));
        foreach (index, parameter; declaration.parameters) {
            if (index != 0) {
                output.put(", ");
            }
            output.put(llvmType(parameter.type));
            if (declaration.hasBody) {
                output.put(format(" %%arg%s", index));
            }
        }
        if (!declaration.hasBody) {
            output.put(")\n");
            return;
        }
        output.put(") {\n");
        foreach (instruction; declaration.instructions) {
            emitInstruction(output, instruction);
        }
        output.put("}\n");
    }

    private void emitInstruction(ref Appender!string output, ref Instruction instruction) {
        switch (instruction.opcode) {
            case Opcode.label:
                output.put(instruction.value ~ ":\n");
                return;
            case Opcode.integerConstant:
                output.put(format("  %s = add %s 0, %s\n", instruction.result,
                    llvmType(instruction.type), instruction.value));
                return;
            case Opcode.booleanConstant:
                if (instruction.operation == "not") {
                    output.put(format("  %s = xor i1 %s, true\n", instruction.result, instruction.value));
                } else {
                    output.put(format("  %s = or i1 false, %s\n", instruction.result, instruction.value));
                }
                return;
            case Opcode.stringConstant:
                output.put(format("  %s = %s\n", instruction.result,
                    strings.instructionPointer(instruction.value)));
                return;
            case Opcode.nullPointer:
                output.put(format("  %s = select i1 true, ptr null, ptr null\n", instruction.result));
                return;
            case Opcode.alloca:
                output.put(format("  %s = alloca %s\n", instruction.result, llvmType(instruction.type)));
                return;
            case Opcode.load:
                output.put(format("  %s = load %s, ptr %s\n", instruction.result,
                    llvmType(instruction.type), instruction.operands[0]));
                return;
            case Opcode.store:
                output.put(format("  store %s %s, ptr %s\n", llvmType(instruction.type),
                    instruction.operands[1], instruction.operands[0]));
                return;
            case Opcode.signExtend:
                output.put(format("  %s = sext %s %s to %s\n", instruction.result,
                    llvmType(instruction.operandTypes[0]), instruction.operands[0],
                    llvmType(instruction.type)));
                return;
            case Opcode.binary:
                output.put(format("  %s = %s %s %s, %s\n", instruction.result,
                    binaryOpcode(instruction.operation), llvmType(instruction.type),
                    instruction.operands[0], instruction.operands[1]));
                return;
            case Opcode.compare:
                output.put(format("  %s = icmp %s %s %s, %s\n", instruction.result,
                    compareOpcode(instruction.operation, instruction.operandTypes[0]),
                    llvmType(instruction.operandTypes[0]),
                    instruction.operands[0], instruction.operands[1]));
                return;
            case Opcode.call:
                emitCall(output, instruction);
                return;
            case Opcode.phi:
                auto pairs = instruction.value.split(";");
                auto first = pairs[0].split("@");
                auto second = pairs[1].split("@");
                output.put(format("  %s = phi i1 [ %s, %%%s ], [ %s, %%%s ]\n",
                    instruction.result, first[0], first[1], second[0], second[1]));
                return;
            case Opcode.branch:
                output.put(format("  br label %%%s\n", instruction.value));
                return;
            case Opcode.conditionalBranch:
                output.put(format("  br i1 %s, label %%%s, label %%%s\n",
                    instruction.operands[0], instruction.operands[1], instruction.operands[2]));
                return;
            case Opcode.returnValue:
                output.put(format("  ret %s %s\n", llvmType(instruction.type), instruction.operands[0]));
                return;
            case Opcode.returnVoid:
                output.put("  ret void\n");
                return;
            default:
                assert(0, "unknown IR opcode");
        }
    }

    private void emitCall(ref Appender!string output, ref Instruction instruction) {
        if (instruction.operation == "writeln") {
            auto formatString = writelnFormat(instruction.operandTypes);
            auto formatPointer = strings.pointer(formatString);
            string[] values = instruction.operands.dup;
            foreach (index, type; instruction.operandTypes) {
                if (type == TypeKind.boolType) {
                    auto promoted = format("%%printf.bool.%s", temporaryIndex++);
                    output.put(format("  %s = zext i1 %s to i32\n", promoted, values[index]));
                    values[index] = promoted;
                }
            }
            output.put("  call i32 (ptr, ...) @printf(ptr " ~ formatPointer);
            foreach (index, operand; values) {
                auto type = instruction.operandTypes[index];
                output.put(", ");
                output.put(format("%s %s", type == TypeKind.boolType ? "i32" : llvmType(type), operand));
            }
            output.put(")\n");
            return;
        }

        auto callText = format("call %s @%s(", llvmType(instruction.type),
            functionName(instruction.operation, instruction.externC));
        auto result = instruction.result.length ? instruction.result ~ " = " : "";
        output.put("  " ~ result ~ callText);
        foreach (index, operand; instruction.operands) {
            output.put(format("%s%s %s", index == 0 ? "" : ", ",
                llvmType(instruction.operandTypes[index]), operand));
        }
        output.put(")\n");
    }

    private static string writelnFormat(TypeKind[] types) {
        auto result = appender!string();
        foreach (type; types) {
            final switch (type) {
                case TypeKind.intType: result.put("%d"); break;
                case TypeKind.longType: result.put("%lld"); break;
                case TypeKind.boolType: result.put("%d"); break;
                case TypeKind.stringType, TypeKind.cStringPointer: result.put("%s"); break;
                case TypeKind.voidType, TypeKind.invalid, TypeKind.voidPointer, TypeKind.nullType:
                    result.put("%s");
                    break;
            }
        }
        result.put("\n");
        return result.data;
    }

    private static string llvmType(TypeKind type) {
        final switch (type) {
            case TypeKind.voidType: return "void";
            case TypeKind.intType: return "i32";
            case TypeKind.longType: return "i64";
            case TypeKind.boolType: return "i1";
            case TypeKind.stringType, TypeKind.cStringPointer, TypeKind.voidPointer,
                    TypeKind.nullType: return "ptr";
            case TypeKind.invalid: return "i32";
        }
    }

    private static string binaryOpcode(string operation) {
        switch (operation) {
            case "+": return "add";
            case "-": return "sub";
            case "*": return "mul";
            case "/": return "sdiv";
            case "%": return "srem";
            default: return "add";
        }
    }

    private static string compareOpcode(string operation, TypeKind type) {
        if (type == TypeKind.voidPointer || type == TypeKind.cStringPointer) {
            return operation == "==" ? "eq" : "ne";
        }
        switch (operation) {
            case "==": return "eq";
            case "!=": return "ne";
            case "<": return "slt";
            case "<=": return "sle";
            case ">": return "sgt";
            case ">=": return "sge";
            default: return "eq";
        }
    }

    private static string functionName(string name, bool externC = false) {
        return externC || name == "main" ? name : "dpp." ~ name;
    }
}
