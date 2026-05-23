#run build();

vulkan_support := false;

LIVE_OUTPUT :: true;

build_sdl3 :: (debug: bool) -> bool {
    build_type := ifx debug then "Debug" else "Release";

    SDL3_BUILD_PATH := "SDL/build";
    make_directory_if_it_does_not_exist(SDL3_BUILD_PATH, true);
    absolute_build_path := get_absolute_path(SDL3_BUILD_PATH);
    print("SDL3 build path: %\n", absolute_build_path);

    print("Confuguring SDL3 build (% mode)...\n", build_type);

    config_command: [..] string;
    array_add(*config_command,
        "cmake",
        "-DSDL_SHARED=ON",
        "-DSDL_STATIC=OFF",
        "-B",
        absolute_build_path,
        tprint("-DCMAKE_BUILD_TYPE=%", build_type),
        "-DSDL_TESTS=OFF",
    );

    run_or_exit(config_command, working_directory = "SDL");
    print("Done configuring SDL3.");
    print("Building SDL3 (% mode)...", build_type);

    build_command: [..] string;
    array_add(*build_command, "cmake", "--build", absolute_build_path);
    if OS == .WINDOWS {
        array_add(*build_command, tprint("--config=%", build_type));
    }
    run_or_exit(build_command, working_directory = "SDL");
    return true;
}

build :: () {

    set_build_options_dc(.{do_output=false});

    options := get_build_options();
    args := options.compile_time_command_line;
    vulkan_support = array_find(args, "-vulkan");
    debug := array_find(args, "-debug");

    if !build_sdl3(debug) {
        compiler_set_workspace_status(.FAILED);
        return;
    }

    if !generate_bindings() {
        compiler_set_workspace_status(.FAILED);
        return;
    }
}

generate_bindings :: () -> bool {

    output_filename: string;
    opts: Generate_Bindings_Options;

    {
        #if OS == .WINDOWS {

            output_filename = "windows/windows.jai";
            opts.strip_flags = .FUNCTIONS_WITH_VALIST;

            FOOTER :: #string EOF
#if CPU == .X64 {
    sdl3 :: #library,no_dll "bin/x64/SDL3";
} else #if CPU == .ARM64 {
    sdl3 :: #library,no_dll "bin/arm64/SDL3";
}
EOF
            // DLL provided by user not in bin, so use our own footer not generated library declaration
            opts.footer = FOOTER;
            opts.generate_library_declarations = false;

            #if CPU == .X64 {
                array_add(*opts.library_search_paths, "windows/bin/x64");
            } else #if CPU == .ARM64 {
                array_add(*opts.library_search_paths, "windows/bin/arm64");
            } else {
                assert(false, "the CPU % is currently unsupported. You might be able to add support for it though!", CPU);
            }

            array_add(*opts.libraries, .{filename="SDL3"});

        } else #if OS == .LINUX {
            opts.strip_flags = .FUNCTIONS_WITH_VALIST;

            output_filename = "linux/linux.jai";

            FOOTER :: #string EOF
libsdl3 :: #library "../SDL/build/libSDL3";
EOF;
            opts.footer = FOOTER;
            opts.generate_library_declarations = false;

            array_add(*opts.library_search_paths, "SDL/build");
            array_add(*opts.library_search_paths, "../SDL/build");
            array_add(*opts.libraries, .{filename="libSDL3.so.0"});

        } else #if OS == .MACOS {

            output_filename = "macos/macos.jai";
            opts.strip_flags = .FUNCTIONS_WITH_VALIST;

            FOOTER :: #string EOF
    libsdl3 :: #library "bin/arm64/libSDL3.0_dynamic"; // Universal binary
EOF;
            // We have a universal binary
            #if CPU == .ARM64 || CPU == .X64 {
                array_add(*opts.library_search_paths, "macos/bin/arm64");
            } else {
                assert(false, "the CPU % is currently unsupported. You might be able to add support for it though!", CPU);
            }

            opts.footer = FOOTER;
            opts.generate_library_declarations = false;

            // We need the .a to bind but .dylib is used in runtime.
            array_add(*opts.libraries, .{filename="libSDL3.0"});
        } else {
            assert(false, "the OS % is currently unsupported. You might be able to add support for it though!", OS);
        }

        array_add(*opts.include_paths, "include");
        array_add(*opts.source_files, "include/SDL3/SDL.h");
        array_add(*opts.source_files, "include/SDL3/SDL_main.h");
        if vulkan_support {
            array_add(*opts.source_files, "include/SDL3/SDL_vulkan.h");
            opts.footer = sprint("#import \"Vulkan\";\n%", opts.footer);
        }

        opts.visitor = sdl3_visitor;
        opts.generate_compile_time_struct_checks = false;
    }

    return generate_bindings(opts, output_filename);
}

event_type_decl: *Enum;

sdl3_visitor :: (decl: *Declaration, parent_decl: *Declaration) -> Declaration_Visit_Result {

    if vulkan_support {
        if begins_with(decl.name, "Vk") {
            decl.decl_flags |= .OMIT_FROM_OUTPUT;
            return .STOP;
        }
    }

    if array_find(DECLARATIONS_TO_OMIT, decl.name) {
        decl.decl_flags |= .OMIT_FROM_OUTPUT;
        return .STOP;
    }

    if decl.kind == .ENUM {
        en := cast(*Enum)decl;
        if en.name == "SDL_EventType" {
            event_type_decl = en; // Save for later
        }
    }

    // Here we replace the Uint8 type to SDL_EventType enum
    if parent_decl && parent_decl.kind == .STRUCT && ends_with(parent_decl.name, "Event") && decl.kind == .DECLARATION && decl.name == "type" {
        type := New(CType);
        type.type_of_enum = event_type_decl;
        type.size = event_type_decl.type.size;
        decl.type = type;
    }

    if parent_decl == null && decl.kind == .TYPEDEF {
        // We handcraft our window flag.
        if decl.name == "SDL_WindowFlags" {
            decl.decl_flags |= .OMIT_FROM_OUTPUT;
            return .STOP;
        }

        // Also handcraft init flag.
        if decl.name == "SDL_InitFlags" {
            decl.decl_flags |= .OMIT_FROM_OUTPUT;
            return .STOP;
        }
    }

    // Remove the init flag define.
    if parent_decl == null && begins_with(decl.name, "SDL_INIT_") {
        decl.decl_flags |= .OMIT_FROM_OUTPUT;
        return .STOP;
    }

    return .RECURSE;
}

#scope_file

#import "Basic";
#import "Compiler";
#import "BuildCpp";
#import "Check";
#import "Bindings_Generator";
#import "File";
#import "String";
#import "Process";

DECLARATIONS_TO_OMIT :: string.[
    "_m_prefetch",
    "__debugbreak",

    /*
    Those are force inlined functions defined in the headers, so they don't appear in the library and so bindings generator complains.

    One way is to automatically remove inline, compile them into a DLL, and turn them into #c_call jai procs. However, this loses inline.

    The performant way is to rewrite them in pure jai code, however that introduces overhead of ensuring they are updated.
    */
    "SDL_size_mul_check_overflow",
    "SDL_size_mul_check_overflow_builtin",
    "SDL_size_add_check_overflow",
    "SDL_size_add_check_overflow_builtin",
    "SDL_SwapFloat",
    "SDL_MostSignificantBitIndex32",
    "SDL_HasExactlyOneBitSet32",
    "SDL_RectToFRect",
    "SDL_PointInRect",
    "SDL_RectEmpty",
    "SDL_RectsEqual",
    "SDL_PointInRectFloat",
    "SDL_RectEmptyFloat",
    "SDL_RectsEqualEpsilon",
    "SDL_RectsEqualFloat",
    "SDL_main",
    "main",
    "wmain",
    "main1",
    "WinMain",
    "wWinMain",
];

run_or_exit :: (command: [] string, working_directory: string = #filepath) {
    // Enable this to see the commands being executed.
    // print("Executing command \"%\" in directory \"%\"\n", join(..command, separator = " "), working_directory);

    result, output_string, error_string := run_command(..command, working_directory = working_directory, capture_and_return_output = true, print_captured_output = LIVE_OUTPUT);
    defer {
        free(output_string);
        free(error_string);
    }
    if result.exit_code != 0 {
        log_error("Could not run command \"%\" in directory \"%\". Exit code: %\nError:\n%", get_quoted_command_string(command), working_directory, result.exit_code, error_string);
        exit(1);
    }
}
