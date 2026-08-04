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
}:

let
  versions = builtins.fromJSON (builtins.readFile ../versions.json);
  release = versions.${component};
in
rustPlatform.buildRustPackage {
  pname = component;
  inherit (release) version;

  src = fetchFromGitHub {
    inherit (release) owner repo rev;
    hash = release.sha256;
  };

  cargoHash = release.cargoHash;
  cargoBuildFlags = [ "-p=${component}" ];
  cargoTestFlags = [ "-p=${component}" ];

  nativeBuildInputs = [ pkg-config ];
  nativeCheckInputs = [ cacert ];
  buildInputs = [ openssl ];
  SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";

  installPhase = ''
    runHook preInstall
    install -Dm755 \
      "target/${stdenv.hostPlatform.rust.rustcTarget}/release/${binary}" \
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
