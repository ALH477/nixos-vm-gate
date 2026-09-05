{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.demod.vmGate;

  guestPath = lib.makeBinPath (
    with pkgs;
    [
      coreutils
      systemd
      util-linux
    ]
  );

  mkCheck =
    name: text:
    let
      safeName = lib.strings.sanitizeDerivationName name;
      package =
        if cfg.lintChecks then
          pkgs.writeShellApplication {
            name = "vm-gate-check-${safeName}";
            runtimeInputs = cfg.checkPath;
            inherit text;
          }
        else
          pkgs.writeShellScriptBin "vm-gate-check-${safeName}" ''
            set -euo pipefail
            export PATH="${lib.makeBinPath cfg.checkPath}:$PATH"
            ${text}
          '';
    in
    {
      inherit name package;
      exe = lib.getExe' package "vm-gate-check-${safeName}";
    };

  checks = lib.mapAttrsToList mkCheck cfg.checks;

  # Each check is bounded so one hung check cannot consume the host's whole
  # timeout budget and turn a clear failure into an ambiguous one.
  checkRunner = pkgs.writeShellScript "vm-gate-checks" ''
    status=0
    ${lib.concatMapStringsSep "\n" (c: ''
      echo "vm-gate: check '${c.name}'"
      if ! ${pkgs.coreutils}/bin/timeout -k 5 ${toString cfg.checkTimeout} ${c.exe}; then
        echo "vm-gate: check '${c.name}' FAILED"
        status=1
      fi
    '') checks}
    exit "$status"
  '';

  subst =
    replacements: file:
    builtins.replaceStrings (map (k: "@${k}@") (
      builtins.attrNames replacements
    )) (builtins.attrValues replacements) (builtins.readFile file);

  guestHarness = pkgs.writeShellScript "vm-gate-guest" (
    subst {
      path = guestPath;
      activation = cfg.activation;
      requireRunning = if cfg.requireSystemRunning then "1" else "0";
      journal = cfg.journal;
      checkRunner = "${checkRunner}";
    } ./vm-gate-guest.sh
  );

  activateHelper = pkgs.writeShellScriptBin "vm-gate-activate" (
    subst {
      coreutils = "${pkgs.coreutils}/bin";
      nixEnv = "${config.nix.package}/bin/nix-env";
      nixStore = "${config.nix.package}/bin/nix-store";
    } ./vm-gate-activate.sh
  );

  wrapper = pkgs.writeShellScriptBin "nixos-rebuild-gated" (
    subst {
      coreutils = "${pkgs.coreutils}/bin";
      utilLinux = "${pkgs.util-linux}/bin";
      env = "${pkgs.coreutils}/bin/env";
      runuser = "${pkgs.util-linux}/bin/runuser";
      nix = "${config.nix.package}/bin/nix";
      nixStore = "${config.nix.package}/bin/nix-store";
      jq = "${pkgs.jq}/bin/jq";
      activate = lib.getExe activateHelper;
      flake = cfg.flake;
      host = cfg.hostName;
      timeout = toString cfg.timeout;
      useBootLoader = if cfg.useBootLoader then "1" else "0";
      vmAttr = if cfg.useBootLoader then "vmWithBootLoader" else "vm";
      gateUser = cfg.user;
      logDir = cfg.logDir;
      stateDir = cfg.stateDir;
      keepRuns = toString cfg.keepRuns;
      allowOverride = if cfg.allowOverride then "1" else "0";
      showDiff = if cfg.showDiff then "1" else "0";
    } ./nixos-rebuild-gated.sh
  );

  # Applied only to the VM build of this system, never to the real one.
  gateVmModule =
    { lib, ... }:
    {
      virtualisation = {
        graphics = false;
        memorySize = cfg.memorySize;
        cores = cfg.cores;
        diskSize = lib.mkDefault cfg.diskSize;

        # Ephemeral tmpfs root. Not valid in bootloader mode, where a real
        # image is required and the host supplies one via $NIX_DISK_IMAGE.
        diskImage = lib.mkIf (!cfg.useBootLoader) null;

        # Boot the way the host actually boots, or the test is about a boot
        # path nobody uses.
        useEFIBoot = lib.mkIf cfg.useBootLoader (
          lib.mkDefault (config.boot.loader.systemd-boot.enable || config.boot.loader.grub.efiSupport)
        );

        # The gate runs code from every flake input. Deny it the network
        # unless a check genuinely needs it.
        restrictNetwork = lib.mkDefault (!cfg.network);

        sharedDirectories.vmgate = {
          source = "$VM_GATE_DIR";
          target = "/vmgate";
        };
      };

      # Bound each unit so a hung one fails fast instead of eating the host's
      # whole timeout and reporting as "no verdict".
      systemd.extraConfig = "DefaultTimeoutStartSec=${toString cfg.unitStartTimeout}s";

      systemd.services.vm-gate = {
        description = "vm-gate health checks";
        wantedBy = [ "multi-user.target" ];
        after = [ "multi-user.target" ];
        serviceConfig = {
          # Type=simple on purpose: a oneshot stays a pending job, and
          # `systemctl is-system-running --wait` would deadlock against it.
          Type = "simple";
          # The harness runs in a transient scope so that an activation phase
          # which stops units cannot kill the harness reporting on it.
          ExecStart = pkgs.writeShellScript "vm-gate-launch" ''
            exec ${pkgs.systemd}/bin/systemd-run --scope --collect --quiet \
              --unit=vm-gate-worker ${guestHarness} \
              || exec ${guestHarness}
          '';
          StandardOutput = "journal+console";
          StandardError = "journal+console";
        };
      };
    };
in
{
  options.demod.vmGate = {
    enable = lib.mkEnableOption "gating activation behind a throwaway VM boot of the candidate generation";

    flake = lib.mkOption {
      type = lib.types.str;
      default = "/etc/nixos";
      description = "Default flake reference the wrapper builds from.";
    };

    hostName = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      defaultText = lib.literalExpression "config.networking.hostName";
      description = ''
        Attribute under `nixosConfigurations` to build. This is the flake
        attribute name, which is not always the machine's hostname; when it is
        wrong the wrapper fails and lists the attributes the flake does define.
      '';
    };

    allowOverride = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Permit `--flake` and `--host` at the command line. Set false to pin the
        wrapper to one configuration. This narrows the blast radius but does not
        make the wrapper safe to grant through sudo: see SECURITY.md.
      '';
    };

    timeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 600;
      description = "Wall-clock seconds the gate VM gets before it is terminated.";
    };

    unitStartTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = "DefaultTimeoutStartSec inside the gate VM.";
    };

    checkTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = "Seconds each individual health check may run for.";
    };

    memorySize = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4096;
      description = ''
        Gate VM RAM in MiB. Outside bootloader mode the guest root and the
        writable store overlay are both tmpfs, so activation writes are charged
        against this number, not against disk.
      '';
    };

    diskSize = lib.mkOption {
      type = lib.types.ints.positive;
      default = 8192;
      description = "Scratch disk size in MiB. Only used in bootloader mode.";
    };

    cores = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Gate VM vCPU count.";
    };

    useBootLoader = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Boot the gate VM through the real bootloader instead of QEMU's direct
        kernel boot. Slower and needs a scratch image, but it is the only way
        this catches a generation that installs a bootloader which will not
        come back up.
      '';
    };

    network = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Give the gate VM outbound network access. Off by default; enable only if a health check needs it.";
    };

    activation = lib.mkOption {
      type = lib.types.enum [
        "none"
        "reactivate"
        "from-current"
      ];
      default = "reactivate";
      description = ''
        What the VM does beyond a cold boot.

        `none`: boot only.

        `reactivate`: re-run `switch-to-configuration test` against the live
        VM. Catches activation scripts and units that work at boot but break
        when re-run against a running system. It cannot catch old-to-new unit
        diffs, because both sides are the same generation.

        `from-current`: rewind the VM to the host's current generation, then
        switch forward to the candidate, which reproduces the transition the
        host is about to perform. Experimental. The rewind is best-effort and
        non-gating: the old generation references real disks, so its mount
        units will fail inside the VM. Expect to need `extraVmConfig` tuning.
      '';
    };

    requireSystemRunning = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Treat a degraded systemd state in the gate VM as a gate failure.";
    };

    journal = lib.mkOption {
      type = lib.types.enum [
        "on-failure"
        "always"
        "never"
      ];
      default = "on-failure";
      description = "When to copy the guest's boot journal out. It is a full log of the candidate generation, so it is retained only on failure by default.";
    };

    checks = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = { };
      example = lib.literalExpression ''
        {
          audio = "systemctl is-active pipewire.service";
          web   = "curl -fsS --max-time 5 http://localhost/health >/dev/null";
        }
      '';
      description = ''
        Shell fragments run inside the gate VM after activation, in attribute
        name order. A non-zero exit fails the gate.

        These land world-readable in the Nix store. Read any credential from a
        runtime path inside the VM rather than inlining it here.
      '';
    };

    checkPath = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = with pkgs; [
        coreutils
        systemd
        curl
      ];
      defaultText = lib.literalExpression "[ pkgs.coreutils pkgs.systemd pkgs.curl ]";
      description = "Packages on PATH for the check fragments.";
    };

    lintChecks = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Build checks with `writeShellApplication`, which shellchecks them at
        build time. This is usually what you want, but a shellcheck finding in
        a check then fails evaluation of the whole system; set false to drop
        the lint and keep `set -euo pipefail`.
      '';
    };

    extraVmConfig = lib.mkOption {
      type = lib.types.deferredModule;
      default = { };
      example = lib.literalExpression ''
        { lib, ... }: {
          services.my-hardware-daemon.enable = false;
          systemd.services.sops-nix.enable = false;
        }
      '';
      description = "Config applied only to the gate VM. Stub out anything needing real hardware, host keys or secrets.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "vm-gate";
      description = "Unprivileged account the gate VM runs as when the wrapper is invoked by root.";
    };

    createUser = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Create the gate user and its kvm group membership.";
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/vm-gate";
      description = "Scratch space for gate runs. Disk-backed on purpose: /tmp is tmpfs on NixOS.";
    };

    logDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/log/vm-gate";
      description = "Where failure diagnostics are kept. Mode 0700, root-owned.";
    };

    keepRuns = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5;
      description = "How many failed runs' diagnostics to retain before pruning the oldest.";
    };

    showDiff = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Print a closure diff against the running system before gating.";
    };

    installWrapper = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Add the wrapper to environment.systemPackages.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = wrapper;
      defaultText = "the generated nixos-rebuild-gated wrapper";
      description = "The generated wrapper, for aliases or CI.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.system.switch.enable or true;
        message = "demod.vmGate activates via switch-to-configuration, which system.switch.enable = false removes.";
      }
      {
        assertion = cfg.memorySize >= 1024;
        message = "demod.vmGate.memorySize below 1024 MiB will not boot a NixOS guest with a tmpfs root.";
      }
    ];

    warnings =
      lib.optional (!cfg.useBootLoader && cfg.memorySize < 3072)
        "demod.vmGate: with a tmpfs guest root, ${toString cfg.memorySize} MiB may run out during activation. 4096 is the tested default."
      ++
        lib.optional (cfg.activation == "from-current")
          "demod.vmGate.activation = \"from-current\" is experimental; the rewind phase will report mount failures for the host's real disks.";

    virtualisation.vmVariant = lib.mkIf (!cfg.useBootLoader) {
      imports = [
        gateVmModule
        cfg.extraVmConfig
      ];
    };

    virtualisation.vmVariantWithBootLoader = lib.mkIf cfg.useBootLoader {
      imports = [
        gateVmModule
        cfg.extraVmConfig
      ];
    };

    users.users = lib.mkIf cfg.createUser {
      ${cfg.user} = {
        isSystemUser = true;
        group = cfg.user;
        description = "vm-gate sandbox";
        home = cfg.stateDir;
        extraGroups = [ "kvm" ];
      };
    };
    users.groups = lib.mkIf cfg.createUser { ${cfg.user} = { }; };

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 ${cfg.user} ${cfg.user} -"
      "d ${cfg.logDir} 0700 root root -"
    ];

    environment.systemPackages = lib.mkIf cfg.installWrapper [ wrapper ];
  };
}
