licenses(["notice"])  # Apache 2

load(
    "//bazel:sentinel_build_system.bzl",
    "sentinel_cc_binary",
    "sentinel_package",
)

sentinel_package()

sentinel_cc_binary(
    name = "boost_thread",
    stamped = True,
    srcs = ["thread_test.cc"],
    deps = [
        "@boost//:thread",
    ],
)