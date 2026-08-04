# SPDX-FileCopyrightText: 2026 Steve Schoettler
#
# SPDX-License-Identifier: Apache-2.0

{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:

let
  versions = builtins.fromJSON (builtins.readFile ../versions.json);
  release = versions.minio;
  versionToTimestamp =
    version:
    let
      splitTimestamp = builtins.elemAt (builtins.split "(.*)(T.*)" version) 1;
    in
    builtins.concatStringsSep "" [
      (builtins.elemAt splitTimestamp 0)
      (builtins.replaceStrings [ "-" ] [ ":" ] (builtins.elemAt splitTimestamp 1))
    ];
  versionToYear = version: builtins.elemAt (lib.splitString "-" version) 0;
in
buildGoModule {
  pname = "buzz-minio";
  inherit (release) version;

  src = fetchFromGitHub {
    inherit (release) owner repo rev;
    hash = release.sha256;
  };
  vendorHash = release.vendorHash;

  doCheck = false;
  subPackages = [ "." ];
  env.CGO_ENABLED = 0;
  tags = [ "kqueue" ];

  ldflags =
    let
      target = "github.com/minio/minio/cmd";
    in
    [
      "-s"
      "-w"
      "-X ${target}.Version=${versionToTimestamp release.version}"
      "-X ${target}.CopyrightYear=${versionToYear release.version}"
      "-X ${target}.ReleaseTag=${release.rev}"
      "-X ${target}.CommitID=${release.rev}"
    ];

  meta = {
    description = "MinIO server pinned to the Buzz relay deployment";
    homepage = "https://min.io/";
    license = lib.licenses.agpl3Plus;
    mainProgram = "minio";
    platforms = lib.platforms.linux;
  };
}
