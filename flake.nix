{
  description = "Nix flake for compiling and developing OppoCustomSideButtonFunctions Android app";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/a7868a727837f3c09cee2ce0ca671c76b1589fed";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      perSystem = system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config = {
              allowUnfree = true;
              android_sdk.accept_license = true;
            };
          };

          androidComposition = pkgs.androidenv.composeAndroidPackages {
            platformVersions = [ "34" "35" "36" "37" ];
            buildToolsVersions = [ "34.0.0" "35.0.0" "36.0.0" "37.0.0" ];
            includeEmulator = false;
            includeSources = false;
            includeSystemImages = false;
            includeNDK = false;
          };

          androidSdk = androidComposition.androidsdk;
          jdk = pkgs.jdk17;
          sdkPath = "${androidSdk}/libexec/android-sdk";

          buildPkgs = with pkgs; [
            jdk
            androidSdk
            git
            which
          ];

          fhs = if pkgs.stdenv.hostPlatform.isLinux then
            pkgs.buildFHSEnv {
              name = "android-dev-fhs";
              targetPkgs = pkgs: buildPkgs ++ (with pkgs; [
                glibc
                zlib
                gcc.cc.lib
                ncurses5
              ]);
              profile = ''
                export ANDROID_HOME="${sdkPath}"
                export ANDROID_SDK_ROOT="${sdkPath}"
                export JAVA_HOME="${jdk}"
                export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
              '';
            }
          else
            null;

          fhsEnv = if pkgs.stdenv.hostPlatform.isLinux then
            fhs.env.overrideAttrs (old: {
              shellHook = ''
                if [ -n "$BASH_EXECUTION_STRING" ]; then
                  exec ${fhs}/bin/android-dev-fhs -c "$BASH_EXECUTION_STRING"
                else
                  exec ${fhs}/bin/android-dev-fhs
                fi
              '';
            })
          else
            null;

          standardShell = pkgs.mkShell {
            name = "android-dev-shell";
            packages = buildPkgs;
            shellHook = ''
              export ANDROID_HOME="${sdkPath}"
              export ANDROID_SDK_ROOT="${sdkPath}"
              export JAVA_HOME="${jdk}"
              export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
            '';
          };

          buildScript = task: pkgs.writeShellScriptBin "build-${task}" ''
            export ANDROID_HOME="${sdkPath}"
            export ANDROID_SDK_ROOT="${sdkPath}"
            export JAVA_HOME="${jdk}"
            export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
            exec ./gradlew :app:${task} "$@"
          '';

          buildFhsScript = task:
            if pkgs.stdenv.hostPlatform.isLinux then
              let
                taskFhs = pkgs.buildFHSEnv {
                  name = "build-${task}-fhs";
                  targetPkgs = pkgs: buildPkgs ++ (with pkgs; [
                    glibc
                    zlib
                    gcc.cc.lib
                    ncurses5
                  ]);
                  runScript = pkgs.writeScript "run-${task}" ''
                    #!/bin/sh
                    export ANDROID_HOME="${sdkPath}"
                    export ANDROID_SDK_ROOT="${sdkPath}"
                    export JAVA_HOME="${jdk}"
                    export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
                    exec ./gradlew :app:${task} "$@"
                  '';
                };
              in
              {
                type = "app";
                program = "${taskFhs}/bin/build-${task}-fhs";
              }
            else
              {
                type = "app";
                program = "${buildScript task}/bin/build-${task}";
              };
        in
        {
          inherit pkgs androidSdk fhs fhsEnv standardShell buildScript buildFhsScript;
        };
    in
    {
      devShells = forAllSystems (system:
        let
          env = perSystem system;
        in
        {
          default = env.standardShell;
          standard = env.standardShell;
          fhs = if env.pkgs.stdenv.hostPlatform.isLinux then env.fhsEnv else env.standardShell;
        }
      );

      packages = forAllSystems (system:
        let
          env = perSystem system;
        in
        {
          default = env.androidSdk;
          android-sdk = env.androidSdk;
        }
      );

      apps = forAllSystems (system:
        let
          env = perSystem system;
        in
        {
          assembleDebug = {
            type = "app";
            program = "${env.buildScript "assembleDebug"}/bin/build-assembleDebug";
          };
          assembleRelease = {
            type = "app";
            program = "${env.buildScript "assembleRelease"}/bin/build-assembleRelease";
          };
          default = {
            type = "app";
            program = "${env.buildScript "assembleDebug"}/bin/build-assembleDebug";
          };
        } // (if env.pkgs.stdenv.hostPlatform.isLinux then {
          fhs = {
            type = "app";
            program = "${env.fhs}/bin/android-dev-fhs";
          };
        } else {})
      );
    };
}
