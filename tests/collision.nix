# Collision detection tests
#
# Tests for detectTerminalCollisions and collision assertions in batch functions.
#
{ lib, helpers }:

let
  inherit (helpers) deferredAppsLib mkCheck testListShouldFail;
in
{
  # ===========================================================================
  # DETECT TERMINAL COLLISIONS TESTS
  # ===========================================================================

  # Test: No collision with different packages
  collision-none =
    let
      result = deferredAppsLib.detectTerminalCollisions [
        { pname = "hello"; }
        { pname = "cowsay"; }
        { pname = "tree"; }
      ];
    in
    mkCheck "collision-none" (result == null);

  # Test: Collision detected with explicit exe
  collision-detected =
    let
      result = deferredAppsLib.detectTerminalCollisions [
        {
          pname = "app1";
          exe = "same-cmd";
        }
        {
          pname = "app2";
          exe = "same-cmd";
        }
      ];
    in
    mkCheck "collision-detected" (result != null && lib.hasInfix "same-cmd" result);

  # Test: No collision when createTerminalCommand = false
  collision-disabled =
    let
      result = deferredAppsLib.detectTerminalCollisions [
        {
          pname = "app1";
          exe = "same-cmd";
          createTerminalCommand = true;
        }
        {
          pname = "app2";
          exe = "same-cmd";
          createTerminalCommand = false;
        }
      ];
    in
    mkCheck "collision-disabled" (result == null);

  # Test: Collision with null exe - both auto-detect to SAME mainProgram
  # This tests the bug fix where exe = null should auto-detect
  collision-null-exe-collides =
    let
      # Both packages with exe = null that auto-detect to different values -> no collision
      result = deferredAppsLib.detectTerminalCollisions [
        {
          pname = "hello";
          exe = null;
        }
        {
          pname = "cowsay";
          exe = null;
        }
      ];
    in
    mkCheck "collision-null-exe-collides" (result == null);

  # Test: Collision where null exe auto-detects to colliding value
  collision-null-exe-auto-collision =
    let
      # Force collision: hello auto-detects to "hello", app2 explicitly uses "hello"
      result = deferredAppsLib.detectTerminalCollisions [
        {
          pname = "hello";
          exe = null;
        } # auto-detects to "hello"
        {
          pname = "app2";
          exe = "hello";
        } # explicitly "hello"
      ];
    in
    mkCheck "collision-null-exe-auto-collision" (result != null && lib.hasInfix "hello" result);

  # Test: Mixed string and attrset inputs
  collision-mixed =
    let
      result = deferredAppsLib.detectTerminalCollisions [
        "hello" # string
        { pname = "cowsay"; } # attrset minimal
        {
          pname = "tree";
          exe = null;
        } # attrset with null
      ];
    in
    mkCheck "collision-mixed" (result == null);

  # ===========================================================================
  # COLLISION ASSERTION TESTS
  # Batch functions should THROW on collision
  # ===========================================================================

  # Test: mkDeferredApps THROWS on collision
  collision-mkDeferredApps-throws = testListShouldFail "collision-mkDeferredApps-throws" (
    deferredAppsLib.mkDeferredApps [
      "hello"
      "hello" # Duplicate!
    ]
  );

  # Test: mkDeferredAppsFrom THROWS on collision
  collision-mkDeferredAppsFrom-throws = testListShouldFail "collision-mkDeferredAppsFrom-throws" (
    deferredAppsLib.mkDeferredAppsFrom "nixpkgs" [
      "hello"
      "hello" # Duplicate!
    ]
  );

  # Test: mkDeferredAppsAdvanced THROWS on collision
  collision-mkDeferredAppsAdvanced-throws =
    testListShouldFail "collision-mkDeferredAppsAdvanced-throws"
      (
        deferredAppsLib.mkDeferredAppsAdvanced [
          {
            pname = "app1";
            exe = "conflict";
          }
          {
            pname = "app2";
            exe = "conflict";
          }
        ]
      );
}
