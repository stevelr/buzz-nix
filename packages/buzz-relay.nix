{
  lib,
  rustPlatform,
  fetchFromGitHub,
  cacert,
  pkg-config,
  openssl,
  stdenv,
}:

let
  versions = builtins.fromJSON (builtins.readFile ../versions.json);
  release = versions."buzz-relay";
in
rustPlatform.buildRustPackage {
  pname = "buzz-relay";
  inherit (release) version;

  src = fetchFromGitHub {
    inherit (release) owner repo rev;
    hash = release.sha256;
  };

  cargoHash = release.cargoHash;
  cargoBuildFlags = [
    "-p=buzz-relay"
    "--bin=buzz-relay"
    "-p=buzz-admin"
    "--bin=buzz-admin"
    "-p=buzz-pair-relay"
    "--bin=buzz-pair-relay"
  ];

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ openssl ];
  SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";

  # Upstream's relay suites require live PostgreSQL, Redis, and S3 services.
  # The NixOS module checks exercise the assembled service configuration.
  doCheck = false;

  installPhase = ''
    runHook preInstall
    for program in buzz-relay buzz-admin buzz-pair-relay; do
      install -Dm755 \
        "target/${stdenv.hostPlatform.rust.rustcTarget}/release/$program" \
        "$out/bin/$program"
    done
    runHook postInstall
  '';

  meta = {
    description = "Buzz WebSocket relay and administration tools";
    homepage = "https://github.com/block/buzz";
    license = lib.licenses.asl20;
    mainProgram = "buzz-relay";
    platforms = lib.platforms.linux;
  };
}
