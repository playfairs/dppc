module ir.ir;

import ast.ast : TypeKind;

public enum Opcode {
    label,
    integerConstant,
    booleanConstant,
    stringConstant,
    nullPointer,
    alloca,
    load,
    store,
    signExtend,
    binary,
    compare,
    call,
    phi,
    branch,
    conditionalBranch,
    returnValue,
    returnVoid
}

public struct Instruction {
    Opcode opcode;
    TypeKind type;
    TypeKind[] operandTypes;
    string result;
    string operation;
    string value;
    string[] operands;
    bool externC;
}

public struct Parameter {
    string name;
    TypeKind type;
}

public struct Function {
    string name;
    TypeKind returnType;
    Parameter[] parameters;
    Instruction[] instructions;
    bool externC;
    bool hasBody = true;
}

public struct IRProgram {
    Function[] functions;
}
