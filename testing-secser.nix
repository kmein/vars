{ lib, config, pkgs, ... }:

{
  name = "secser";
  meta.maintainers = with lib.maintainers; [ ];

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ ];

      systemd.services.secser = {
        description = "Secser daemon";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "${pkgs.callPackage ./packages/secser {}}/bin/secser serve";
          RuntimeDirectory = "secser";
          StateDirectory = "secser";
          User = "nobody";
          Group = "nogroup";
        };
      };

      virtualisation.diskSize = 4096;
      virtualisation.memorySize = 2048;
      nix.settings.extra-sandbox-paths = [ "/run/secser/secser.sock" ];
      nix.settings.sandbox = true;
      nix.settings.substituters = lib.mkForce [ ];
    };

  testScript = ''
    machine.wait_for_unit("secser.service")
    machine.wait_for_file("/run/secser/secser.sock")

    # Build a derivation that uses secser to write a secret side-effect
    machine.succeed(
      """
      nix-build -E "
        with import <nixpkgs> {};
        runCommand \\"test-secret\\" {
          buildInputs = [ ${pkgs.callPackage ./packages/secser {}} ];
        } \\"
          touch \\$out
          echo 'my-super-secret-data' | secser send \\$out
        \\"
      "
      """
    )

    machine.succeed("cat /var/lib/secser/test-secret")
    machine.succeed("grep -q my-super-secret-data /var/lib/secser/test-secret")
  '';
}
