REPOSITORY_LOCATIONS = dict(
    com_github_fmtlib_fmt = dict(
        sha256 = "4c0741e10183f75d7d6f730b8708a99b329b2f942dad5a9da3385ab92bb4a15c",
        strip_prefix = "fmt-5.3.0",
        urls = ["https://github.com/fmtlib/fmt/releases/download/5.3.0/fmt-5.3.0.zip"],
    ),
    rules_foreign_cc = dict(
        sha256 = "78cbd1a8134b2f0ead8e637228d8ac1ac7c0ab3f0fbcd149a85e55330697d9a3",
        strip_prefix = "rules_foreign_cc-216ded8acb95d81e312b228dce3c39872c7a7c34",
        urls = ["https://github.com/bazelbuild/rules_foreign_cc/archive/216ded8acb95d81e312b228dce3c39872c7a7c34.tar.gz"],
    ),
    com_github_google_benchmark = dict(
        # TODO (moderation) change back to tarball method on next benchmark release
        sha256 = "0de43b6eaddd356f1d6cd164f73f37faf2f6c96fd684e1f7ea543ce49c1d144e",
        strip_prefix = "benchmark-505be96ab23056580a3a2315abba048f4428b04e",
        urls = ["https://github.com/google/benchmark/archive/505be96ab23056580a3a2315abba048f4428b04e.tar.gz"],
    ),
    com_google_googletest = dict(
        sha256 = "a4cb4b0c3ebb191b798594aca674ad47eee255dcb4c26885cf7f49777703484f",
        strip_prefix = "googletest-eb9225ce361affe561592e0912320b9db84985d0",
        # TODO(akonradi): Switch this back to a released version later than 1.8.1 once there is
        # one available.
        urls = ["https://github.com/google/googletest/archive/eb9225ce361affe561592e0912320b9db84985d0.tar.gz"],
    ),
    subpar = dict(
        sha256 = "eddbfc920e9cd565500370114316757848b672deba06dc2336acfa81b4ac0e6d",
        strip_prefix = "subpar-1.3.0",
        urls = ["https://github.com/google/subpar/archive/1.3.0.tar.gz"],
    ),
)
