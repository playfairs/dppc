module linker.linker;

import std.file : exists, mkdirRecurse, remove, write;
import std.path : dirName;
import std.process : spawnProcess, wait;

public struct LinkResult {
    bool success;
    int exitCode;
}

public struct Linker {
    public LinkResult link(string llvmIR, string outputPath, string[] objectFiles = null) {
        auto irPath = outputPath ~ ".dpp.ll";
        auto outputDirectory = dirName(outputPath);
        if (outputDirectory.length != 0) {
            mkdirRecurse(outputDirectory);
        }
        write(irPath, llvmIR);
        scope(exit) {
            if (irPath.exists) {
                remove(irPath);
            }
        }

        auto arguments = [
            "clang",
            "-Qunused-arguments",
            "-Wno-override-module",
            "-x",
            "ir",
            irPath
        ];
        if (objectFiles.length) {
            arguments ~= ["-x", "none"] ~ objectFiles;
        }
        arguments ~= ["-o", outputPath];
        auto process = spawnProcess(arguments);
        auto status = wait(process);
        return LinkResult(status == 0, status);
    }
}
