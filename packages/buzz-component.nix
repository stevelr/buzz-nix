# SPDX-FileCopyrightText: 2026 Steve Schoettler
#
# SPDX-License-Identifier: Apache-2.0

{
  lib,
  rustPlatform,
  fetchFromGitHub,
  cacert,
  pkg-config,
  openssl,
  stdenv,
  component,
  binary,
  description,
  doCheck ? true,
  # Build a cargo example rather than the crate's own binaries, and install it
  # as `binary`. Cargo's --example selector suppresses normal binary targets.
  example ? null,
  pname ? component,
}:

let
  versions = builtins.fromJSON (builtins.readFile ../versions.json);
  release = versions.${component};
  buildDir = if example == null then "release" else "release/examples";
  buildName = if example == null then binary else example;
in
rustPlatform.buildRustPackage {
  inherit pname;
  inherit (release) version;

  src = fetchFromGitHub {
    inherit (release) owner repo rev;
    hash = release.sha256;
  };

  cargoHash = release.cargoHash;
  cargoBuildFlags = [
    "-p=${component}"
  ]
  ++ lib.optionals (example != null) [
    "--example"
    example
  ];
  cargoTestFlags = [ "-p=${component}" ];
  inherit doCheck;

  nativeBuildInputs = [ pkg-config ];
  nativeCheckInputs = [ cacert ];
  buildInputs = [ openssl ];
  SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";

  installPhase = ''
    runHook preInstall
    install -Dm755 \
      "target/${stdenv.hostPlatform.rust.rustcTarget}/${buildDir}/${buildName}" \
      "$out/bin/${binary}"
    runHook postInstall
  '';

  meta = {
    inherit description;
    homepage = "https://github.com/block/buzz";
    license = lib.licenses.asl20;
    mainProgram = binary;
    platforms = lib.platforms.unix;
  };
}
