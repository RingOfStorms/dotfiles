# Hand-written part of fleet-edge's /topology atlas. Schema:
# flakes/fleet-edge/internal/topology/topology.go.
#
# Everything the inventory can derive is deliberately absent -- inventory
# hosts, container placement, public and tailnet routes, DNS ownership,
# tailnet membership and fleet-agent polling are merged in at render time.
# This file only carries what the inventory cannot know: physical gear,
# recorded cabling, VLANs, the plain-language role of each box, and the column
# layout. Explaining the map belongs in the README, not in the spec.
#
# Sources for the facts below:
#   hosts/h005/_constants.nix      VLANs, static leases, WAN/trunk ports
#   hosts/h005/switch_readme.md    switch models, ports, trunk tagging
#   hosts/pikvm/*.md               both PiKVMs, ConnectPRO port mapping
#   hosts/oracle/o002/nginx.nix    public edge (proxies to :8443 upstreams)
#   hosts/h005/dns-records.nix     public zone (single source: imported below)
#
# The map is vertical: the first column is everything outside the house
# (cloud hubs and the two derived name clouds), the second is the physical
# rack, the third is the rest of the house. The rack is ONE box because it is
# one enclosure: the modem and h005 share a shelf with the switches.
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
  domain = fleet.global.domain;

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

  # The job of each kind of gear, in plain language. A station shows its name
  # and this line; the full record lives in the sidebar and in the
  # downloadable SVG, which is the point of a fixed-size station.
  roles = {
    dns = "authoritative DNS";
    cloud = "public edge";
    modem = "WAN modem";
    switch = "switch";
    kvm = "KVM console";
    ups = "battery backup";
    ap = "wifi access point";
    device = "device";
  };

  # Membership badges: short, descriptive, never derived from them.
  vlanBadges = toString lan.id;
  mgmtBadge = "VLAN ${toString mgmt.id}";

  # Hostless node: gear the fleet inventory doesn't track. `extra` overrides
  # the kind's role, adds badges, and turns the station into a segment bar.
  gearWith =
    id: zone: kind: label: lines: extra:
    {
      inherit
        id
        zone
        kind
        label
        lines
        ;
      role = if extra ? role then extra.role else (roles.${kind} or "device");
      badges = extra.badges or [ ];
      segment = extra.segment or false;
    };
  gear = id: zone: kind: label: lines: gearWith id zone kind label lines { };

  # Inventory host: label, icon, IPs, live state, station counts, tailnet mark
  # and the whole drilldown are derived, so only placement, role and badges are
  # given. `badges` describes where it sits, not what it runs.
  placedWith =
    zone: host: extra:
    {
      inherit host zone;
      role = extra.role or "";
      badges = extra.badges or [ "VLAN ${vlanBadges}" ];
    };
  placed = zone: host: placedWith zone host { };

  # A LAN attachment whose switch and port were never recorded: a real
  # attachment drawn dashed, claiming no cable and no port.
  lanWire = host: wire "fabric" host "lan" "switch/port not recorded";
  # The other end of the same segment: a switch that carries VLAN lan. This
  # is the logical L2 fabric, not a cable — the recorded switch-to-switch
  # link above stays the only claim about wiring between them.
  fabricWire =
    sw: wire sw "fabric" "lan" "VLAN ${toString lan.id} shared fabric";
  wire = from: to: kind: label: {
    inherit
      from
      to
      kind
      label
      ;
  };
in
{
  width = 1500;

  # The route columns must fit the whole public zone; a taller minimum only
  # stretches the regions that ask to share the leftover height.
  height = 1000;

  # Anything the spec doesn't place lands here (a new fleet host shows up in
  # the house without editing this file).
  defaultZone = "lan";

  # TMREM printer: LAN only, no tailnet node, no fleet-agent.
  hide = [ "t" ];

  hubs = {
    # Coordination server: the tailnet shows as a station tag and a journey,
    # never as a permanent fan across the map.
    tailnet = "";
    # Public reverse proxy for `via = edge` routes: the public cloud's
    # collector leads into this node.
    edge = "o002";
    # No `via = router` route has a host (minecraft is unplaced), so there is
    # nothing to derive; claiming h005 here would invent a path.
    router = "";
    # Where fleet-edge runs: poll lines to every host with a fleet-agent.
    dashboard = "h005";
  };

  # The public zone has exactly one source: the records the edge actually
  # serves. The route clouds mark which of these names a declared route owns.
  dns = (import ./dns-records.nix { inherit fleet; }).publicSpec;

  columns = [
    # ── Outside: the cloud hubs, then the two derived name clouds ────
    {
      id = "outside";
      label = "Outside";
      flex = 0.9;
      zones = [
        {
          id = "cloud";
          label = "Oracle Cloud (o002)";
          kind = "cloud";
          flex = 1.0;
        }
        {
          # One marker per public FQDN, bundled into the edge hub. Names the
          # zone declares without a route stay faint and unowned.
          id = "public";
          label = "Public names · ${domain}";
          kind = "cloud";
          layout = "routes";
          group = "public";
          flex = 2.4;
        }
        {
          # One marker per overlay-only name, bundled into one trunk that
          # branches once per owning host.
          id = "overlay";
          label = "Overlay names";
          kind = "tailnet";
          layout = "routes";
          group = "overlay";
          flex = 1.2;
        }
        {
          id = "dns";
          label = "Authoritative DNS";
          kind = "internet";
          flex = 1.0;
        }
      ];
    }

    # ── The rack: one enclosure, one region, listed in rack order ────
    {
      id = "rackband";
      label = "Rack";
      flex = 1.35;
      zones = [
        {
          id = "rack";
          label = "Rack · modem, router, switches, servers, console, UPS";
          kind = "rack";
          box = true;
          # Two columns read down the first, then the next: rack order stays
          # vertical and the enclosure keeps its place in the width.
          layout = "flow";
          cols = 2;
          fill = "column";
          flex = 1.0;
        }
      ];
    }

    # ── The rest of the house ───────────────────────────────────────
    {
      id = "house";
      label = "Home";
      flex = 1.0;
      zones = [
        {
          id = "lan";
          label = "Home LAN · VLAN ${toString lan.id}";
          kind = "lan";
          flex = 1.6;
        }
        {
          id = "roaming";
          label = "Roaming laptops & workstations";
          kind = "roaming";
          flex = 1.0;
        }
      ];
    }
  ];

  nodes = [
    # ── Oracle Cloud (o002) ─────────────────────────────────────────
    (placedWith "cloud" "o002" {
      badges = [ "public :443" ];
    })

    # ── Authoritative DNS ───────────────────────────────────────────
    (gearWith "bunny" "dns" "dns" "Bunny DNS" [
      "authoritative zone"
      "${domain} · TTL 300"
    ] { })

    # ── Rack, in rack order (top to bottom) ─────────────────────────
    # The modem and the router share the rack with the switches: the box is
    # the enclosure, not "the servers".
    (gear "modem" "rack" "modem" "Modem" [ "WAN -> ${net.wanInterface}" ])
    (placedWith "rack" "h005" {
      role = "router · dashboard";
      badges = [
        "VLAN ${vlanBadges}"
        mgmtBadge
      ];
    })
    (gearWith "sg3210x" "rack" "switch" "SG3210X-M2" [
      "Omada L2 · 8×2.5G + 2×10G"
      "mgmt ${lease "SG3210X-M2"} (${mgmtBadge})"
      "Tw1/0/8 tagged ${toString mgmt.id}+${toString lan.id}"
    ] {
      role = "core switch";
      badges = [
        "VLAN ${vlanBadges}"
        mgmtBadge
      ];
    })
    (gearWith "sg1428pe" "rack" "switch" "TL-SG1428PE" [
      "Easy Smart PoE · flat"
      "VLAN ${vlanBadges} only · no STP"
      "Te1/0/10 · forced 1G"
    ] { role = "PoE switch"; })
    (placed "rack" "h001")
    (placed "rack" "h003")
    (placed "rack" "h004")
    (gearWith "connectpro" "rack" "kvm" "ConnectPRO KVM" [
      "4-port USB + DP switch"
      "1:h001 2:h005 3:h003"
      "4:h004"
    ] { role = "KVM switch"; })
    (gearWith "fleetkvm" "rack" "kvm" "fleetkvm (V4 Plus)" [
      "ConnectPRO console"
      "DP -> HDMI capture"
      "setup incomplete · no tailnet yet"
    ] { role = "PiKVM console"; })
    (gearWith "pikvm" "rack" "kvm" "pikvm (V4 Mini)" [
      "tailnet 100.64.0.16 · #16"
      "USB/HDMI target not recorded"
    ] {
      role = "PiKVM console";
      badges = [ "tailnet" ];
    })
    (gearWith "apc1" "rack" "ups" "UPS 1 · APC XS 1500M" [
      "USB -> h005 (NUT)"
      "remote: h001, h004"
    ] { })
    (gearWith "apc2" "rack" "ups" "UPS 2 · APC XS 1500M" [
      "USB -> h005 (NUT)"
      "remote: h001, h004"
    ] { })

    # ── Home LAN (VLAN 20) ──────────────────────────────────────────
    # The only thing the repo records about LAN wiring is that these hosts
    # are on the LAN: no switch port, no port number. The fabric bar stands
    # for that neutral attachment so no invented cable is drawn.
    (gearWith "fabric" "lan" "device" "LAN attachment" [
      "switch and port not recorded"
      "dashed = on the LAN, cable unknown"
    ] { role = "LAN segment"; segment = true; })
    (placed "lan" "hass")
    (gearWith "ap-rax70" "lan" "ap" "RAX70" [
      "AP / wifi router"
      "${lease "RAX70"} (reservation)"
      "switch cabling not recorded"
    ] { role = "wifi router"; })
    (gearWith "ap-axt1800" "lan" "ap" "AXT1800" [
      "AP / travel router"
      "${lease "AXT1800"} (reservation)"
      "switch cabling not recorded"
    ] { role = "travel router"; })

    # ── Roaming ─────────────────────────────────────────────────────
    (placedWith "roaming" "lio" { badges = [ ]; })
    (placedWith "roaming" "juni" { badges = [ ]; })
    (placedWith "roaming" "gp3" { badges = [ ]; })
    (placedWith "roaming" "oren" { badges = [ ]; })
    (placedWith "roaming" "i001" { badges = [ ]; })
    (placedWith "roaming" "joe" { badges = [ ]; })
  ];

  links = [
    # ── Physical, recorded cabling only ─────────────────────────────
    (wire "modem" "h005" "wan" "${net.wanInterface}")
    (wire "h005" "sg3210x" "trunk" "${net.trunkInterface} ↔ Tw1/0/8 · tagged ${toString mgmt.id}+${toString lan.id}")
    (wire "sg3210x" "sg1428pe" "ethernet" "Te1/0/10 SFP+ DAC · VLAN ${toString lan.id}")

    # The LAN segment's other end. Both switches carry VLAN lan, so the
    # fabric is a shared L2 segment they attach to -- that is what makes the
    # chain modem -> h005 -> switch -> fabric -> server readable. It claims no
    # cable and no port: the one recorded cable between the switches stays
    # the Te1/0/10 line above.
    (fabricWire "sg3210x")
    (fabricWire "sg1428pe")

    # LAN attachment (dashed): these boxes are on the LAN, but which switch
    # port -- or which switch -- carries each one is nowhere in the repo, so
    # the link claims a subnet and nothing more.
    (lanWire "h001")
    (lanWire "h003")
    (lanWire "h004")
    (lanWire "hass")
    (lanWire "ap-rax70")
    (lanWire "ap-axt1800")

    # KVM cabling (hosts/pikvm/fleetkvm_v4plus.md): ConnectPRO ports 1-4.
    (wire "connectpro" "h001" "kvm" "port 1")
    (wire "connectpro" "h005" "kvm" "port 2")
    (wire "connectpro" "h003" "kvm" "port 3")
    (wire "connectpro" "h004" "kvm" "port 4")
    (wire "connectpro" "fleetkvm" "kvm" "console -> HDMI")

    (wire "apc1" "h005" "power" "USB (NUT)")
    (wire "apc2" "h005" "power" "USB (NUT)")

    # ── Control ─────────────────────────────────────────────────────
    (wire "h005" "bunny" "control" "dns-plan push (Bunny API)")
    (wire "h005" "o002" "control" "vhost + override push (ssh)")
  ];
}
