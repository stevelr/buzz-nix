# SPDX-FileCopyrightText: 2026 Steve Schoettler
#
# SPDX-License-Identifier: Apache-2.0

{
  lib,
  stdenv,
  fetchFromGitHub,
  rustPlatform,
  autoPatchelfHook,
  cmake,
  pkg-config,
  perl,
  llvmPackages,
}:

let
  versions = builtins.fromJSON (builtins.readFile ../versions.json);
  release = versions.ferron;
in
rustPlatform.buildRustPackage {
  pname = "ferron";
  inherit (release) version;

  src = fetchFromGitHub {
    inherit (release) owner repo rev;
    hash = release.sha256;
  };

  cargoHash = release.cargoHash;
  nativeBuildInputs = [
    autoPatchelfHook
    cmake
    llvmPackages.clang
    perl
    pkg-config
  ];
  buildInputs = [ stdenv.cc.cc.lib ];
  LIBCLANG_PATH = "${llvmPackages.libclang.lib}/lib";

  doCheck = false;

  meta = {
    description = "Fast, memory-safe web server written in Rust";
    homepage = "https://github.com/ferronweb/ferron";
    license = lib.licenses.mit;
    mainProgram = "ferron";
    platforms = lib.platforms.linux;
  };
}
