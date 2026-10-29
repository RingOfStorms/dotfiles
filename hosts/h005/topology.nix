# Hand-written part of fleet-edge's /topology diagram. Schema:
# flakes/fleet-edge/internal/topology/topology.go.
#
# Everything the inventory can derive is deliberately absent -- inventory
# hosts, container placement, public `via = edge` paths, tailnet membership
# and fleet-agent polling are merged in at render time. This file only
# carries what the inventory cannot know: physical gear, cabling, VLANs and
# the explanation shown next to the diagram.
#
# Sources for the facts below:
#   hosts/fleet.nix                roles, overlay/LAN IPs (state comes from the poll)
#   hosts/h005/_constants.nix      VLANs, static leases, WAN/trunk ports
#   hosts/h005/switch_readme.md    switch models, ports, trunk tagging
#   hosts/pikvm/*.md               both PiKVMs, ConnectPRO port mapping
#   hosts/oracle/o002/nginx.nix    public edge (proxies to :8443 upstreams)
#   hosts/h005/dns-records.nix     Bunny zone (o002 + headscale A records)
#
# A node id that is not an inventory host must never collide with a fleet
# host name (gp3 h001 h003 h004 h005 hass i001 joe juni lio o002 oren t) or
# with another node id: topology.Validate rejects both at startup, and it
# also rejects unknown hosts/zones, unresolved or self-looping links, and
# hubs that name a node the diagram doesn't place.
{ fleet, constants }:
let
  net = constants.network;
  lan = net.vlans.lan;
  mgmt = net.vlans.management;

  # Static DHCP reservation -> address, so labels can't drift from
  # _constants.nix. Throws instead of rendering a stale/blank address.
  lease =
    name:
    let
      hits = builtins.filter (l: l.name == name) net.staticLeases;
    in
    if hits == [ ] then
      throw "h005/topology.nix: no static lease named ${name} in _constants.nix"
    else
      (builtins.head hits).ip;

  # Hostless node: gear the fleet inventory doesn't track.
  gear = id: zone: kind: label: lines: {
    inherit
      id
      zone
      kind
      label
      lines
      ;
  };
  # Inventory host: label, icon, IPs, live state, metrics and container
  # chips are all derived, so only the placement is given.
  placed = zone: host: {
    inherit host zone;
  };
  wire = from: to: kind: label: {
    inherit
      from
      to
      kind
      label
      ;
  };
  note = title: text: {
    inherit title text;
  };
in
{
  width = 1800;

  # Anything the spec doesn't place lands here (a new fleet host shows up in
  # the LAN zone without editing this file).
  defaultZone = "lan";

  # TMREM printer: LAN only, no tailnet node, no fleet-agent.
  hide = [ "t" ];

  hubs = {
    # Coordination server: edges to every placed host with an overlay IP.
    tailnet = "headscale";
    # Public reverse proxy for `via = edge` routes (15, all on h001).
    edge = "o002";
    # No `via = router` route has a host (minecraft is unplaced), so there is
    # nothing to derive; claiming h005 here would draw an empty fan.
    router = "";
    # Where fleet-edge runs: poll edges to every host with a fleet-agent.
    dashboard = "h005";
  };

  rows = [
    {
      zones = [
        {
          id = "internet";
          label = "Internet";
          kind = "internet";
          flex = 1.0;
        }
        {
          id = "cloud";
          label = "Oracle Cloud (o002)";
          kind = "cloud";
          flex = 1.2;
        }
      ];
    }
    {
      zones = [
        {
          id = "home";
          label = "Router (h005)";
          kind = "home";
          flex = 1.2;
        }
        {
          id = "rack";
          label = "Rack";
          kind = "rack";
          flex = 2.4;
        }
      ];
    }
    {
      zones = [
        {
          id = "lan";
          label = "Home LAN · VLAN ${toString lan.id}";
          kind = "lan";
          flex = 1.0;
        }
        {
          id = "roaming";
          label = "Roaming laptops & workstations";
          kind = "roaming";
          flex = 1.25;
        }
      ];
    }
  ];

  nodes = [
    # ── WAN ─────────────────────────────────────────────────────────
    (gear "internet" "internet" "internet" "Internet" [ "ISP uplink" ])
    (gear "bunny" "internet" "dns" "Bunny DNS" [
      "authoritative zone"
      "${fleet.global.domain} · TTL 300"
    ])

    # ── Oracle Cloud (o002) ─────────────────────────────────────────
    (placed "cloud" "o002")
    (gear "headscale" "cloud" "mesh" "headscale" [
      "coordination server"
      "DERP region 999 (o002)"
      "net.${fleet.global.domain}"
    ])

    # ── Home router ─────────────────────────────────────────────────
    (gear "modem" "home" "modem" "Modem" [ "WAN -> ${net.wanInterface}" ])
    (placed "home" "h005")

    # ── Rack ────────────────────────────────────────────────────────
    (gear "sg3210x" "rack" "switch" "SG3210X-M2" [
      "Omada L2 · 8×2.5G + 2×10G"
      "mgmt ${lease "SG3210X-M2"} (VLAN ${toString mgmt.id})"
      "Tw1/0/8 tagged ${toString mgmt.id}+${toString lan.id}"
    ])
    (gear "sg1428pe" "rack" "switch" "TL-SG1428PE" [
      "Easy Smart PoE · flat"
      "VLAN ${toString lan.id} only · no STP"
      "Te1/0/10 · forced 1G"
    ])
    (placed "rack" "h001")
    (placed "rack" "h003")
    (placed "rack" "h004")
    (gear "connectpro" "rack" "kvm" "ConnectPRO KVM" [
      "4-port USB + DP switch"
      "1:h001 2:h005 3:h003"
      "4:h004"
    ])
    (gear "fleetkvm" "rack" "kvm" "fleetkvm (V4 Plus)" [
      "ConnectPRO console"
      "DP -> HDMI capture"
      "setup incomplete · no tailnet yet"
    ])
    (gear "pikvm" "rack" "kvm" "pikvm (V4 Mini)" [
      "tailnet 100.64.0.16 · #16"
      "USB/HDMI target not recorded"
    ])
    (gear "apc1" "rack" "ups" "UPS 1 · APC XS 1500M" [
      "USB -> h005 (NUT)"
      "remote: h001, h004"
    ])
    (gear "apc2" "rack" "ups" "UPS 2 · APC XS 1500M" [
      "USB -> h005 (NUT)"
      "remote: h001, h004"
    ])

    # ── Home LAN (VLAN 20) ──────────────────────────────────────────
    # Home Assistant: a wired LAN appliance whose shelf position isn't
    # recorded, so it sits with the home gear rather than in the rack.
    (placed "lan" "hass")
    (gear "ap-rax70" "lan" "ap" "RAX70" [
      "AP / wifi router"
      "${lease "RAX70"} (reservation)"
      "switch cabling not recorded"
    ])
    (gear "ap-axt1800" "lan" "ap" "AXT1800" [
      "AP / travel router"
      "${lease "AXT1800"} (reservation)"
      "switch cabling not recorded"
    ])

    # ── Roaming ─────────────────────────────────────────────────────
    (placed "roaming" "lio")
    (placed "roaming" "juni")
    (placed "roaming" "gp3")
    (placed "roaming" "oren")
    (placed "roaming" "i001")
    (placed "roaming" "joe")
  ];

  links = [
    # ── Physical ────────────────────────────────────────────────────
    (wire "internet" "modem" "wan" "ISP")
    (wire "modem" "h005" "wan" "${net.wanInterface}")
    (wire "h005" "sg3210x" "trunk" "${net.trunkInterface} ↔ Tw1/0/8 · tagged ${toString mgmt.id}+${toString lan.id}")
    (wire "sg3210x" "sg1428pe" "ethernet" "Te1/0/10 SFP+ DAC · VLAN ${toString lan.id}")

    # KVM cabling (hosts/pikvm/fleetkvm_v4plus.md): ConnectPRO ports 1-4.
    (wire "connectpro" "h001" "kvm" "port 1")
    (wire "connectpro" "h005" "kvm" "port 2")
    (wire "connectpro" "h003" "kvm" "port 3")
    (wire "connectpro" "h004" "kvm" "port 4")
    (wire "connectpro" "fleetkvm" "kvm" "console -> HDMI")

    (wire "apc1" "h005" "power" "USB (NUT)")
    (wire "apc2" "h005" "power" "USB (NUT)")

    # ── Tailnet (membership only; the rest is derived from the inventory) ──
    (wire "headscale" "pikvm" "tailnet" "node 16 · untagged josh")

    # ── Public paths (o002 -> h001 is derived from `via = edge`) ────
    (wire "internet" "o002" "public" "https :443 · o002.${fleet.global.domain}")
    (wire "internet" "headscale" "public" "https :443 · DERP 3478/udp")

    # ── Control ─────────────────────────────────────────────────────
    (wire "h005" "bunny" "control" "dns-plan push (Bunny API)")
    (wire "h005" "o002" "control" "vhost + override push (ssh)")
  ];

  notes = [
    (note "Declared, not discovered" ''
      Every fleet host in this diagram is one NixOS configuration in one
      flake; a deploy builds that closure and copies it over the tailnet.
      Containers are declared per service, so names, placement and chips are
      read from the repo rather than from a scan. Switches, APs, KVM gear and
      UPSes are not fleet hosts and have no such configuration, so they are
      hand-declared here with whatever the repo actually records about them.
    '')
    (note "Poll, not push" ''
      fleet-edge on h005 polls each host's fleet-agent at
      http://<overlayIp>:9101/status.json every 30 seconds. Agents never push
      and hold no dashboard credentials, so a stopped dashboard costs no
      agent anything. CPU, memory and uptime in a box come from that poll;
      grey "not polled" means no agent, and hand-declared gear has no live
      state at all.
    '')
    (note "Tailnet = membership and policy, not a relay" ''
      The purple fan from headscale is key distribution, MagicDNS and ACL
      policy. Data between tailnet nodes is WireGuard end to end -- direct
      when NAT allows, through o002's embedded DERP when it doesn't -- and
      never transits the dashboard. The roaming machines keep their overlay
      address anywhere; the home LAN is only one of their paths.
    '')
    (note "Public path" ''
      Internet -> o002, whose names live in the Bunny zone (A records o002
      and headscale, wildcard CNAMEs to o002) -> o002's nginx terminates TLS
      and proxies to the service host's :8443 edge listener over the
      tailnet. headscale.<domain> is the exception that lands on headscale
      itself. The amber o002 -> h001 edges are the declared public routes.
    '')
    (note "Declared routing is not proof of reachability" ''
      Public edges are derived from route declarations, so one is drawn even
      while its container is stopped: the chip dot carries the real state.
      The zone still declares a minecraft -> home CNAME, but minecraft:game
      has via = router and no host, so nothing forwards the port and no
      port-forward edge exists. That is why Router is left without a hub
      node.
    '')
    (note "Two VLANs, one trunk" ''
      ${net.trunkInterface} ↔ Tw1/0/8 is the only tagged trunk, carrying
      VLAN ${toString mgmt.id} (management, ${mgmt.ipv4}/${toString mgmt.ipv4Prefix})
      and VLAN ${toString lan.id} (lan, ${lan.ipv4}/${toString lan.ipv4Prefix},
      DHCP and DNS on h005). The core switch's own management address sits on
      VLAN ${toString mgmt.id} and no untagged access port exists for it, so
      management is reachable only through h005. TL-SG1428PE is factory-flat:
      it extends VLAN ${toString lan.id} only, untagged, without STP.
    '')
    (note "Container placement" ''
      Chips are the containers the repo declares on that host, read from the
      inventory -- never inferred from what happens to be running. A host
      declared as a container host with services shows them; one declared
      with none shows no chips and is not an error. The chip dot is the
      polled state; the left stripe is exposure (public > lan > tailnet >
      local).
    '')
    (note "KVM, UPS, and what isn't recorded" ''
      fleetkvm drives a ConnectPRO 4-port KVM (1 h001, 2 h005, 3 h003,
      4 h004). Its PiKVM image is still being set up, so it is not on the
      tailnet yet. pikvm is on the tailnet as an untagged node but its
      USB/HDMI target is not recorded anywhere in the repo. Both APC XS
      1500M UPSes talk to h005 over USB and shut h001 and h004 down on
      battery. Nothing in the repo records which switch port -- or which
      switch -- each AP and rack host is wired to, so no access cable is
      drawn: a DHCP reservation proves a subnet, not an ethernet endpoint.
      Only the h005 trunk and the switch-to-switch link are recorded and
      drawn.
    '')
  ];
}
