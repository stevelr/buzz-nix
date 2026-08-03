{ callPackage }:

callPackage ./buzz-component.nix {
  component = "buzz-acp";
  binary = "buzz-acp";
  description = "Buzz ACP harness for headless agents";
}
