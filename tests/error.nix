# Error case validation tests
#
# Tests that verify proper error handling for invalid inputs.
# These tests use testShouldFail to verify that expressions throw errors.
#
{ helpers }:

let
  inherit (helpers) deferredAppsLib testShouldFail;
in
{
  # ===========================================================================
  # PNAME VALIDATION ERRORS
  # ===========================================================================

  # Test: Verify empty pname throws error
  error-empty-pname = testShouldFail "error-empty-pname" (
    deferredAppsLib.mkDeferredApp { pname = ""; }
  );

  # Test: Verify pname with slash throws error
  error-pname-slash = testShouldFail "error-pname-slash" (
    deferredAppsLib.mkDeferredApp { pname = "foo/bar"; }
  );

  # Test: Verify pname with space throws error
  error-pname-space = testShouldFail "error-pname-space" (
    deferredAppsLib.mkDeferredApp { pname = "foo bar"; }
  );

  # Test: Verify pname starting with dot throws error
  error-pname-dot = testShouldFail "error-pname-dot" (
    deferredAppsLib.mkDeferredApp { pname = ".hidden"; }
  );

  # Test: Verify pname starting with dash throws error
  error-pname-dash = testShouldFail "error-pname-dash" (
    deferredAppsLib.mkDeferredApp { pname = "-invalid"; }
  );

  # ===========================================================================
  # PACKAGE EXISTENCE ERRORS
  # ===========================================================================

  # Test: Verify nonexistent package throws error
  error-nonexistent-package = testShouldFail "error-nonexistent-package" (
    deferredAppsLib.mkDeferredApp { pname = "this-package-definitely-does-not-exist-12345"; }
  );
}
