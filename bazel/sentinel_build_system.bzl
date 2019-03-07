load("@rules_foreign_cc//tools/build_defs:cmake.bzl", "cmake_external")

def sentinel_package():
    native.package(default_visibility = ["//visibility:public"])

# A genrule variant that can output a directory. This is useful when doing things like
# generating a fuzz corpus mechanically.
def _sentinel_directory_genrule_impl(ctx):
    tree = ctx.actions.declare_directory(ctx.attr.name + ".outputs")
    ctx.actions.run_shell(
        inputs = ctx.files.srcs,
        tools = ctx.files.tools,
        outputs = [tree],
        command = "mkdir -p " + tree.path + " && " + ctx.expand_location(ctx.attr.cmd),
        env = {"GENRULE_OUTPUT_DIR": tree.path},
    )
    return [DefaultInfo(files = depset([tree]))]

sentinel_directory_genrule = rule(
    implementation = _sentinel_directory_genrule_impl,
    attrs = {
        "srcs": attr.label_list(),
        "cmd": attr.string(),
        "tools": attr.label_list(),
    },
)

# Compute the final copts based on various options.
def sentinel_copts(repository, test = False):
    posix_options = [
        "-Wall",
        "-Wextra",
        "-Werror",
        "-Wnon-virtual-dtor",
        "-Woverloaded-virtual",
        "-Wold-style-cast",
        "-Wvla",
        "-std=c++14",
    ]

    msvc_options = [
        "-WX",
        "-Zc:__cplusplus",
        "-std:c++14",
        "-DWIN32",
        "-DWIN32_LEAN_AND_MEAN",
        # need win8 for ntohll
        # https://msdn.microsoft.com/en-us/library/windows/desktop/aa383745(v=vs.85).aspx
        "-D_WIN32_WINNT=0x0602",
        "-DNTDDI_VERSION=0x06020000",
        "-DCARES_STATICLIB",
        "-DNGHTTP2_STATICLIB",
    ]

    return select({
               repository + "//bazel:windows_x86_64": msvc_options,
               "//conditions:default": posix_options,
           }) + select({
               # Bazel adds an implicit -DNDEBUG for opt.
               repository + "//bazel:opt_build": [] if test else ["-ggdb3"],
               repository + "//bazel:fastbuild_build": [],
               repository + "//bazel:dbg_build": ["-ggdb3"],
               repository + "//bazel:windows_opt_build": [],
               repository + "//bazel:windows_fastbuild_build": [],
               repository + "//bazel:windows_dbg_build": [],
           }) + select({
               repository + "//bazel:disable_tcmalloc": ["-DABSL_MALLOC_HOOK_MMAP_DISABLE"],
               "//conditions:default": ["-DTCMALLOC"],
           }) + select({
               repository + "//bazel:debug_tcmalloc": ["-DENVOY_MEMORY_DEBUG_ENABLED=1"],
               "//conditions:default": [],
           }) + select({
               repository + "//bazel:disable_signal_trace": [],
               "//conditions:default": ["-DENVOY_HANDLE_SIGNALS"],
           }) + select({
               repository + "//bazel:enable_log_debug_assert_in_release": ["-DENVOY_LOG_DEBUG_ASSERT_IN_RELEASE"],
               "//conditions:default": [],
           }) + select({
               # TCLAP command line parser needs this to support int64_t/uint64_t
               "@bazel_tools//tools/osx:darwin": ["-DHAVE_LONG_LONG"],
               "//conditions:default": [],
           }) + sentinel_select_perf_annotation(["-DENVOY_PERF_ANNOTATION"])

def sentinel_static_link_libstdcpp_linkopts():
    return sentinel_select_force_libcpp(
        # TODO(PiotrSikora): statically link libc++ once that's possible.
        # See: https://reviews.llvm.org/D53238
        ["-stdlib=libc++"],
        ["-static-libstdc++", "-static-libgcc"],
    )

# Compute the final linkopts based on various options.
def sentinel_linkopts():
    return select({
               # The macOS system library transitively links common libraries (e.g., pthread).
               "@bazel_tools//tools/osx:darwin": [
                   # See note here: http://luajit.org/install.html
                   "-pagezero_size 10000",
                   "-image_base 100000000",
               ],
               "@sentinel//bazel:windows_x86_64": [
                   "-DEFAULTLIB:advapi32.lib",
                   "-DEFAULTLIB:ws2_32.lib",
                   "-WX",
               ],
               "//conditions:default": [
                   "-pthread",
                   "-lrt",
                   "-ldl",
                   "-Wl,--hash-style=gnu",
               ],
           }) + sentinel_static_link_libstdcpp_linkopts() + \
           sentinel_select_exported_symbols(["-Wl,-E"])

def _sentinel_stamped_linkopts():
    return select({
        # Coverage builds in CI are failing to link when setting a build ID.
        #
        # /usr/bin/ld.gold: internal error in write_build_id, at ../../gold/layout.cc:5419
        "@sentinel//bazel:coverage_build": [],
        "@sentinel//bazel:windows_x86_64": [],

        # macOS doesn't have an official equivalent to the `.note.gnu.build-id`
        # ELF section, so just stuff the raw ID into a new text section.
        "@bazel_tools//tools/osx:darwin": [
            "-sectcreate __TEXT __build_id",
            "$(location @sentinel//bazel:raw_build_id.ldscript)",
        ],

        # Note: assumes GNU GCC (or compatible) handling of `--build-id` flag.
        "//conditions:default": [
            "-Wl,@$(location @sentinel//bazel:gnu_build_id.ldscript)",
        ],
    })

def _sentinel_stamped_deps():
    return select({
        "@bazel_tools//tools/osx:darwin": [
            "@sentinel//bazel:raw_build_id.ldscript",
        ],
        "//conditions:default": [
            "@sentinel//bazel:gnu_build_id.ldscript",
        ],
    })

# Compute the test linkopts based on various options.
def sentinel_test_linkopts():
    return select({
        "@bazel_tools//tools/osx:darwin": [
            # See note here: http://luajit.org/install.html
            "-pagezero_size 10000",
            "-image_base 100000000",
        ],
        "@sentinel//bazel:windows_x86_64": [
            "-DEFAULTLIB:advapi32.lib",
            "-DEFAULTLIB:ws2_32.lib",
            "-WX",
        ],

        # TODO(mattklein123): It's not great that we universally link against the following libs.
        # In particular, -latomic and -lrt are not needed on all platforms. Make this more granular.
        "//conditions:default": ["-pthread", "-lrt", "-ldl"],
    }) + sentinel_select_force_libcpp(["-lc++fs"], ["-lstdc++fs", "-latomic"])

# References to sentinel external dependencies should be wrapped with this function.
def sentinel_external_dep_path(dep):
    return "//external:%s" % dep

# Transform the package path (e.g. include/sentinel/common) into a path for
# exporting the package headers at (e.g. sentinel/common). Source files can then
# include using this path scheme (e.g. #include "sentinel/common/time.h").
def sentinel_include_prefix(path):
    if path.startswith("source/") or path.startswith("include/"):
        return "/".join(path.split("/")[1:])
    return None

# External CMake C++ library targets should be specified with this function. This defaults
# to building the dependencies with ninja
def sentinel_cmake_external(
        name,
        cache_entries = {},
        cmake_options = ["-GNinja"],
        make_commands = ["ninja", "ninja install"],
        lib_source = "",
        postfix_script = "",
        static_libraries = [],
        copy_pdb = False,
        pdb_name = "",
        cmake_files_dir = "$BUILD_TMPDIR/CMakeFiles",
        **kwargs):
    # On Windows, we don't want to explicitly set CMAKE_BUILD_TYPE,
    # rules_foreign_cc will figure it out for us
    cache_entries_no_build_type = {key: cache_entries[key] for key in cache_entries.keys() if key != "CMAKE_BUILD_TYPE"}

    pf = ""
    if copy_pdb:
        if pdb_name == "":
            pdb_name = name

        copy_command = "cp {cmake_files_dir}/{pdb_name}.dir/{pdb_name}.pdb $INSTALLDIR/lib/{pdb_name}.pdb".format(cmake_files_dir = cmake_files_dir, pdb_name = pdb_name)
        if postfix_script != "":
            copy_command = copy_command + " && " + postfix_script

        pf = select({
            "@sentinel//bazel:windows_dbg_build": copy_command,
            "//conditions:default": postfix_script,
        })
    else:
        pf = postfix_script

    cmake_external(
        name = name,
        cache_entries = select({
            "@sentinel//bazel:windows_x86_64": cache_entries_no_build_type,
            "//conditions:default": cache_entries,
        }),
        cmake_options = cmake_options,
        generate_crosstool_file = select({
            "@sentinel//bazel:windows_x86_64": True,
            "//conditions:default": False,
        }),
        lib_source = lib_source,
        make_commands = make_commands,
        postfix_script = pf,
        static_libraries = static_libraries,
        **kwargs
    )

# sentinel C++ library targets that need no transformations or additional dependencies before being
# passed to cc_library should be specified with this function. Note: this exists to ensure that
# all sentinel targets pass through an sentinel-declared skylark function where they can be modified
# before being passed to a native bazel function.
def sentinel_basic_cc_library(name, **kargs):
    native.cc_library(name = name, **kargs)

# Used to select a dependency that has different implementations on POSIX vs Windows.
# The platform-specific implementations should be specified with sentinel_cc_posix_library
# and sentinel_cc_win32_library respectively
def sentinel_cc_platform_dep(name):
    return select({
        "@sentinel//bazel:windows_x86_64": [name + "_win32"],
        "//conditions:default": [name + "_posix"],
    })

# Used to specify a library that only builds on POSIX
def sentinel_cc_posix_library(name, srcs = [], hdrs = [], **kargs):
    sentinel_cc_library(
        name = name + "_posix",
        srcs = select({
            "@sentinel//bazel:windows_x86_64": [],
            "//conditions:default": srcs,
        }),
        hdrs = select({
            "@sentinel//bazel:windows_x86_64": [],
            "//conditions:default": hdrs,
        }),
        **kargs
    )

# Used to specify a library that only builds on Windows
def sentinel_cc_win32_library(name, srcs = [], hdrs = [], **kargs):
    sentinel_cc_library(
        name = name + "_win32",
        srcs = select({
            "@sentinel//bazel:windows_x86_64": srcs,
            "//conditions:default": [],
        }),
        hdrs = select({
            "@sentinel//bazel:windows_x86_64": hdrs,
            "//conditions:default": [],
        }),
        **kargs
    )

# sentinel C++ library targets should be specified with this function.
def sentinel_cc_library(
        name,
        srcs = [],
        hdrs = [],
        copts = [],
        visibility = None,
        external_deps = [],
        repository = "",
        linkstamp = None,
        tags = [],
        deps = [],
        strip_include_prefix = None):
    native.cc_library(
        name = name,
        srcs = srcs,
        hdrs = hdrs,
        copts = sentinel_copts(repository) + copts,
        visibility = visibility,
        tags = tags,
        deps = deps + [sentinel_external_dep_path(dep) for dep in external_deps] + [
            repository + "//include/sentinel/common:base_includes",
            repository + "//source/common/common:fmt_lib",
            sentinel_external_dep_path("abseil_flat_hash_map"),
            sentinel_external_dep_path("abseil_flat_hash_set"),
            sentinel_external_dep_path("abseil_strings"),
            sentinel_external_dep_path("spdlog"),
            sentinel_external_dep_path("fmtlib"),
        ],
        include_prefix = sentinel_include_prefix(native.package_name()),
        alwayslink = 1,
        linkstatic = 1,
        linkstamp = select({
            repository + "//bazel:windows_x86_64": None,
            "//conditions:default": linkstamp,
        }),
        strip_include_prefix = strip_include_prefix,
    )

# sentinel C++ binary targets should be specified with this function.
def sentinel_cc_binary(
        name,
        srcs = [],
        data = [],
        testonly = 0,
        visibility = None,
        external_deps = [],
        repository = "",
        stamped = False,
        deps = [],
        linkopts = []):
    if not linkopts:
        linkopts = sentinel_linkopts()
    if stamped:
        linkopts = linkopts + _sentinel_stamped_linkopts()
        deps = deps + _sentinel_stamped_deps()
    deps = deps + [sentinel_external_dep_path(dep) for dep in external_deps]
    native.cc_binary(
        name = name,
        srcs = srcs,
        data = data,
        copts = sentinel_copts(repository),
        linkopts = linkopts,
        testonly = testonly,
        linkstatic = 1,
        visibility = visibility,
        stamp = 1,
        deps = deps,
    )

load("@bazel_tools//tools/build_defs/pkg:pkg.bzl", "pkg_tar")

# sentinel C++ fuzz test targes. These are not included in coverage runs.
def sentinel_cc_fuzz_test(name, corpus, deps = [], tags = [], **kwargs):
    if not (corpus.startswith("//") or corpus.startswith(":")):
        corpus_name = name + "_corpus"
        corpus = native.glob([corpus + "/**"])
        native.filegroup(
            name = corpus_name,
            srcs = corpus,
        )
    else:
        corpus_name = corpus
    pkg_tar(
        name = name + "_corpus_tar",
        srcs = [corpus_name],
        testonly = 1,
    )
    test_lib_name = name + "_lib"
    sentinel_cc_test_library(
        name = test_lib_name,
        deps = deps + ["//test/fuzz:fuzz_runner_lib"],
        **kwargs
    )
    native.cc_test(
        name = name,
        copts = sentinel_copts("@sentinel", test = True),
        linkopts = sentinel_test_linkopts(),
        linkstatic = 1,
        args = ["$(locations %s)" % corpus_name],
        data = [corpus_name],
        # No fuzzing on macOS.
        deps = select({
            "@bazel_tools//tools/osx:darwin": ["//test:dummy_main"],
            "//conditions:default": [
                ":" + test_lib_name,
                "//test/fuzz:main",
            ],
        }),
        tags = tags,
    )

    # This target exists only for
    # https://github.com/google/oss-fuzz/blob/master/projects/sentinel/build.sh. It won't yield
    # anything useful on its own, as it expects to be run in an environment where the linker options
    # provide a path to FuzzingEngine.
    native.cc_binary(
        name = name + "_driverless",
        copts = sentinel_copts("@sentinel", test = True),
        linkopts = ["-lFuzzingEngine"] + sentinel_test_linkopts(),
        linkstatic = 1,
        testonly = 1,
        deps = [":" + test_lib_name],
        tags = ["manual"] + tags,
    )

# sentinel C++ test targets should be specified with this function.
def sentinel_cc_test(
        name,
        srcs = [],
        data = [],
        # List of pairs (Bazel shell script target, shell script args)
        repository = "",
        external_deps = [],
        deps = [],
        tags = [],
        args = [],
        shard_count = None,
        coverage = True,
        local = False):
    test_lib_tags = []
    if coverage:
        test_lib_tags.append("coverage_test_lib")
    sentinel_cc_test_library(
        name = name + "_lib",
        srcs = srcs,
        data = data,
        external_deps = external_deps,
        deps = deps,
        repository = repository,
        tags = test_lib_tags,
    )
    native.cc_test(
        name = name,
        copts = sentinel_copts(repository, test = True),
        linkopts = sentinel_test_linkopts(),
        linkstatic = 1,
        deps = [
            ":" + name + "_lib",
            repository + "//test:main",
        ],
        # from https://github.com/google/googletest/blob/6e1970e2376c14bf658eb88f655a054030353f9f/googlemock/src/gmock.cc#L51
        # 2 - by default, mocks act as StrictMocks.
        args = args + ["--gmock_default_mock_behavior=2"],
        tags = tags + ["coverage_test"],
        local = local,
        shard_count = shard_count,
    )

# sentinel C++ related test infrastructure (that want gtest, gmock, but may be
# relied on by sentinel_cc_test_library) should use this function.
def sentinel_cc_test_infrastructure_library(
        name,
        srcs = [],
        hdrs = [],
        data = [],
        external_deps = [],
        deps = [],
        repository = "",
        tags = []):
    native.cc_library(
        name = name,
        srcs = srcs,
        hdrs = hdrs,
        data = data,
        copts = sentinel_copts(repository, test = True),
        testonly = 1,
        deps = deps + [sentinel_external_dep_path(dep) for dep in external_deps] + [
            sentinel_external_dep_path("googletest"),
        ],
        tags = tags,
        alwayslink = 1,
        linkstatic = 1,
    )

# sentinel C++ test related libraries (that want gtest, gmock) should be specified
# with this function.
def sentinel_cc_test_library(
        name,
        srcs = [],
        hdrs = [],
        data = [],
        external_deps = [],
        deps = [],
        repository = "",
        tags = []):
    deps = deps + [
        repository + "//test/test_common:printers_includes",
        repository + "//test/test_common:test_base",
    ]
    sentinel_cc_test_infrastructure_library(
        name,
        srcs,
        hdrs,
        data,
        external_deps,
        deps,
        repository,
        tags,
    )

# sentinel test binaries should be specified with this function.
def sentinel_cc_test_binary(
        name,
        **kargs):
    sentinel_cc_binary(
        name,
        testonly = 1,
        linkopts = sentinel_test_linkopts() + sentinel_static_link_libstdcpp_linkopts(),
        **kargs
    )

# sentinel Python test binaries should be specified with this function.
def sentinel_py_test_binary(
        name,
        external_deps = [],
        deps = [],
        **kargs):
    native.py_binary(
        name = name,
        deps = deps + [sentinel_external_dep_path(dep) for dep in external_deps],
        **kargs
    )

# sentinel C++ mock targets should be specified with this function.
def sentinel_cc_mock(name, **kargs):
    sentinel_cc_test_library(name = name, **kargs)

# sentinel shell tests that need to be included in coverage run should be specified with this function.
def sentinel_sh_test(
        name,
        srcs = [],
        data = [],
        coverage = True,
        **kargs):
    if coverage:
        test_runner_cc = name + "_test_runner.cc"
        native.genrule(
            name = name + "_gen_test_runner",
            srcs = srcs,
            outs = [test_runner_cc],
            cmd = "$(location //bazel:gen_sh_test_runner.sh) $(SRCS) >> $@",
            tools = ["//bazel:gen_sh_test_runner.sh"],
        )
        sentinel_cc_test_library(
            name = name + "_lib",
            srcs = [test_runner_cc],
            data = srcs + data,
            tags = ["coverage_test_lib"],
            deps = ["//test/test_common:environment_lib"],
        )
    native.sh_test(
        name = name,
        srcs = ["//bazel:sh_test_wrapper.sh"],
        data = srcs + data,
        args = srcs,
        **kargs
    )

def sentinel_select_perf_annotation(xs):
    return select({
        "@sentinel//bazel:enable_perf_annotation": xs,
        "//conditions:default": [],
    })

# Select the given values if exporting is enabled in the current build.
def sentinel_select_exported_symbols(xs):
    return select({
        "@sentinel//bazel:enable_exported_symbols": xs,
        "//conditions:default": [],
    })

def sentinel_select_force_libcpp(if_libcpp, default = None):
    return select({
        "@sentinel//bazel:force_libcpp": if_libcpp,
        "@bazel_tools//tools/osx:darwin": [],
        "@sentinel//bazel:windows_x86_64": [],
        "//conditions:default": default or [],
    })

def sentinel_select_quiche(xs, repository = ""):
    return select({
        repository + "//bazel:enable_quiche": xs,
        "//conditions:default": [],
    })
