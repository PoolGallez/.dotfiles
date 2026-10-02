# VM/sniffing tooling for hosts that actually do virtualization work
# (currently just getriebe, alongside its own libvirtd/virt-manager setup
# in hosts/getriebe/configuration.nix). Pulled out of the old comms.nix
# grab-bag, which forced these onto every desktop host regardless of need.
{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    qemu
    quickemu
    libpcap
  ];
}
