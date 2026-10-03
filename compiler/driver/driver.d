module driver.driver;

import ast.ast : Program, SourceLocation;
import backend.llvm_backend : LLVMBackend;
import ctfe.ctfe : CompileTimeEvaluator;
import diagnostics.diagnostics : Diagnostics;
import lexer.lexer : Lexer, Token, TokenKind;
import linker.linker : Linker;
import lowering.lowering : Lowerer;
import optimizer.optimizer : Optimizer;
import parser.parser : Parser;
import semantic.semantic : SemanticAnalyzer;
import std.file : exists, readText, thisExePath, write;
import std.path : buildPath, dirName;
import std.process : spawnProcess, wait;
import std.stdio : stderr, writeln;
import std.string : endsWith;
import symbols.symbols : SymbolTable;

enum string compilerName = "dpp";
enum string compilerVersion = "0.2.0";

private void printUsage()
{
    writeln("Usage: dpp [--check] [--emit-ir FILE] [-o FILE] [--run] SOURCE.dpp");
    writeln("       dpp run [--emit-ir FILE] [-o FILE] SOURCE.dpp [-- ARGS...]");
    writeln("Compile the supported D++ core to a native executable.");
}

public int runCompiler(string[] args)
{
    if (args.length > 1 && args[1] == "run")
    {
        args = [args[0], "--run"] ~ args[2 .. $];
    }

    string sourcePath;
    string outputPath;
    string irPath;
    string[] linkObjects;
    bool checkOnly;
    bool runAfterBuild;
    string[] programArguments;
    bool programArgsStarted;

    for (size_t index = 1; index < args.length; index++)
    {
        auto argument = args[index];
        if (programArgsStarted)
        {
            programArguments ~= argument;
        }
        else if (argument == "--")
        {
            programArgsStarted = true;
        }
        else if (argument == "--help" || argument == "-h")
        {
            printUsage();
            return 0;
        }
        else if (argument == "--version")
        {
            writeln(compilerName, " ", compilerVersion);
            return 0;
        }
        else if (argument == "--check")
        {
            checkOnly = true;
        }
        else if (argument == "--run")
        {
            runAfterBuild = true;
        }
        else if (argument == "-o")
        {
            if (++index >= args.length)
            {
                stderr.writeln("dpp: -o requires an output path");
                return 2;
            }
            outputPath = args[index];
        }
        else if (argument == "--emit-ir")
        {
            if (++index >= args.length)
            {
                stderr.writeln("dpp: --emit-ir requires a path");
                return 2;
            }
            irPath = args[index];
        }
        else if (argument == "--link-object")
        {
            if (++index >= args.length)
            {
                stderr.writeln("dpp: --link-object requires an object-file path");
                return 2;
            }
            linkObjects ~= args[index];
        }
        else if (argument.length && argument[0] == '-')
        {
            stderr.writeln("dpp: unknown option '", argument, "'");
            printUsage();
            return 2;
        }
        else if (sourcePath.length == 0)
        {
            sourcePath = argument;
        }
        else
        {
            stderr.writeln("dpp: only one source file is supported in this compiler increment");
            return 2;
        }
    }

    if (sourcePath.length == 0)
    {
        printUsage();
        return 2;
    }
    if (!sourcePath.endsWith(".dpp") && !sourcePath.endsWith(".d"))
    {
        stderr.writeln("dpp: source file must use .dpp or .d extension");
        return 2;
    }

    try
    {
        auto source = readText(sourcePath);
        auto diagnostics = Diagnostics();
        auto lexer = Lexer(source, sourcePath, &diagnostics);
        Token[] tokens;
        while (true)
        {
            auto token = lexer.nextToken();
            if (token.kind != TokenKind.invalid)
            {
                tokens ~= token;
            }
            if (token.kind == TokenKind.end)
            {
                break;
            }
        }

        auto parser = Parser(tokens, &diagnostics);
        auto program = parser.parseProgram();
        if (diagnostics.hasErrors())
        {
            diagnostics.print();
            return 1;
        }

        auto analyzer = SemanticAnalyzer(&diagnostics);
        auto symbols = analyzer.analyze(program);
        if (diagnostics.hasErrors())
        {
            diagnostics.print();
            return 1;
        }

        auto ctfe = CompileTimeEvaluator();
        ctfe.evaluate(program);
        auto lowerer = Lowerer();
        auto irProgram = lowerer.lower(program, symbols);
        auto optimizer = Optimizer();
        optimizer.optimize(irProgram);
        auto backend = new LLVMBackend();
        auto llvmIR = backend.emit(irProgram);

        if (irPath.length)
        {
            write(irPath, llvmIR);
        }
        if (checkOnly)
        {
            return 0;
        }

        if (outputPath.length == 0)
        {
            outputPath = sourcePath ~ ".out";
        }
        auto linker = Linker();
        auto linkResult = linker.link(llvmIR, outputPath, linkObjects, runtimeLibraryPath());
        if (!linkResult.success)
        {
            stderr.writeln("dpp: native code generation or linking failed with exit status ",
                    linkResult.exitCode);
            return 1;
        }

        if (runAfterBuild)
        {
            auto command = [outputPath] ~ programArguments;
            return wait(spawnProcess(command));
        }
        return 0;
    }
    catch (Exception error)
    {
        stderr.writeln("dpp: ", error.msg);
        return 1;
    }
}

private string runtimeLibraryPath()
{
    auto executableDirectory = dirName(thisExePath());
    auto buildDirectory = dirName(executableDirectory);
    auto developmentLibrary = buildPath(buildDirectory, "dpp_runtime", "libdpp_runtime.a");
    if (developmentLibrary.exists)
    {
        return developmentLibrary;
    }

    auto installationDirectory = dirName(executableDirectory);
    auto installedLibrary = buildPath(installationDirectory, "lib", "libdpp_runtime.a");
    if (installedLibrary.exists)
    {
        return installedLibrary;
    }
    throw new Exception("cannot locate libdpp_runtime.a beside the compiler");
}
