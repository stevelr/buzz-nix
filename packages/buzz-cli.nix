{ callPackage }:

callPackage ./buzz-component.nix {
  component = "buzz-cli";
  binary = "buzz";
  description = "Command-line client for Buzz";
}
