workspace(name = "sentinel")

load("//bazel:repositories.bzl", "sentinel_dependencies")
load("//bazel:cc_configure.bzl", "cc_configure")

sentinel_dependencies()

load("@rules_foreign_cc//:workspace_definitions.bzl", "rules_foreign_cc_dependencies")

rules_foreign_cc_dependencies()

cc_configure()

new_local_repository(
     name = "boost",
     build_file = "bazel/external/boost.BUILD",
     path = "source/third_party/boost_1_69_0"
)
