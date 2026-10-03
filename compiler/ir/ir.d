module ir.ir;

import ast.ast : TypeKind;

public enum Opcode
{
    label,
    integerConstant,
    booleanConstant,
    stringConstant,
    nullPointer,
    alloca,
    fieldAddress,
    arrayElementAddress,
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

public struct Instruction
{
    Opcode opcode;
    TypeKind type;
    TypeKind[] operandTypes;
    string result;
    string operation;
    string value;
    string[] operands;
    bool externC;
    string namedType;
    bool[] indirectArguments;
    size_t arrayLength;
}

public struct Parameter
{
    string name;
    TypeKind type;
    bool isReference;
}

public struct Function
{
    string name;
    TypeKind returnType;
    Parameter[] parameters;
    Instruction[] instructions;
    bool externC;
    bool hasBody = true;
}

public struct StructType
{
    string name;
    TypeKind[] fieldTypes;
    string[] fieldNamedTypes;
    size_t size;
    size_t alignment;
    bool hasUserDestructor;
    bool hasGeneratedDestructor;
    bool needsDestruction;
    string[] constructorNames;
    size_t[] fieldArrayLengths;
    TypeKind[] fieldElementTypes;
}

public struct IRProgram
{
    StructType[] structs;
    Function[] functions;
}
