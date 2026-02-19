{
  description = "dwight.nvim development environment";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };
  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        buildInputs = with pkgs; [
          lua
          lua-language-server
          stylua
          marksman
        ];
        shellHook = ''
          echo "Welcome to dwight.nvim"
          if [ -z "$TMUX" ]; then
            exec tmux new-session -A -s dwight.nvim
          fi
        '';
      };
    };
}
