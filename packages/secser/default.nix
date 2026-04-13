{ lib, buildGoModule }:

buildGoModule {
  pname = "secser";
  version = "0.1.0";

  src = ./.;

  vendorHash = null;

  meta = with lib; {
    description = "A local service for safely persisting Nix build side-effects as secrets";
    license = licenses.mit;
    maintainers = [ ];
  };
}
