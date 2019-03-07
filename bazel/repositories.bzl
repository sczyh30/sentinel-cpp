load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load(":genrule_repository.bzl", "genrule_repository")
load(":repository_locations.bzl", "REPOSITORY_LOCATIONS")
load(":target_recipes.bzl", "TARGET_RECIPES")
load(
    "@bazel_tools//tools/cpp:windows_cc_configure.bzl",
    "find_vc_path",
    "setup_vc_env_vars",
)
load("@bazel_tools//tools/cpp:lib_cc_configure.bzl", "get_env_var")

# go version for rules_go
GO_VERSION = "1.10.4"

# Make all contents of an external repository accessible under a filegroup.  Used for external HTTP
# archives, e.g. cares.
BUILD_ALL_CONTENT = """filegroup(name = "all", srcs = glob(["**"]), visibility = ["//visibility:public"])"""

def _repository_impl(name, **kwargs):
    # `existing_rule_keys` contains the names of repositories that have already
    # been defined in the Bazel workspace. By skipping repos with existing keys,
    # users can override dependency versions by using standard Bazel repository
    # rules in their WORKSPACE files.
    existing_rule_keys = native.existing_rules().keys()
    if name in existing_rule_keys:
        # This repository has already been defined, probably because the user
        # wants to override the version. Do nothing.
        return

    loc_key = kwargs.pop("repository_key", name)
    location = REPOSITORY_LOCATIONS[loc_key]

    # Git tags are mutable. We want to depend on commit IDs instead. Give the
    # user a useful error if they accidentally specify a tag.
    if "tag" in location:
        fail(
            "Refusing to depend on Git tag %r for external dependency %r: use 'commit' instead." %
            (location["tag"], name),
        )

    # HTTP tarball at a given URL. Add a BUILD file if requested.
    http_archive(
        name = name,
        urls = location["urls"],
        sha256 = location["sha256"],
        strip_prefix = location.get("strip_prefix", ""),
        **kwargs
    )

def _build_recipe_repository_impl(ctxt):
    # on Windows, all deps use rules_foreign_cc
    if ctxt.os.name.upper().startswith("WINDOWS"):
        return

    # modify the recipes list based on the build context
    recipes = _apply_dep_blacklist(ctxt, ctxt.attr.recipes)

    # Setup the build directory with links to the relevant files.
    ctxt.symlink(Label("//bazel:repositories.sh"), "repositories.sh")
    ctxt.symlink(
        Label("//ci/build_container:build_and_install_deps.sh"),
        "build_and_install_deps.sh",
    )
    ctxt.symlink(Label("//ci/build_container:recipe_wrapper.sh"), "recipe_wrapper.sh")
    ctxt.symlink(Label("//ci/build_container:Makefile"), "Makefile")
    for r in recipes:
        ctxt.symlink(
            Label("//ci/build_container/build_recipes:" + r + ".sh"),
            "build_recipes/" + r + ".sh",
        )
    ctxt.symlink(Label("//ci/prebuilt:BUILD"), "BUILD")

    # Run the build script.
    print("Fetching external dependencies...")
    result = ctxt.execute(
        ["./repositories.sh"] + recipes,
        quiet = False,
    )
    print(result.stdout)
    print(result.stderr)
    print("External dep build exited with return code: %d" % result.return_code)
    if result.return_code != 0:
        print("\033[31;1m\033[48;5;226m External dependency build failed, check above log " +
              "for errors and ensure all prerequisites at " +
              "https://github.com/alibaba/sentinel-cpp/blob/master/bazel/README.md#quick-start-bazel-build-for-developers are met.")

        # This error message doesn't appear to the user :( https://github.com/bazelbuild/bazel/issues/3683
        fail("External dep build failed")

def _default_sentinel_build_config_impl(ctx):
    ctx.file("WORKSPACE", "")
    ctx.file("BUILD.bazel", "")
    ctx.symlink(ctx.attr.config, "extensions_build_config.bzl")

_default_sentinel_build_config = repository_rule(
    implementation = _default_sentinel_build_config_impl,
)

def sentinel_dependencies(path = "@sentinel_deps//", skip_targets = []):
    sentinel_repository = repository_rule(
        implementation = _build_recipe_repository_impl,
        environ = [
            "CC",
            "CXX",
            "CFLAGS",
            "CXXFLAGS",
            "LD_LIBRARY_PATH",
        ],
        # Don't pretend we're in the sandbox, we do some evil stuff with sentinel_dep_cache.
        local = True,
        attrs = {
            "recipes": attr.string_list(),
        },
    )

    # Ideally, we wouldn't have a single repository target for all dependencies, but instead one per
    # dependency, as suggested in #747. However, it's much faster to build all deps under a single
    # recursive make job and single make jobserver.
    recipes = depset()
    for t in TARGET_RECIPES:
        if t not in skip_targets:
            recipes += depset([TARGET_RECIPES[t]])

    sentinel_repository(
        name = "sentinel_deps",
        recipes = recipes.to_list(),
    )

    for t in TARGET_RECIPES:
        if t not in skip_targets:
            native.bind(
                name = t,
                actual = path + ":" + t,
            )

    # Treat sentinel's overall build config as an external repo, so projects that
    # build sentinel as a subcomponent can easily override the config.
    if "sentinel_build_config" not in native.existing_rules().keys():
        _default_sentinel_build_config(name = "sentinel_build_config")

    # Setup rules_foreign_cc
    _foreign_cc_dependencies()

    # The long repo names (`com_github_fmtlib_fmt` instead of `fmtlib`) are
    # semi-standard in the Bazel community, intended to avoid both duplicate
    # dependencies and name conflicts.
    _com_github_fmtlib_fmt()
    _com_github_google_benchmark()
    _com_google_googletest()

    # Used for bundling gcovr into a relocatable .par file.
    _repository_impl("subpar")

def _com_github_fmtlib_fmt():
    _repository_impl(
        name = "com_github_fmtlib_fmt",
        build_file = "@sentinel//bazel/external:fmtlib.BUILD",
    )
    native.bind(
        name = "fmtlib",
        actual = "@com_github_fmtlib_fmt//:fmtlib",
    )

def _com_github_google_benchmark():
    location = REPOSITORY_LOCATIONS["com_github_google_benchmark"]
    http_archive(
        name = "com_github_google_benchmark",
        **location
    )
    native.bind(
        name = "benchmark",
        actual = "@com_github_google_benchmark//:benchmark",
    )

def _com_google_googletest():
    _repository_impl("com_google_googletest")
    native.bind(
        name = "googletest",
        actual = "@com_google_googletest//:gtest",
    )

def _foreign_cc_dependencies():
    _repository_impl("rules_foreign_cc")

def _apply_dep_blacklist(ctxt, recipes):
    newlist = []
    skip_list = []
    for t in recipes:
        if t not in skip_list:
            newlist.append(t)
    return newlist

def _is_linux(ctxt):
    return ctxt.os.name == "linux"

def _is_arch(ctxt, arch):
    res = ctxt.execute(["uname", "-m"])
    return arch in res.stdout

def _is_linux_ppc(ctxt):
    return _is_linux(ctxt) and _is_arch(ctxt, "ppc")

def _is_linux_x86_64(ctxt):
    return _is_linux(ctxt) and _is_arch(ctxt, "x86_64")
