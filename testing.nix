{ lib, config, pkgs, ... }:

{
  name = "vars";
  meta.maintainers = with lib.maintainers; [ lassulus ];

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [
        ./options.nix
        ./backends/on-machine.nix
      ];
      vars.settings.on-machine.enable = true;

      environment.systemPackages = [
        pkgs.expect
        (pkgs.writeScriptBin "run-generate-vars" ''
          #!${pkgs.expect}/bin/expect -f
          set timeout 30
          spawn generate-vars
          expect "press control-d to finish"
          send "multi line content1\rmulti line content2\r"
          send "\x04"
            expect "doesn't show the input"
            send "hidden prompt content\r"
            expect "a simple line prompt"
            send "simple prompt content\r"
            expect eof
        '')
      ];

      vars.generators.test-generate = {
        files.aamulti = {};
        files.hidden = {};
        files.line = {};
        prompts.aamulti.type = "multiline";
        prompts.hidden.type = "hidden";
        prompts.line.type = "line";
        script = ''
          cat "$prompts"/aamulti > "$out"/aamulti
          cat "$prompts"/hidden > "$out"/hidden
          cat "$prompts"/line > "$out"/line
        '';
      };

      vars.generators.test-in = {
        dependencies = [ "test-generate" ];
        files.output = {};
        prompts.output.type = "line";
        script = ''
          cat "$in"/test-generate/aamulti "$prompts"/output > "$out"/output
        '';
      };

    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.succeed("run-generate-vars")
    machine.succeed("grep -q 'multi line content1' /var/lib/vars/test-generate/aamulti")
    machine.succeed("grep -q 'hidden prompt content' /var/lib/vars/test-generate/hidden")
    machine.succeed("grep -q 'simple prompt content' /var/lib/vars/test-generate/line")

    machine.succeed("systemctl restart generate-vars")
    machine.succeed("grep -q 'multi line content1' /var/lib/vars/test-in/output")
  '';
}
